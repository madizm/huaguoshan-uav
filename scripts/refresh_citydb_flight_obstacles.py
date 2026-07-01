#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Build and refresh a single-source 3DCityDB geomgrids obstacle view.

中文说明：
    这个脚本是“CityDB 几何/建筑专用”的障碍物网格生成脚本。它从
    ``citydb.feature`` + ``citydb.geometry_data`` 中读取几何对象，挑选每个
    feature 的代表几何，然后调用 iBEST-DB 的 ``ST_AsGrids`` 或
    ``ST_AsGrids3D`` 生成 ``geomgrids``，最终写入物化视图。

主要输出：
    - ``citydb_grid.flight_obstacles``：计算用物化视图，保存 ``geomgrids``。
    - ``citydb_grid.flight_obstacles_codes_view``：展示用普通视图，把网格转成
      GGER 文本，便于排查和人工查看。
    - 可选 ``public.flight_obstacles`` wrapper：兼容 ``ST_FindGridsPath`` 这类只
      需要 ``id, grids`` 的调用方。

和 ``refresh_citydb_obstacle_grids.py`` 的关系：
    本脚本可以看作早期/轻量的 building-only 版本；后者是多来源版本，会把
    建筑、地形、禁飞区、临时管制区统一汇总为同名总视图。

External display contract:
    GGER only; BGC is intentionally not emitted by generated views/APIs.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg import sql


# 默认连接到花果山项目库；生产/测试环境建议用 CITYDB_DSN 或 --dsn 覆盖。
DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
DEFAULT_CITYDB_SCHEMA = "citydb"
DEFAULT_GRID_SCHEMA = "citydb_grid"
DEFAULT_VIEW_NAME = "flight_obstacles"
DEFAULT_CODES_VIEW_NAME = "flight_obstacles_codes_view"
DEFAULT_PUBLIC_WRAPPER_SCHEMA = "public"
DEFAULT_PUBLIC_WRAPPER_NAME = "flight_obstacles"
DEFAULT_DETAIL_LEVEL = 19
DEFAULT_SAMPLE_SIZE = 5


class ScriptError(RuntimeError):
    """Raised for user-actionable script failures."""


@dataclass(frozen=True)
class ViewNames:
    """Names of all database objects managed by this script."""

    grid_schema: str
    view_name: str
    codes_view_name: str
    public_wrapper_schema: str
    public_wrapper_name: str


@dataclass(frozen=True)
class SampleRow:
    """Small diagnostic row printed after dry-run/rebuild/refresh."""

    feature_id: int
    geometry_id: int
    objectid: str | None
    objectclass_id: int | None
    detail_level: int | None
    dimension: int
    cell_count: int | None
    gger_grids: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create/rebuild or refresh citydb_grid.flight_obstacles geomgrids materialized view.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--dsn",
        default=os.getenv("CITYDB_DSN", DEFAULT_DSN),
        help="PostgreSQL DSN. Can also be provided via CITYDB_DSN.",
    )
    parser.add_argument("--citydb-schema", default=DEFAULT_CITYDB_SCHEMA, help="3DCityDB schema name.")
    parser.add_argument("--grid-schema", default=DEFAULT_GRID_SCHEMA, help="Schema for derived grid views.")
    parser.add_argument("--view-name", default=DEFAULT_VIEW_NAME, help="Materialized view name.")
    parser.add_argument("--codes-view-name", default=DEFAULT_CODES_VIEW_NAME, help="GGER display view name.")
    parser.add_argument(
        "--dimension",
        type=int,
        choices=[2, 3],
        default=3,
        help="Generate 2D footprint grids or 3D obstacle grids.",
    )
    parser.add_argument(
        "--detail-level",
        type=int,
        default=DEFAULT_DETAIL_LEVEL,
        help="GGER/GeoSOT detail level in [6, 32]. Ignored when --auto-detail-level is used.",
    )
    parser.add_argument(
        "--auto-detail-level",
        action="store_true",
        help="Let iBEST-DB choose the detail level by passing -1 to ST_AsGrids/ST_AsGrids3D.",
    )
    agg_group = parser.add_mutually_exclusive_group()
    agg_group.add_argument("--agg", dest="is_agg", action="store_true", help="Enable geomgrids aggregation.")
    agg_group.add_argument("--no-agg", dest="is_agg", action="store_false", help="Disable geomgrids aggregation.")
    parser.set_defaults(is_agg=True)
    parser.add_argument(
        "--objectid-like",
        default=None,
        help="Optional SQL LIKE filter for citydb.feature.objectid, for example 'osm:%%'.",
    )
    parser.add_argument(
        "--objectclass-id",
        type=int,
        action="append",
        default=[],
        help="Optional objectclass id filter. Repeat to include multiple classes, e.g. --objectclass-id 901.",
    )
    parser.add_argument("--limit", type=int, default=None, help="Optional maximum number of features in the view.")
    parser.add_argument(
        "--refresh-only",
        action="store_true",
        help="Only refresh an existing materialized view; do not rebuild DDL or indexes.",
    )
    refresh_group = parser.add_mutually_exclusive_group()
    refresh_group.add_argument(
        "--concurrently",
        dest="concurrently",
        action="store_true",
        help="Use REFRESH MATERIALIZED VIEW CONCURRENTLY in --refresh-only mode.",
    )
    refresh_group.add_argument(
        "--no-concurrently",
        dest="concurrently",
        action="store_false",
        help="Use plain REFRESH MATERIALIZED VIEW in --refresh-only mode.",
    )
    parser.set_defaults(concurrently=True)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run support checks and print a sample query without creating or refreshing views.",
    )
    parser.add_argument(
        "--sample-size",
        type=int,
        default=DEFAULT_SAMPLE_SIZE,
        help="Number of sample rows to print after dry-run/rebuild/refresh.",
    )
    parser.add_argument(
        "--create-public-wrapper",
        action="store_true",
        help="Create public.flight_obstacles wrapper view for ST_FindGridsPath compatibility.",
    )
    parser.add_argument(
        "--public-wrapper-schema",
        default=DEFAULT_PUBLIC_WRAPPER_SCHEMA,
        help="Schema for the optional ST_FindGridsPath wrapper view.",
    )
    parser.add_argument(
        "--public-wrapper-name",
        default=DEFAULT_PUBLIC_WRAPPER_NAME,
        help="Name for the optional ST_FindGridsPath wrapper view.",
    )
    parser.add_argument(
        "--grant-role",
        default=None,
        help="Optional database role to grant USAGE/SELECT on generated schema and views, e.g. web_anon.",
    )
    return parser.parse_args()


def validate_identifier(value: str, label: str) -> None:
    if not value or "\x00" in value:
        raise ScriptError(f"{label} cannot be empty or contain NUL")


def validate_args(args: argparse.Namespace) -> None:
    for value, label in [
        (args.citydb_schema, "--citydb-schema"),
        (args.grid_schema, "--grid-schema"),
        (args.view_name, "--view-name"),
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
    if args.refresh_only and (args.objectid_like or args.objectclass_id or args.limit is not None):
        raise ScriptError("filters affect view DDL and cannot be changed with --refresh-only; rebuild the view instead")


def view_names(args: argparse.Namespace) -> ViewNames:
    return ViewNames(
        grid_schema=args.grid_schema,
        view_name=args.view_name,
        codes_view_name=args.codes_view_name,
        public_wrapper_schema=args.public_wrapper_schema,
        public_wrapper_name=args.public_wrapper_name,
    )


def qname(schema_name: str, relation_name: str) -> sql.Composed:
    return sql.SQL("{}.{}").format(sql.Identifier(schema_name), sql.Identifier(relation_name))


def qname_literal(schema_name: str, relation_name: str) -> str:
    return f"{schema_name}.{relation_name}"


def bool_literal(value: bool) -> sql.Literal:
    return sql.Literal(value)


def ensure_database_support(conn: psycopg.Connection[Any], citydb_schema: str) -> None:
    """Check required iBEST-DB/PostGIS functions, type, GIN opclass and CityDB tables exist."""
    with conn.cursor() as cur:
        cur.execute(
            """
            select
              to_regtype('public.geomgrids') is not null as has_geomgrids,
              to_regprocedure('public.st_asgrids(geometry,integer,boolean)') is not null as has_asgrids,
              to_regprocedure('public.st_asgrids3d(geometry,integer,boolean)') is not null as has_asgrids3d,
              to_regprocedure('public.st_astext(geomgrids,text)') is not null as has_astext,
              to_regprocedure('public.st_detaillevel(geomgrids)') is not null as has_detaillevel,
              to_regprocedure('public.st_ncells(geomgrids)') is not null as has_ncells,
              to_regprocedure('public.st_transform(geometry,integer)') is not null as has_transform,
              to_regprocedure('public.st_force2d(geometry)') is not null as has_force2d,
              to_regprocedure('public.st_isempty(geometry)') is not null as has_isempty
            """
        )
        support = dict(zip([desc.name for desc in cur.description], cur.fetchone(), strict=True))
        missing = [name.removeprefix("has_") for name, ok in support.items() if not ok]
        if missing:
            raise ScriptError(
                "Missing required database support: "
                + ", ".join(missing)
                + ". Install/enable PostGIS and iBEST-DB best_geomgrids first."
            )

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

        cur.execute("select to_regclass(%s), to_regclass(%s)", (f"{citydb_schema}.feature", f"{citydb_schema}.geometry_data"))
        feature_regclass, geometry_data_regclass = cur.fetchone()
        if feature_regclass is None or geometry_data_regclass is None:
            raise ScriptError(f"Missing {citydb_schema}.feature or {citydb_schema}.geometry_data")


def build_where_clause(args: argparse.Namespace) -> sql.Composed:
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
    """Build the CTE that chooses one representative geometry per CityDB feature.

    Some CityDB features can have multiple geometry rows. For obstacle generation
    we keep the largest 2D envelope first, then fall back to the geometry id for a
    deterministic tie-breaker.
    """

    limit_clause = sql.SQL("")
    if args.limit is not None:
        limit_clause = sql.SQL("\n            limit {}").format(sql.Literal(args.limit))

    return sql.SQL(
        """
        ranked_geometry as (
            select distinct on (f.id)
                f.id as feature_id,
                f.objectid,
                f.objectclass_id,
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
        where_clause=build_where_clause(args),
        limit_clause=limit_clause,
    )


def build_grids_expression(args: argparse.Namespace) -> sql.Composed:
    """Return the SQL expression that converts a geometry into geomgrids.

    ``--dimension 3`` produces true 3D obstacle grids via ``ST_AsGrids3D``;
    ``--dimension 2`` produces footprint grids via ``ST_AsGrids``. Both paths
    transform geometry to EPSG:4326 before grid generation.
    """

    detail_level = -1 if args.auto_detail_level else args.detail_level
    if args.dimension == 3:
        return sql.SQL("public.ST_AsGrids3D(public.ST_Transform(geometry, 4326), {}, {})").format(
            sql.Literal(detail_level), bool_literal(args.is_agg)
        )
    return sql.SQL("public.ST_AsGrids(public.ST_Transform(public.ST_Force2D(geometry), 4326), {}, {})").format(
        sql.Literal(detail_level), bool_literal(args.is_agg)
    )


def build_materialized_view_sql(args: argparse.Namespace) -> sql.Composed:
    """Create the main materialized view DDL for ``citydb_grid.flight_obstacles``."""

    ranked_geometry_cte = build_ranked_geometry_cte(args)
    grids_expression = build_grids_expression(args)
    return sql.SQL(
        """
        create materialized view {target_view} as
        with {ranked_geometry_cte}, generated_grids as (
            select
                feature_id,
                geometry_id,
                objectid,
                objectclass_id,
                {dimension}::smallint as dimension,
                {is_agg}::boolean as is_agg,
                {grids_expression} as grids,
                public.ST_SRID(geometry) as source_srid,
                now() as generated_at
            from ranked_geometry
        )
        select
            feature_id,
            geometry_id,
            objectid,
            objectclass_id,
            dimension,
            public.ST_DetailLevel(grids)::integer as detail_level,
            is_agg,
            grids,
            source_srid,
            generated_at
        from generated_grids
        where grids is not null
        """
    ).format(
        target_view=qname(args.grid_schema, args.view_name),
        ranked_geometry_cte=ranked_geometry_cte,
        dimension=sql.Literal(args.dimension),
        is_agg=bool_literal(args.is_agg),
        grids_expression=grids_expression,
    )


def build_dry_run_sql(args: argparse.Namespace) -> sql.Composed:
    ranked_geometry_cte = build_ranked_geometry_cte(args)
    grids_expression = build_grids_expression(args)
    sample_limit = max(args.sample_size, 0)
    return sql.SQL(
        """
        with {ranked_geometry_cte}, generated_grids as (
            select
                feature_id,
                geometry_id,
                objectid,
                objectclass_id,
                {dimension}::smallint as dimension,
                {grids_expression} as grids
            from ranked_geometry
        )
        select
            count(*) over ()::integer as total_count,
            feature_id,
            geometry_id,
            objectid,
            objectclass_id,
            public.ST_DetailLevel(grids)::integer as detail_level,
            dimension,
            public.ST_nCells(grids)::integer as cell_count,
            public.ST_AsText(grids, 'GGER') as gger_grids
        from generated_grids
        where grids is not null
        order by feature_id
        limit {sample_limit}
        """
    ).format(
        ranked_geometry_cte=ranked_geometry_cte,
        dimension=sql.Literal(args.dimension),
        grids_expression=grids_expression,
        sample_limit=sql.Literal(sample_limit),
    )


def view_depends_on_relation(
    conn: psycopg.Connection[Any],
    view_schema: str,
    view_name: str,
    target_schema: str,
    target_name: str,
) -> bool:
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


def drop_dependent_views(conn: psycopg.Connection[Any], names: ViewNames, drop_public_wrapper: bool) -> None:
    with conn.cursor() as cur:
        cur.execute(sql.SQL("drop view if exists {}").format(qname(names.grid_schema, names.codes_view_name)))

    # A wrapper from an earlier run would otherwise block DROP MATERIALIZED VIEW.
    # Drop it only if it actually depends on this script's target relation.
    should_drop_wrapper = drop_public_wrapper or view_depends_on_relation(
        conn,
        names.public_wrapper_schema,
        names.public_wrapper_name,
        names.grid_schema,
        names.view_name,
    )
    if should_drop_wrapper:
        with conn.cursor() as cur:
            cur.execute(sql.SQL("drop view if exists {}").format(qname(names.public_wrapper_schema, names.public_wrapper_name)))


def rebuild_materialized_view(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    """Drop and recreate the obstacle materialized view plus indexes/wrappers."""

    names = view_names(args)
    with conn.cursor() as cur:
        cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.grid_schema)))
    drop_dependent_views(conn, names, drop_public_wrapper=args.create_public_wrapper)
    with conn.cursor() as cur:
        cur.execute(sql.SQL("drop materialized view if exists {}").format(qname(args.grid_schema, args.view_name)))
        cur.execute(build_materialized_view_sql(args))
        cur.execute(
            sql.SQL("create unique index {index_name} on {target_view} (geometry_id)").format(
                index_name=sql.Identifier(f"{args.view_name}_geometry_id_idx"),
                target_view=qname(args.grid_schema, args.view_name),
            )
        )
        cur.execute(
            sql.SQL("create index {index_name} on {target_view} (feature_id)").format(
                index_name=sql.Identifier(f"{args.view_name}_feature_id_idx"),
                target_view=qname(args.grid_schema, args.view_name),
            )
        )
        cur.execute(
            sql.SQL("create index {index_name} on {target_view} (objectid)").format(
                index_name=sql.Identifier(f"{args.view_name}_objectid_idx"),
                target_view=qname(args.grid_schema, args.view_name),
            )
        )
        cur.execute(
            sql.SQL("create index {index_name} on {target_view} using gin (grids gin_grids_ops)").format(
                index_name=sql.Identifier(f"{args.view_name}_grids_gin_idx"),
                target_view=qname(args.grid_schema, args.view_name),
            )
        )
        cur.execute(build_codes_view_sql(args))
        if args.create_public_wrapper:
            cur.execute(sql.SQL("create schema if not exists {}").format(sql.Identifier(args.public_wrapper_schema)))
            cur.execute(build_public_wrapper_sql(args))
        if args.grant_role:
            grant_generated_objects(cur, args)


def refresh_materialized_view(conn: psycopg.Connection[Any], args: argparse.Namespace) -> None:
    """Refresh an existing materialized view without changing its DDL."""

    refresh_keyword = sql.SQL("concurrently ") if args.concurrently else sql.SQL("")
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL("refresh materialized view {}{}").format(refresh_keyword, qname(args.grid_schema, args.view_name))
        )


def build_codes_view_sql(args: argparse.Namespace) -> sql.Composed:
    """Create the human-readable GGER companion view.

    The main materialized view keeps the native ``geomgrids`` value for spatial
    computation. This companion view is only for display/debugging.
    """

    return sql.SQL(
        """
        create or replace view {codes_view} as
        select
            feature_id,
            geometry_id,
            objectid,
            objectclass_id,
            dimension,
            detail_level,
            is_agg,
            public.ST_nCells(grids)::integer as cell_count,
            public.ST_AsText(grids, 'GGER') as gger_grids,
            source_srid,
            generated_at
        from {target_view}
        """
    ).format(
        codes_view=qname(args.grid_schema, args.codes_view_name),
        target_view=qname(args.grid_schema, args.view_name),
    )


def build_public_wrapper_sql(args: argparse.Namespace) -> sql.Composed:
    return sql.SQL(
        """
        create or replace view {wrapper_view} as
        select geometry_id as id, grids
        from {target_view}
        """
    ).format(
        wrapper_view=qname(args.public_wrapper_schema, args.public_wrapper_name),
        target_view=qname(args.grid_schema, args.view_name),
    )


def grant_generated_objects(cur: psycopg.Cursor[Any], args: argparse.Namespace) -> None:
    role = sql.Identifier(args.grant_role)
    cur.execute(sql.SQL("grant usage on schema {} to {}").format(sql.Identifier(args.grid_schema), role))
    cur.execute(sql.SQL("grant select on {}, {} to {}").format(
        qname(args.grid_schema, args.view_name),
        qname(args.grid_schema, args.codes_view_name),
        role,
    ))
    if args.create_public_wrapper:
        cur.execute(sql.SQL("grant usage on schema {} to {}").format(sql.Identifier(args.public_wrapper_schema), role))
        cur.execute(sql.SQL("grant select on {} to {}").format(qname(args.public_wrapper_schema, args.public_wrapper_name), role))


def relation_count(conn: psycopg.Connection[Any], schema_name: str, relation_name: str) -> int:
    with conn.cursor() as cur:
        cur.execute(sql.SQL("select count(*) from {}").format(qname(schema_name, relation_name)))
        return int(cur.fetchone()[0])


def fetch_relation_sample(
    conn: psycopg.Connection[Any], schema_name: str, relation_name: str, sample_size: int
) -> list[SampleRow]:
    if sample_size <= 0:
        return []
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                select
                    feature_id,
                    geometry_id,
                    objectid,
                    objectclass_id,
                    detail_level,
                    dimension,
                    public.ST_nCells(grids)::integer as cell_count,
                    public.ST_AsText(grids, 'GGER') as gger_grids
                from {target_view}
                order by feature_id
                limit {sample_size}
                """
            ).format(target_view=qname(schema_name, relation_name), sample_size=sql.Literal(sample_size))
        )
        return [row_to_sample(row) for row in cur.fetchall()]


def fetch_dry_run_sample(conn: psycopg.Connection[Any], args: argparse.Namespace) -> tuple[int, list[SampleRow]]:
    with conn.cursor() as cur:
        cur.execute(build_dry_run_sql(args))
        rows = cur.fetchall()
    if not rows:
        return 0, []
    total_count = int(rows[0][0])
    samples = [row_to_sample(row[1:]) for row in rows]
    return total_count, samples


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
        feature_id=int(row[0]),
        geometry_id=int(row[1]),
        objectid=coerce_text(row[2]),
        objectclass_id=int(row[3]) if row[3] is not None else None,
        detail_level=int(row[4]) if row[4] is not None else None,
        dimension=int(row[5]),
        cell_count=int(row[6]) if row[6] is not None else None,
        gger_grids=coerce_text(row[7]),
    )


def print_samples(total_count: int, samples: list[SampleRow], sample_size: int) -> None:
    print(f"Matched/generated obstacle rows: {total_count}")
    if not samples:
        if sample_size > 0:
            print("No sample rows available.")
        return
    print("Sample GGER grids:")
    for row in samples:
        label = row.objectid or f"feature:{row.feature_id}"
        gger = (row.gger_grids or "").strip()
        if len(gger) > 220:
            gger = gger[:217] + "..."
        print(
            f"- {label} (feature_id={row.feature_id}, geometry_id={row.geometry_id}, "
            f"class={row.objectclass_id or '-'}, dim={row.dimension}, "
            f"detail={row.detail_level}, cells={row.cell_count}): {gger or '-'}"
        )


def print_post_action_hint(args: argparse.Namespace) -> None:
    target = qname_literal(args.grid_schema, args.view_name)
    codes = qname_literal(args.grid_schema, args.codes_view_name)
    print(f"Materialized view: {target}")
    print(f"GGER display view: {codes}")
    if args.create_public_wrapper:
        wrapper = qname_literal(args.public_wrapper_schema, args.public_wrapper_name)
        print(f"ST_FindGridsPath wrapper: {wrapper} (id, grids)")
    print("External display contract: GGER only; BGC is not emitted by generated views.")


def main() -> int:
    """CLI entry point: validate, connect, dry-run/rebuild/refresh, then sample."""

    args = parse_args()
    try:
        validate_args(args)
        with psycopg.connect(args.dsn, connect_timeout=15, autocommit=True) as conn:
            ensure_database_support(conn, args.citydb_schema)
            if args.dry_run:
                total_count, samples = fetch_dry_run_sample(conn, args)
                print_samples(total_count, samples, args.sample_size)
                print("Dry run: no views or indexes were created/refreshed.")
                return 0

            if args.refresh_only:
                refresh_materialized_view(conn, args)
                action = "Refreshed"
            else:
                rebuild_materialized_view(conn, args)
                action = "Rebuilt"

            total_count = relation_count(conn, args.grid_schema, args.view_name)
            samples = fetch_relation_sample(conn, args.grid_schema, args.view_name, args.sample_size)
            print(f"{action} {qname_literal(args.grid_schema, args.view_name)}.")
            print_samples(total_count, samples, args.sample_size)
            print_post_action_hint(args)
            return 0
    except (psycopg.Error, ScriptError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
