#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
#   "pyproj>=3.6",
#   "requests>=2.32",
#   "shapely>=2.0",
# ]
# ///
"""Import OSM building footprints for the Huaguoshan area into 3DCityDB 5.x.

Data source: OpenStreetMap via Overpass API. OSM heights are community-maintained
and may be missing or inaccurate. This importer creates approximate LoD1 solids
by extruding footprints from z=0 to a derived height.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

import psycopg
from psycopg.types.json import Jsonb
from pyproj import Transformer
import requests
from shapely.geometry import MultiPolygon, Point, Polygon, shape
from shapely.geometry.polygon import orient
from shapely.ops import transform as shapely_transform
from shapely.validation import make_valid


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
TARGET_SRID = 32650
DEFAULT_HEIGHT_M = 10.0
LEVEL_HEIGHT_M = 2.2
BATCH_CODE = "osm_huaguoshan_2026_06_29"

# User-provided polygon. GeoJSON order is [lng, lat].
AREA_GEOJSON = {
    "type": "Polygon",
    "coordinates": [[
        [119.23062143399773, 34.6640111299246],
        [119.3058473500937, 34.66387620237016],
        [119.30574254976909, 34.63041169680007],
        [119.23071540183122, 34.630255366340634],
        [119.23062143399773, 34.6640111299246],
    ]],
}

# 3DCityDB official geometry_properties.type enum, confirmed from citydb-tool
# org.citydb.model.geometry.GeometryType.
GEOM_TYPE_SOLID = 9


@dataclass
class ImportStats:
    fetched_elements: int = 0
    parsed_buildings: int = 0
    imported: int = 0
    updated: int = 0
    inserted: int = 0
    skipped: dict[str, int] = field(default_factory=dict)
    height_sources: dict[str, int] = field(default_factory=dict)

    def skip(self, reason: str) -> None:
        self.skipped[reason] = self.skipped.get(reason, 0) + 1

    def height_source(self, source: str) -> None:
        self.height_sources[source] = self.height_sources.get(source, 0) + 1


@dataclass
class Building:
    osm_type: str
    osm_id: int
    tags: dict[str, str]
    geometry: Polygon
    height: float
    height_source: str
    levels: int | None
    solid_wkt: str
    envelope_polygon_wkt: str

    @property
    def objectid(self) -> str:
        return f"osm:{self.osm_type}:{self.osm_id}"

    @property
    def osm_url(self) -> str:
        return f"https://www.openstreetmap.org/{self.osm_type}/{self.osm_id}"


class ImportErrorWithReason(Exception):
    def __init__(self, reason: str, message: str | None = None):
        super().__init__(message or reason)
        self.reason = reason


def build_overpass_query(area: Polygon, timeout: int) -> str:
    # Overpass poly order is "lat lon lat lon ...".
    coords = list(area.exterior.coords)
    poly = " ".join(f"{lat:.14f} {lon:.14f}" for lon, lat in coords)
    return f"""[out:json][timeout:{timeout}];
(
  way[\"building\"](poly:\"{poly}\");
  relation[\"building\"](poly:\"{poly}\");
);
out body geom;"""


def fetch_overpass(query: str, url: str, retries: int) -> dict[str, Any]:
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            response = requests.post(
                url,
                data=query.encode("utf-8"),
                headers={
                    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                    "User-Agent": "huaguoshan-osm-3dcitydb-import/0.1",
                },
                timeout=120,
            )
            try:
                response.raise_for_status()
            except requests.HTTPError as exc:
                raise requests.HTTPError(f"{exc}; response={response.text[:500]}") from exc
            return response.json()
        except Exception as exc:  # noqa: BLE001 - report HTTP/JSON errors uniformly
            last_error = exc
            if attempt < retries:
                sleep_s = min(30, 2 ** attempt)
                print(f"Overpass request failed on attempt {attempt}/{retries}: {exc}; retrying in {sleep_s}s", file=sys.stderr)
                time.sleep(sleep_s)
    raise RuntimeError(f"Overpass request failed after {retries} attempts: {last_error}")


def parse_height(tags: dict[str, str]) -> tuple[float, str, int | None]:
    height = parse_length_m(tags.get("height"))
    if height and height > 0:
        return height, "height_tag", parse_levels(tags.get("building:levels"))

    levels = parse_levels(tags.get("building:levels"))
    if levels and levels > 0:
        return levels * LEVEL_HEIGHT_M, "levels_tag", levels

    return DEFAULT_HEIGHT_M, "default", None


def parse_length_m(value: str | None) -> float | None:
    if not value:
        return None
    text = value.strip().lower().replace(",", ".")
    # Values sometimes look like "12 m", "12.5m", "40 ft".
    match = re.search(r"[-+]?\d+(?:\.\d+)?", text)
    if not match:
        return None
    number = float(match.group(0))
    if "ft" in text or "feet" in text or "'" in text:
        return number * 0.3048
    return number


def parse_levels(value: str | None) -> int | None:
    if not value:
        return None
    match = re.search(r"\d+(?:\.\d+)?", value.replace(",", "."))
    if not match:
        return None
    return max(1, int(round(float(match.group(0)))))


def coord_key(coord: tuple[float, float], precision: int = 7) -> tuple[float, float]:
    return (round(coord[0], precision), round(coord[1], precision))


def close_ring(coords: Sequence[tuple[float, float]]) -> list[tuple[float, float]]:
    cleaned: list[tuple[float, float]] = []
    for coord in coords:
        if not cleaned or coord_key(cleaned[-1]) != coord_key(coord):
            cleaned.append(coord)
    if len(cleaned) < 3:
        raise ImportErrorWithReason("too_few_points")
    if coord_key(cleaned[0]) != coord_key(cleaned[-1]):
        cleaned.append(cleaned[0])
    if len(cleaned) < 4:
        raise ImportErrorWithReason("too_few_points")
    return cleaned


def geometry_points(element_or_member: dict[str, Any]) -> list[tuple[float, float]]:
    geometry = element_or_member.get("geometry") or []
    return [(float(point["lon"]), float(point["lat"])) for point in geometry if "lon" in point and "lat" in point]


def assemble_rings(segments: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    rings: list[list[tuple[float, float]]] = []
    remaining = [segment for segment in segments if len(segment) >= 2]

    while remaining:
        ring = remaining.pop(0)
        changed = True
        while coord_key(ring[0]) != coord_key(ring[-1]) and changed:
            changed = False
            start = coord_key(ring[0])
            end = coord_key(ring[-1])
            for index, segment in enumerate(remaining):
                seg_start = coord_key(segment[0])
                seg_end = coord_key(segment[-1])
                if end == seg_start:
                    ring.extend(segment[1:])
                elif end == seg_end:
                    ring.extend(reversed(segment[:-1]))
                elif start == seg_end:
                    ring = segment[:-1] + ring
                elif start == seg_start:
                    ring = list(reversed(segment[1:])) + ring
                else:
                    continue
                remaining.pop(index)
                changed = True
                break

        if coord_key(ring[0]) == coord_key(ring[-1]):
            rings.append(close_ring(ring))

    return rings


def polygon_from_way(element: dict[str, Any]) -> Polygon:
    return clean_polygon(Polygon(close_ring(geometry_points(element))))


def polygon_from_relation(element: dict[str, Any]) -> Polygon | MultiPolygon:
    outer_segments: list[list[tuple[float, float]]] = []
    inner_segments: list[list[tuple[float, float]]] = []

    for member in element.get("members") or []:
        if member.get("type") != "way":
            continue
        coords = geometry_points(member)
        if len(coords) < 2:
            continue
        role = member.get("role") or "outer"
        if role == "inner":
            inner_segments.append(coords)
        else:
            outer_segments.append(coords)

    outer_rings = assemble_rings(outer_segments)
    inner_rings = assemble_rings(inner_segments)
    if not outer_rings:
        raise ImportErrorWithReason("relation_no_outer_ring")

    inner_polys = []
    for ring in inner_rings:
        try:
            inner_polys.append(Polygon(ring))
        except Exception:
            pass

    polygons: list[Polygon] = []
    for outer in outer_rings:
        outer_poly = Polygon(outer)
        holes = [list(poly.exterior.coords) for poly in inner_polys if outer_poly.contains(poly.representative_point())]
        polygons.append(Polygon(outer, holes))

    if len(polygons) == 1:
        return clean_polygon(polygons[0])
    return clean_multipolygon(MultiPolygon(polygons))


def clean_polygon(poly: Polygon) -> Polygon:
    if poly.is_empty:
        raise ImportErrorWithReason("empty_geometry")
    if not poly.is_valid:
        fixed = make_valid(poly)
        if isinstance(fixed, Polygon):
            poly = fixed
        elif isinstance(fixed, MultiPolygon):
            poly = max(fixed.geoms, key=lambda p: p.area)
        else:
            fixed = poly.buffer(0)
            if isinstance(fixed, Polygon):
                poly = fixed
            elif isinstance(fixed, MultiPolygon):
                poly = max(fixed.geoms, key=lambda p: p.area)
    if poly.is_empty or not poly.is_valid or poly.area <= 0:
        raise ImportErrorWithReason("invalid_geometry")
    return orient(poly, sign=1.0)


def clean_multipolygon(geom: MultiPolygon) -> Polygon | MultiPolygon:
    fixed = make_valid(geom)
    if isinstance(fixed, Polygon):
        return clean_polygon(fixed)
    if isinstance(fixed, MultiPolygon):
        polygons = [clean_polygon(poly) for poly in fixed.geoms if not poly.is_empty and poly.area > 0]
        if len(polygons) == 1:
            return polygons[0]
        if polygons:
            return MultiPolygon(polygons)
    raise ImportErrorWithReason("invalid_geometry")


def parse_buildings(elements: Iterable[dict[str, Any]], area_lonlat: Polygon, transformer: Transformer, limit: int | None, stats: ImportStats) -> list[Building]:
    buildings: list[Building] = []
    seen: set[str] = set()

    for element in elements:
        if limit is not None and len(buildings) >= limit:
            break
        osm_type = element.get("type")
        if osm_type not in {"way", "relation"}:
            continue
        osm_id = int(element["id"])
        objectid = f"osm:{osm_type}:{osm_id}"
        if objectid in seen:
            continue
        seen.add(objectid)

        tags = {str(key): str(value) for key, value in (element.get("tags") or {}).items()}
        try:
            footprint_lonlat = polygon_from_way(element) if osm_type == "way" else polygon_from_relation(element)
            if not footprint_lonlat.intersects(area_lonlat):
                stats.skip("outside_area")
                continue

            if isinstance(footprint_lonlat, MultiPolygon):
                # lod1Solid targets a single AbstractSolid. Keep the largest part and report the simplification.
                stats.skip("multipolygon_extra_parts_dropped")
                footprint_lonlat = max(footprint_lonlat.geoms, key=lambda p: p.area)

            height, height_source, levels = parse_height(tags)
            footprint_projected = shapely_transform(transformer.transform, footprint_lonlat)
            footprint_projected = clean_polygon(footprint_projected)
            solid_wkt = polyhedral_surface_wkt(footprint_projected, height)
            envelope_wkt = envelope_polygon_wkt(footprint_projected)

            buildings.append(Building(
                osm_type=osm_type,
                osm_id=osm_id,
                tags=tags,
                geometry=footprint_projected,
                height=height,
                height_source=height_source,
                levels=levels,
                solid_wkt=solid_wkt,
                envelope_polygon_wkt=envelope_wkt,
            ))
            stats.parsed_buildings += 1
            stats.height_source(height_source)
        except ImportErrorWithReason as exc:
            stats.skip(exc.reason)
        except Exception as exc:  # noqa: BLE001
            stats.skip("parse_error")
            print(f"Skipping {objectid}: {exc}", file=sys.stderr)

    return buildings


def ring_coords_2d(ring: Any) -> list[tuple[float, float]]:
    return [(float(x), float(y)) for x, y in ring.coords]


def coord3(coord: tuple[float, float], z: float) -> str:
    return f"{coord[0]:.3f} {coord[1]:.3f} {z:.3f}"


def polygon_patch_wkt(rings: list[list[tuple[float, float]]], z: float, reverse: bool = False) -> str:
    parts = []
    for ring in rings:
        coords = list(reversed(ring)) if reverse else ring
        parts.append("(" + ",".join(coord3(coord, z) for coord in coords) + ")")
    return "(" + ",".join(parts) + ")"


def vertical_patches_for_ring(ring: list[tuple[float, float]], height: float, reverse: bool = False) -> list[str]:
    patches = []
    sequence = list(reversed(ring)) if reverse else ring
    for p0, p1 in zip(sequence, sequence[1:]):
        if coord_key(p0, 3) == coord_key(p1, 3):
            continue
        coords = [p0, p1, p1, p0, p0]
        zs = [0.0, 0.0, height, height, 0.0]
        patches.append("((" + ",".join(coord3(coord, z) for coord, z in zip(coords, zs)) + "))")
    return patches


def polyhedral_surface_wkt(poly: Polygon, height: float) -> str:
    exterior = close_ring(ring_coords_2d(poly.exterior))
    holes = [close_ring(ring_coords_2d(interior)) for interior in poly.interiors]

    patches = []
    # bottom and top patches. Reverse the bottom to make shell orientation more consistent.
    patches.append(polygon_patch_wkt([exterior, *holes], 0.0, reverse=True))
    patches.append(polygon_patch_wkt([exterior, *holes], height, reverse=False))
    patches.extend(vertical_patches_for_ring(exterior, height, reverse=False))
    for hole in holes:
        patches.extend(vertical_patches_for_ring(hole, height, reverse=True))
    return "POLYHEDRALSURFACE Z (" + ",".join(patches) + ")"


def envelope_polygon_wkt(poly: Polygon) -> str:
    minx, miny, maxx, maxy = poly.bounds
    return (
        "POLYGON Z (("
        f"{minx:.3f} {miny:.3f} 0.000,"
        f"{maxx:.3f} {miny:.3f} 0.000,"
        f"{maxx:.3f} {maxy:.3f} 0.000,"
        f"{minx:.3f} {maxy:.3f} 0.000,"
        f"{minx:.3f} {miny:.3f} 0.000"
        "))"
    )


def ensure_metadata(conn: psycopg.Connection[Any], target_srid: int) -> None:
    with conn.cursor() as cur:
        cur.execute("select id from citydb.objectclass where id = 901 and classname = 'Building'")
        if cur.fetchone() is None:
            raise RuntimeError("Missing citydb.objectclass Building id=901")
        cur.execute("select id from citydb.datatype where id in (1,3,5,11,14)")
        if len(cur.fetchall()) < 5:
            raise RuntimeError("Missing required 3DCityDB datatype rows")
        cur.execute(
            """
            insert into citydb.database_srs (srid, srs_name)
            values (%s, %s)
            on conflict (srid) do nothing
            """,
            (target_srid, f"urn:ogc:def:crs:EPSG::{target_srid}"),
        )


def delete_existing_feature(cur: psycopg.Cursor[Any], feature_id: int) -> None:
    # Delete property rows first because property.feature_id has no cascade action.
    cur.execute("delete from citydb.property where feature_id = %s", (feature_id,))
    cur.execute("delete from citydb.geometry_data where feature_id = %s", (feature_id,))


def upsert_building(cur: psycopg.Cursor[Any], building: Building, target_srid: int) -> tuple[int, bool]:
    cur.execute("select id from citydb.feature where objectid = %s", (building.objectid,))
    row = cur.fetchone()
    existed = row is not None

    if existed:
        feature_id = int(row[0])
        delete_existing_feature(cur, feature_id)
        cur.execute(
            """
            update citydb.feature
            set objectclass_id = 901,
                identifier = %s,
                identifier_codespace = 'https://www.openstreetmap.org',
                envelope = ST_GeomFromText(%s, %s),
                last_modification_date = now(),
                updating_person = current_user,
                reason_for_update = 'OSM building import refresh',
                lineage = 'OpenStreetMap via Overpass API'
            where id = %s
            """,
            (building.osm_url, building.envelope_polygon_wkt, target_srid, feature_id),
        )
    else:
        cur.execute(
            """
            insert into citydb.feature
              (objectclass_id, objectid, identifier, identifier_codespace, envelope, creation_date, lineage)
            values
              (901, %s, %s, 'https://www.openstreetmap.org', ST_GeomFromText(%s, %s), now(), 'OpenStreetMap via Overpass API')
            returning id
            """,
            (building.objectid, building.osm_url, building.envelope_polygon_wkt, target_srid),
        )
        feature_id = int(cur.fetchone()[0])

    cur.execute(
        """
        insert into citydb.geometry_data (geometry, geometry_properties, feature_id)
        values (ST_GeomFromText(%s, %s), %s, %s)
        returning id
        """,
        (building.solid_wkt, target_srid, Jsonb({"type": GEOM_TYPE_SOLID}), feature_id),
    )
    geometry_id = int(cur.fetchone()[0])

    insert_property_rows(cur, feature_id, geometry_id, building)
    return feature_id, existed


def insert_property_rows(cur: psycopg.Cursor[Any], feature_id: int, geometry_id: int, building: Building) -> None:
    cur.execute(
        """
        insert into citydb.property
          (feature_id, datatype_id, namespace_id, name, val_lod, val_geometry_id)
        values (%s, 11, 1, 'lod1Solid', '1', %s)
        """,
        (feature_id, geometry_id),
    )

    building_class = building.tags.get("building")
    if building_class:
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_string)
            values (%s, 14, 10, 'class', %s)
            """,
            (feature_id, building_class[:4000]),
        )

    if building.levels is not None:
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_int)
            values (%s, 3, 10, 'storeysAboveGround', %s)
            """,
            (feature_id, building.levels),
        )

    generic_rows = [
        ("osmType", building.osm_type),
        ("osmId", str(building.osm_id)),
        ("osmUrl", building.osm_url),
        ("osmImportBatch", BATCH_CODE),
        ("osmHeightSource", building.height_source),
    ]
    for name, value in generic_rows:
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_string)
            values (%s, 5, 3, %s, %s)
            """,
            (feature_id, name, value[:4000]),
        )

    cur.execute(
        """
        insert into citydb.property
          (feature_id, datatype_id, namespace_id, name, val_double, val_uom)
        values (%s, 4, 3, 'derivedHeight', %s, 'm')
        """,
        (feature_id, building.height),
    )

    tags_json = json.dumps(building.tags, ensure_ascii=False, sort_keys=True)
    if len(tags_json) <= 4000:
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_string)
            values (%s, 5, 3, 'osmTags', %s)
            """,
            (feature_id, tags_json),
        )
    else:
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_content, val_content_mime_type)
            values (%s, 1, 3, 'osmTags', %s, 'application/json')
            """,
            (feature_id, tags_json),
        )


def import_buildings(buildings: Sequence[Building], dsn: str, target_srid: int, stats: ImportStats, batch_size: int) -> None:
    with psycopg.connect(dsn, connect_timeout=15) as conn:
        ensure_metadata(conn, target_srid)
        with conn.cursor() as cur:
            for index, building in enumerate(buildings, start=1):
                _, existed = upsert_building(cur, building, target_srid)
                stats.imported += 1
                if existed:
                    stats.updated += 1
                else:
                    stats.inserted += 1
                if index % batch_size == 0:
                    conn.commit()
                    print(f"Committed {index}/{len(buildings)} buildings")
        conn.commit()


def validate_import(dsn: str) -> dict[str, Any]:
    with psycopg.connect(dsn, connect_timeout=15) as conn, conn.cursor() as cur:
        cur.execute(
            """
            select count(*)
            from citydb.feature
            where objectid like 'osm:%%'
              and lineage = 'OpenStreetMap via Overpass API'
            """
        )
        feature_count = cur.fetchone()[0]
        cur.execute(
            """
            select count(*),
                   count(*) filter (where ST_SRID(geometry) = %s),
                   count(*) filter (where not ST_IsEmpty(geometry)),
                   count(*) filter (where ST_GeometryType(geometry) = 'ST_PolyhedralSurface' and ST_IsClosed(geometry))
            from citydb.geometry_data
            where feature_id in (
              select id from citydb.feature where objectid like 'osm:%%'
            )
            """,
            (TARGET_SRID,),
        )
        geometry_count, srid_count, non_empty_count, closed_solid_count = cur.fetchone()
        return {
            "osm_feature_count": feature_count,
            "geometry_count": geometry_count,
            "geometry_srid_32650_count": srid_count,
            "non_empty_geometry_count": non_empty_count,
            "closed_polyhedral_surface_count": closed_solid_count,
        }


def print_report(stats: ImportStats, validation: dict[str, Any] | None = None) -> None:
    report = {
        "fetched_elements": stats.fetched_elements,
        "parsed_buildings": stats.parsed_buildings,
        "imported": stats.imported,
        "inserted": stats.inserted,
        "updated": stats.updated,
        "height_sources": stats.height_sources,
        "skipped": stats.skipped,
        "validation": validation,
        "note": "OSM building footprints and height tags are community-maintained and may be missing or inaccurate.",
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsn", default=os.getenv("DATABASE_URL", DEFAULT_DSN), help="PostgreSQL DSN")
    parser.add_argument("--overpass-url", default=OVERPASS_URL)
    parser.add_argument("--overpass-timeout", type=int, default=60)
    parser.add_argument("--overpass-retries", type=int, default=3)
    parser.add_argument("--target-srid", type=int, default=TARGET_SRID)
    parser.add_argument("--limit", type=int, help="Limit number of parsed buildings, useful for tests")
    parser.add_argument("--batch-size", type=int, default=500)
    parser.add_argument("--save-overpass-json", help="Write raw Overpass JSON to this path")
    parser.add_argument("--load-overpass-json", help="Read raw Overpass JSON from this path instead of fetching")
    parser.add_argument("--execute", action="store_true", help="Write to database. Without this flag, only performs a dry run.")
    args = parser.parse_args(argv)

    stats = ImportStats()
    area_lonlat = shape(AREA_GEOJSON)
    if not isinstance(area_lonlat, Polygon):
        raise RuntimeError("AREA_GEOJSON must be a Polygon")

    if args.load_overpass_json:
        with open(args.load_overpass_json, "r", encoding="utf-8") as file:
            data = json.load(file)
    else:
        query = build_overpass_query(area_lonlat, args.overpass_timeout)
        print("Fetching OSM buildings from Overpass...", file=sys.stderr)
        data = fetch_overpass(query, args.overpass_url, args.overpass_retries)
        if args.save_overpass_json:
            os.makedirs(os.path.dirname(args.save_overpass_json) or ".", exist_ok=True)
            with open(args.save_overpass_json, "w", encoding="utf-8") as file:
                json.dump(data, file, ensure_ascii=False)

    elements = data.get("elements") or []
    stats.fetched_elements = len(elements)
    transformer = Transformer.from_crs("EPSG:4326", f"EPSG:{args.target_srid}", always_xy=True)
    buildings = parse_buildings(elements, area_lonlat, transformer, args.limit, stats)

    if args.execute:
        import_buildings(buildings, args.dsn, args.target_srid, stats, args.batch_size)
        validation = validate_import(args.dsn)
    else:
        validation = None
        print("Dry run only. Re-run with --execute to write to 3DCityDB.", file=sys.stderr)

    print_report(stats, validation)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
