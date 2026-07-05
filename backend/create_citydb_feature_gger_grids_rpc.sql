-- PostgREST RPC: fetch GGER geomgrids and per-cell bbox info for a picked CityDB feature.
--
-- Usage through PostgREST:
--   POST /rpc/get_citydb_feature_gger_grids
--   {"p_feature_identifier":"osm:way:1002427134"}
--
-- The identifier can be citydb.feature.id, objectid, or identifier. The RPC
-- returns GGER only. BGC is intentionally not part of the external API contract.

begin;

create or replace function public.get_citydb_feature_gger_grids(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
with matched_feature as (
    select
        f.id,
        f.objectid,
        f.identifier,
        f.identifier_codespace,
        f.objectclass_id,
        oc.classname as objectclass
    from citydb.feature f
    left join citydb.objectclass oc on oc.id = f.objectclass_id
    where f.objectid = p_feature_identifier
       or f.identifier = p_feature_identifier
       or (
            p_feature_identifier ~ '^[0-9]+$'
            and f.id = p_feature_identifier::bigint
       )
    order by
        case
            when f.objectid = p_feature_identifier then 1
            when f.identifier = p_feature_identifier then 2
            else 3
        end,
        f.id
    limit 1
), matched_grid as (
    select
        fo.*,
        gd.feature_id,
        gd.id as geometry_id,
        ST_SRID(gd.geometry) as source_srid
    from matched_feature f
    join citydb.geometry_data gd on gd.feature_id = f.id
    join citydb_grid.flight_obstacles fo
      on fo.source_kind = 'building'
     and fo.source_id = gd.id::text
    order by gd.id
    limit 1
)
select case
    when not exists (select 1 from matched_feature) then null::jsonb
    when not exists (select 1 from matched_grid) then jsonb_build_object(
        'feature', (
            select jsonb_strip_nulls(jsonb_build_object(
                'id', f.id,
                'objectid', f.objectid,
                'identifier', f.identifier,
                'identifier_codespace', f.identifier_codespace,
                'objectclass_id', f.objectclass_id,
                'objectclass', f.objectclass
            ))
            from matched_feature f
        ),
        'grid', null
    )
    else jsonb_build_object(
        'feature', (
            select jsonb_strip_nulls(jsonb_build_object(
                'id', f.id,
                'objectid', f.objectid,
                'identifier', f.identifier,
                'identifier_codespace', f.identifier_codespace,
                'objectclass_id', f.objectclass_id,
                'objectclass', f.objectclass
            ))
            from matched_feature f
        ),
        'grid', (
            select jsonb_strip_nulls(jsonb_build_object(
                'feature_id', g.feature_id,
                'geometry_id', g.geometry_id,
                'source_kind', g.source_kind,
                'source_id', g.source_id,
                'source_name', g.source_name,
                'dimension', g.dimension,
                'detail_level', g.detail_level,
                'is_agg', g.is_agg,
                'cell_count', ST_nCells(g.grids),
                'gger_grids', ST_AsText(g.grids, 'GGER'),
                'gger_grids_with_box', ST_WithBox(g.grids, 'GGER'),
                'source_srid', g.source_srid,
                'priority', g.priority,
                'generated_at', g.generated_at
            ))
            from matched_grid g
        )
    )
end;
$$;

comment on function public.get_citydb_feature_gger_grids(text)
is 'Fetch GGER geomgrids and ST_WithBox bbox text for a CityDB feature identifier. Returns no BGC fields.';

grant execute on function public.get_citydb_feature_gger_grids(text) to admin;

-- PostgREST uses the first exposed schema in pgrest.conf (`citydb`) as the
-- default RPC schema. Keep the main implementation in `public`, and expose this
-- thin wrapper so `/rpc/get_citydb_feature_gger_grids` works without custom
-- Content-Profile headers.
create or replace function citydb.get_citydb_feature_gger_grids(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
    select public.get_citydb_feature_gger_grids(p_feature_identifier);
$$;

comment on function citydb.get_citydb_feature_gger_grids(text)
is 'PostgREST wrapper for public.get_citydb_feature_gger_grids(text).';

grant usage on schema citydb_grid to admin;
grant select on citydb_grid.flight_obstacles to admin;
grant select on citydb_grid.flight_obstacles_codes_view to admin;
grant execute on function citydb.get_citydb_feature_gger_grids(text) to admin;

notify pgrst, 'reload schema';

commit;
