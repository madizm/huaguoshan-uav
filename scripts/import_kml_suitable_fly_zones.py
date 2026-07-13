#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Import KML suitable-flight airspaces into PostGIS.

Each KML Placemark becomes one ``airspace.suitable_fly_zone`` row.  Its
Polygon elements are kept together as a WGS84 MultiPolygon, including holes.
The import is idempotent per source file and Placemark id.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import psycopg
from psycopg import sql


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
DEFAULT_SCHEMA = "airspace"
DEFAULT_TABLE = "suitable_fly_zone"


class ScriptError(RuntimeError):
    """Raised for KML or command-line input that cannot be imported."""


@dataclass(frozen=True)
class Zone:
    """A suitable-flight zone decoded from one KML Placemark."""

    source_feature_id: str
    name: str
    source_layer: str | None
    source_properties: dict[str, str]
    geometry: dict[str, Any]


def local_name(element: ET.Element) -> str:
    """Return an XML element name without its optional namespace."""

    return element.tag.rsplit("}", 1)[-1]


def children_named(element: ET.Element, name: str) -> list[ET.Element]:
    return [child for child in element if local_name(child) == name]


def descendants_named(element: ET.Element, name: str) -> Iterable[ET.Element]:
    return (child for child in element.iter() if local_name(child) == name)


def element_text(element: ET.Element | None) -> str | None:
    if element is None or element.text is None:
        return None
    value = element.text.strip()
    return value or None


def first_child_text(element: ET.Element, name: str) -> str | None:
    return next((element_text(child) for child in children_named(element, name) if element_text(child)), None)


def parse_coordinates(raw: str, context: str) -> list[list[float]]:
    """Decode a KML coordinate list to a closed GeoJSON linear ring."""

    points: list[list[float]] = []
    for tuple_index, item in enumerate(raw.split(), start=1):
        values = item.split(",")
        if len(values) < 2:
            raise ScriptError(f"{context}: coordinate #{tuple_index} must contain longitude and latitude")
        try:
            longitude, latitude = float(values[0]), float(values[1])
        except ValueError as exc:
            raise ScriptError(f"{context}: coordinate #{tuple_index} has a non-numeric longitude or latitude") from exc
        if not -180 <= longitude <= 180 or not -90 <= latitude <= 90:
            raise ScriptError(f"{context}: coordinate #{tuple_index} is outside WGS84 longitude/latitude bounds")
        # This dataset describes horizontal airspace boundaries. KML altitude,
        # when present, is intentionally not persisted as polygon coordinates.
        points.append([longitude, latitude])

    if len(points) < 3 or len({tuple(point) for point in points}) < 3:
        raise ScriptError(f"{context}: a linear ring needs at least three distinct points")
    if points[0] != points[-1]:
        points.append(points[0])
    return points


def parse_polygon(polygon: ET.Element, context: str) -> list[list[list[float]]]:
    """Convert one KML Polygon into GeoJSON coordinates (outer ring + holes)."""

    outer_boundaries = children_named(polygon, "outerBoundaryIs")
    if len(outer_boundaries) != 1:
        raise ScriptError(f"{context}: Polygon must contain exactly one outerBoundaryIs")

    def boundary_ring(boundary: ET.Element, label: str) -> list[list[float]]:
        rings = list(descendants_named(boundary, "LinearRing"))
        if len(rings) != 1:
            raise ScriptError(f"{context}: {label} must contain exactly one LinearRing")
        coordinates = first_child_text(rings[0], "coordinates")
        if not coordinates:
            raise ScriptError(f"{context}: {label} has no coordinates")
        return parse_coordinates(coordinates, f"{context} {label}")

    rings = [boundary_ring(outer_boundaries[0], "outer boundary")]
    for hole_index, boundary in enumerate(children_named(polygon, "innerBoundaryIs"), start=1):
        rings.append(boundary_ring(boundary, f"inner boundary #{hole_index}"))
    return rings


def placemark_properties(placemark: ET.Element) -> dict[str, str]:
    """Read KML ExtendedData/SimpleData values without coupling to one schema."""

    properties: dict[str, str] = {}
    for simple_data in descendants_named(placemark, "SimpleData"):
        key = simple_data.get("name")
        value = element_text(simple_data)
        if key and value is not None:
            properties[key] = value
    return properties


def load_zones(kml_path: Path) -> list[Zone]:
    try:
        root = ET.parse(kml_path).getroot()
    except (ET.ParseError, OSError) as exc:
        raise ScriptError(f"Cannot read KML {kml_path}: {exc}") from exc

    zones: list[Zone] = []
    used_ids: set[str] = set()
    for placemark_index, placemark in enumerate(descendants_named(root, "Placemark"), start=1):
        source_feature_id = placemark.get("id") or f"placemark-{placemark_index}"
        if source_feature_id in used_ids:
            raise ScriptError(f"Duplicate Placemark id: {source_feature_id!r}")
        used_ids.add(source_feature_id)

        properties = placemark_properties(placemark)
        name = properties.get("aliasname") or first_child_text(placemark, "name") or source_feature_id
        polygons = [
            parse_polygon(polygon, f"Placemark {source_feature_id!r}, Polygon #{polygon_index}")
            for polygon_index, polygon in enumerate(descendants_named(placemark, "Polygon"), start=1)
        ]
        if not polygons:
            raise ScriptError(f"Placemark {source_feature_id!r} does not contain a Polygon")
        zones.append(
            Zone(
                source_feature_id=source_feature_id,
                name=name,
                source_layer=properties.get("layer"),
                source_properties=properties,
                geometry={"type": "MultiPolygon", "coordinates": polygons},
            )
        )

    if not zones:
        raise ScriptError("KML does not contain any Placemark")
    return zones


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Import KML suitable-flight airspaces into airspace.suitable_fly_zone.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--kml", type=Path, default=Path("data/shifeikongyu.kml"), help="Source KML file.")
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument("--schema", default=DEFAULT_SCHEMA, help="Destination schema.")
    parser.add_argument("--table", default=DEFAULT_TABLE, help="Destination table.")
    parser.add_argument("--source-file", default=None, help="Stable source label used for idempotent upserts; defaults to KML filename.")
    parser.add_argument("--dry-run", action="store_true", help="Parse and validate the KML without changing the database.")
    return parser.parse_args()


def validate_identifier(value: str, option: str) -> None:
    if not value or "\x00" in value or "." in value:
        raise ScriptError(f"{option} must be a simple non-empty SQL identifier")


def validate_args(args: argparse.Namespace) -> None:
    validate_identifier(args.schema, "--schema")
    validate_identifier(args.table, "--table")
    if not args.kml.is_file():
        raise ScriptError(f"KML file not found: {args.kml}")
    if args.source_file is not None and not args.source_file.strip():
        raise ScriptError("--source-file cannot be empty")


def qname(args: argparse.Namespace) -> sql.Composed:
    return sql.Identifier(args.schema, args.table)


def create_target_table(cur: psycopg.Cursor[Any], args: argparse.Namespace) -> None:
    target = qname(args)
    cur.execute(
        sql.SQL(
            """
            create schema if not exists {schema};
            create table if not exists {target} (
              id bigint generated by default as identity primary key,
              name text not null,
              source_file text not null,
              source_feature_id text not null,
              source_layer text,
              source_properties jsonb not null default '{{}}'::jsonb,
              geom geometry(MultiPolygon, 4326) not null,
              imported_at timestamptz not null default now(),
              updated_at timestamptz not null default now(),
              unique (source_file, source_feature_id)
            );
            create index if not exists {geom_index} on {target} using gist (geom);
            """
        ).format(
            schema=sql.Identifier(args.schema),
            target=target,
            geom_index=sql.Identifier(f"{args.table}_geom_gix"),
        )
    )
    cur.execute(
        sql.SQL("comment on table {target} is {comment};").format(
            target=target,
            comment=sql.Literal("适飞空域范围。每条记录对应源 KML 的一个 Placemark。"),
        ),
    )
    cur.execute(
        sql.SQL("comment on column {target}.geom is {comment};").format(
            target=target,
            comment=sql.Literal("适飞空域水平范围，WGS84 MultiPolygon；保留 KML 多面及孔洞。"),
        ),
    )
    cur.execute(
        sql.SQL("comment on column {target}.source_properties is {comment};").format(
            target=target,
            comment=sql.Literal("源 KML ExtendedData 属性，保留导入溯源信息。"),
        ),
    )


def upsert_zone(cur: psycopg.Cursor[Any], args: argparse.Namespace, source_file: str, zone: Zone) -> int:
    target = qname(args)
    cur.execute(
        sql.SQL(
            """
            insert into {target} (
              name, source_file, source_feature_id, source_layer, source_properties, geom, imported_at, updated_at
            ) values (
              %s, %s, %s, %s, %s::jsonb,
              ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), 3)),
              now(), now()
            )
            on conflict (source_file, source_feature_id) do update set
              name = excluded.name,
              source_layer = excluded.source_layer,
              source_properties = excluded.source_properties,
              geom = excluded.geom,
              imported_at = excluded.imported_at,
              updated_at = now()
            returning id
            """
        ).format(target=target),
        (
            zone.name,
            source_file,
            zone.source_feature_id,
            zone.source_layer,
            json.dumps(zone.source_properties, ensure_ascii=False),
            json.dumps(zone.geometry, ensure_ascii=False),
        ),
    )
    result = cur.fetchone()
    if result is None:
        raise ScriptError(f"Database did not return an id for Placemark {zone.source_feature_id!r}")
    return int(result[0])


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        zones = load_zones(args.kml)
        source_file = args.source_file or args.kml.name
        if args.dry_run:
            print(f"Validated {len(zones)} suitable-flight zone(s) from {args.kml}; database unchanged.")
            for zone in zones:
                print(f"- {zone.source_feature_id}: {zone.name} ({len(zone.geometry['coordinates'])} polygon(s))")
            return 0

        with psycopg.connect(args.dsn, connect_timeout=15, client_encoding="UTF8") as conn:
            with conn.cursor() as cur:
                create_target_table(cur, args)
                results = [(upsert_zone(cur, args, source_file, zone), zone) for zone in zones]
            conn.commit()
        print(f"Upserted {len(results)} suitable-flight zone(s) into {args.schema}.{args.table}.")
        for row_id, zone in results:
            print(f"- #{row_id}: {zone.name} [{zone.source_feature_id}]")
        return 0
    except (psycopg.Error, OSError, ScriptError, UnicodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
