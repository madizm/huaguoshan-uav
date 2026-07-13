#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "numpy>=1.26",
#   "pyproj>=3.6",
#   "rasterio>=1.3",
#   "shapely>=2.0",
# ]
# ///
"""Export W/G candidate and suitable airspace as fixed-level GGER 3D Tiles.

The exporter voxelizes low-altitude AGL bands against a backend-authoritative
DEM, writes one fixed-level tileset per GGER level, and preserves per-cell GGER
codes and W/G/MIXED properties in a legacy b3dm batch table so Cesium picking
can read them with ``picked.getProperty(...)``.

First-version semantics follow ``docs/wg-candidate-suitable-gger-tiles-plan.md``:

* W Candidate: [0, 120)m AGL.
* G Candidate: [120, 300]m AGL.
* Candidate tiles do not subtract B/C controlled airspace.
* Suitable tiles are candidate cells whose horizontal footprint intersects the
  two-dimensional Airspace Suitability Footprint.
* Suitable inclusion is conservative: any intersection is included.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

WGS84 = "EPSG:4326"
ECEF = "EPSG:4978"
DEFAULT_INPUT = Path("data/dem/lianyungang/copernicus-dem-glo30-lianyungang_epsg32650.tif")
DEFAULT_OUTPUT = Path("exports/airspace/wg_gger")
DEFAULT_SUITABLE_FOOTPRINT = Path("data/shifeikongyu.kml")
EARTH_RADIUS_METERS = 6371008.8
EARTH_EQUATORIAL_RADIUS_METERS = 6378137.0
THETA0_RAD = math.pi / 180.0
DMS_FRACTION_SCALE = 2048
UNDERGROUND_FLAG = 2147483648
UINT32_SIZE = 4294967296


class ExportError(RuntimeError):
    """Raised for invalid export inputs or empty outputs."""


@dataclass(frozen=True)
class CellBounds:
    west: float
    south: float
    east: float
    north: float
    center_lon: float
    center_lat: float
    min_x: int
    min_y: int
    max_x: int
    max_y: int


@dataclass(frozen=True)
class HeightBounds:
    min_height: float
    max_height: float
    center_height: float
    min_layer: int
    max_layer_exclusive: int


@dataclass(frozen=True)
class AirspaceCell:
    gger_3d_code: str
    gger_2d_code: str
    level: int
    tileset_kind: str
    candidate_class: str
    suitability_status: str
    west: float
    south: float
    east: float
    north: float
    min_height: float
    max_height: float
    agl_min: float
    agl_max: float
    dem_min: float
    dem_max: float
    dem_mean: float
    w_coverage_ratio: float
    g_coverage_ratio: float
    dominant_class: str
    is_mixed: bool


def pad_to(data: bytes, alignment: int, fill: bytes = b"\x00") -> bytes:
    return data + fill * ((alignment - len(data) % alignment) % alignment)


def pad_json(data: bytes, alignment: int = 4) -> bytes:
    return pad_to(data, alignment, b" ")


def level_step(level: int) -> int:
    assert_level(level)
    return 1 << (32 - level)


def assert_level(level: int) -> None:
    if int(level) != level or level < 1 or level > 32:
        raise ValueError("GGER level must be an integer from 1 to 32")


def coordinate_to_index(value: float) -> int:
    abs_value = abs(float(value))
    total_seconds = abs_value * 3600.0
    degrees = math.floor(total_seconds / 3600.0)
    minute_seconds = total_seconds - degrees * 3600.0
    minutes = math.floor(minute_seconds / 60.0)
    second_value = minute_seconds - minutes * 60.0
    seconds = math.floor(second_value)
    fractions = math.floor((second_value - seconds) * DMS_FRACTION_SCALE)
    degree_code = degrees + (256 if value < 0 else 0)

    if minutes >= 60:
        minutes = 0
        degree_code += 1
    if seconds >= 60:
        seconds = 0
        minutes += 1
    if fractions >= DMS_FRACTION_SCALE:
        fractions = 0
        seconds += 1

    return int((((degree_code * 64 + minutes) * 64 + seconds) * DMS_FRACTION_SCALE) + fractions)


def index_to_coordinate(index: int, axis: str) -> float:
    unsigned = int(index) & 0xFFFFFFFF
    fractions = unsigned % DMS_FRACTION_SCALE
    total = unsigned // DMS_FRACTION_SCALE
    seconds = total % 64
    total //= 64
    minutes = total % 64
    degree_code = total // 64
    negative = degree_code >= 256
    degrees = degree_code - 256 if negative else degree_code
    value = degrees + minutes / 60.0 + (seconds + fractions / DMS_FRACTION_SCALE) / 3600.0
    if negative:
        value = -value
    if axis == "lat":
        return max(-90.0, min(90.0, value))
    return max(-180.0, min(180.0, value))


def floor_to_level_index(index: int, level: int) -> int:
    step = level_step(level)
    return (int(index) // step) * step


def cell_bounds_from_indices(min_x: int, min_y: int, level: int) -> CellBounds:
    step = level_step(level)
    max_x = min_x + step
    max_y = min_y + step
    west = index_to_coordinate(min_x, "lon")
    east = index_to_coordinate(min(max_x, UINT32_SIZE - 1), "lon")
    south = index_to_coordinate(min_y, "lat")
    north = index_to_coordinate(min(max_y, UINT32_SIZE - 1), "lat")
    if east < west:
        west, east = east, west
    if north < south:
        south, north = north, south
    return CellBounds(
        west=west,
        south=south,
        east=east,
        north=north,
        center_lon=(west + east) / 2.0,
        center_lat=(south + north) / 2.0,
        min_x=min_x,
        min_y=min_y,
        max_x=max_x,
        max_y=max_y,
    )


def get_cell_bounds(longitude: float, latitude: float, level: int) -> CellBounds:
    return cell_bounds_from_indices(
        floor_to_level_index(coordinate_to_index(longitude), level),
        floor_to_level_index(coordinate_to_index(latitude), level),
        level,
    )


def iter_horizontal_cells(west: float, south: float, east: float, north: float, level: int) -> Iterable[CellBounds]:
    step = level_step(level)
    min_x = floor_to_level_index(coordinate_to_index(west), level)
    max_x = floor_to_level_index(coordinate_to_index(east), level)
    min_y = floor_to_level_index(coordinate_to_index(south), level)
    max_y = floor_to_level_index(coordinate_to_index(north), level)
    x = min_x
    while x <= max_x:
        y = min_y
        while y <= max_y:
            bounds = cell_bounds_from_indices(x, y, level)
            if bounds.east >= west and bounds.west <= east and bounds.north >= south and bounds.south <= north:
                yield bounds
            y += step
        x += step


def arc_second_fractions_to_extended_dms_index(value: int) -> int:
    fractions = value % DMS_FRACTION_SCALE
    total_seconds = value // DMS_FRACTION_SCALE
    seconds = total_seconds % 60
    total_minutes = total_seconds // 60
    minutes = total_minutes % 60
    degrees = total_minutes // 60
    return int(((degrees * 64 + minutes) * 64 + seconds) * DMS_FRACTION_SCALE + fractions)


def height_to_layer(height: float) -> int:
    if not math.isfinite(height):
        raise ValueError("height must be finite")
    if height <= -EARTH_EQUATORIAL_RADIUS_METERS:
        raise ValueError("height is outside the valid GGER domain")

    absolute_height = abs(height)
    if height < 0:
        height_ratio = EARTH_EQUATORIAL_RADIUS_METERS / (EARTH_EQUATORIAL_RADIUS_METERS - absolute_height)
    else:
        height_ratio = (absolute_height + EARTH_EQUATORIAL_RADIUS_METERS) / EARTH_EQUATORIAL_RADIUS_METERS
    arc_second_fractions = math.floor(
        (THETA0_RAD / (THETA0_RAD / (3600.0 * DMS_FRACTION_SCALE)))
        * (math.log(height_ratio) / math.log(1.0 + THETA0_RAD))
    )
    layer = arc_second_fractions_to_extended_dms_index(arc_second_fractions)
    return UNDERGROUND_FLAG + layer if height < 0 else layer


def extended_dms_index_to_arc_second_fractions(index: int) -> int:
    value = int(index)
    fractions = value % DMS_FRACTION_SCALE
    total = value // DMS_FRACTION_SCALE
    seconds = total % 64
    total //= 64
    minutes = total % 64
    degrees = total // 64
    return int(((degrees * 60 + minutes) * 60 + seconds) * DMS_FRACTION_SCALE + fractions)


def layer_to_height(z: int) -> float:
    unsigned = int(z) & 0xFFFFFFFF
    underground = unsigned >= UNDERGROUND_FLAG
    layer = unsigned - UNDERGROUND_FLAG if underground else unsigned
    arc_second_fractions = extended_dms_index_to_arc_second_fractions(layer)
    exponent = arc_second_fractions / (3600.0 * DMS_FRACTION_SCALE)
    factor = math.pow(1.0 + THETA0_RAD, exponent)
    if underground:
        return -EARTH_EQUATORIAL_RADIUS_METERS * (1.0 - 1.0 / factor)
    return EARTH_EQUATORIAL_RADIUS_METERS * (factor - 1.0)


def height_bounds_from_unsigned_min(unsigned_min: int, level: int) -> HeightBounds:
    step = level_step(level)
    unsigned_max = min(unsigned_min + step, UINT32_SIZE - 1)
    if unsigned_min < UNDERGROUND_FLAG <= unsigned_max:
        unsigned_max = UNDERGROUND_FLAG - 1
    min_height = layer_to_height(unsigned_min)
    max_height = layer_to_height(unsigned_max)
    if max_height < min_height:
        min_height, max_height = max_height, min_height
    return HeightBounds(
        min_height=min_height,
        max_height=max_height,
        center_height=min_height + (max_height - min_height) / 2.0,
        min_layer=unsigned_min,
        max_layer_exclusive=unsigned_min + step,
    )


def get_height_bounds(height: float, level: int) -> HeightBounds:
    unsigned_layer = height_to_layer(height) & 0xFFFFFFFF
    unsigned_min = floor_to_level_index(unsigned_layer, level)
    return height_bounds_from_unsigned_min(unsigned_min, level)


def iter_height_layers(min_height: float, max_height: float, level: int) -> Iterable[HeightBounds]:
    step = level_step(level)
    start = floor_to_level_index(height_to_layer(min_height) & 0xFFFFFFFF, level)
    stop = floor_to_level_index(height_to_layer(max_height) & 0xFFFFFFFF, level)
    layer = start
    while layer <= stop:
        bounds = height_bounds_from_unsigned_min(layer, level)
        if bounds.max_height >= min_height and bounds.min_height <= max_height:
            yield bounds
        layer += step


def bit_at(value: int, bit_index: int) -> int:
    return (int(value) >> bit_index) & 1


def encode_2d(longitude: float, latitude: float, level: int) -> str:
    assert_level(level)
    x = coordinate_to_index(longitude)
    y = coordinate_to_index(latitude)
    code = "G"
    for bit_index in range(31, 31 - level, -1):
        code += str(bit_at(y, bit_index) * 2 + bit_at(x, bit_index))
    return code


def encode_3d(longitude: float, latitude: float, height: float, level: int) -> str:
    assert_level(level)
    x = coordinate_to_index(longitude)
    y = coordinate_to_index(latitude)
    z = height_to_layer(height)
    code = "GZ"
    for bit_index in range(31, 31 - level, -1):
        code += str(bit_at(y, bit_index) * 4 + bit_at(x, bit_index) * 2 + bit_at(z, bit_index))
    return code


def overlap_length(a_min: float, a_max: float, b_min: float, b_max: float) -> float:
    return max(0.0, min(a_max, b_max) - max(a_min, b_min))


def classify_candidate(
    abs_min: float,
    abs_max: float,
    dem_samples: Sequence[float],
    dominant_threshold: float = 0.8,
) -> tuple[str, float, float, str, bool, float, float]:
    """Classify an absolute-height GGER cell against W/G AGL bands.

    Returns candidate_class, w_ratio, g_ratio, dominant_class, is_mixed,
    displayed_agl_min, displayed_agl_max.
    """

    w_overlap = 0.0
    g_overlap = 0.0
    min_agl = math.inf
    max_agl = -math.inf
    for dem in dem_samples:
        w_overlap += overlap_length(abs_min, abs_max, dem, dem + 120.0)
        g_overlap += overlap_length(abs_min, abs_max, dem + 120.0, dem + 300.0)
        min_agl = min(min_agl, abs_min - dem)
        max_agl = max(max_agl, abs_max - dem)

    total = w_overlap + g_overlap
    if total <= 0:
        return "NONE", 0.0, 0.0, "NONE", False, 0.0, 0.0

    w_ratio = w_overlap / total
    g_ratio = g_overlap / total
    if w_ratio >= dominant_threshold:
        return "W", w_ratio, g_ratio, "W", False, 0.0, 120.0
    if g_ratio >= dominant_threshold:
        return "G", w_ratio, g_ratio, "G", False, 120.0, 300.0
    return "MIXED", w_ratio, g_ratio, "W" if w_ratio >= g_ratio else "G", True, max(0.0, min_agl), min(300.0, max_agl)


def import_runtime_dependencies() -> tuple[Any, Any, Any, Any, Any, Any]:
    try:
        import numpy as np
        import rasterio
        from pyproj import Transformer
        from rasterio.windows import from_bounds
        from shapely.geometry import MultiPolygon, Polygon, box, shape
        from shapely.ops import unary_union
    except ImportError as exc:
        raise ExportError("Missing runtime dependency. Run with `uv run scripts/export_wg_airspace_3dtiles.py ...`.") from exc
    return np, rasterio, Transformer, from_bounds, (MultiPolygon, Polygon, box, shape), unary_union


def kml_local_name(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def kml_children_named(element: ET.Element, name: str) -> list[ET.Element]:
    return [child for child in element if kml_local_name(child) == name]


def kml_descendants_named(element: ET.Element, name: str) -> Iterable[ET.Element]:
    return (child for child in element.iter() if kml_local_name(child) == name)


def kml_element_text(element: ET.Element | None) -> str | None:
    if element is None or element.text is None:
        return None
    text = element.text.strip()
    return text or None


def parse_kml_coordinates(raw: str) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for item in raw.split():
        values = item.split(",")
        if len(values) < 2:
            continue
        points.append((float(values[0]), float(values[1])))
    if points and points[0] != points[-1]:
        points.append(points[0])
    return points


def parse_kml_footprint(path: Path, polygon_class: Any, unary_union: Any) -> Any:
    root = ET.parse(path).getroot()
    polygons: list[Any] = []
    for polygon in kml_descendants_named(root, "Polygon"):
        outer_elements = kml_children_named(polygon, "outerBoundaryIs")
        if not outer_elements:
            continue
        outer_ring = next(kml_descendants_named(outer_elements[0], "LinearRing"), None)
        outer_coords = next(kml_descendants_named(outer_ring, "coordinates"), None) if outer_ring is not None else None
        outer_text = kml_element_text(outer_coords)
        if not outer_text:
            continue
        holes: list[list[tuple[float, float]]] = []
        for inner in kml_children_named(polygon, "innerBoundaryIs"):
            inner_ring = next(kml_descendants_named(inner, "LinearRing"), None)
            inner_coords = next(kml_descendants_named(inner_ring, "coordinates"), None) if inner_ring is not None else None
            inner_text = kml_element_text(inner_coords)
            if inner_text:
                holes.append(parse_kml_coordinates(inner_text))
        polygons.append(polygon_class(parse_kml_coordinates(outer_text), holes))
    if not polygons:
        raise ExportError(f"No Polygon footprint found in {path}")
    return unary_union(polygons)


def load_footprint(path: Path | None) -> Any | None:
    if path is None:
        return None
    _, _, _, _, geometry_classes, unary_union = import_runtime_dependencies()
    _, polygon_class, _, shape_func = geometry_classes
    suffix = path.suffix.lower()
    if suffix == ".kml":
        return parse_kml_footprint(path, polygon_class, unary_union)
    if suffix in {".geojson", ".json"}:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("type") == "FeatureCollection":
            return unary_union([shape_func(feature["geometry"]) for feature in payload.get("features", []) if feature.get("geometry")])
        if payload.get("type") == "Feature":
            return shape_func(payload["geometry"])
        return shape_func(payload)
    raise ExportError(f"Unsupported footprint format: {path}")


def enu_axes(lon_rad: float, lat_rad: float) -> tuple[Any, Any, Any]:
    import numpy as np

    sin_lon, cos_lon = math.sin(lon_rad), math.cos(lon_rad)
    sin_lat, cos_lat = math.sin(lat_rad), math.cos(lat_rad)
    east = np.array([-sin_lon, cos_lon, 0.0], dtype=np.float64)
    north = np.array([-sin_lat * cos_lon, -sin_lat * sin_lon, cos_lat], dtype=np.float64)
    up = np.array([cos_lat * cos_lon, cos_lat * sin_lon, sin_lat], dtype=np.float64)
    return east, north, up


def make_tile_transform(center_ecef: Any, east: Any, north: Any, up: Any) -> list[float]:
    return [
        float(east[0]), float(east[1]), float(east[2]), 0.0,
        float(north[0]), float(north[1]), float(north[2]), 0.0,
        float(up[0]), float(up[1]), float(up[2]), 0.0,
        float(center_ecef[0]), float(center_ecef[1]), float(center_ecef[2]), 1.0,
    ]


def cell_region(cell: AirspaceCell) -> list[float]:
    return [math.radians(cell.west), math.radians(cell.south), math.radians(cell.east), math.radians(cell.north), cell.min_height, cell.max_height]


def union_region(cells: Sequence[AirspaceCell]) -> list[float]:
    return [
        math.radians(min(cell.west for cell in cells)),
        math.radians(min(cell.south for cell in cells)),
        math.radians(max(cell.east for cell in cells)),
        math.radians(max(cell.north for cell in cells)),
        min(cell.min_height for cell in cells),
        max(cell.max_height for cell in cells),
    ]


def ecef_corners_for_cell(cell: AirspaceCell, transformer: Any, np: Any) -> Any:
    lon = np.array([cell.west, cell.east, cell.east, cell.west, cell.west, cell.east, cell.east, cell.west], dtype=np.float64)
    lat = np.array([cell.south, cell.south, cell.north, cell.north, cell.south, cell.south, cell.north, cell.north], dtype=np.float64)
    height = np.array([cell.min_height] * 4 + [cell.max_height] * 4, dtype=np.float64)
    x, y, z = transformer.transform(lon, lat, height)
    return np.column_stack([x, y, z]).astype(np.float64)


def write_glb_lines(path: Path, cells: Sequence[AirspaceCell], transform_to_ecef: Any) -> list[float]:
    np, _, Transformer, _, _, _ = import_runtime_dependencies()
    center_lon = sum((cell.west + cell.east) / 2.0 for cell in cells) / len(cells)
    center_lat = sum((cell.south + cell.north) / 2.0 for cell in cells) / len(cells)
    center_height = sum((cell.min_height + cell.max_height) / 2.0 for cell in cells) / len(cells)
    center_ecef = np.asarray(transform_to_ecef.transform(center_lon, center_lat, center_height), dtype=np.float64)
    east, north, up = enu_axes(math.radians(center_lon), math.radians(center_lat))
    transform = make_tile_transform(center_ecef, east, north, up)

    edge_pairs = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
    positions: list[list[float]] = []
    batch_ids: list[int] = []
    for batch_id, cell in enumerate(cells):
        corners = ecef_corners_for_cell(cell, transform_to_ecef, np)
        local = corners - center_ecef
        local_e = local @ east
        local_n = local @ north
        local_u = local @ up
        gltf_corners = np.column_stack([local_e, local_u, -local_n]).astype(np.float32)
        for a, b in edge_pairs:
            positions.append(gltf_corners[a].tolist())
            positions.append(gltf_corners[b].tolist())
            batch_ids.extend([batch_id, batch_id])

    positions_np = np.ascontiguousarray(np.asarray(positions, dtype=np.float32), dtype="<f4")
    batch_component_type = 5123 if len(cells) <= 65535 else 5125
    batch_dtype = "<u2" if batch_component_type == 5123 else "<u4"
    batch_np = np.ascontiguousarray(np.asarray(batch_ids, dtype=batch_dtype))
    position_bytes = positions_np.tobytes()
    batch_offset = len(pad_to(position_bytes, 4))
    batch_bytes = batch_np.tobytes()
    bin_blob = pad_to(position_bytes, 4) + pad_to(batch_bytes, 4)

    gltf = {
        "asset": {"version": "2.0", "generator": "scripts/export_wg_airspace_3dtiles.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "_BATCHID": 1}, "material": 0, "mode": 1}]}],
        "materials": [{
            "name": "GGER airspace voxel outlines",
            "doubleSided": True,
            "alphaMode": "BLEND",
            "pbrMetallicRoughness": {
                "baseColorFactor": [0.1, 0.85, 0.95, 0.65],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0,
            },
            "extensions": {"KHR_materials_unlit": {}},
        }],
        "buffers": [{"byteLength": len(bin_blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(position_bytes), "target": 34962},
            {"buffer": 0, "byteOffset": batch_offset, "byteLength": len(batch_bytes), "target": 34962},
        ],
        "accessors": [
            {"bufferView": 0, "byteOffset": 0, "componentType": 5126, "count": int(positions_np.shape[0]), "type": "VEC3", "min": positions_np.min(axis=0).astype(float).tolist(), "max": positions_np.max(axis=0).astype(float).tolist()},
            {"bufferView": 1, "byteOffset": 0, "componentType": batch_component_type, "count": int(batch_np.size), "type": "SCALAR", "min": [0], "max": [len(cells) - 1]},
        ],
    }
    json_blob = pad_json(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), 4)
    total_length = 12 + 8 + len(json_blob) + 8 + len(bin_blob)
    header = struct.pack("<III", 0x46546C67, 2, total_length)
    path.write_bytes(header + struct.pack("<II", len(json_blob), 0x4E4F534A) + json_blob + struct.pack("<II", len(bin_blob), 0x004E4942) + bin_blob)
    return transform


def write_b3dm(path: Path, cells: Sequence[AirspaceCell], transform_to_ecef: Any) -> list[float]:
    glb_path = path.with_suffix(".glb.tmp")
    transform = write_glb_lines(glb_path, cells, transform_to_ecef)
    glb = glb_path.read_bytes()
    glb_path.unlink()

    feature_table = pad_json(json.dumps({"BATCH_LENGTH": len(cells)}, separators=(",", ":")).encode("utf-8"), 8)
    batch_table_payload = {
        "gger_3d_code": [cell.gger_3d_code for cell in cells],
        "gger_2d_code": [cell.gger_2d_code for cell in cells],
        "level": [cell.level for cell in cells],
        "tileset_kind": [cell.tileset_kind for cell in cells],
        "candidate_class": [cell.candidate_class for cell in cells],
        "suitability_status": [cell.suitability_status for cell in cells],
        "height_datum": ["AGL" for _ in cells],
        "agl_min": [round(cell.agl_min, 3) for cell in cells],
        "agl_max": [round(cell.agl_max, 3) for cell in cells],
        "bbox_min_lon": [cell.west for cell in cells],
        "bbox_min_lat": [cell.south for cell in cells],
        "bbox_min_h": [round(cell.min_height, 3) for cell in cells],
        "bbox_max_lon": [cell.east for cell in cells],
        "bbox_max_lat": [cell.north for cell in cells],
        "bbox_max_h": [round(cell.max_height, 3) for cell in cells],
        "dem_min": [round(cell.dem_min, 3) for cell in cells],
        "dem_max": [round(cell.dem_max, 3) for cell in cells],
        "w_coverage_ratio": [round(cell.w_coverage_ratio, 4) for cell in cells],
        "g_coverage_ratio": [round(cell.g_coverage_ratio, 4) for cell in cells],
        "dominant_class": [cell.dominant_class for cell in cells],
        "is_mixed": [cell.is_mixed for cell in cells],
    }
    batch_table = pad_json(json.dumps(batch_table_payload, separators=(",", ":")).encode("utf-8"), 8)
    header_length = 28
    byte_length = header_length + len(feature_table) + len(batch_table) + len(glb)
    header = struct.pack("<4sIIIIII", b"b3dm", 1, byte_length, len(feature_table), 0, len(batch_table), 0)
    path.write_bytes(header + feature_table + batch_table + glb)
    return transform


def split_batches(cells: Sequence[AirspaceCell], batch_size: int) -> Iterable[Sequence[AirspaceCell]]:
    for index in range(0, len(cells), batch_size):
        yield cells[index:index + batch_size]


def write_tileset(output_dir: Path, cells: Sequence[AirspaceCell], batch_size: int, geometric_error: float) -> None:
    if not cells:
        raise ExportError(f"No cells to write under {output_dir}")
    _, _, Transformer, _, _, _ = import_runtime_dependencies()
    to_ecef = Transformer.from_crs(WGS84, ECEF, always_xy=True)
    content_dir = output_dir / "content"
    content_dir.mkdir(parents=True, exist_ok=True)

    children = []
    for batch_index, batch in enumerate(split_batches(cells, batch_size)):
        uri = f"content/airspace_r{batch_index:04d}.b3dm"
        path = output_dir / uri
        transform = write_b3dm(path, batch, to_ecef)
        children.append({
            "transform": transform,
            "boundingVolume": {"region": union_region(batch)},
            "geometricError": 0,
            "refine": "ADD",
            "content": {"uri": uri},
        })

    root = children[0] if len(children) == 1 else {
        "boundingVolume": {"region": union_region(cells)},
        "geometricError": geometric_error,
        "refine": "ADD",
        "children": children,
    }
    tileset = {
        "asset": {"version": "1.0", "generator": "scripts/export_wg_airspace_3dtiles.py"},
        "geometricError": geometric_error,
        "root": root,
    }
    (output_dir / "tileset.json").write_text(json.dumps(tileset, indent=2), encoding="utf-8")


def transformer_bounds(src: Any, Transformer: Any) -> tuple[float, float, float, float]:
    to_wgs84 = Transformer.from_crs(src.crs, WGS84, always_xy=True)
    left, bottom, right, top = src.bounds
    xs = [left, right, right, left]
    ys = [bottom, bottom, top, top]
    lon, lat = to_wgs84.transform(xs, ys)
    return min(lon), min(lat), max(lon), max(lat)


def parse_bounds(value: str | None) -> tuple[float, float, float, float] | None:
    if value is None:
        return None
    parts = [float(part.strip()) for part in value.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("--bounds must be west,south,east,north")
    west, south, east, north = parts
    if west >= east or south >= north:
        raise argparse.ArgumentTypeError("--bounds must satisfy west < east and south < north")
    return west, south, east, north


def dem_samples_for_cell(src: Any, cell: CellBounds, sample_step: int, max_samples: int, np: Any, Transformer: Any, from_bounds: Any) -> list[float]:
    to_src = Transformer.from_crs(WGS84, src.crs, always_xy=True)
    xs, ys = to_src.transform([cell.west, cell.east, cell.east, cell.west], [cell.south, cell.south, cell.north, cell.north])
    try:
        window = from_bounds(min(xs), min(ys), max(xs), max(ys), transform=src.transform).round_offsets().round_lengths()
        full_window = window.intersection(src.window(*src.bounds))
    except Exception:
        return []
    if full_window.width <= 0 or full_window.height <= 0:
        return []
    band = src.read(1, window=full_window, masked=True).astype("float64")
    if band.size == 0:
        return []
    stride = max(1, int(sample_step))
    if max_samples > 0:
        approx_stride = int(math.ceil(math.sqrt(band.size / max_samples)))
        stride = max(stride, approx_stride)
    sampled = band[::stride, ::stride]
    values = np.asarray(sampled.compressed(), dtype=np.float64)
    values = values[np.isfinite(values)]
    return [float(value) for value in values]



def build_cells_for_level(
    src: Any,
    level: int,
    bounds: tuple[float, float, float, float],
    sample_step: int,
    max_samples_per_cell: int,
    dominant_threshold: float,
    max_cells: int,
    footprint: Any | None,
) -> tuple[list[AirspaceCell], list[AirspaceCell]]:
    np, _, Transformer, from_bounds, geometry_classes, _ = import_runtime_dependencies()
    _, _, box, _ = geometry_classes
    candidate_cells: list[AirspaceCell] = []
    suitable_cells: list[AirspaceCell] = []
    west, south, east, north = bounds

    for hcell in iter_horizontal_cells(west, south, east, north, level):
        dem_samples = dem_samples_for_cell(src, hcell, sample_step, max_samples_per_cell, np, Transformer, from_bounds)
        if not dem_samples:
            continue
        min_dem = min(dem_samples)
        max_dem = max(dem_samples)
        horizontal_intersects_footprint = False
        if footprint is not None:
            horizontal_intersects_footprint = bool(footprint.intersects(box(hcell.west, hcell.south, hcell.east, hcell.north)))

        for height in iter_height_layers(min_dem, max_dem + 300.0, level):
            classification = classify_candidate(height.min_height, height.max_height, dem_samples, dominant_threshold)
            if classification[0] == "NONE":
                continue
            common = dict(
                gger_3d_code=encode_3d(hcell.center_lon, hcell.center_lat, height.center_height, level),
                gger_2d_code=encode_2d(hcell.center_lon, hcell.center_lat, level),
                level=level,
                candidate_class=classification[0],
                west=hcell.west,
                south=hcell.south,
                east=hcell.east,
                north=hcell.north,
                min_height=height.min_height,
                max_height=height.max_height,
                agl_min=classification[5],
                agl_max=classification[6],
                dem_min=min_dem,
                dem_max=max_dem,
                dem_mean=sum(dem_samples) / len(dem_samples),
                w_coverage_ratio=classification[1],
                g_coverage_ratio=classification[2],
                dominant_class=classification[3],
                is_mixed=classification[4],
            )
            candidate_cells.append(AirspaceCell(tileset_kind="candidate", suitability_status="NONE", **common))
            if horizontal_intersects_footprint:
                suitable_cells.append(AirspaceCell(tileset_kind="suitable", suitability_status="SUITABLE", **common))
            if max_cells > 0 and len(candidate_cells) >= max_cells:
                return candidate_cells, suitable_cells
    return candidate_cells, suitable_cells


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT, help="Backend-authoritative DEM GeoTIFF")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output directory containing candidate/ and suitable/")
    parser.add_argument("--levels", default="20", help="Comma-separated GGER levels to export")
    parser.add_argument("--bounds", type=parse_bounds, default=None, help="Optional WGS84 west,south,east,north subset")
    parser.add_argument("--suitable-footprint", type=Path, default=DEFAULT_SUITABLE_FOOTPRINT, help="Optional KML/GeoJSON Airspace Suitability Footprint")
    parser.add_argument("--no-suitable-footprint", action="store_true", help="Only export candidate tiles; do not export suitable tiles")
    parser.add_argument("--sample-step", type=int, default=1, help="DEM sample stride inside each GGER horizontal cell")
    parser.add_argument("--max-samples-per-cell", type=int, default=256, help="Cap sampled DEM points per horizontal cell")
    parser.add_argument("--dominant-threshold", type=float, default=0.8, help="W/G ratio threshold before a cell becomes MIXED")
    parser.add_argument("--batch-size", type=int, default=1000, help="Cells per b3dm content tile")
    parser.add_argument("--max-cells", type=int, default=0, help="Safety cap for candidate cells per level; 0 means unlimited")
    parser.add_argument("--execute", action="store_true", help="Write 3D Tiles. Without this flag, print a dry-run summary only")
    return parser


def parse_levels(value: str) -> list[int]:
    levels = [int(part.strip()) for part in value.split(",") if part.strip()]
    if not levels:
        raise argparse.ArgumentTypeError("--levels must contain at least one level")
    for level in levels:
        assert_level(level)
    return levels


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.input.exists():
        parser.error(f"input file not found: {args.input}")
    if args.sample_step < 1:
        parser.error("--sample-step must be >= 1")
    if args.max_samples_per_cell < 1:
        parser.error("--max-samples-per-cell must be >= 1")
    if not 0.5 <= args.dominant_threshold <= 1.0:
        parser.error("--dominant-threshold must be in [0.5, 1.0]")
    if args.batch_size < 1:
        parser.error("--batch-size must be >= 1")
    if args.max_cells < 0:
        parser.error("--max-cells must be >= 0")
    levels = parse_levels(args.levels)

    np, rasterio, Transformer, _, _, _ = import_runtime_dependencies()
    footprint_path = None if args.no_suitable_footprint else args.suitable_footprint
    if footprint_path is not None and not footprint_path.exists():
        parser.error(f"suitable footprint not found: {footprint_path}")
    footprint = load_footprint(footprint_path)

    with rasterio.open(args.input) as src:
        if src.crs is None:
            raise ExportError(f"{args.input} has no CRS")
        bounds = args.bounds or transformer_bounds(src, Transformer)
        print("W/G GGER airspace export summary")
        print(f"  DEM:                 {args.input}")
        print(f"  output:              {args.output}")
        print(f"  bounds:              {bounds[0]:.8f},{bounds[1]:.8f},{bounds[2]:.8f},{bounds[3]:.8f}")
        print(f"  levels:              {', '.join(map(str, levels))}")
        print(f"  suitable footprint:  {footprint_path if footprint_path else 'disabled'}")

        for level in levels:
            candidate_cells, suitable_cells = build_cells_for_level(
                src=src,
                level=level,
                bounds=bounds,
                sample_step=args.sample_step,
                max_samples_per_cell=args.max_samples_per_cell,
                dominant_threshold=args.dominant_threshold,
                max_cells=args.max_cells,
                footprint=footprint,
            )
            print(f"  level {level}: candidate={len(candidate_cells):,}, suitable={len(suitable_cells):,}")
            if not args.execute:
                continue
            if candidate_cells:
                write_tileset(args.output / "candidate" / f"level-{level}", candidate_cells, args.batch_size, geometric_error=max(1.0, 2 ** max(0, 22 - level)))
            if footprint is not None and suitable_cells:
                write_tileset(args.output / "suitable" / f"level-{level}", suitable_cells, args.batch_size, geometric_error=max(1.0, 2 ** max(0, 22 - level)))

    if not args.execute:
        print("Dry run only. Add --execute to write candidate/suitable 3D Tiles.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
