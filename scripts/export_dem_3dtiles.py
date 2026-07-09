#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "numpy>=1.26",
#   "pyproj>=3.6",
#   "rasterio>=1.3",
# ]
# ///
"""Export a DEM GeoTIFF as simple 3D Tiles 1.1 terrain mesh tiles.

The output is intended for visual inspection in Cesium, not as a replacement for
Cesium quantized-mesh terrain. It splits large DEMs into source-pixel windows,
builds one GLB mesh per non-empty window, places each mesh in an east-north-up
tile frame, and writes a tileset.json hierarchy that references the GLBs.
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
from rasterio.windows import Window
from rasterio.windows import bounds as window_bounds


@dataclass(frozen=True)
class TileMetadata:
    uri: str
    transform: list[float]
    region: list[float]
    geometric_error: float
    vertex_count: int
    triangle_count: int
    elevation_min: float
    elevation_max: float
    elevation_mean: float

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


def build_mesh(input_path: Path, sample_step: int, z_offset: float, window: Window | None = None) -> MeshData:
    if sample_step < 1:
        raise ValueError("sample_step must be >= 1")

    with rasterio.open(input_path) as src:
        return build_mesh_from_dataset(src, sample_step, z_offset, window)


def build_mesh_from_dataset(src: rasterio.io.DatasetReader, sample_step: int, z_offset: float, window: Window | None = None) -> MeshData:
    if src.count < 1:
        raise ValueError(f"{src.name} has no raster bands")
    if src.crs is None:
        raise ValueError(f"{src.name} has no CRS")

    read_window = window or Window(0, 0, src.width, src.height)
    band = src.read(1, window=read_window, masked=True).astype("float64")
    height, width = band.shape
    rows = np.arange(0, height, sample_step, dtype=np.int32)
    cols = np.arange(0, width, sample_step, dtype=np.int32)
    sampled = band[np.ix_(rows, cols)]
    elevations = np.asarray(sampled.filled(np.nan), dtype=np.float64) + z_offset
    valid = ~np.ma.getmaskarray(sampled)
    valid &= np.isfinite(elevations)
    if not np.any(valid):
        raise ValueError("DEM tile contains no valid cells at the requested sample step")

    valid_elevations = elevations[valid]
    tile_transform = src.window_transform(read_window)

    xs_1d, _ = raster_xy(tile_transform, np.zeros_like(cols), cols, offset="center")
    _, ys_1d = raster_xy(tile_transform, rows, np.zeros_like(rows), offset="center")
    xs = np.asarray(xs_1d, dtype=np.float64)
    ys = np.asarray(ys_1d, dtype=np.float64)
    grid_x, grid_y = np.meshgrid(xs, ys)

    # Center on the valid DEM tile footprint to keep GLB coordinates small.
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
        raise ValueError("sampled DEM tile produced no triangles")

    indices = np.asarray(faces, dtype=np.uint32).reshape(-1)

    left, bottom, right, top = window_bounds(read_window, src.transform)
    corner_x = [left, right, right, left]
    corner_y = [bottom, bottom, top, top]
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

    pixel_size = max(abs(float(src.transform.a)), abs(float(src.transform.e)), 1.0)
    return MeshData(
        positions_gltf=positions_gltf,
        indices=indices,
        transform=make_tile_transform(center_ecef, east, north, up),
        region=region,
        geometric_error=max(1.0, pixel_size * sample_step * 4.0),
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


def mesh_metadata(uri: str, mesh: MeshData) -> TileMetadata:
    return TileMetadata(
        uri=uri,
        transform=mesh.transform,
        region=mesh.region,
        geometric_error=mesh.geometric_error,
        vertex_count=mesh.vertex_count,
        triangle_count=mesh.triangle_count,
        elevation_min=mesh.elevation_min,
        elevation_max=mesh.elevation_max,
        elevation_mean=mesh.elevation_mean,
    )


def union_region(tiles: list[TileMetadata]) -> list[float]:
    return [
        min(tile.region[0] for tile in tiles),
        min(tile.region[1] for tile in tiles),
        max(tile.region[2] for tile in tiles),
        max(tile.region[3] for tile in tiles),
        min(tile.region[4] for tile in tiles),
        max(tile.region[5] for tile in tiles),
    ]


def tile_json(tile: TileMetadata) -> dict[str, Any]:
    return {
        "transform": tile.transform,
        "boundingVolume": {"region": tile.region},
        "geometricError": 0,
        "refine": "ADD",
        "content": {"uri": tile.uri},
    }


def write_tileset(path: Path, tiles: list[TileMetadata]) -> None:
    if not tiles:
        raise ValueError("cannot write tileset without tiles")

    if len(tiles) == 1:
        root = tile_json(tiles[0])
    else:
        root = {
            "boundingVolume": {"region": union_region(tiles)},
            "geometricError": max(tile.geometric_error for tile in tiles),
            "refine": "ADD",
            "children": [tile_json(tile) for tile in tiles],
        }

    tileset = {
        "asset": {
            "version": "1.1",
            "generator": "scripts/export_dem_3dtiles.py",
        },
        "geometricError": max(tile.geometric_error for tile in tiles),
        "root": root,
    }
    path.write_text(json.dumps(tileset, indent=2), encoding="utf-8")


def iter_tile_windows(width: int, height: int, tile_size: int, sample_step: int) -> list[tuple[int, int, Window]]:
    if tile_size <= 0:
        return [(0, 0, Window(0, 0, width, height))]
    windows: list[tuple[int, int, Window]] = []
    for yoff in range(0, height, tile_size):
        for xoff in range(0, width, tile_size):
            row = yoff // tile_size
            col = xoff // tile_size
            # Include one sampled edge row/column from the neighbour so adjacent
            # meshes share a boundary vertex line. Without this halo, each GLB
            # ends at its last pixel center and the next starts at the next pixel
            # center, leaving a visible one-sample gap between independent tiles.
            extra_width = sample_step if xoff + tile_size < width else 0
            extra_height = sample_step if yoff + tile_size < height else 0
            windows.append((
                row,
                col,
                Window(
                    xoff,
                    yoff,
                    min(tile_size + extra_width, width - xoff),
                    min(tile_size + extra_height, height - yoff),
                ),
            ))
    return windows


def export_tiles(
    input_path: Path,
    output_dir: Path,
    sample_step: int,
    z_offset: float,
    tile_size: int,
    color: tuple[float, float, float],
    alpha: float,
    execute: bool,
) -> list[TileMetadata]:
    tiles: list[TileMetadata] = []
    with rasterio.open(input_path) as src:
        windows = iter_tile_windows(src.width, src.height, tile_size, sample_step)
        for row, col, window in windows:
            uri = "content/dem_mesh.glb" if tile_size <= 0 else f"content/dem_tile_r{row:04d}_c{col:04d}.glb"
            try:
                mesh = build_mesh_from_dataset(src, sample_step, z_offset, window)
            except ValueError as exc:
                message = str(exc)
                if "contains no valid cells" in message or "produced no triangles" in message:
                    print(f"Skipping empty DEM tile r{row:04d} c{col:04d}: {message}", file=sys.stderr)
                    continue
                raise

            if execute:
                glb_path = output_dir / uri
                glb_path.parent.mkdir(parents=True, exist_ok=True)
                write_glb(glb_path, mesh, color, alpha)
            tiles.append(mesh_metadata(uri, mesh))
    return tiles


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT, help="Input DEM GeoTIFF")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output 3D Tiles directory")
    parser.add_argument("--sample-step", type=int, default=1, help="Use every Nth DEM pixel inside each mesh tile")
    parser.add_argument("--tile-size", type=int, default=512, help="Source DEM pixel width/height per 3D Tiles content tile. Use 0 to export one GLB.")
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
    if args.sample_step < 1:
        parser.error("--sample-step must be >= 1")
    if args.tile_size < 0:
        parser.error("--tile-size must be >= 0")
    if args.tile_size > 0 and args.tile_size % args.sample_step != 0:
        parser.error("--tile-size must be divisible by --sample-step so adjacent mesh tiles share a seam edge")

    output_dir = args.output
    tileset_path = output_dir / "tileset.json"
    tiles = export_tiles(args.input, output_dir, args.sample_step, args.z_offset, args.tile_size, args.color, args.alpha, args.execute)
    if not tiles:
        raise ValueError("DEM export produced no non-empty mesh tiles")

    total_vertices = sum(tile.vertex_count for tile in tiles)
    total_triangles = sum(tile.triangle_count for tile in tiles)
    weighted_elevation_mean = sum(tile.elevation_mean * tile.vertex_count for tile in tiles) / total_vertices

    print("DEM 3D Tiles export summary")
    print(f"  input:        {args.input}")
    print(f"  output:       {output_dir}")
    print(f"  sample step:  {args.sample_step}")
    print(f"  tile size:    {'single GLB' if args.tile_size == 0 else f'{args.tile_size} px'}")
    print(f"  z offset:     {args.z_offset:.3f} m")
    print(f"  tiles:        {len(tiles):,}")
    print(f"  vertices:     {total_vertices:,}")
    print(f"  triangles:    {total_triangles:,}")
    print(f"  elevation:    {min(tile.elevation_min for tile in tiles):.3f} .. {max(tile.elevation_max for tile in tiles):.3f} m (mean {weighted_elevation_mean:.3f} m)")

    if not args.execute:
        print("Dry run only. Add --execute to write tileset.json and GLB content tiles.")
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    write_tileset(tileset_path, tiles)
    print(f"Wrote {tileset_path}")
    print(f"Wrote {len(tiles):,} GLB content tile(s) under {output_dir / 'content'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
