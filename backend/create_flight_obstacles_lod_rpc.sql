-- PostgREST RPC: adaptive LOD terrain flight obstacle GGER geomgrids for Cesium display.
--
-- Usage through PostgREST:
--   POST /rpc/list_flight_obstacles_gger_lod
--   {"p_source_kind":"terrain","p_lod_level":1,"p_west":119.2,"p_south":34.6,"p_east":119.3,"p_north":34.7,"p_center_lon":119.25,"p_center_lat":34.65,"p_limit":500,"p_include_boxes":true}
--
-- Returns GGER only. BGC is intentionally not part of the external API contract.

begin;

drop function if exists citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, integer, boolean);
drop function if exists public.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, integer, boolean);

create or replace function public.list_flight_obstacles_gger_lod(
    p_source_kind text default 'terrain',
    p_lod_level integer default null,
    p_west double precision default null,
    p_south double precision default null,
    p_east double precision default null,
    p_north double precision default null,
    p_center_lon double precision default null,
    p_center_lat double precision default null,
    p_limit integer default 1000,
    p_include_boxes boolean default true
)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
with params as (
    select
        nullif(p_source_kind, '') as source_kind,
        case
            when p_west is not null and p_south is not null and p_east is not null and p_north is not null
            then public.ST_MakeEnvelope(
                least(p_west, p_east),
                least(p_south, p_north),
                greatest(p_west, p_east),
                greatest(p_south, p_north),
                4326
            )
            else null::geometry
        end as bbox,
        case
            when p_center_lon is not null and p_center_lat is not null
             and p_center_lon between -180 and 180
             and p_center_lat between -90 and 90
            then public.ST_SetSRID(public.ST_MakePoint(p_center_lon, p_center_lat), 4326)
            else null::geometry
        end as center_point,
        greatest(0, least(coalesce(p_limit, 1000), 1000)) as safe_limit
), limited_obstacles as (
    select lod.*
    from citydb_grid.obstacles_terrain_lod lod
    cross join params p
    where lod.source_kind = coalesce(p.source_kind, 'terrain')
      and (p_lod_level is null or lod.lod_level = p_lod_level)
      and (p.bbox is null or lod.footprint_4326 && p.bbox)
    order by
        case when p.center_point is null then 0.0 else public.ST_Distance(lod.footprint_4326, p.center_point) end,
        lod.lod_level,
        lod.source_id
    limit (select safe_limit from params)
)
select coalesce(
    jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
            'source_kind', source_kind,
            'source_id', source_id,
            'source_name', source_name,
            'lod_level', lod_level,
            'block_size_px', block_size_px,
            'dimension', dimension,
            'detail_level', detail_level,
            'is_agg', is_agg,
            'cell_count', cell_count,
            'min_height', min_height,
            'max_height', max_height,
            'gger_grids', public.ST_AsText(grids, 'GGER'),
            'gger_grids_with_box', case when p_include_boxes then public.ST_WithBox(grids, 'GGER') else null end,
            'generated_at', generated_at
        ))
    ),
    '[]'::jsonb
)
from limited_obstacles;
$$;

comment on function public.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean)
is 'List display-only terrain flight obstacle LOD geomgrids as GGER text and optional ST_WithBox bbox text. Bbox-filtered results can be prioritized by view center. Returns no BGC fields.';

grant execute on function public.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean) to web_anon;

-- PostgREST exposes the first configured schema (`citydb`) as the default RPC
-- schema in this project. Keep implementation in public and expose a citydb
-- wrapper for /rpc/list_flight_obstacles_gger_lod.
create or replace function citydb.list_flight_obstacles_gger_lod(
    p_source_kind text default 'terrain',
    p_lod_level integer default null,
    p_west double precision default null,
    p_south double precision default null,
    p_east double precision default null,
    p_north double precision default null,
    p_center_lon double precision default null,
    p_center_lat double precision default null,
    p_limit integer default 1000,
    p_include_boxes boolean default true
)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
    select public.list_flight_obstacles_gger_lod(p_source_kind, p_lod_level, p_west, p_south, p_east, p_north, p_center_lon, p_center_lat, p_limit, p_include_boxes);
$$;

comment on function citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean)
is 'PostgREST wrapper for public.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean).';

grant usage on schema citydb_grid to web_anon;
grant select on citydb_grid.obstacles_terrain_lod to web_anon;
grant execute on function citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean) to web_anon;

notify pgrst, 'reload schema';

commit;
