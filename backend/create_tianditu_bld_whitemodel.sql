-- 天地图江苏建筑白膜：staging、跨瓦片重组、拉伸建模与 pg2b3dm 导出物化视图。
-- 数据源：tdtjs:BLD 矢量瓦片（EPSG:4490，按 4326 处理），详见 docs/tianditu_bld_whitemodel_3dtiles_plan.md。
-- 依赖 terrain.dem_tile（EPSG:32650）采样基底高程；可安全重复执行。

begin;

-- 一、瓦片碎片明细：同一建筑跨瓦片时被切成多片，先按 (elemid, tile) 落表。
create table if not exists raw.tianditu_bld_fragment (
  elemid text not null,
  z smallint not null,
  x integer not null,
  y integer not null,
  floor_num integer,
  geom geometry(Polygon, 4326) not null,
  ingested_at timestamptz not null default now(),
  primary key (elemid, z, x, y)
);
comment on table raw.tianditu_bld_fragment is '天地图建筑瓦片碎片明细，按建筑 ID 和瓦片坐标幂等。';
comment on column raw.tianditu_bld_fragment.elemid is '建筑唯一 ID，来源于瓦片 ELEMID 属性。';
comment on column raw.tianditu_bld_fragment.floor_num is '楼层数，由 FLOOR 字符串解析，非法值置空。';
comment on column raw.tianditu_bld_fragment.geom is '建筑轮廓碎片，WGS84 Polygon（EPSG:4326）。';

create index if not exists tianditu_bld_fragment_geom_gix on raw.tianditu_bld_fragment using gist (geom);

-- 二、重组后的完整建筑轮廓。
create table if not exists raw.tianditu_bld_feature (
  elemid text primary key,
  floor_num integer,
  geom geometry(MultiPolygon, 4326) not null,
  source_tiles integer not null default 1,
  ingested_at timestamptz not null default now()
);
comment on table raw.tianditu_bld_feature is '天地图建筑完整轮廓，按 ELEMID 跨瓦片 ST_Union 重组。';
comment on column raw.tianditu_bld_feature.source_tiles is '该建筑来源瓦片数，大于 1 表示跨瓦片重组。';
comment on column raw.tianditu_bld_feature.geom is '建筑完整轮廓，WGS84 MultiPolygon（EPSG:4326）。';

create index if not exists tianditu_bld_feature_geom_gix on raw.tianditu_bld_feature using gist (geom);

-- 三、重组函数：全量刷新建筑轮廓。返回重组后的建筑数量。
create or replace function raw.rebuild_tianditu_bld_features()
returns bigint language sql as $$
  with merged as (
    select elemid,
           max(floor_num) as floor_num,
           count(distinct (z, x, y)) as source_tiles,
           ST_Multi(ST_UnaryUnion(ST_Collect(ST_MakeValid(geom)))) as geom
    from raw.tianditu_bld_fragment
    group by elemid
  ), upserted as (
    insert into raw.tianditu_bld_feature (elemid, floor_num, geom, source_tiles)
    select elemid, floor_num, geom, source_tiles from merged
    on conflict (elemid) do update set
      floor_num = excluded.floor_num,
      geom = excluded.geom,
      source_tiles = excluded.source_tiles,
      ingested_at = now()
    returning 1
  )
  select count(*) from upserted;
$$;
comment on function raw.rebuild_tianditu_bld_features() is '按 ELEMID 跨瓦片重组建筑轮廓并 upsert。返回重组建筑数量。';

-- 四、白膜导出物化视图：FLOOR×3m 拉伸，基底高程取 DEM（EPSG:32650），无覆盖则为 0。
-- 遵循 pg2b3dm 契约：geom（3D）、id、class、material_data。
drop materialized view if exists raw.tianditu_bld_whitemodel_export;
create materialized view raw.tianditu_bld_whitemodel_export as
with parts as (
  select f.elemid, f.floor_num, (ST_Dump(f.geom)).geom as geom
  from raw.tianditu_bld_feature f
), elevated as (
  select elemid,
         floor_num,
         least(coalesce(floor_num, 1), 100) * 3.0 as height_m,
         coalesce((
           select ST_Value(t.rast, ST_Transform(ST_Centroid(parts.geom), 32650))
           from terrain.dem_tile t
           where ST_Intersects(t.rast, ST_Transform(ST_Centroid(parts.geom), 32650))
           limit 1
         ), 0)::double precision as base_z,
         geom
  from parts
)
select ST_Translate(ST_Extrude(geom, 0, 0, height_m), 0, 0, base_z) as geom,
       elemid as id,
       'tianditu_bld'::text as class,
       jsonb_build_object(
         'PbrMetallicRoughness', jsonb_build_object(
           'BaseColors', array['#F2F2F2'],
           'MetallicRoughness', array['#00000080']
         )
       )::json as material_data,
       floor_num as gen_floor,
       height_m::real as gen_height_m,
       base_z::real as gen_base_z
from elevated
where not ST_IsEmpty(geom);
comment on materialized view raw.tianditu_bld_whitemodel_export is '天地图建筑白膜 pg2b3dm 导出视图，体块为楼层×3m 拉伸并贴 DEM。';
comment on column raw.tianditu_bld_whitemodel_export.gen_height_m is '拉伸高度，单位米，楼层数×3，楼层上限 100 防异常。';
comment on column raw.tianditu_bld_whitemodel_export.gen_base_z is '基底高程，单位米，取建筑质心处 DEM 值，无 DEM 覆盖为 0。';

create index if not exists tianditu_bld_whitemodel_export_geom_gix
on raw.tianditu_bld_whitemodel_export using gist (st_centroid(st_envelope(geom)));

commit;
