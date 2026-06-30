#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "numpy>=1.26",
#   "pyproj>=3.6",
#   "rasterio>=1.3",
# ]
# ///
"""Export a DEM GeoTIFF as a simple 3D Tiles 1.1 terrain mesh.

The output is intended for visual inspection in Cesium, not as a replacement for
Cesium quantized-mesh terrain. It builds one GLB mesh from the DEM, places it in
an east-north-up tile frame, and writes a tileset.json that references the GLB.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import rasterio
from pyproj import Transformer
from rasterio.transform import xy as raster_xy

WGS84 = "EPSG:4326"
ECEF = "EPSG:4978"
DEFAULT_INPUT = Path("data/dem/copernicus-dem-glo30-huaguoshan_epsg32650.tif")
DEFAULT_OUTPUT = Path("exports/terrain/huaguoshan_dem_3dtiles")


@dataclass(frozen=True)
class MeshData:
    positions_gltf: np.ndarray
    indices: np.ndarray
    transform: list[float]
    region: list[float]
    geometric_error: float
    vertex_count: int
    triangle_count: int
    elevation_min: float
    elevation_max: float
    elevation_mean: float


def parse_color(value: str) -> tuple[float, float, float]:
    raw = value.strip()
    if raw.startswith("#"):
        raw = raw[1:]
    if len(raw) != 6:
        raise argparse.ArgumentTypeError("color must be a #RRGGBB hex value")
    try:
        return tuple(int(raw[i : i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("color must be a #RRGGBB hex value") from exc


def pad4(data: bytes) -> bytes:
    return data + (b"\x00" * ((4 - len(data) % 4) % 4))


def pad_json(data: bytes) -> bytes:
    # GLB JSON chunks must be padded with ASCII spaces. Padding with NUL bytes
    # makes some glTF parsers pass the padding through to JSON.parse(), causing
    # errors like "Unexpected non-whitespace character after JSON".
    return data + (b" " * ((4 - len(data) % 4) % 4))


def enu_axes(lon_rad: float, lat_rad: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    sin_lon, cos_lon = math.sin(lon_rad), math.cos(lon_rad)
    sin_lat, cos_lat = math.sin(lat_rad), math.cos(lat_rad)
    east = np.array([-sin_lon, cos_lon, 0.0], dtype=np.float64)
    north = np.array([-sin_lat * cos_lon, -sin_lat * sin_lon, cos_lat], dtype=np.float64)
    up = np.array([cos_lat * cos_lon, cos_lat * sin_lon, sin_lat], dtype=np.float64)
    return east, north, up


def make_tile_transform(
    center_ecef: np.ndarray,
    east: np.ndarray,
    north: np.ndarray,
    up: np.ndarray,
) -> list[float]:
    # 3D Tiles matrices are column-major. The tile coordinate frame is z-up:
    # x=east, y=north, z=up. The glTF content itself remains y-up and Cesium
    # converts it to z-up before applying this tile transform.
    return [
        float(east[0]), float(east[1]), float(east[2]), 0.0,
        float(north[0]), float(north[1]), float(north[2]), 0.0,
        float(up[0]), float(up[1]), float(up[2]), 0.0,
        float(center_ecef[0]), float(center_ecef[1]), float(center_ecef[2]), 1.0,
    ]


def build_mesh(input_path: Path, sample_step: int, z_offset: float) -> MeshData:
    if sample_step < 1:
        raise ValueError("sample_step must be >= 1")

    with rasterio.open(input_path) as src:
        if src.count < 1:
            raise ValueError(f"{input_path} has no raster bands")
        if src.crs is None:
            raise ValueError(f"{input_path} has no CRS")

        band = src.read(1, masked=True).astype("float64")
        rows = np.arange(0, src.height, sample_step, dtype=np.int32)
        cols = np.arange(0, src.width, sample_step, dtype=np.int32)
        sampled = band[np.ix_(rows, cols)]
        valid = ~np.ma.getmaskarray(sampled)
        if not np.any(valid):
            raise ValueError("DEM contains no valid cells at the requested sample step")

        elevations = np.asarray(sampled.filled(np.nan), dtype=np.float64) + z_offset
        valid_elevations = elevations[valid]

        xs_1d, _ = raster_xy(src.transform, np.zeros_like(cols), cols, offset="center")
        _, ys_1d = raster_xy(src.transform, rows, np.zeros_like(rows), offset="center")
        xs = np.asarray(xs_1d, dtype=np.float64)
        ys = np.asarray(ys_1d, dtype=np.float64)
        grid_x, grid_y = np.meshgrid(xs, ys)

        # Center on the valid DEM footprint to keep GLB coordinates small.
        center_x = float(np.nanmean(grid_x[valid]))
        center_y = float(np.nanmean(grid_y[valid]))
        center_z = float(np.nanmean(valid_elevations))

        to_wgs84 = Transformer.from_crs(src.crs, WGS84, always_xy=True)
        to_ecef = Transformer.from_crs(src.crs, ECEF, always_xy=True)
        center_lon, center_lat = to_wgs84.transform(center_x, center_y)
        center_ecef = np.asarray(to_ecef.transform(center_x, center_y, center_z), dtype=np.float64)
        east, north, up = enu_axes(math.radians(center_lon), math.radians(center_lat))

        valid_x = grid_x[valid]
        valid_y = grid_y[valid]
        valid_z = elevations[valid]
        ecef_x, ecef_y, ecef_z = to_ecef.transform(valid_x, valid_y, valid_z)
        ecef = np.column_stack([ecef_x, ecef_y, ecef_z]).astype(np.float64)
        delta = ecef - center_ecef
        local_e = delta @ east
        local_n = delta @ north
        local_u = delta @ up

        # glTF is y-up. Cesium converts glTF y-up to the 3D Tiles z-up tile
        # frame as (x, y, z) -> (x, -z, y), so encode ENU as (E, U, -N).
        positions_gltf = np.column_stack([local_e, local_u, -local_n]).astype(np.float32)

        index_grid = np.full(valid.shape, -1, dtype=np.int64)
        index_grid[valid] = np.arange(positions_gltf.shape[0], dtype=np.int64)

        faces: list[tuple[int, int, int]] = []
        row_count, col_count = valid.shape
        for r in range(row_count - 1):
            for c in range(col_count - 1):
                v00 = int(index_grid[r, c])
                v10 = int(index_grid[r, c + 1])
                v01 = int(index_grid[r + 1, c])
                v11 = int(index_grid[r + 1, c + 1])
                if min(v00, v10, v01, v11) < 0:
                    continue
                faces.append((v00, v10, v01))
                faces.append((v10, v11, v01))

        if not faces:
            raise ValueError("sampled DEM produced no triangles")

        indices = np.asarray(faces, dtype=np.uint32).reshape(-1)

        bounds = src.bounds
        corner_x = [bounds.left, bounds.right, bounds.right, bounds.left]
        corner_y = [bounds.bottom, bounds.bottom, bounds.top, bounds.top]
        lon, lat = to_wgs84.transform(corner_x, corner_y)
        west, east_lon = min(lon), max(lon)
        south, north_lat = min(lat), max(lat)
        region = [
            math.radians(float(west)),
            math.radians(float(south)),
            math.radians(float(east_lon)),
            math.radians(float(north_lat)),
            float(np.nanmin(valid_elevations)),
            float(np.nanmax(valid_elevations)),
        ]

    return MeshData(
        positions_gltf=positions_gltf,
        indices=indices,
        transform=make_tile_transform(center_ecef, east, north, up),
        region=region,
        geometric_error=max(1.0, 30.0 * sample_step * 4.0),
        vertex_count=int(positions_gltf.shape[0]),
        triangle_count=int(indices.size // 3),
        elevation_min=float(np.nanmin(valid_elevations)),
        elevation_max=float(np.nanmax(valid_elevations)),
        elevation_mean=float(np.nanmean(valid_elevations)),
    )


def write_glb(path: Path, mesh: MeshData, color: tuple[float, float, float], alpha: float) -> None:
    positions = np.ascontiguousarray(mesh.positions_gltf, dtype="<f4")
    indices = np.ascontiguousarray(mesh.indices, dtype="<u4")

    position_bytes = positions.tobytes()
    index_offset = len(pad4(position_bytes))
    index_bytes = indices.tobytes()
    bin_blob = pad4(position_bytes) + pad4(index_bytes)

    gltf: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "scripts/export_dem_3dtiles.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{
            "primitives": [{
                "attributes": {"POSITION": 0},
                "indices": 1,
                "material": 0,
                "mode": 4,
            }]
        }],
        "materials": [{
            "name": "DEM translucent terrain",
            "doubleSided": True,
            "alphaMode": "BLEND" if alpha < 1.0 else "OPAQUE",
            "pbrMetallicRoughness": {
                "baseColorFactor": [float(color[0]), float(color[1]), float(color[2]), float(alpha)],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0,
            },
            "extensions": {"KHR_materials_unlit": {}},
        }],
        "buffers": [{"byteLength": len(bin_blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(position_bytes), "target": 34962},
            {"buffer": 0, "byteOffset": index_offset, "byteLength": len(index_bytes), "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "byteOffset": 0,
                "componentType": 5126,
                "count": int(positions.shape[0]),
                "type": "VEC3",
                "min": positions.min(axis=0).astype(float).tolist(),
                "max": positions.max(axis=0).astype(float).tolist(),
            },
            {
                "bufferView": 1,
                "byteOffset": 0,
                "componentType": 5125,
                "count": int(indices.size),
                "type": "SCALAR",
                "min": [int(indices.min())],
                "max": [int(indices.max())],
            },
        ],
    }

    json_blob = pad_json(json.dumps(gltf, separators=(",", ":")).encode("utf-8"))
    total_length = 12 + 8 + len(json_blob) + 8 + len(bin_blob)
    header = struct.pack("<III", 0x46546C67, 2, total_length)
    json_chunk_header = struct.pack("<II", len(json_blob), 0x4E4F534A)
    bin_chunk_header = struct.pack("<II", len(bin_blob), 0x004E4942)
    path.write_bytes(header + json_chunk_header + json_blob + bin_chunk_header + bin_blob)


def write_tileset(path: Path, mesh: MeshData) -> None:
    tileset = {
        "asset": {
            "version": "1.1",
            "generator": "scripts/export_dem_3dtiles.py",
        },
        "geometricError": mesh.geometric_error,
        "root": {
            "transform": mesh.transform,
            "boundingVolume": {"region": mesh.region},
            "geometricError": 0,
            "refine": "ADD",
            "content": {"uri": "content/dem_mesh.glb"},
        },
    }
    path.write_text(json.dumps(tileset, indent=2), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT, help="Input DEM GeoTIFF")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output 3D Tiles directory")
    parser.add_argument("--sample-step", type=int, default=1, help="Use every Nth DEM pixel")
    parser.add_argument("--z-offset", type=float, default=1.0, help="Vertical offset in metres to reduce z-fighting")
    parser.add_argument("--alpha", type=float, default=0.55, help="Material alpha in [0, 1]")
    parser.add_argument("--color", type=parse_color, default=parse_color("#3f8f63"), help="Terrain color as #RRGGBB")
    parser.add_argument("--execute", action="store_true", help="Write output files. Without this flag, only print a dry-run summary")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.input.exists():
        parser.error(f"input file not found: {args.input}")
    if not 0.0 <= args.alpha <= 1.0:
        parser.error("--alpha must be in [0, 1]")

    mesh = build_mesh(args.input, args.sample_step, args.z_offset)
    output_dir = args.output
    glb_path = output_dir / "content" / "dem_mesh.glb"
    tileset_path = output_dir / "tileset.json"

    print("DEM 3D Tiles export summary")
    print(f"  input:        {args.input}")
    print(f"  output:       {output_dir}")
    print(f"  sample step:  {args.sample_step}")
    print(f"  z offset:     {args.z_offset:.3f} m")
    print(f"  vertices:     {mesh.vertex_count:,}")
    print(f"  triangles:    {mesh.triangle_count:,}")
    print(f"  elevation:    {mesh.elevation_min:.3f} .. {mesh.elevation_max:.3f} m (mean {mesh.elevation_mean:.3f} m)")

    if not args.execute:
        print("Dry run only. Add --execute to write tileset.json and dem_mesh.glb.")
        return 0

    glb_path.parent.mkdir(parents=True, exist_ok=True)
    write_glb(glb_path, mesh, args.color, args.alpha)
    write_tileset(tileset_path, mesh)
    print(f"Wrote {tileset_path}")
    print(f"Wrote {glb_path} ({glb_path.stat().st_size / (1024 * 1024):.2f} MiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
