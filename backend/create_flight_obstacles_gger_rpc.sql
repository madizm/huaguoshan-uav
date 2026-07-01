-- PostgREST RPC: list multi-source flight obstacle GGER geomgrids for Cesium display.
--
-- Usage through PostgREST:
--   POST /rpc/list_flight_obstacles_gger
--   {"p_source_kind":"no_fly_zone","p_limit":200,"p_include_boxes":true}
--
-- Returns GGER only. BGC is intentionally not part of the external API contract.

begin;

create or replace function public.list_flight_obstacles_gger(
    p_source_kind text default null,
    p_limit integer default 200,
    p_include_boxes boolean default true
)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
with limited_obstacles as (
    select fo.*
    from citydb_grid.flight_obstacles fo
    where p_source_kind is null
       or fo.source_kind = p_source_kind
    order by
        fo.priority desc,
        fo.source_kind,
        fo.source_id
    limit greatest(0, least(coalesce(p_limit, 200), 1000))
)
select coalesce(
    jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
            'source_kind', source_kind,
            'source_id', source_id,
            'source_name', source_name,
            'dimension', dimension,
            'detail_level', detail_level,
            'is_agg', is_agg,
            'cell_count', public.ST_nCells(grids),
            'gger_grids', public.ST_AsText(grids, 'GGER'),
            'gger_grids_with_box', case when p_include_boxes then public.ST_WithBox(grids, 'GGER') else null end,
            'valid_from', valid_from,
            'valid_to', valid_to,
            'priority', priority,
            'generated_at', generated_at
        ))
    ),
    '[]'::jsonb
)
from limited_obstacles;
$$;

comment on function public.list_flight_obstacles_gger(text, integer, boolean)
is 'List multi-source flight obstacle geomgrids as GGER text and optional ST_WithBox bbox text. Returns no BGC fields.';

grant execute on function public.list_flight_obstacles_gger(text, integer, boolean) to web_anon;

-- PostgREST exposes the first configured schema (`citydb`) as the default RPC
-- schema in this project. Keep implementation in public and expose a citydb
-- wrapper for /rpc/list_flight_obstacles_gger.
create or replace function citydb.list_flight_obstacles_gger(
    p_source_kind text default null,
    p_limit integer default 200,
    p_include_boxes boolean default true
)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
    select public.list_flight_obstacles_gger(p_source_kind, p_limit, p_include_boxes);
$$;

comment on function citydb.list_flight_obstacles_gger(text, integer, boolean)
is 'PostgREST wrapper for public.list_flight_obstacles_gger(text, integer, boolean).';

grant usage on schema citydb_grid to web_anon;
grant select on citydb_grid.flight_obstacles to web_anon;
grant select on citydb_grid.flight_obstacles_codes_view to web_anon;
grant execute on function citydb.list_flight_obstacles_gger(text, integer, boolean) to web_anon;

notify pgrst, 'reload schema';

commit;
