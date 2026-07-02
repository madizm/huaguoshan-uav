#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Seed/import airspace no-fly and temporary-control zones.

The script writes to the existing project tables and intentionally does not
migrate their schema:

- airspace.no_fly_zone
- airspace.temp_control_zone

GeoJSON input can be a Geometry, Feature, or FeatureCollection. Polygon inputs
are normalized to MultiPolygon in PostGIS before insertion.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import psycopg
from psycopg import sql


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
DEFAULT_AIRSPACE_SCHEMA = "airspace"
VALID_KINDS = ("no-fly-zone", "temp-control")
VALID_STATUSES = ("planned", "active", "cancelled")


class ScriptError(RuntimeError):
    """Raised for user-actionable import errors."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Import GeoJSON airspace zones into existing airspace.no_fly_zone/temp_control_zone tables.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument("--airspace-schema", default=DEFAULT_AIRSPACE_SCHEMA, help="Existing airspace schema name.")
    parser.add_argument("--kind", choices=VALID_KINDS, required=True, help="Target airspace zone type.")
    parser.add_argument("--geojson", type=Path, required=True, help="GeoJSON Geometry, Feature, or FeatureCollection to import.")
    parser.add_argument("--name", default=None, help="Zone name. Feature property 'name' is used when omitted.")
    parser.add_argument("--min-height", type=float, default=0.0, help="Fallback min_height in metres.")
    parser.add_argument("--max-height", type=float, default=None, help="Fallback max_height in metres; NULL uses refresh script default.")
    parser.add_argument("--safety-buffer-m", type=float, default=0.0, help="Fallback horizontal safety buffer in metres.")
    parser.add_argument("--enabled", dest="enabled", action="store_true", help="Insert no-fly zones as enabled.")
    parser.add_argument("--disabled", dest="enabled", action="store_false", help="Insert no-fly zones as disabled.")
    parser.set_defaults(enabled=True)
    parser.add_argument("--valid-from", default=None, help="temp-control valid_from timestamptz literal.")
    parser.add_argument("--valid-to", default=None, help="temp-control valid_to timestamptz literal.")
    parser.add_argument("--status", choices=VALID_STATUSES, default="planned", help="temp-control status.")
    parser.add_argument(
        "--replace-by-name",
        action="store_true",
        help="Delete existing rows with the same resolved name in the target table before inserting.",
    )
    return parser.parse_args()


def validate_identifier(value: str, label: str) -> None:
    if not value or "\x00" in value or "." in value:
        raise ScriptError(f"{label} must be a simple non-empty identifier")


def validate_args(args: argparse.Namespace) -> None:
    validate_identifier(args.airspace_schema, "--airspace-schema")
    if not args.geojson.exists():
        raise ScriptError(f"GeoJSON file not found: {args.geojson}")
    if args.safety_buffer_m < 0:
        raise ScriptError("--safety-buffer-m cannot be negative")
    if args.max_height is not None and args.max_height <= args.min_height:
        raise ScriptError("--max-height must be greater than --min-height")
    if args.kind == "temp-control" and (not args.valid_from or not args.valid_to):
        raise ScriptError("--valid-from and --valid-to are required for --kind temp-control")


def load_geojson(path: Path) -> list[dict[str, Any]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ScriptError(f"Invalid GeoJSON JSON: {exc}") from exc

    geo_type = raw.get("type")
    if geo_type == "FeatureCollection":
        features = raw.get("features")
        if not isinstance(features, list) or not features:
            raise ScriptError("FeatureCollection must contain at least one feature")
        return features
    if geo_type == "Feature":
        return [raw]
    if geo_type in {"Polygon", "MultiPolygon", "GeometryCollection"}:
        return [{"type": "Feature", "properties": {}, "geometry": raw}]
    raise ScriptError(f"Unsupported GeoJSON type: {geo_type!r}")


def feature_value(feature: dict[str, Any], key: str, fallback: Any) -> Any:
    properties = feature.get("properties") or {}
    value = properties.get(key)
    return fallback if value is None or value == "" else value


def resolved_rows(args: argparse.Namespace) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index, feature in enumerate(load_geojson(args.geojson), start=1):
        geometry = feature.get("geometry")
        if not geometry:
            raise ScriptError(f"Feature #{index} has no geometry")
        name = feature_value(feature, "name", args.name)
        if not name:
            stem = args.geojson.stem.replace("_", " ")
            name = stem if len(load_geojson(args.geojson)) == 1 else f"{stem} #{index}"
        min_height = float(feature_value(feature, "min_height", args.min_height))
        max_height_raw = feature_value(feature, "max_height", args.max_height)
        max_height = None if max_height_raw is None else float(max_height_raw)
        safety_buffer_m = float(feature_value(feature, "safety_buffer_m", args.safety_buffer_m))
        if safety_buffer_m < 0:
            raise ScriptError(f"Feature #{index} safety_buffer_m cannot be negative")
        if max_height is not None and max_height <= min_height:
            raise ScriptError(f"Feature #{index} max_height must be greater than min_height")
        rows.append(
            {
                "name": str(name),
                "geometry_json": json.dumps(geometry, ensure_ascii=False),
                "min_height": min_height,
                "max_height": max_height,
                "safety_buffer_m": safety_buffer_m,
                "enabled": bool(feature_value(feature, "enabled", args.enabled)),
                "valid_from": feature_value(feature, "valid_from", args.valid_from),
                "valid_to": feature_value(feature, "valid_to", args.valid_to),
                "status": str(feature_value(feature, "status", args.status)),
            }
        )
    return rows


def qname(schema_name: str, relation_name: str) -> sql.Composed:
    return sql.SQL("{}.{}").format(sql.Identifier(schema_name), sql.Identifier(relation_name))


def geometry_expression() -> sql.SQL:
    return sql.SQL(
        "public.ST_Multi(public.ST_CollectionExtract(public.ST_MakeValid(public.ST_SetSRID(public.ST_GeomFromGeoJSON(%s), 4326)), 3))"
    )


def insert_no_fly_zone(cur: psycopg.Cursor[Any], args: argparse.Namespace, row: dict[str, Any]) -> int:
    if args.replace_by_name:
        cur.execute(sql.SQL("delete from {} where name = %s").format(qname(args.airspace_schema, "no_fly_zone")), (row["name"],))
    cur.execute(
        sql.SQL(
            """
            insert into {target}
                (name, geom, min_height, max_height, safety_buffer_m, enabled, updated_at)
            values
                (%s, {geom}, %s, %s, %s, %s, now())
            returning id
            """
        ).format(target=qname(args.airspace_schema, "no_fly_zone"), geom=geometry_expression()),
        (row["name"], row["geometry_json"], row["min_height"], row["max_height"], row["safety_buffer_m"], row["enabled"]),
    )
    return int(cur.fetchone()[0])


def insert_temp_control(cur: psycopg.Cursor[Any], args: argparse.Namespace, row: dict[str, Any]) -> int:
    if row["status"] not in VALID_STATUSES:
        raise ScriptError(f"Invalid temp-control status for {row['name']!r}: {row['status']}")
    if args.replace_by_name:
        cur.execute(sql.SQL("delete from {} where name = %s").format(qname(args.airspace_schema, "temp_control_zone")), (row["name"],))
    cur.execute(
        sql.SQL(
            """
            insert into {target}
                (name, geom, min_height, max_height, safety_buffer_m, valid_from, valid_to, status, updated_at)
            values
                (%s, {geom}, %s, %s, %s, %s::timestamptz, %s::timestamptz, %s, now())
            returning id
            """
        ).format(target=qname(args.airspace_schema, "temp_control_zone"), geom=geometry_expression()),
        (
            row["name"],
            row["geometry_json"],
            row["min_height"],
            row["max_height"],
            row["safety_buffer_m"],
            row["valid_from"],
            row["valid_to"],
            row["status"],
        ),
    )
    return int(cur.fetchone()[0])


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        rows = resolved_rows(args)
        inserted: list[tuple[int, str]] = []
        with psycopg.connect(args.dsn, connect_timeout=15) as conn:
            with conn.cursor() as cur:
                for row in rows:
                    if args.kind == "no-fly-zone":
                        row_id = insert_no_fly_zone(cur, args, row)
                    else:
                        row_id = insert_temp_control(cur, args, row)
                    inserted.append((row_id, row["name"]))
            conn.commit()
        print(f"Inserted {len(inserted)} {args.kind} row(s) into {args.airspace_schema}.")
        for row_id, name in inserted:
            print(f"- #{row_id}: {name}")
        print("Refresh geomgrids with scripts/refresh_citydb_obstacle_grids.py before using RPC/frontend results.")
        return 0
    except (psycopg.Error, OSError, ScriptError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
