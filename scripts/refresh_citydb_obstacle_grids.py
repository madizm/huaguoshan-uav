#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Build and refresh multi-source geomgrids flight obstacle views.

中文说明：
    这是当前推荐使用的“多来源飞行障碍物网格生成脚本”。它把建筑、地形、
    禁飞区、临时管制区分别转换为统一结构的 ``geomgrids`` 物化视图，再用
    ``UNION ALL`` 汇总成一个对外使用的总视图。

主要输出：
    - ``citydb_grid.obstacles_buildings``：3DCityDB 建筑/几何障碍物。
    - ``citydb_grid.obstacles_terrain``：DEM 地形障碍物。
    - ``citydb_grid.obstacles_no_fly_zones``：长期禁飞区障碍物。
    - ``citydb_grid.obstacles_temp_control_active``：当前有效的临时管制区。
    - ``citydb_grid.flight_obstacles``：上述来源的统一总物化视图。
    - ``citydb_grid.flight_obstacles_codes_view``：GGER 文本展示视图。
    - ``public.flight_obstacles``：兼容 ``ST_FindGridsPath`` 的 ``id, grids`` wrapper。

运行模式：
    - 默认 ``--source all`` 会重建/刷新所有来源。
    - 可以用 ``--source buildings`` 等参数只处理某个来源。
    - ``--refresh-only`` 只刷新已有物化视图，不改变 DDL。
    - ``--source airspace`` 只处理长期禁飞区与临时管制区。
    - ``--refresh-total`` 在单来源/airspace 刷新后同步刷新统一总障碍视图。
    - ``--dry-run`` 只检查候选源数据数量，不创建或刷新对象。

External display contract:
    GGER only; BGC is intentionally not emitted by generated views/APIs.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from dataclasses import dataclass
from typing import Any, Callable, Iterable

import psycopg
from psycopg import sql


# 默认连接到花果山项目库；生产/测试环境建议用 CITYDB_DSN 或 --dsn 覆盖。
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
DEFAULT_TERRAIN_LOD_VIEW_NAME = "obstacles_terrain_lod"
DEFAULT_TERRAIN_LOD_SPEC = "0:32:15,1:16:17,2:4:19"

# 每个 source 都先落到一个同构的 source-specific 物化视图，再汇总到总视图。
SOURCE_TO_VIEW = {
    "buildings": "obstacles_buildings",
    "terrain": "obstacles_terrain",
    "no-fly-zones": "obstacles_no_fly_zones",
    "temp-control": "obstacles_temp_control_active",
}
SOURCE_ORDER = ("buildings", "terrain", "no-fly-zones", "temp-control")
AIRSPACE_SOURCES = ("no-fly-zones", "temp-control")


class ScriptError(RuntimeError):
    """Raised for user-actionable script failures."""


@dataclass(frozen=True)
class SampleRow:
    """Small diagnostic row printed from the unified obstacle view."""

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


@dataclass(frozen=True)
class TerrainLodSpec:
    """Display-only terrain LOD generation spec.

    ``lod_level`` is a frontend/display level, ``block_size_px`` controls DEM
    pixel aggregation, and ``detail_level`` controls GGER/GeoSOT grid precision.
    """

    lod_level: int
    block_size_px: int
    detail_level: int


@dataclass(frozen=True)
class ObstacleSourceAdapter:
    """Internal seam for a source that produces standard 飞行障碍 rows."""

    source: str
    view_name: str
    description: str
    build_view_sql: Callable[[], sql.Composed]


@dataclass(frozen=True)
class AirspaceConstraintObstacleAdapter:
    """Configured adapter for 空域约束 sources that share one implementation."""

    args: argparse.Namespace
    has_terrain_tables: bool
    source: str
    view_name: str
    source_kind: str
    table_name: str
    priority: int
    description: str
    enabled_filter_sql: sql.Composable
    include_validity_window: bool = False

    def build_view_sql(self) -> sql.Composed:
        return build_airspace_constraint_obstacles_sql(self.args, self, self.has_terrain_tables)


@dataclass(frozen=True)
class TerrainLodDisplayAdapter:
    """Display-only adapter kept out of the unified route-planning view."""

    args: argparse.Namespace
    has_terrain_tables: bool
    source: str = "terrain-lod-display"
    view_name: str = DEFAULT_TERRAIN_LOD_VIEW_NAME
    description: str = "display-only terrain LOD adapter"

    def build_view_sql(self) -> sql.Composed:
        return build_obstacles_terrain_lod_sql(self.args, self.has_terrain_tables)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create/rebuild or refresh multi-source citydb_grid flight obstacle geomgrids views.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument(
        "--source",
        choices=[*SOURCE_ORDER, "airspace", "all"],
        default="all",
        help="Source materialized view(s) to rebuild/refresh. Use --refresh-total to update the union view for non-all sources.",
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
    parser.add_argument(
        "--terrain-min-max-elevation-m",
        type=float,
        default=None,
        help=(
            "Optional absolute terrain filter: skip terrain tiles/blocks whose raw DEM max_elevation "
            "is below this orthometric height in metres. Use only when a separate ground/AGL "
            "constraint already prevents ground collision."
        ),
    )
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
    parser.add_argument(
        "--terrain-lod-display",
        action="store_true",
        help="Create/refresh the display-only terrain LOD materialized view for adaptive frontend loading.",
    )
    parser.add_argument(
        "--terrain-lod-view-name",
        default=DEFAULT_TERRAIN_LOD_VIEW_NAME,
        help="Display-only terrain LOD materialized view name in --grid-schema.",
    )
    parser.add_argument(
        "--terrain-lod-spec",
        default=DEFAULT_TERRAIN_LOD_SPEC,
        help="Comma-separated terrain display LOD specs as lod:block_size_pixels:detail_level.",
    )

    refresh_group = parser.add_mutually_exclusive_group()
    refresh_group.add_argument("--refresh-only", action="store_true", help="Refresh existing materialized views only; do not rebuild DDL.")
    refresh_group.add_argument("--dry-run", action="store_true", help="Run checks and print source row counts without creating/refeshing views.")
    parser.add_argument(
        "--refresh-total",
        action="store_true",
        help=(
            "After refreshing/rebuilding selected source view(s), also refresh/rebuild the unified "
            "flight_obstacles view, wrapper, and codes view without refreshing unrelated sources. "
            "Implicit for --source all."
        ),
    )
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


def parse_terrain_lod_spec(value: str) -> tuple[TerrainLodSpec, ...]:
    specs: list[TerrainLodSpec] = []
    seen_levels: set[int] = set()
    for raw_part in value.split(","):
        part = raw_part.strip()
        if not part:
            continue
        pieces = part.split(":")
        if len(pieces) != 3:
            raise ScriptError("--terrain-lod-spec entries must be lod:block_size_pixels:detail_level")
        try:
            lod_level, block_size_px, detail_level = (int(piece) for piece in pieces)
        except ValueError as exc:
            raise ScriptError("--terrain-lod-spec values must be integers") from exc
        if lod_level < 0:
            raise ScriptError("--terrain-lod-spec lod levels must be non-negative")
        if lod_level in seen_levels:
            raise ScriptError(f"--terrain-lod-spec contains duplicate lod level {lod_level}")
        if block_size_px < 1:
            raise ScriptError("--terrain-lod-spec block sizes must be positive")
        if detail_level < 6 or detail_level > 32:
            raise ScriptError("--terrain-lod-spec detail levels must be in [6, 32]")
        specs.append(TerrainLodSpec(lod_level=lod_level, block_size_px=block_size_px, detail_level=detail_level))
        seen_levels.add(lod_level)
    if not specs:
        raise ScriptError("--terrain-lod-spec must contain at least one LOD entry")
    return tuple(sorted(specs, key=lambda spec: spec.lod_level))


def validate_args(args: argparse.Namespace) -> None:
    for value, label in [
        (args.citydb_schema, "--citydb-schema"),
        (args.grid_schema, "--grid-schema"),
        (args.airspace_schema, "--airspace-schema"),
        (args.total_view_name, "--total-view-name"),
        (args.codes_view_name, "--codes-view-name"),
        (args.terrain_lod_view_name, "--terrain-lod-view-name"),
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
    if args.terrain_min_max_elevation_m is not None and not math.isfinite(args.terrain_min_max_elevation_m):
        raise ScriptError("--terrain-min-max-elevation-m must be a finite number")
    if args.default_zone_max_height <= 0:
        raise ScriptError("--default-zone-max-height must be positive")
    if args.terrain_block_size_pixels < 1:
        raise ScriptError("--terrain-block-size-pixels must be positive")
    parse_terrain_lod_spec(args.terrain_lod_spec)
    if args.refresh_only and (args.objectid_like or args.objectclass_id or args.limit is not None):
        raise ScriptError("building filters affect view DDL and cannot be changed with --refresh-only; rebuild instead")
    if args.refresh_only and args.terrain_min_max_elevation_m is not None:
        raise ScriptError("--terrain-min-max-elevation-m affects terrain view DDL and cannot be applied with --refresh-only; rebuild instead")


def selected_sources(args: argparse.Namespace) -> tuple[str, ...]:
    """Resolve ``--source`` into the concrete source view names to process."""

    if args.source == "all":
        return SOURCE_ORDER
    if args.source == "airspace":
        return AIRSPACE_SOURCES
    return (args.source,)


def should_update_total(args: argparse.Namespace) -> bool:
    """Whether this run should update the unified obstacle view and wrappers."""

    return args.source == "all" or args.refresh_total


def qname(schema_name: str, relation_name: str) -> sql.Composed:
    return sql.SQL("{}.{}").format(sql.Identifier(schema_name), sql.Identifier(relation_name))


def qname_literal(schema_name: str, relation_name: str) -> str:
    return f"{schema_name}.{relation_name}"


def detail_literal(args: argparse.Namespace) -> sql.Literal:
    return sql.Literal(-1 if args.auto_detail_level else args.detail_level)


def bool_literal(value: bool) -> sql.Literal:
    return sql.Literal(value)


def terrain_min_max_elevation_filter(args: argparse.Namespace, expression: sql.Composable) -> sql.Composable:
    """Optional SQL predicate for skipping low-elevation terrain obstacles.

    The threshold is applied to the raw DEM maximum elevation before adding
    ``--terrain-clearance-m``. It is an absolute orthometric height in metres,
    not AGL and not WGS84 ellipsoidal height.
    """

    if args.terrain_min_max_elevation_m is None:
        return sql.SQL("")
    return sql.SQL("and {} >= {}").format(expression, sql.Literal(args.terrain_min_max_elevation_m))


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
    """Create schemas, helper functions, and airspace tables required downstream.

    This makes the script self-initializing for no-fly-zone and temporary-control
    workflows: an empty airspace schema is enough for a first rebuild.
    """

    cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.grid_schema)))
    cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.airspace_schema)))
    cur.execute(build_bbox_prism_function_sql(args))
    cur.execute(build_polygon_prism_function_sql(args))
    cur.execute(build_airspace_tables_sql(args))


def build_bbox_prism_function_sql(args: argparse.Namespace) -> sql.Composed:
    """Create helper SQL function that turns a footprint bbox into a 3D prism."""

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
    """Create helper SQL function that extrudes a polygon footprint into 3D."""

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
    """Create business tables for no-fly zones and temporary control zones."""

    return sql.SQL(
        """
        create table if not exists {airspace_schema}.no_fly_zone (
          id bigserial primary key,
          name text not null,
          geom geometry(MultiPolygon, 4326) not null,
          height_datum text not null default 'AMSL',
          min_height double precision default 0,
          max_height double precision,
          safety_buffer_m double precision default 0,
          enabled boolean default true,
          created_at timestamptz default now(),
          updated_at timestamptz default now(),
          constraint no_fly_zone_height_datum_chk check (height_datum in ('AMSL', 'AGL')),
          constraint no_fly_zone_height_range_chk check (max_height is null or max_height > coalesce(min_height, 0))
        );

        alter table {airspace_schema}.no_fly_zone
          add column if not exists height_datum text not null default 'AMSL';

        update {airspace_schema}.no_fly_zone
        set height_datum = upper(coalesce(height_datum, 'AMSL'))
        where height_datum is null or height_datum <> upper(height_datum);

        alter table {airspace_schema}.no_fly_zone
          alter column height_datum set default 'AMSL',
          alter column height_datum set not null;

        create index if not exists no_fly_zone_geom_gix
          on {airspace_schema}.no_fly_zone using gist (geom);
        create index if not exists no_fly_zone_enabled_idx
          on {airspace_schema}.no_fly_zone (enabled);
        create index if not exists no_fly_zone_height_datum_idx
          on {airspace_schema}.no_fly_zone (height_datum);

        create table if not exists {airspace_schema}.temp_control_zone (
          id bigserial primary key,
          name text not null,
          geom geometry(MultiPolygon, 4326) not null,
          height_datum text not null default 'AMSL',
          min_height double precision default 0,
          max_height double precision,
          safety_buffer_m double precision default 0,
          valid_from timestamptz not null,
          valid_to timestamptz not null,
          status text not null default 'planned',
          created_at timestamptz default now(),
          updated_at timestamptz default now(),
          constraint temp_control_zone_height_datum_chk check (height_datum in ('AMSL', 'AGL')),
          constraint temp_control_zone_height_range_chk check (max_height is null or max_height > coalesce(min_height, 0)),
          constraint temp_control_zone_valid_window_chk check (valid_to > valid_from),
          constraint temp_control_zone_status_chk check (status in ('planned', 'active', 'cancelled'))
        );

        alter table {airspace_schema}.temp_control_zone
          add column if not exists height_datum text not null default 'AMSL';

        update {airspace_schema}.temp_control_zone
        set height_datum = upper(coalesce(height_datum, 'AMSL'))
        where height_datum is null or height_datum <> upper(height_datum);

        alter table {airspace_schema}.temp_control_zone
          alter column height_datum set default 'AMSL',
          alter column height_datum set not null;

        create index if not exists temp_control_zone_geom_gix
          on {airspace_schema}.temp_control_zone using gist (geom);
        create index if not exists temp_control_zone_active_window_idx
          on {airspace_schema}.temp_control_zone (status, valid_from, valid_to);
        create index if not exists temp_control_zone_height_datum_idx
          on {airspace_schema}.temp_control_zone (height_datum);

        do $do$
        begin
          if not exists (
            select 1 from pg_constraint
            where conname = 'no_fly_zone_height_datum_chk'
              and conrelid = {no_fly_zone_regclass}::regclass
          ) then
            alter table {airspace_schema}.no_fly_zone
              add constraint no_fly_zone_height_datum_chk
              check (height_datum in ('AMSL', 'AGL'));
          end if;

          if not exists (
            select 1 from pg_constraint
            where conname = 'temp_control_zone_height_datum_chk'
              and conrelid = {temp_control_zone_regclass}::regclass
          ) then
            alter table {airspace_schema}.temp_control_zone
              add constraint temp_control_zone_height_datum_chk
              check (height_datum in ('AMSL', 'AGL'));
          end if;

          if not exists (
            select 1 from pg_constraint
            where conname = 'no_fly_zone_height_range_chk'
              and conrelid = {no_fly_zone_regclass}::regclass
          ) then
            alter table {airspace_schema}.no_fly_zone
              add constraint no_fly_zone_height_range_chk
              check (max_height is null or max_height > coalesce(min_height, 0));
          end if;

          if not exists (
            select 1 from pg_constraint
            where conname = 'temp_control_zone_height_range_chk'
              and conrelid = {temp_control_zone_regclass}::regclass
          ) then
            alter table {airspace_schema}.temp_control_zone
              add constraint temp_control_zone_height_range_chk
              check (max_height is null or max_height > coalesce(min_height, 0));
          end if;
        end;
        $do$;
        """
    ).format(
        airspace_schema=sql.Identifier(args.airspace_schema),
        no_fly_zone_regclass=sql.Literal(f"{args.airspace_schema}.no_fly_zone"),
        temp_control_zone_regclass=sql.Literal(f"{args.airspace_schema}.temp_control_zone"),
    )


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


def build_empty_terrain_lod_view_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create materialized view {target_view} as
        select
            null::text as source_kind,
            null::text as source_id,
            null::text as source_name,
            null::integer as lod_level,
            null::integer as block_size_px,
            null::smallint as dimension,
            null::integer as detail_level,
            null::boolean as is_agg,
            null::public.geomgrids as grids,
            null::geometry(Polygon, 4326) as footprint_4326,
            null::double precision as min_height,
            null::double precision as max_height,
            null::integer as cell_count,
            null::timestamptz as generated_at
        where false
        """
    ).format(target_view=qname(args.grid_schema, args.terrain_lod_view_name))


def build_obstacles_terrain_lod_sql(args: argparse.Namespace, has_terrain_tables: bool) -> sql.Composed:
    """Build optional display-only terrain LOD materialized view DDL.

    This view is separate from routing/avoidance computation. It pre-aggregates
    DEM blocks at multiple grid detail levels so the frontend can load terrain
    obstacles adaptively.
    """

    if not has_terrain_tables:
        return build_empty_terrain_lod_view_sql(args)

    specs = parse_terrain_lod_spec(args.terrain_lod_spec)
    spec_values = sql.SQL(",\n                ").join(
        sql.SQL("({}, {}, {})").format(
            sql.Literal(spec.lod_level),
            sql.Literal(spec.block_size_px),
            sql.Literal(spec.detail_level),
        )
        for spec in specs
    )
    dataset_filter = sql.SQL("")
    if args.terrain_dataset_key is not None:
        dataset_filter = sql.SQL("and ds.dataset_key = {} ").format(sql.Literal(args.terrain_dataset_key))
    terrain_threshold_filter = terrain_min_max_elevation_filter(args, sql.SQL("raw_max_elevation"))

    return sql.SQL(
        """
        create materialized view {target_view} as
        with lod_spec(lod_level, block_size_px, detail_level) as (
            values
                {spec_values}
        ), pixels as (
            select
                t.id as tile_pk,
                coalesce(ds.dataset_key, ds.id::text) as dataset_key,
                coalesce(t.tile_id, t.id::text) as tile_name,
                px.x,
                px.y,
                px.geom,
                px.val::double precision as elevation
            from terrain.dem_tile t
            join terrain.dem_dataset ds on ds.id = t.dataset_id
            cross join lateral public.ST_PixelAsPolygons(t.rast, 1, true) as px(geom, val, x, y)
            where t.rast is not null
              {dataset_filter}
        ), blocks as (
            select
                p.tile_pk,
                p.dataset_key,
                p.tile_name,
                s.lod_level,
                s.block_size_px,
                s.detail_level,
                ((p.x - 1) / s.block_size_px)::integer as block_x,
                ((p.y - 1) / s.block_size_px)::integer as block_y,
                public.ST_Envelope(public.ST_Collect(p.geom)) as extent,
                (min(p.elevation) - {underground_tolerance})::double precision as min_z,
                max(p.elevation)::double precision as raw_max_elevation,
                (max(p.elevation) + {terrain_clearance})::double precision as max_z
            from pixels p
            cross join lod_spec s
            where p.elevation is not null
            group by p.tile_pk, p.dataset_key, p.tile_name, s.lod_level, s.block_size_px, s.detail_level, block_x, block_y
        ), generated_grids as (
            select
                'terrain'::text as source_kind,
                (dataset_key || ':' || tile_pk::text || ':lod:' || lod_level::text || ':block:' || block_x::text || ':' || block_y::text) as source_id,
                (dataset_key || ':' || tile_name || ':LOD' || lod_level::text || ':block:' || block_x::text || ':' || block_y::text) as source_name,
                lod_level,
                block_size_px,
                3::smallint as dimension,
                detail_level,
                true::boolean as is_agg,
                public.ST_AsGrids3D(
                    public.ST_Transform({grid_schema}.make_bbox_prism_3d(extent, min_z, max_z), 4326),
                    detail_level,
                    true
                ) as grids,
                public.ST_Transform(public.ST_Force2D(extent), 4326)::geometry(Polygon, 4326) as footprint_4326,
                min_z as min_height,
                max_z as max_height,
                now() as generated_at
            from blocks
            where extent is not null
              and not public.ST_IsEmpty(extent)
              and max_z > min_z
              {terrain_threshold_filter}
        )
        select
            source_kind,
            source_id,
            source_name,
            lod_level,
            block_size_px,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            footprint_4326,
            min_height,
            max_height,
            public.ST_nCells(grids)::integer as cell_count,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, args.terrain_lod_view_name),
        spec_values=spec_values,
        underground_tolerance=sql.Literal(args.underground_tolerance_m),
        terrain_clearance=sql.Literal(args.terrain_clearance_m),
        dataset_filter=dataset_filter,
        terrain_threshold_filter=terrain_threshold_filter,
        grid_schema=sql.Identifier(args.grid_schema),
    )


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
    """Build the CTE that chooses one representative geometry per CityDB feature."""

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
    """Build the buildings source view from 3DCityDB geometry_data."""

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
    """Build the terrain source view from DEM tiles.

    If terrain tables are absent, an empty but schema-compatible view is created
    so the unified ``flight_obstacles`` view can still be built.
    """

    if not has_terrain_tables:
        return build_empty_obstacle_view_sql(args, SOURCE_TO_VIEW["terrain"])

    dataset_filter = sql.SQL("")
    if args.terrain_dataset_key is not None:
        dataset_filter = sql.SQL("and ds.dataset_key = {} ").format(sql.Literal(args.terrain_dataset_key))
    terrain_tile_threshold_filter = terrain_min_max_elevation_filter(args, sql.SQL("t.max_elevation"))
    terrain_block_threshold_filter = terrain_min_max_elevation_filter(args, sql.SQL("raw_max_elevation"))

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
                    max(elevation)::double precision as raw_max_elevation,
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
                  {terrain_block_threshold_filter}
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
            terrain_block_threshold_filter=terrain_block_threshold_filter,
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
              {terrain_tile_threshold_filter}
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
        terrain_tile_threshold_filter=terrain_tile_threshold_filter,
        grid_schema=sql.Identifier(args.grid_schema),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def build_airspace_terrain_blocks_cte(args: argparse.Namespace, has_terrain_tables: bool) -> sql.Composed:
    """Return a CTE body with DEM blocks used to resolve AGL airspace heights.

    AGL zones are semantically relative to local ground height.  We reuse the
    same DEM pixel/block approach as terrain ``block-prism`` so each airspace
    piece gets a local min/max elevation instead of one coarse polygon-wide
    terrain range.  If terrain tables are unavailable the CTE is empty; AGL
    zones are intentionally omitted rather than misinterpreted as AMSL.
    """

    if not has_terrain_tables:
        return sql.SQL(
            """
            select
                null::text as block_id,
                null::geometry as extent,
                null::double precision as min_elevation,
                null::double precision as max_elevation
            where false
            """
        )

    dataset_filter = sql.SQL("")
    if args.terrain_dataset_key is not None:
        dataset_filter = sql.SQL("and ds.dataset_key = {} ").format(sql.Literal(args.terrain_dataset_key))

    return sql.SQL(
        """
        with pixels as (
            select
                t.id as tile_pk,
                coalesce(ds.dataset_key, ds.id::text) as dataset_key,
                ((px.x - 1) / {block_size})::integer as block_x,
                ((px.y - 1) / {block_size})::integer as block_y,
                px.geom,
                px.val::double precision as elevation
            from terrain.dem_tile t
            join terrain.dem_dataset ds on ds.id = t.dataset_id
            cross join lateral public.ST_PixelAsPolygons(t.rast, 1, true) as px(geom, val, x, y)
            where t.rast is not null
              {dataset_filter}
        )
        select
            (dataset_key || ':' || tile_pk::text || ':block:' || block_x::text || ':' || block_y::text) as block_id,
            public.ST_Envelope(public.ST_Collect(geom)) as extent,
            min(elevation)::double precision as min_elevation,
            max(elevation)::double precision as max_elevation
        from pixels
        where elevation is not null
        group by tile_pk, dataset_key, block_x, block_y
        """
    ).format(block_size=sql.Literal(args.terrain_block_size_pixels), dataset_filter=dataset_filter)


def build_airspace_constraint_obstacles_sql(
    args: argparse.Namespace,
    adapter: AirspaceConstraintObstacleAdapter,
    has_terrain_tables: bool,
) -> sql.Composed:
    """Build a configured 空域约束 source view.

    Long-lived no-fly zones and currently active temporary-control zones share
    the same height-datum, safety-buffer, terrain-block, and prism projection
    implementation; only source table, validity policy, and priority vary.
    """

    airspace_volume = (
        sql.SQL("{grid_schema}.make_polygon_prism_3d(footprint, min_z, max_z)")
        if args.airspace_mode == "polygon-prism"
        else sql.SQL("{grid_schema}.make_bbox_prism_3d(footprint, min_z, max_z)")
    )
    zone_validity_columns = sql.SQL(",\n                valid_from,\n                valid_to") if adapter.include_validity_window else sql.SQL("")
    amsl_validity_columns = sql.SQL(",\n                valid_from,\n                valid_to") if adapter.include_validity_window else sql.SQL("")
    agl_validity_columns = sql.SQL(",\n                z.valid_from,\n                z.valid_to") if adapter.include_validity_window else sql.SQL("")
    generated_validity_columns = sql.SQL(",\n                valid_from,\n                valid_to") if adapter.include_validity_window else sql.SQL("")
    final_validity_columns = (
        sql.SQL("valid_from,\n            valid_to")
        if adapter.include_validity_window
        else sql.SQL("null::timestamptz as valid_from,\n            null::timestamptz as valid_to")
    )

    return sql.SQL(
        """
        create materialized view {target_view} as
        with zones as (
            select
                id,
                name,
                upper(coalesce(height_datum, 'AMSL')) as height_datum,
                case
                    when coalesce(safety_buffer_m, 0) > 0
                    then public.ST_Buffer(geom::geography, safety_buffer_m)::geometry
                    else geom
                end as footprint_4326,
                coalesce(min_height, 0)::double precision as height_min,
                coalesce(max_height, {default_max_height})::double precision as height_max{zone_validity_columns}
            from {airspace_table}
            where {enabled_filter}
              and geom is not null
              and not public.ST_IsEmpty(geom)
        ), terrain_blocks as (
            {terrain_blocks_cte}
        ), amsl_pieces as (
            select
                id::text as source_id,
                name as source_name,
                footprint_4326 as footprint,
                height_min as min_z,
                height_max as max_z{amsl_validity_columns}
            from zones
            where height_datum <> 'AGL'
        ), agl_pieces as (
            select
                (z.id::text || ':agl:' || b.block_id) as source_id,
                z.name as source_name,
                public.ST_CollectionExtract(public.ST_MakeValid(public.ST_Intersection(public.ST_Transform(z.footprint_4326, public.ST_SRID(b.extent)), b.extent)), 3) as footprint,
                (b.min_elevation + z.height_min)::double precision as min_z,
                (b.max_elevation + z.height_max)::double precision as max_z{agl_validity_columns}
            from zones z
            join terrain_blocks b
              on z.height_datum = 'AGL'
             and b.extent is not null
             and public.ST_Intersects(public.ST_Transform(z.footprint_4326, public.ST_SRID(b.extent)), b.extent)
        ), volume_pieces as (
            select * from amsl_pieces
            union all
            select * from agl_pieces
        ), generated_grids as (
            select
                {source_kind}::text as source_kind,
                source_id,
                source_name,
                3::smallint as dimension,
                {is_agg}::boolean as is_agg,
                public.ST_AsGrids3D(
                    public.ST_Transform({airspace_volume}, 4326),
                    {detail_level},
                    {is_agg}
                ) as grids{generated_validity_columns},
                now() as generated_at
            from volume_pieces
            where footprint is not null
              and not public.ST_IsEmpty(footprint)
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
            {final_validity_columns},
            {priority}::integer as priority,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, adapter.view_name),
        airspace_table=qname(args.airspace_schema, adapter.table_name),
        source_kind=sql.Literal(adapter.source_kind),
        default_max_height=sql.Literal(args.default_zone_max_height),
        enabled_filter=adapter.enabled_filter_sql,
        zone_validity_columns=zone_validity_columns,
        amsl_validity_columns=amsl_validity_columns,
        agl_validity_columns=agl_validity_columns,
        generated_validity_columns=generated_validity_columns,
        final_validity_columns=final_validity_columns,
        priority=sql.Literal(adapter.priority),
        terrain_blocks_cte=build_airspace_terrain_blocks_cte(args, has_terrain_tables),
        airspace_volume=airspace_volume.format(grid_schema=sql.Identifier(args.grid_schema)),
        detail_level=detail_literal(args),
        is_agg=bool_literal(args.is_agg),
    )


def build_obstacles_no_fly_zones_sql(args: argparse.Namespace, has_terrain_tables: bool) -> sql.Composed:
    """Build the long-lived no-fly-zone source view from airspace polygons."""

    return obstacle_source_adapter(args, "no-fly-zones", has_terrain_tables).build_view_sql()


def planning_time_expression(args: argparse.Namespace) -> sql.Composable:
    if args.planning_time:
        return sql.SQL("{}::timestamptz").format(sql.Literal(args.planning_time))
    return sql.SQL("now()")


def build_obstacles_temp_control_sql(args: argparse.Namespace, has_terrain_tables: bool) -> sql.Composed:
    """Build the currently active temporary-control source view."""

    return obstacle_source_adapter(args, "temp-control", has_terrain_tables).build_view_sql()


def _airspace_constraint_adapters(args: argparse.Namespace, has_terrain_tables: bool) -> tuple[AirspaceConstraintObstacleAdapter, ...]:
    return (
        AirspaceConstraintObstacleAdapter(
            args=args,
            has_terrain_tables=has_terrain_tables,
            source="no-fly-zones",
            view_name=SOURCE_TO_VIEW["no-fly-zones"],
            source_kind="no_fly_zone",
            table_name="no_fly_zone",
            priority=1000,
            description="long-lived 空域约束 adapter",
            enabled_filter_sql=sql.SQL("enabled is true"),
        ),
        AirspaceConstraintObstacleAdapter(
            args=args,
            has_terrain_tables=has_terrain_tables,
            source="temp-control",
            view_name=SOURCE_TO_VIEW["temp-control"],
            source_kind="temp_control",
            table_name="temp_control_zone",
            priority=1100,
            description="time-bound 空域约束 adapter",
            enabled_filter_sql=sql.SQL("status in ('planned', 'active')\n              and {planning_time} >= valid_from\n              and {planning_time} < valid_to").format(
                planning_time=planning_time_expression(args)
            ),
            include_validity_window=True,
        ),
    )


def obstacle_source_adapters(args: argparse.Namespace, has_terrain_tables: bool) -> tuple[ObstacleSourceAdapter | AirspaceConstraintObstacleAdapter, ...]:
    """Return configured source adapters in unified 飞行障碍 source order."""

    airspace_adapters = {adapter.source: adapter for adapter in _airspace_constraint_adapters(args, has_terrain_tables)}
    return (
        ObstacleSourceAdapter(
            source="buildings",
            view_name=SOURCE_TO_VIEW["buildings"],
            description="3DCityDB building geometry adapter",
            build_view_sql=lambda args=args: build_obstacles_buildings_sql(args),
        ),
        ObstacleSourceAdapter(
            source="terrain",
            view_name=SOURCE_TO_VIEW["terrain"],
            description="DEM terrain obstacle adapter",
            build_view_sql=lambda args=args, has_terrain_tables=has_terrain_tables: build_obstacles_terrain_sql(args, has_terrain_tables),
        ),
        airspace_adapters["no-fly-zones"],
        airspace_adapters["temp-control"],
    )


def obstacle_source_adapter(args: argparse.Namespace, source: str, has_terrain_tables: bool) -> ObstacleSourceAdapter | AirspaceConstraintObstacleAdapter:
    for adapter in obstacle_source_adapters(args, has_terrain_tables):
        if adapter.source == source:
            return adapter
    raise AssertionError(f"Unhandled source: {source}")


def obstacle_display_adapters(args: argparse.Namespace, has_terrain_tables: bool) -> tuple[TerrainLodDisplayAdapter, ...]:
    """Return display-only adapters that are not part of the route-planning union."""

    if not args.terrain_lod_display:
        return ()
    return (
        TerrainLodDisplayAdapter(
            args=args,
            has_terrain_tables=has_terrain_tables,
            view_name=args.terrain_lod_view_name,
        ),
    )


def source_view_sql(args: argparse.Namespace, source: str, has_terrain_tables: bool) -> sql.Composed:
    return obstacle_source_adapter(args, source, has_terrain_tables).build_view_sql()


def build_total_view_sql(args: argparse.Namespace) -> sql.Composed:
    """Build the unified ``flight_obstacles`` materialized view from all sources."""

    selects = sql.SQL("\n        union all\n").join(
        sql.SQL("select * from {}").format(qname(args.grid_schema, SOURCE_TO_VIEW[source])) for source in SOURCE_ORDER
    )
    return sql.SQL("create materialized view {target_view} as\n        {selects}").format(
        target_view=qname(args.grid_schema, args.total_view_name),
        selects=selects,
    )


def build_codes_view_sql(args: argparse.Namespace) -> sql.Composed:
    """Create the human-readable GGER companion view for the unified view."""

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
    """Create the ``id, grids`` compatibility wrapper used by path-finding calls."""

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


def create_terrain_lod_indexes(cur: psycopg.Cursor[Any], args: argparse.Namespace) -> None:
    target = qname(args.grid_schema, args.terrain_lod_view_name)
    view_name = args.terrain_lod_view_name
    cur.execute(
        sql.SQL("create unique index {index_name} on {target_view} (lod_level, source_kind, source_id)").format(
            index_name=sql.Identifier(f"{view_name}_uidx"),
            target_view=target,
        )
    )
    cur.execute(
        sql.SQL("create index {index_name} on {target_view} (lod_level)").format(
            index_name=sql.Identifier(f"{view_name}_lod_idx"),
            target_view=target,
        )
    )
    cur.execute(
        sql.SQL("create index {index_name} on {target_view} using gist (footprint_4326)").format(
            index_name=sql.Identifier(f"{view_name}_footprint_gix"),
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
    relation_names = [
        (args.grid_schema, args.total_view_name),
        (args.grid_schema, args.codes_view_name),
        (args.public_wrapper_schema, args.public_wrapper_name),
        *((args.grid_schema, SOURCE_TO_VIEW[source]) for source in SOURCE_ORDER),
    ]
    relations = []
    for schema_name, relation_name in relation_names:
        cur.execute("select to_regclass(%s) is not null", (qname_literal(schema_name, relation_name),))
        if bool(cur.fetchone()[0]):
            relations.append(qname(schema_name, relation_name))
    if args.terrain_lod_display:
        cur.execute("select to_regclass(%s) is not null", (qname_literal(args.grid_schema, args.terrain_lod_view_name),))
        lod_exists = bool(cur.fetchone()[0])
    else:
        lod_exists = False
    if lod_exists:
        relations.append(qname(args.grid_schema, args.terrain_lod_view_name))
    if relations:
        cur.execute(sql.SQL("grant select on {} to {}").format(sql.SQL(", ").join(relations), role))


def ensure_all_source_views_exist(cur: psycopg.Cursor[Any], args: argparse.Namespace, has_terrain_tables: bool) -> None:
    for adapter in obstacle_source_adapters(args, has_terrain_tables):
        cur.execute("select to_regclass(%s) is not null", (qname_literal(args.grid_schema, adapter.view_name),))
        exists = bool(cur.fetchone()[0])
        if not exists:
            cur.execute(adapter.build_view_sql())
            create_source_indexes(cur, args, adapter.view_name)


def rebuild_views(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    """Drop/recreate selected source views and optionally rebuild the unified total view."""

    sources = selected_sources(args)
    update_total = should_update_total(args)
    has_terrain_tables = regclass_exists(conn, "terrain", "dem_tile") and regclass_exists(conn, "terrain", "dem_dataset")
    drop_dependent_views(conn, args)
    with conn.cursor() as cur:
        ensure_schemas_and_helpers(cur, args)
        cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, args.total_view_name)))
        for source in sources:
            adapter = obstacle_source_adapter(args, source, has_terrain_tables)
            cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, adapter.view_name)))
            cur.execute(adapter.build_view_sql())
            create_source_indexes(cur, args, adapter.view_name)
            if source == "terrain":
                for display_adapter in obstacle_display_adapters(args, has_terrain_tables):
                    cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, display_adapter.view_name)))
                    cur.execute(display_adapter.build_view_sql())
                    create_terrain_lod_indexes(cur, args)

        if update_total:
            ensure_all_source_views_exist(cur, args, has_terrain_tables)
            cur.execute(build_total_view_sql(args))
            create_source_indexes(cur, args, args.total_view_name)
            cur.execute(build_codes_view_sql(args))
            cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.public_wrapper_schema)))
            cur.execute(build_public_wrapper_sql(args))
        if args.grant_role:
            grant_generated_objects(cur, args)
        if update_total and not args.skip_pgrst_notify:
            cur.execute("notify pgrst, 'reload schema'")


def refresh_one(cur: psycopg.Cursor[Any], args: argparse.Namespace, schema_name: str, view_name: str) -> None:
    refresh_keyword = sql.SQL("concurrently ") if args.concurrently else sql.SQL("")
    cur.execute(sql.SQL("refresh materialized view {}{}").format(refresh_keyword, qname(schema_name, view_name)))


def refresh_views(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    """Refresh selected source views and optionally the unified total view without DDL changes."""

    sources = selected_sources(args)
    update_total = should_update_total(args)
    with conn.cursor() as cur:
        for source in sources:
            adapter = obstacle_source_adapter(args, source, False)
            refresh_one(cur, args, args.grid_schema, adapter.view_name)
            if source == "terrain":
                for display_adapter in obstacle_display_adapters(args, False):
                    refresh_one(cur, args, args.grid_schema, display_adapter.view_name)
        if update_total:
            refresh_one(cur, args, args.grid_schema, args.total_view_name)
            cur.execute(build_codes_view_sql(args))
            cur.execute(build_public_wrapper_sql(args))
        if args.grant_role:
            grant_generated_objects(cur, args)
        if update_total and not args.skip_pgrst_notify:
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
            where_parts: list[str] = []
            params: list[Any] = []
            if args.terrain_dataset_key:
                where_parts.append("ds.dataset_key = %s")
                params.append(args.terrain_dataset_key)
            if args.terrain_min_max_elevation_m is not None:
                where_parts.append("t.max_elevation is not null and t.max_elevation >= %s")
                params.append(args.terrain_min_max_elevation_m)
            where_clause = " where " + " and ".join(where_parts) if where_parts else ""
            cur.execute(
                """
                select count(*)
                from terrain.dem_tile t
                join terrain.dem_dataset ds on ds.id = t.dataset_id
                """ + where_clause,
                params,
            )
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


def terrain_lod_counts(conn: psycopg.Connection[Any], args: argparse.Namespace) -> list[tuple[int, int, int | None]]:
    if not regclass_exists(conn, args.grid_schema, args.terrain_lod_view_name):
        return []
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                select lod_level, count(*)::integer as row_count, sum(cell_count)::integer as total_cells
                from {target_view}
                group by lod_level
                order by lod_level
                """
            ).format(target_view=qname(args.grid_schema, args.terrain_lod_view_name))
        )
        return [(int(row[0]), int(row[1]), int(row[2]) if row[2] is not None else None) for row in cur.fetchall()]


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
    if args.terrain_lod_display:
        print(f"Terrain LOD display view: {qname_literal(args.grid_schema, args.terrain_lod_view_name)} ({args.terrain_lod_spec})")
    print(f"GGER display view: {qname_literal(args.grid_schema, args.codes_view_name)}")
    print(f"ST_FindGridsPath wrapper: {qname_literal(args.public_wrapper_schema, args.public_wrapper_name)} (id, grids)")
    print(f"Generation modes: airspace={args.airspace_mode}, terrain={args.terrain_mode}")
    if args.terrain_min_max_elevation_m is not None:
        print(
            "Terrain obstacle filter: "
            f"raw DEM max_elevation >= {args.terrain_min_max_elevation_m} m "
            "(absolute EGM2008 orthometric height; not AGL)"
        )
    print("External display contract: GGER only; BGC is not emitted by generated views.")


def main() -> int:
    """CLI entry point: validate, connect, dry-run/rebuild/refresh, then sample."""

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

            print(f"{action} source view(s): {', '.join(selected_sources(args))}.")
            for source in SOURCE_ORDER:
                view_name = SOURCE_TO_VIEW[source]
                if regclass_exists(conn, args.grid_schema, view_name):
                    print(f"- {qname_literal(args.grid_schema, view_name)}: {relation_count(conn, args.grid_schema, view_name)} rows")
            if args.terrain_lod_display:
                lod_counts = terrain_lod_counts(conn, args)
                if lod_counts:
                    print(f"- {qname_literal(args.grid_schema, args.terrain_lod_view_name)}:")
                    for lod_level, row_count, total_cells in lod_counts:
                        print(f"  - LOD{lod_level}: {row_count} rows, {total_cells or 0} cells")
            if should_update_total(args):
                total_count = relation_count(conn, args.grid_schema, args.total_view_name)
                print(f"Unified materialized view rows: {total_count}")
                print_samples(total_count, fetch_samples(conn, args))
            elif regclass_exists(conn, args.grid_schema, args.total_view_name):
                print(
                    f"Unified materialized view {qname_literal(args.grid_schema, args.total_view_name)} was not refreshed in this run. "
                    "Run with --refresh-total or --source all to update it."
                )
            else:
                print(
                    f"Unified materialized view {qname_literal(args.grid_schema, args.total_view_name)} is not present. "
                    "Run with --refresh-total or --source all to recreate it."
                )
            print_post_action_hint(args)
            return 0
    except (psycopg.Error, ScriptError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
