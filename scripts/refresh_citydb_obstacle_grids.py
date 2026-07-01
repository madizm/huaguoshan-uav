#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Build and refresh multi-source geomgrids flight obstacle views.

The generated schema follows docs/multi_source_flight_obstacles_plan.md:
source-specific materialized views are normalized to a common contract and then
UNION ALL'ed into citydb_grid.flight_obstacles. External text output remains
GGER-only; BGC is intentionally not emitted.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Any, Iterable

import psycopg
from psycopg import sql


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
DEFAULT_CITYDB_SCHEMA = "citydb"
DEFAULT_GRID_SCHEMA = "citydb_grid"
DEFAULT_AIRSPACE_SCHEMA = "airspace"
DEFAULT_TOTAL_VIEW_NAME = "flight_obstacles"
DEFAULT_CODES_VIEW_NAME = "flight_obstacles_codes_view"
DEFAULT_PUBLIC_WRAPPER_SCHEMA = "public"
DEFAULT_PUBLIC_WRAPPER_NAME = "flight_obstacles"
DEFAULT_DETAIL_LEVEL = 19
DEFAULT_SAMPLE_SIZE = 5
DEFAULT_TERRAIN_CLEARANCE_M = 30.0
DEFAULT_UNDERGROUND_TOLERANCE_M = 0.0
DEFAULT_ZONE_MAX_HEIGHT_M = 500.0
DEFAULT_AIRSPACE_MODE = "bbox"
DEFAULT_TERRAIN_MODE = "tile-bbox"
DEFAULT_TERRAIN_BLOCK_SIZE_PIXELS = 4

SOURCE_TO_VIEW = {
    "buildings": "obstacles_buildings",
    "terrain": "obstacles_terrain",
    "no-fly-zones": "obstacles_no_fly_zones",
    "temp-control": "obstacles_temp_control_active",
}
SOURCE_ORDER = ("buildings", "terrain", "no-fly-zones", "temp-control")


class ScriptError(RuntimeError):
    """Raised for user-actionable script failures."""


@dataclass(frozen=True)
class SampleRow:
    source_kind: str
    source_id: str
    source_name: str | None
    dimension: int
    detail_level: int | None
    is_agg: bool
    cell_count: int | None
    valid_from: str | None
    valid_to: str | None
    priority: int
    gger_grids: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create/rebuild or refresh multi-source citydb_grid flight obstacle geomgrids views.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument(
        "--source",
        choices=[*SOURCE_ORDER, "all"],
        default="all",
        help="Source materialized view(s) to rebuild/refresh before rebuilding the union view.",
    )
    parser.add_argument("--citydb-schema", default=DEFAULT_CITYDB_SCHEMA, help="3DCityDB schema name.")
    parser.add_argument("--grid-schema", default=DEFAULT_GRID_SCHEMA, help="Schema for generated obstacle views.")
    parser.add_argument("--airspace-schema", default=DEFAULT_AIRSPACE_SCHEMA, help="Schema for no-fly/temp-control business tables.")
    parser.add_argument("--total-view-name", default=DEFAULT_TOTAL_VIEW_NAME, help="Unified materialized view name.")
    parser.add_argument("--codes-view-name", default=DEFAULT_CODES_VIEW_NAME, help="GGER display view name.")
    parser.add_argument("--public-wrapper-schema", default=DEFAULT_PUBLIC_WRAPPER_SCHEMA, help="Schema for ST_FindGridsPath wrapper view.")
    parser.add_argument("--public-wrapper-name", default=DEFAULT_PUBLIC_WRAPPER_NAME, help="Name for ST_FindGridsPath wrapper view.")
    parser.add_argument("--detail-level", type=int, default=DEFAULT_DETAIL_LEVEL, help="GGER/GeoSOT detail level in [6, 32].")
    parser.add_argument("--auto-detail-level", action="store_true", help="Pass -1 to ST_AsGrids/ST_AsGrids3D and let iBEST-DB choose detail level.")
    agg_group = parser.add_mutually_exclusive_group()
    agg_group.add_argument("--agg", dest="is_agg", action="store_true", help="Enable geomgrids aggregation.")
    agg_group.add_argument("--no-agg", dest="is_agg", action="store_false", help="Disable geomgrids aggregation.")
    parser.set_defaults(is_agg=True)

    # Building filters retained from the original building-only script.
    parser.add_argument("--objectid-like", default=None, help="Optional SQL LIKE filter for citydb.feature.objectid, e.g. 'osm:%%'.")
    parser.add_argument("--objectclass-id", type=int, action="append", default=[], help="Optional CityDB objectclass filter for buildings; repeatable.")
    parser.add_argument("--limit", type=int, default=None, help="Optional maximum building features in obstacles_buildings.")

    # Terrain / airspace policy knobs.
    parser.add_argument("--terrain-dataset-key", default=None, help="Optional terrain.dem_dataset.dataset_key filter.")
    parser.add_argument("--terrain-clearance-m", type=float, default=DEFAULT_TERRAIN_CLEARANCE_M, help="Meters added above DEM max_elevation.")
    parser.add_argument("--underground-tolerance-m", type=float, default=DEFAULT_UNDERGROUND_TOLERANCE_M, help="Meters subtracted below DEM min_elevation.")
    parser.add_argument("--default-zone-max-height", type=float, default=DEFAULT_ZONE_MAX_HEIGHT_M, help="Fallback max_height for airspace zones with NULL max_height.")
    parser.add_argument("--planning-time", default=None, help="Optional timestamptz literal for temp-control active filtering; default uses now() at refresh time.")
    parser.add_argument(
        "--airspace-mode",
        choices=["bbox", "polygon-prism"],
        default=DEFAULT_AIRSPACE_MODE,
        help="How no-fly/temp-control polygons are converted to 3D obstacle volumes.",
    )
    parser.add_argument(
        "--terrain-mode",
        choices=["tile-bbox", "block-prism"],
        default=DEFAULT_TERRAIN_MODE,
        help="How DEM terrain is converted to 3D obstacle volumes.",
    )
    parser.add_argument(
        "--terrain-block-size-pixels",
        type=int,
        default=DEFAULT_TERRAIN_BLOCK_SIZE_PIXELS,
        help="DEM pixel block width/height for --terrain-mode block-prism.",
    )

    refresh_group = parser.add_mutually_exclusive_group()
    refresh_group.add_argument("--refresh-only", action="store_true", help="Refresh existing materialized views only; do not rebuild DDL.")
    refresh_group.add_argument("--dry-run", action="store_true", help="Run checks and print source row counts without creating/refeshing views.")
    concur_group = parser.add_mutually_exclusive_group()
    concur_group.add_argument("--concurrently", dest="concurrently", action="store_true", help="Use REFRESH MATERIALIZED VIEW CONCURRENTLY in --refresh-only mode.")
    concur_group.add_argument("--no-concurrently", dest="concurrently", action="store_false", help="Use plain REFRESH MATERIALIZED VIEW in --refresh-only mode.")
    parser.set_defaults(concurrently=True)

    parser.add_argument("--sample-size", type=int, default=DEFAULT_SAMPLE_SIZE, help="Number of sample rows to print.")
    parser.add_argument("--grant-role", default=None, help="Optional DB role to grant usage/select, e.g. web_anon.")
    parser.add_argument("--skip-pgrst-notify", action="store_true", help="Do not run NOTIFY pgrst, 'reload schema'.")
    return parser.parse_args()


def validate_identifier(value: str, label: str) -> None:
    if not value or "\x00" in value:
        raise ScriptError(f"{label} cannot be empty or contain NUL")


def validate_args(args: argparse.Namespace) -> None:
    for value, label in [
        (args.citydb_schema, "--citydb-schema"),
        (args.grid_schema, "--grid-schema"),
        (args.airspace_schema, "--airspace-schema"),
        (args.total_view_name, "--total-view-name"),
        (args.codes_view_name, "--codes-view-name"),
        (args.public_wrapper_schema, "--public-wrapper-schema"),
        (args.public_wrapper_name, "--public-wrapper-name"),
    ]:
        validate_identifier(value, label)
    if args.detail_level < 6 or args.detail_level > 32:
        raise ScriptError("--detail-level must be in [6, 32]")
    if args.limit is not None and args.limit < 1:
        raise ScriptError("--limit must be positive")
    if args.sample_size < 0:
        raise ScriptError("--sample-size cannot be negative")
    if args.terrain_clearance_m < 0:
        raise ScriptError("--terrain-clearance-m cannot be negative")
    if args.underground_tolerance_m < 0:
        raise ScriptError("--underground-tolerance-m cannot be negative")
    if args.default_zone_max_height <= 0:
        raise ScriptError("--default-zone-max-height must be positive")
    if args.terrain_block_size_pixels < 1:
        raise ScriptError("--terrain-block-size-pixels must be positive")
    if args.refresh_only and (args.objectid_like or args.objectclass_id or args.limit is not None):
        raise ScriptError("building filters affect view DDL and cannot be changed with --refresh-only; rebuild instead")


def selected_sources(args: argparse.Namespace) -> tuple[str, ...]:
    if args.source == "all":
        return SOURCE_ORDER
    return (args.source,)


def qname(schema_name: str, relation_name: str) -> sql.Composed:
    return sql.SQL("{}.{}").format(sql.Identifier(schema_name), sql.Identifier(relation_name))


def qname_literal(schema_name: str, relation_name: str) -> str:
    return f"{schema_name}.{relation_name}"


def detail_literal(args: argparse.Namespace) -> sql.Literal:
    return sql.Literal(-1 if args.auto_detail_level else args.detail_level)


def bool_literal(value: bool) -> sql.Literal:
    return sql.Literal(value)


def regclass_exists(conn: psycopg.Connection[Any], schema_name: str, relation_name: str) -> bool:
    with conn.cursor() as cur:
        cur.execute("select to_regclass(%s) is not null", (qname_literal(schema_name, relation_name),))
        return bool(cur.fetchone()[0])


def ensure_database_support(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    """Check required iBEST-DB/PostGIS support and mandatory CityDB tables."""
    with conn.cursor() as cur:
        cur.execute(
            """
            select
              to_regtype('public.geomgrids') is not null as has_geomgrids,
              to_regprocedure('public.st_asgrids3d(geometry,integer,boolean)') is not null as has_asgrids3d,
              to_regprocedure('public.st_astext(geomgrids,text)') is not null as has_astext,
              to_regprocedure('public.st_detaillevel(geomgrids)') is not null as has_detaillevel,
              to_regprocedure('public.st_ncells(geomgrids)') is not null as has_ncells,
              to_regprocedure('public.st_transform(geometry,integer)') is not null as has_transform,
              to_regprocedure('public.st_force2d(geometry)') is not null as has_force2d,
              to_regprocedure('public.st_isempty(geometry)') is not null as has_isempty,
              to_regprocedure('public.st_buffer(geography,double precision)') is not null as has_geography_buffer,
              to_regprocedure('public.st_force3dz(geometry,double precision)') is not null as has_force3dz,
              to_regprocedure('public.st_makevalid(geometry)') is not null as has_makevalid,
              to_regprocedure('public.st_collectionextract(geometry,integer)') is not null as has_collectionextract,
              to_regprocedure('public.st_extrude(geometry,double precision,double precision,double precision)') is not null as has_extrude,
              to_regprocedure('public.st_pixelaspolygons(raster,integer,boolean)') is not null as has_pixelaspolygons
            """
        )
        support = dict(zip([desc.name for desc in cur.description], cur.fetchone(), strict=True))
        missing = [name.removeprefix("has_") for name, ok in support.items() if not ok]
        if missing:
            raise ScriptError("Missing required database support: " + ", ".join(missing) + ". Install/enable PostGIS and iBEST-DB best_geomgrids first.")

        cur.execute(
            """
            select exists (
                select 1
                from pg_opclass opc
                join pg_am am on am.oid = opc.opcmethod
                where opc.opcname = 'gin_grids_ops'
                  and am.amname = 'gin'
            )
            """
        )
        if not cur.fetchone()[0]:
            raise ScriptError("Missing GIN opclass gin_grids_ops for geomgrids")

        if "buildings" in selected_sources(args) or args.source == "all":
            cur.execute("select to_regclass(%s), to_regclass(%s)", (f"{args.citydb_schema}.feature", f"{args.citydb_schema}.geometry_data"))
            feature_regclass, geometry_data_regclass = cur.fetchone()
            if feature_regclass is None or geometry_data_regclass is None:
                raise ScriptError(f"Missing {args.citydb_schema}.feature or {args.citydb_schema}.geometry_data")


def ensure_schemas_and_helpers(cur: psycopg.Cursor[Any], args: argparse.Namespace) -> None:
    cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.grid_schema)))
    cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.airspace_schema)))
    cur.execute(build_bbox_prism_function_sql(args))
    cur.execute(build_polygon_prism_function_sql(args))
    cur.execute(build_airspace_tables_sql(args))


def build_bbox_prism_function_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        r"""
        create or replace function {grid_schema}.make_bbox_prism_3d(
            p_footprint geometry,
            p_min_z double precision,
            p_max_z double precision
        ) returns geometry
        language plpgsql
        immutable
        parallel safe
        as $func$
        declare
            env geometry;
            minx double precision;
            miny double precision;
            maxx double precision;
            maxy double precision;
            lo_z double precision;
            hi_z double precision;
            srid integer;
        begin
            if p_footprint is null or public.ST_IsEmpty(p_footprint) or p_min_z is null or p_max_z is null then
                return null;
            end if;
            lo_z := least(p_min_z, p_max_z);
            hi_z := greatest(p_min_z, p_max_z);
            if lo_z = hi_z then
                hi_z := lo_z + 0.01;
            end if;

            srid := public.ST_SRID(p_footprint);
            env := public.ST_Envelope(public.ST_Force2D(p_footprint));
            minx := public.ST_XMin(public.Box3D(env));
            miny := public.ST_YMin(public.Box3D(env));
            maxx := public.ST_XMax(public.Box3D(env));
            maxy := public.ST_YMax(public.Box3D(env));

            if minx = maxx or miny = maxy then
                return null;
            end if;

            return public.ST_SetSRID(public.ST_GeomFromText(format(
                'POLYHEDRALSURFACE Z (' ||
                '((%1$s %2$s %5$s,%1$s %4$s %5$s,%3$s %4$s %5$s,%3$s %2$s %5$s,%1$s %2$s %5$s)),' ||
                '((%1$s %2$s %6$s,%3$s %2$s %6$s,%3$s %4$s %6$s,%1$s %4$s %6$s,%1$s %2$s %6$s)),' ||
                '((%1$s %2$s %5$s,%3$s %2$s %5$s,%3$s %2$s %6$s,%1$s %2$s %6$s,%1$s %2$s %5$s)),' ||
                '((%3$s %2$s %5$s,%3$s %4$s %5$s,%3$s %4$s %6$s,%3$s %2$s %6$s,%3$s %2$s %5$s)),' ||
                '((%3$s %4$s %5$s,%1$s %4$s %5$s,%1$s %4$s %6$s,%3$s %4$s %6$s,%3$s %4$s %5$s)),' ||
                '((%1$s %4$s %5$s,%1$s %2$s %5$s,%1$s %2$s %6$s,%1$s %4$s %6$s,%1$s %4$s %5$s))' ||
                ')',
                minx, miny, maxx, maxy, lo_z, hi_z
            )), srid);
        end;
        $func$
        """
    ).format(grid_schema=sql.Identifier(args.grid_schema))


def build_polygon_prism_function_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        r"""
        create or replace function {grid_schema}.make_polygon_prism_3d(
            p_footprint geometry,
            p_min_z double precision,
            p_max_z double precision
        ) returns geometry
        language plpgsql
        immutable
        parallel safe
        as $func$
        declare
            lo_z double precision;
            hi_z double precision;
            clean_footprint geometry;
            srid integer;
        begin
            if p_footprint is null or public.ST_IsEmpty(p_footprint) or p_min_z is null or p_max_z is null then
                return null;
            end if;

            lo_z := least(p_min_z, p_max_z);
            hi_z := greatest(p_min_z, p_max_z);
            if lo_z = hi_z then
                hi_z := lo_z + 0.01;
            end if;

            srid := public.ST_SRID(p_footprint);
            clean_footprint := public.ST_CollectionExtract(public.ST_MakeValid(public.ST_Force2D(p_footprint)), 3);
            if clean_footprint is null or public.ST_IsEmpty(clean_footprint) then
                return null;
            end if;

            return public.ST_SetSRID(public.ST_Extrude(public.ST_Force3DZ(clean_footprint, lo_z), 0, 0, hi_z - lo_z), srid);
        end;
        $func$
        """
    ).format(grid_schema=sql.Identifier(args.grid_schema))


def build_airspace_tables_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create table if not exists {airspace_schema}.no_fly_zone (
          id bigserial primary key,
          name text not null,
          geom geometry(MultiPolygon, 4326) not null,
          min_height double precision default 0,
          max_height double precision,
          safety_buffer_m double precision default 0,
          enabled boolean default true,
          created_at timestamptz default now(),
          updated_at timestamptz default now()
        );

        create index if not exists no_fly_zone_geom_gix
          on {airspace_schema}.no_fly_zone using gist (geom);
        create index if not exists no_fly_zone_enabled_idx
          on {airspace_schema}.no_fly_zone (enabled);

        create table if not exists {airspace_schema}.temp_control_zone (
          id bigserial primary key,
          name text not null,
          geom geometry(MultiPolygon, 4326) not null,
          min_height double precision default 0,
          max_height double precision,
          safety_buffer_m double precision default 0,
          valid_from timestamptz not null,
          valid_to timestamptz not null,
          status text not null default 'planned',
          created_at timestamptz default now(),
          updated_at timestamptz default now(),
          constraint temp_control_zone_valid_window_chk check (valid_to > valid_from),
          constraint temp_control_zone_status_chk check (status in ('planned', 'active', 'cancelled'))
        );

        create index if not exists temp_control_zone_geom_gix
          on {airspace_schema}.temp_control_zone using gist (geom);
        create index if not exists temp_control_zone_active_window_idx
          on {airspace_schema}.temp_control_zone (status, valid_from, valid_to);
        """
    ).format(airspace_schema=sql.Identifier(args.airspace_schema))


def build_empty_obstacle_view_sql(args: argparse.Namespace, view_name: str) -> sql.Composed:
    return sql.SQL(
        """
        create materialized view {target_view} as
        select
            null::text as source_kind,
            null::text as source_id,
            null::text as source_name,
            null::smallint as dimension,
            null::integer as detail_level,
            null::boolean as is_agg,
            null::public.geomgrids as grids,
            null::timestamptz as valid_from,
            null::timestamptz as valid_to,
            null::integer as priority,
            null::timestamptz as generated_at
        where false
        """
    ).format(target_view=qname(args.grid_schema, view_name))


def build_building_where_clause(args: argparse.Namespace) -> sql.Composed:
    where_parts: list[sql.Composable] = [
        sql.SQL("gd.geometry is not null"),
        sql.SQL("not public.ST_IsEmpty(gd.geometry)"),
        sql.SQL("public.ST_SRID(gd.geometry) > 0"),
    ]
    if args.objectid_like is not None:
        where_parts.append(sql.SQL("f.objectid like {}").format(sql.Literal(args.objectid_like)))
    if args.objectclass_id:
        ids = sql.SQL(", ").join(sql.Literal(value) for value in args.objectclass_id)
        where_parts.append(sql.SQL("f.objectclass_id in ({})").format(ids))
    return sql.SQL(" and ").join(where_parts)


def build_ranked_geometry_cte(args: argparse.Namespace) -> sql.Composed:
    limit_clause = sql.SQL("")
    if args.limit is not None:
        limit_clause = sql.SQL("\n            limit {}").format(sql.Literal(args.limit))
    return sql.SQL(
        """
        ranked_geometry as (
            select distinct on (f.id)
                f.id as feature_id,
                f.objectid,
                gd.id as geometry_id,
                gd.geometry
            from {citydb_schema}.feature f
            join {citydb_schema}.geometry_data gd on gd.feature_id = f.id
            where {where_clause}
            order by
                f.id,
                public.ST_Area(public.ST_Envelope(public.ST_Force2D(gd.geometry))) desc nulls last,
                gd.id{limit_clause}
        )
        """
    ).format(
        citydb_schema=sql.Identifier(args.citydb_schema),
        where_clause=build_building_where_clause(args),
        limit_clause=limit_clause,
    )


def build_obstacles_buildings_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create materialized view {target_view} as
        with {ranked_geometry_cte}, generated_grids as (
            select
                'building'::text as source_kind,
                geometry_id::text as source_id,
                coalesce(objectid, feature_id::text) as source_name,
                3::smallint as dimension,
                {is_agg}::boolean as is_agg,
                public.ST_AsGrids3D(public.ST_Transform(geometry, 4326), {detail_level}, {is_agg}) as grids,
                now() as generated_at
            from ranked_geometry
        )
        select
            source_kind,
            source_id,
            source_name,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            null::timestamptz as valid_from,
            null::timestamptz as valid_to,
            100::integer as priority,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, SOURCE_TO_VIEW["buildings"]),
        ranked_geometry_cte=build_ranked_geometry_cte(args),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def build_obstacles_terrain_sql(args: argparse.Namespace, has_terrain_tables: bool) -> sql.Composed:
    if not has_terrain_tables:
        return build_empty_obstacle_view_sql(args, SOURCE_TO_VIEW["terrain"])

    dataset_filter = sql.SQL("")
    if args.terrain_dataset_key is not None:
        dataset_filter = sql.SQL("and ds.dataset_key = {} ").format(sql.Literal(args.terrain_dataset_key))

    if args.terrain_mode == "block-prism":
        return sql.SQL(
            """
            create materialized view {target_view} as
            with pixels as (
                select
                    t.id as tile_pk,
                    coalesce(ds.dataset_key, ds.id::text) as dataset_key,
                    coalesce(t.tile_id, t.id::text) as tile_name,
                    ((px.x - 1) / {block_size})::integer as block_x,
                    ((px.y - 1) / {block_size})::integer as block_y,
                    px.geom,
                    px.val::double precision as elevation
                from terrain.dem_tile t
                join terrain.dem_dataset ds on ds.id = t.dataset_id
                cross join lateral public.ST_PixelAsPolygons(t.rast, 1, true) as px(geom, val, x, y)
                where t.rast is not null
                  {dataset_filter}
            ), blocks as (
                select
                    tile_pk,
                    dataset_key,
                    tile_name,
                    block_x,
                    block_y,
                    public.ST_Envelope(public.ST_Collect(geom)) as extent,
                    (min(elevation) - {underground_tolerance})::double precision as min_z,
                    (max(elevation) + {terrain_clearance})::double precision as max_z
                from pixels
                where elevation is not null
                group by tile_pk, dataset_key, tile_name, block_x, block_y
            ), generated_grids as (
                select
                    'terrain'::text as source_kind,
                    (dataset_key || ':' || tile_pk::text || ':block:' || block_x::text || ':' || block_y::text) as source_id,
                    (dataset_key || ':' || tile_name || ':block:' || block_x::text || ':' || block_y::text) as source_name,
                    3::smallint as dimension,
                    {is_agg}::boolean as is_agg,
                    public.ST_AsGrids3D(
                        public.ST_Transform({grid_schema}.make_bbox_prism_3d(extent, min_z, max_z), 4326),
                        {detail_level},
                        {is_agg}
                    ) as grids,
                    now() as generated_at
                from blocks
                where extent is not null
                  and not public.ST_IsEmpty(extent)
                  and max_z > min_z
            )
            select
                source_kind,
                source_id,
                source_name,
                dimension,
                public.ST_DetailLevel(grids)::integer as detail_level,
                is_agg,
                grids,
                null::timestamptz as valid_from,
                null::timestamptz as valid_to,
                50::integer as priority,
                generated_at
            from generated_grids
            where grids is not null
            """
        ).format(
            target_view=qname(args.grid_schema, SOURCE_TO_VIEW["terrain"]),
            block_size=sql.Literal(args.terrain_block_size_pixels),
            underground_tolerance=sql.Literal(args.underground_tolerance_m),
            terrain_clearance=sql.Literal(args.terrain_clearance_m),
            dataset_filter=dataset_filter,
            grid_schema=sql.Identifier(args.grid_schema),
            detail_level=detail_literal(args),
            is_agg=bool_literal(args.is_agg),
        )

    return sql.SQL(
        """
        create materialized view {target_view} as
        with prepared as (
            select
                t.id as tile_id,
                coalesce(ds.dataset_key, ds.id::text) as dataset_key,
                coalesce(t.tile_id, t.id::text) as tile_name,
                t.extent,
                (t.min_elevation - {underground_tolerance})::double precision as min_z,
                (t.max_elevation + {terrain_clearance})::double precision as max_z
            from terrain.dem_tile t
            join terrain.dem_dataset ds on ds.id = t.dataset_id
            where t.extent is not null
              and not public.ST_IsEmpty(t.extent)
              and t.min_elevation is not null
              and t.max_elevation is not null
              {dataset_filter}
        ), generated_grids as (
            select
                'terrain'::text as source_kind,
                (dataset_key || ':' || tile_id::text) as source_id,
                (dataset_key || ':' || tile_name) as source_name,
                3::smallint as dimension,
                {is_agg}::boolean as is_agg,
                public.ST_AsGrids3D(
                    public.ST_Transform({grid_schema}.make_bbox_prism_3d(extent, min_z, max_z), 4326),
                    {detail_level},
                    {is_agg}
                ) as grids,
                now() as generated_at
            from prepared
        )
        select
            source_kind,
            source_id,
            source_name,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            null::timestamptz as valid_from,
            null::timestamptz as valid_to,
            50::integer as priority,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, SOURCE_TO_VIEW["terrain"]),
        underground_tolerance=sql.Literal(args.underground_tolerance_m),
        terrain_clearance=sql.Literal(args.terrain_clearance_m),
        dataset_filter=dataset_filter,
        grid_schema=sql.Identifier(args.grid_schema),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def build_obstacles_no_fly_zones_sql(args: argparse.Namespace) -> sql.Composed:
    airspace_volume = sql.SQL("{grid_schema}.make_polygon_prism_3d(footprint, min_z, max_z)") if args.airspace_mode == "polygon-prism" else sql.SQL("{grid_schema}.make_bbox_prism_3d(footprint, min_z, max_z)")
    return sql.SQL(
        """
        create materialized view {target_view} as
        with prepared as (
            select
                id,
                name,
                case
                    when coalesce(safety_buffer_m, 0) > 0
                    then public.ST_Buffer(geom::geography, safety_buffer_m)::geometry
                    else geom
                end as footprint,
                coalesce(min_height, 0)::double precision as min_z,
                coalesce(max_height, {default_max_height})::double precision as max_z
            from {airspace_schema}.no_fly_zone
            where enabled is true
              and geom is not null
              and not public.ST_IsEmpty(geom)
        ), generated_grids as (
            select
                'no_fly_zone'::text as source_kind,
                id::text as source_id,
                name as source_name,
                3::smallint as dimension,
                {is_agg}::boolean as is_agg,
                public.ST_AsGrids3D(
                    public.ST_Transform({airspace_volume}, 4326),
                    {detail_level},
                    {is_agg}
                ) as grids,
                now() as generated_at
            from prepared
            where max_z > min_z
        )
        select
            source_kind,
            source_id,
            source_name,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            null::timestamptz as valid_from,
            null::timestamptz as valid_to,
            1000::integer as priority,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, SOURCE_TO_VIEW["no-fly-zones"]),
        airspace_schema=sql.Identifier(args.airspace_schema),
        default_max_height=sql.Literal(args.default_zone_max_height),
        airspace_volume=airspace_volume.format(grid_schema=sql.Identifier(args.grid_schema)),
        grid_schema=sql.Identifier(args.grid_schema),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def planning_time_expression(args: argparse.Namespace) -> sql.Composable:
    if args.planning_time:
        return sql.SQL("{}::timestamptz").format(sql.Literal(args.planning_time))
    return sql.SQL("now()")


def build_obstacles_temp_control_sql(args: argparse.Namespace) -> sql.Composed:
    planning_time = planning_time_expression(args)
    airspace_volume = sql.SQL("{grid_schema}.make_polygon_prism_3d(footprint, min_z, max_z)") if args.airspace_mode == "polygon-prism" else sql.SQL("{grid_schema}.make_bbox_prism_3d(footprint, min_z, max_z)")
    return sql.SQL(
        """
        create materialized view {target_view} as
        with prepared as (
            select
                id,
                name,
                case
                    when coalesce(safety_buffer_m, 0) > 0
                    then public.ST_Buffer(geom::geography, safety_buffer_m)::geometry
                    else geom
                end as footprint,
                coalesce(min_height, 0)::double precision as min_z,
                coalesce(max_height, {default_max_height})::double precision as max_z,
                valid_from,
                valid_to
            from {airspace_schema}.temp_control_zone
            where status in ('planned', 'active')
              and {planning_time} >= valid_from
              and {planning_time} < valid_to
              and geom is not null
              and not public.ST_IsEmpty(geom)
        ), generated_grids as (
            select
                'temp_control'::text as source_kind,
                id::text as source_id,
                name as source_name,
                3::smallint as dimension,
                {is_agg}::boolean as is_agg,
                public.ST_AsGrids3D(
                    public.ST_Transform({airspace_volume}, 4326),
                    {detail_level},
                    {is_agg}
                ) as grids,
                valid_from,
                valid_to,
                now() as generated_at
            from prepared
            where max_z > min_z
        )
        select
            source_kind,
            source_id,
            source_name,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            valid_from,
            valid_to,
            1100::integer as priority,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, SOURCE_TO_VIEW["temp-control"]),
        airspace_schema=sql.Identifier(args.airspace_schema),
        default_max_height=sql.Literal(args.default_zone_max_height),
        planning_time=planning_time,
        airspace_volume=airspace_volume.format(grid_schema=sql.Identifier(args.grid_schema)),
        grid_schema=sql.Identifier(args.grid_schema),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def source_view_sql(args: argparse.Namespace, source: str, has_terrain_tables: bool) -> sql.Composed:
    if source == "buildings":
        return build_obstacles_buildings_sql(args)
    if source == "terrain":
        return build_obstacles_terrain_sql(args, has_terrain_tables)
    if source == "no-fly-zones":
        return build_obstacles_no_fly_zones_sql(args)
    if source == "temp-control":
        return build_obstacles_temp_control_sql(args)
    raise AssertionError(f"Unhandled source: {source}")


def build_total_view_sql(args: argparse.Namespace) -> sql.Composed:
    selects = sql.SQL("\n        union all\n").join(
        sql.SQL("select * from {}").format(qname(args.grid_schema, SOURCE_TO_VIEW[source])) for source in SOURCE_ORDER
    )
    return sql.SQL("create materialized view {target_view} as\n        {selects}").format(
        target_view=qname(args.grid_schema, args.total_view_name),
        selects=selects,
    )


def build_codes_view_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create or replace view {codes_view} as
        select
            source_kind,
            source_id,
            source_name,
            dimension,
            detail_level,
            public.ST_nCells(grids)::integer as cell_count,
            public.ST_AsText(grids, 'GGER') as gger_grids,
            valid_from,
            valid_to,
            priority,
            generated_at
        from {target_view}
        """
    ).format(
        codes_view=qname(args.grid_schema, args.codes_view_name),
        target_view=qname(args.grid_schema, args.total_view_name),
    )


def build_public_wrapper_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create or replace view {wrapper_view} as
        select
            row_number() over (order by source_kind, source_id) as id,
            grids
        from {target_view}
        """
    ).format(
        wrapper_view=qname(args.public_wrapper_schema, args.public_wrapper_name),
        target_view=qname(args.grid_schema, args.total_view_name),
    )


def view_depends_on_relation(conn: psycopg.Connection[Any], view_schema: str, view_name: str, target_schema: str, target_name: str) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            """
            select exists (
                select 1
                from pg_rewrite rw
                join pg_depend dep on dep.objid = rw.oid
                join pg_class view_rel on view_rel.oid = rw.ev_class
                join pg_namespace view_ns on view_ns.oid = view_rel.relnamespace
                join pg_class target_rel on target_rel.oid = dep.refobjid
                join pg_namespace target_ns on target_ns.oid = target_rel.relnamespace
                where view_ns.nspname = %s
                  and view_rel.relname = %s
                  and view_rel.relkind = 'v'
                  and target_ns.nspname = %s
                  and target_rel.relname = %s
            )
            """,
            (view_schema, view_name, target_schema, target_name),
        )
        return bool(cur.fetchone()[0])


def drop_dependent_views(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    with conn.cursor() as cur:
        cur.execute(sql.SQL("drop view if exists {}").format(qname(args.grid_schema, args.codes_view_name)))
    if view_depends_on_relation(conn, args.public_wrapper_schema, args.public_wrapper_name, args.grid_schema, args.total_view_name):
        with conn.cursor() as cur:
            cur.execute(sql.SQL("drop view if exists {}").format(qname(args.public_wrapper_schema, args.public_wrapper_name)))


def create_source_indexes(cur: psycopg.Cursor[Any], args: argparse.Namespace, view_name: str) -> None:
    target = qname(args.grid_schema, view_name)
    cur.execute(
        sql.SQL("create unique index {index_name} on {target_view} (source_kind, source_id)").format(
            index_name=sql.Identifier(f"{view_name}_source_uidx"),
            target_view=target,
        )
    )
    cur.execute(
        sql.SQL("create index {index_name} on {target_view} (source_kind)").format(
            index_name=sql.Identifier(f"{view_name}_source_kind_idx"),
            target_view=target,
        )
    )
    cur.execute(
        sql.SQL("create index {index_name} on {target_view} using gin (grids gin_grids_ops)").format(
            index_name=sql.Identifier(f"{view_name}_grids_gin_idx"),
            target_view=target,
        )
    )


def grant_generated_objects(cur: psycopg.Cursor[Any], args: argparse.Namespace) -> None:
    role = sql.Identifier(args.grant_role)
    cur.execute(sql.SQL("grant usage on schema {} to {}").format(sql.Identifier(args.grid_schema), role))
    cur.execute(sql.SQL("grant usage on schema {} to {}").format(sql.Identifier(args.airspace_schema), role))
    cur.execute(sql.SQL("grant usage on schema {} to {}").format(sql.Identifier(args.public_wrapper_schema), role))
    relations = [
        qname(args.grid_schema, args.total_view_name),
        qname(args.grid_schema, args.codes_view_name),
        qname(args.public_wrapper_schema, args.public_wrapper_name),
        *(qname(args.grid_schema, SOURCE_TO_VIEW[source]) for source in SOURCE_ORDER),
    ]
    cur.execute(sql.SQL("grant select on {} to {}").format(sql.SQL(", ").join(relations), role))


def ensure_all_source_views_exist(cur: psycopg.Cursor[Any], args: argparse.Namespace, has_terrain_tables: bool) -> None:
    for source in SOURCE_ORDER:
        view_name = SOURCE_TO_VIEW[source]
        cur.execute("select to_regclass(%s) is not null", (qname_literal(args.grid_schema, view_name),))
        exists = bool(cur.fetchone()[0])
        if not exists:
            cur.execute(source_view_sql(args, source, has_terrain_tables))
            create_source_indexes(cur, args, view_name)


def rebuild_views(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    sources = selected_sources(args)
    has_terrain_tables = regclass_exists(conn, "terrain", "dem_tile") and regclass_exists(conn, "terrain", "dem_dataset")
    drop_dependent_views(conn, args)
    with conn.cursor() as cur:
        ensure_schemas_and_helpers(cur, args)
        cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, args.total_view_name)))
        for source in sources:
            cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, SOURCE_TO_VIEW[source])))
            cur.execute(source_view_sql(args, source, has_terrain_tables))
            create_source_indexes(cur, args, SOURCE_TO_VIEW[source])

        ensure_all_source_views_exist(cur, args, has_terrain_tables)
        cur.execute(build_total_view_sql(args))
        create_source_indexes(cur, args, args.total_view_name)
        cur.execute(build_codes_view_sql(args))
        cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.public_wrapper_schema)))
        cur.execute(build_public_wrapper_sql(args))
        if args.grant_role:
            grant_generated_objects(cur, args)
        if not args.skip_pgrst_notify:
            cur.execute("notify pgrst, 'reload schema'")


def refresh_one(cur: psycopg.Cursor[Any], args: argparse.Namespace, schema_name: str, view_name: str) -> None:
    refresh_keyword = sql.SQL("concurrently ") if args.concurrently else sql.SQL("")
    cur.execute(sql.SQL("refresh materialized view {}{}").format(refresh_keyword, qname(schema_name, view_name)))


def refresh_views(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    sources = selected_sources(args)
    with conn.cursor() as cur:
        for source in sources:
            refresh_one(cur, args, args.grid_schema, SOURCE_TO_VIEW[source])
        refresh_one(cur, args, args.grid_schema, args.total_view_name)
        cur.execute(build_codes_view_sql(args))
        cur.execute(build_public_wrapper_sql(args))
        if args.grant_role:
            grant_generated_objects(cur, args)
        if not args.skip_pgrst_notify:
            cur.execute("notify pgrst, 'reload schema'")


def source_base_counts(conn: psycopg.Connection[Any], args: argparse.Namespace) -> dict[str, int | str]:
    counts: dict[str, int | str] = {}
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                select count(*)
                from {citydb_schema}.feature f
                join {citydb_schema}.geometry_data gd on gd.feature_id = f.id
                where {where_clause}
                """
            ).format(citydb_schema=sql.Identifier(args.citydb_schema), where_clause=build_building_where_clause(args))
        )
        counts["buildings"] = int(cur.fetchone()[0])

        if regclass_exists(conn, "terrain", "dem_tile") and regclass_exists(conn, "terrain", "dem_dataset"):
            if args.terrain_dataset_key:
                cur.execute(
                    """
                    select count(*)
                    from terrain.dem_tile t
                    join terrain.dem_dataset ds on ds.id = t.dataset_id
                    where ds.dataset_key = %s
                    """,
                    (args.terrain_dataset_key,),
                )
            else:
                cur.execute("select count(*) from terrain.dem_tile")
            counts["terrain"] = int(cur.fetchone()[0])
        else:
            counts["terrain"] = "missing terrain.dem_dataset/dem_tile (will create empty obstacle view)"

        if regclass_exists(conn, args.airspace_schema, "no_fly_zone"):
            cur.execute(sql.SQL("select count(*) from {} where enabled is true").format(qname(args.airspace_schema, "no_fly_zone")))
            counts["no-fly-zones"] = int(cur.fetchone()[0])
        else:
            counts["no-fly-zones"] = f"missing {args.airspace_schema}.no_fly_zone (will be created on rebuild)"

        if regclass_exists(conn, args.airspace_schema, "temp_control_zone"):
            cur.execute(
                sql.SQL(
                    """
                    select count(*)
                    from {temp_table}
                    where status in ('planned', 'active')
                      and {planning_time} >= valid_from
                      and {planning_time} < valid_to
                    """
                ).format(temp_table=qname(args.airspace_schema, "temp_control_zone"), planning_time=planning_time_expression(args))
            )
            counts["temp-control"] = int(cur.fetchone()[0])
        else:
            counts["temp-control"] = f"missing {args.airspace_schema}.temp_control_zone (will be created on rebuild)"
    return counts


def relation_count(conn: psycopg.Connection[Any], schema_name: str, relation_name: str) -> int:
    with conn.cursor() as cur:
        cur.execute(sql.SQL("select count(*) from {}").format(qname(schema_name, relation_name)))
        return int(cur.fetchone()[0])


def fetch_samples(conn: psycopg.Connection[Any], args: argparse.Namespace) -> list[SampleRow]:
    if args.sample_size <= 0:
        return []
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                select
                    source_kind,
                    source_id,
                    source_name,
                    dimension,
                    detail_level,
                    is_agg,
                    public.ST_nCells(grids)::integer as cell_count,
                    valid_from::text,
                    valid_to::text,
                    priority,
                    public.ST_AsText(grids, 'GGER') as gger_grids
                from {target_view}
                order by priority desc, source_kind, source_id
                limit {sample_size}
                """
            ).format(target_view=qname(args.grid_schema, args.total_view_name), sample_size=sql.Literal(args.sample_size))
        )
        return [row_to_sample(row) for row in cur.fetchall()]


def coerce_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, memoryview):
        return bytes(value).decode("utf-8", errors="replace")
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8", errors="replace")
    return str(value)


def row_to_sample(row: tuple[Any, ...]) -> SampleRow:
    return SampleRow(
        source_kind=coerce_text(row[0]) or "",
        source_id=coerce_text(row[1]) or "",
        source_name=coerce_text(row[2]),
        dimension=int(row[3]),
        detail_level=int(row[4]) if row[4] is not None else None,
        is_agg=bool(row[5]),
        cell_count=int(row[6]) if row[6] is not None else None,
        valid_from=coerce_text(row[7]),
        valid_to=coerce_text(row[8]),
        priority=int(row[9]),
        gger_grids=coerce_text(row[10]),
    )


def print_counts(title: str, counts: dict[str, int | str]) -> None:
    print(title)
    for source in SOURCE_ORDER:
        print(f"- {source}: {counts[source]}")


def print_samples(total_count: int, samples: Iterable[SampleRow]) -> None:
    print(f"Unified obstacle rows: {total_count}")
    sample_list = list(samples)
    if not sample_list:
        print("No sample rows available.")
        return
    print("Sample GGER grids:")
    for row in sample_list:
        label = row.source_name or f"{row.source_kind}:{row.source_id}"
        gger = (row.gger_grids or "").strip()
        if len(gger) > 220:
            gger = gger[:217] + "..."
        validity = ""
        if row.valid_from or row.valid_to:
            validity = f", valid={row.valid_from or '-'}..{row.valid_to or '-'}"
        print(
            f"- {label} ({row.source_kind}:{row.source_id}, dim={row.dimension}, "
            f"detail={row.detail_level}, cells={row.cell_count}, priority={row.priority}{validity}): {gger or '-'}"
        )


def print_post_action_hint(args: argparse.Namespace) -> None:
    print(f"Unified materialized view: {qname_literal(args.grid_schema, args.total_view_name)}")
    for source in SOURCE_ORDER:
        print(f"Source view: {qname_literal(args.grid_schema, SOURCE_TO_VIEW[source])}")
    print(f"GGER display view: {qname_literal(args.grid_schema, args.codes_view_name)}")
    print(f"ST_FindGridsPath wrapper: {qname_literal(args.public_wrapper_schema, args.public_wrapper_name)} (id, grids)")
    print(f"Generation modes: airspace={args.airspace_mode}, terrain={args.terrain_mode}")
    print("External display contract: GGER only; BGC is not emitted by generated views.")


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        with psycopg.connect(args.dsn, connect_timeout=15, autocommit=True) as conn:
            ensure_database_support(conn, args)

            if args.dry_run:
                print_counts("Candidate source rows:", source_base_counts(conn, args))
                print("Dry run: no schemas, tables, functions, or obstacle materialized views were created/refreshed.")
                return 0

            with conn.cursor() as cur:
                ensure_schemas_and_helpers(cur, args)

            if args.refresh_only:
                refresh_views(conn, args)
                action = "Refreshed"
            else:
                rebuild_views(conn, args)
                action = "Rebuilt"

            total_count = relation_count(conn, args.grid_schema, args.total_view_name)
            print(f"{action} {qname_literal(args.grid_schema, args.total_view_name)}.")
            for source in SOURCE_ORDER:
                print(f"- {qname_literal(args.grid_schema, SOURCE_TO_VIEW[source])}: {relation_count(conn, args.grid_schema, SOURCE_TO_VIEW[source])} rows")
            print_samples(total_count, fetch_samples(conn, args))
            print_post_action_hint(args)
            return 0
    except (psycopg.Error, ScriptError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
