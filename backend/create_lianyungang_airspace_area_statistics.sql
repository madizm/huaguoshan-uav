-- 连云港市空域面积统计物化视图。
--
-- 一个统计周期内，每类区域先做空间并集，避免相交或重复配置被重复计入。
-- 适飞面积来自连云港市的二维适飞基底；长期禁飞面积仅统计 enabled 区域；
-- 临时禁飞面积仅统计刷新时 status=active 且处于有效时间窗内的区域。
--
-- 刷新当前统计：
--   refresh materialized view concurrently airspace.lianyungang_airspace_area_statistics;

begin;

-- This deployment is intentionally repeatable. Drop the API facade first so
-- the materialized-view definition may evolve without requiring CASCADE.
drop view if exists api.lianyungang_airspace_area_statistics;
drop materialized view if exists airspace.lianyungang_airspace_area_statistics;

create materialized view airspace.lianyungang_airspace_area_statistics as
with suitable_geometry as (
  select st_collectionextract(st_unaryunion(st_collect(geom)), 3) as geom
  from airspace.suitable_fly_zone
  where name = '连云港市'
), no_fly_geometry as (
  select st_collectionextract(st_unaryunion(st_collect(geom)), 3) as geom
  from airspace.no_fly_zone
  where enabled
), temporary_no_fly_geometry as (
  select st_collectionextract(st_unaryunion(st_collect(geom)), 3) as geom
  from airspace.temp_control_zone
  where status = 'active'
    and valid_from <= statement_timestamp()
    and valid_to > statement_timestamp()
)
select
  '连云港市'::text as city_name,
  coalesce(
    round((st_area(suitable_geometry.geom::geography) / 1000000.0)::numeric, 6),
    0.000000::numeric
  )::numeric(14, 6) as suitable_area_km2,
  coalesce(
    round((st_area(no_fly_geometry.geom::geography) / 1000000.0)::numeric, 6),
    0.000000::numeric
  )::numeric(14, 6) as no_fly_area_km2,
  coalesce(
    round((st_area(temporary_no_fly_geometry.geom::geography) / 1000000.0)::numeric, 6),
    0.000000::numeric
  )::numeric(14, 6) as temporary_no_fly_area_km2,
  statement_timestamp() as refreshed_at
from suitable_geometry
cross join no_fly_geometry
cross join temporary_no_fly_geometry;

-- A unique index enables non-blocking concurrent refreshes after initial creation.
create unique index lianyungang_airspace_area_statistics_city_name_uidx
  on airspace.lianyungang_airspace_area_statistics (city_name);

grant select on table airspace.lianyungang_airspace_area_statistics to admin;

create view api.lianyungang_airspace_area_statistics as
select
  city_name,
  suitable_area_km2,
  no_fly_area_km2,
  temporary_no_fly_area_km2,
  refreshed_at
from airspace.lianyungang_airspace_area_statistics;

comment on materialized view airspace.lianyungang_airspace_area_statistics is '连云港市适飞、长期禁飞和当前生效临时禁飞区域面积统计物化视图；面积单位为平方公里。';
comment on column airspace.lianyungang_airspace_area_statistics.city_name is '统计所属城市，固定为连云港市。';
comment on column airspace.lianyungang_airspace_area_statistics.suitable_area_km2 is '连云港市适飞区域面积，单位平方公里；相交面已做并集去重。';
comment on column airspace.lianyungang_airspace_area_statistics.no_fly_area_km2 is '已启用长期禁飞区域面积，单位平方公里；相交面已做并集去重。';
comment on column airspace.lianyungang_airspace_area_statistics.temporary_no_fly_area_km2 is '刷新时当前生效临时禁飞区域面积，单位平方公里；相交面已做并集去重。';
comment on column airspace.lianyungang_airspace_area_statistics.refreshed_at is '统计物化视图最后一次生成时间。';

comment on view api.lianyungang_airspace_area_statistics is '连云港市适飞、长期禁飞和当前生效临时禁飞区域面积统计只读 API；面积单位为平方公里。';
comment on column api.lianyungang_airspace_area_statistics.city_name is '统计所属城市，固定为连云港市。';
comment on column api.lianyungang_airspace_area_statistics.suitable_area_km2 is '适飞区域面积，单位平方公里。';
comment on column api.lianyungang_airspace_area_statistics.no_fly_area_km2 is '已启用长期禁飞区域面积，单位平方公里。';
comment on column api.lianyungang_airspace_area_statistics.temporary_no_fly_area_km2 is '当前生效临时禁飞区域面积，单位平方公里。';
comment on column api.lianyungang_airspace_area_statistics.refreshed_at is '统计物化视图最后一次生成时间。';

grant select on api.lianyungang_airspace_area_statistics to admin;

notify pgrst, 'reload schema';

commit;
