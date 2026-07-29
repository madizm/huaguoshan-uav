-- 将浏览器计算的三维凸包转换为 iBEST-DB GGER 三维网格。
--
-- PostgREST:
--   POST /rpc/grid_convex_hull_3d
--   {
--     "p_wkt": "POLYHEDRALSURFACE Z (...)",
--     "p_detail_level": 19,
--     "p_is_agg": true,
--     "p_max_cells": 5000
--   }

begin;

create or replace function public.grid_convex_hull_3d(
    p_wkt text,
    p_detail_level integer default 19,
    p_is_agg boolean default true,
    p_max_cells integer default 5000
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_geometry geometry;
    v_grids public.geomgrids;
    v_cell_count integer;
begin
    if p_wkt is null or btrim(p_wkt) = '' then
        raise exception using errcode = '22023', message = 'p_wkt 不能为空';
    end if;
    if octet_length(p_wkt) > 1048576 then
        raise exception using errcode = '22023', message = 'p_wkt 超过 1 MiB 限制';
    end if;
    if p_detail_level not between 6 and 32 then
        raise exception using errcode = '22023', message = 'p_detail_level 必须在 6 到 32 之间';
    end if;
    if p_max_cells not between 1 and 10000 then
        raise exception using errcode = '22023', message = 'p_max_cells 必须在 1 到 10000 之间';
    end if;

    begin
        v_geometry := ST_GeomFromText(p_wkt, 4326);
    exception when others then
        raise exception using errcode = '22023', message = 'p_wkt 不是有效的 WKT：' || sqlerrm;
    end;

    if ST_GeometryType(v_geometry) <> 'ST_PolyhedralSurface' then
        raise exception using errcode = '22023', message = 'p_wkt 必须是 POLYHEDRALSURFACE Z';
    end if;
    if ST_CoordDim(v_geometry) <> 3 then
        raise exception using errcode = '22023', message = 'p_wkt 必须包含 Z 高度';
    end if;
    if ST_XMin(Box3D(v_geometry)) < -180 or ST_XMax(Box3D(v_geometry)) > 180
       or ST_YMin(Box3D(v_geometry)) < -90 or ST_YMax(Box3D(v_geometry)) > 90 then
        raise exception using errcode = '22023', message = '凸包经纬度超出 EPSG:4326 范围';
    end if;
    if ST_ZMin(Box3D(v_geometry)) < -12000 or ST_ZMax(Box3D(v_geometry)) > 100000 then
        raise exception using errcode = '22023', message = '凸包高度超出允许范围 [-12000, 100000] 米';
    end if;

    v_grids := ST_AsGrids3D(v_geometry, p_detail_level, p_is_agg);
    v_cell_count := ST_nCells(v_grids);
    if v_cell_count > p_max_cells then
        raise exception using
            errcode = '54000',
            message = format('网格数量 %s 超过限制 %s，请降低 detail level', v_cell_count, p_max_cells);
    end if;

    return jsonb_build_object(
        'dimension', 3,
        'detail_level', ST_DetailLevel(v_grids),
        'is_agg', p_is_agg,
        'cell_count', v_cell_count,
        'height_datum', 'ELLIPSOID',
        'source_srid', 4326,
        'gger_grids', ST_AsText(v_grids, 'GGER'),
        'gger_grids_with_box', ST_WithBox(v_grids, 'GGER')
    );
end;
$$;

comment on function public.grid_convex_hull_3d(text, integer, boolean, integer)
is '将 EPSG:4326 POLYHEDRALSURFACE Z 凸包传给 iBEST-DB ST_AsGrids3D。返回 JSON：dimension、detail_level、is_agg、cell_count、height_datum、source_srid、gger_grids、gger_grids_with_box。';

revoke all on function public.grid_convex_hull_3d(text, integer, boolean, integer) from public;
revoke all on function public.grid_convex_hull_3d(text, integer, boolean, integer) from anonymous;
grant execute on function public.grid_convex_hull_3d(text, integer, boolean, integer) to admin;

-- pgrest.conf 首个 exposed schema 为 citydb，使用包装函数暴露 RPC。
create or replace function citydb.grid_convex_hull_3d(
    p_wkt text,
    p_detail_level integer default 19,
    p_is_agg boolean default true,
    p_max_cells integer default 5000
)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, pg_temp
as $$
    select public.grid_convex_hull_3d(p_wkt, p_detail_level, p_is_agg, p_max_cells);
$$;

comment on function citydb.grid_convex_hull_3d(text, integer, boolean, integer)
is 'PostgREST 包装：调用 public.grid_convex_hull_3d，并返回 GGER 网格及 ST_WithBox 单元包围盒 JSON。';

revoke all on function citydb.grid_convex_hull_3d(text, integer, boolean, integer) from public;
revoke all on function citydb.grid_convex_hull_3d(text, integer, boolean, integer) from anonymous;
grant execute on function citydb.grid_convex_hull_3d(text, integer, boolean, integer) to admin;

-- 当前 PostgREST 暴露 api schema；该包装函数是正式 HTTP RPC seam。
create or replace function api.grid_convex_hull_3d(
    p_wkt text,
    p_detail_level integer default 19,
    p_is_agg boolean default true,
    p_max_cells integer default 5000
)
returns jsonb
language sql
stable
security definer
set search_path = public, api, pg_temp
as $$
    select public.grid_convex_hull_3d(p_wkt, p_detail_level, p_is_agg, p_max_cells);
$$;

comment on function api.grid_convex_hull_3d(text, integer, boolean, integer)
is '将 EPSG:4326 三维凸包交给 iBEST-DB 打码。返回 JSON：dimension、detail_level、is_agg、cell_count、height_datum、source_srid、gger_grids、gger_grids_with_box。';

revoke all on function api.grid_convex_hull_3d(text, integer, boolean, integer) from public;
revoke all on function api.grid_convex_hull_3d(text, integer, boolean, integer) from anonymous;
grant execute on function api.grid_convex_hull_3d(text, integer, boolean, integer) to admin;

notify pgrst, 'reload schema';

commit;
