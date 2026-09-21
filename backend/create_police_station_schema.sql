-- 警务工作站/警务站真实 POI 数据模型。
--
-- 数据来源：天地图地名搜索 V2.0（queryType=13 分类搜索，分类码 190200 公检法机构），
-- 覆盖连云港市全域（连云/海州/赣榆/东海/灌云/灌南）的 POI 收录结果。
-- 坐标为天地图 CGCS2000，按 WGS84 等同处理，geometry 为 Point / EPSG:4326。
-- 与库内花果山景区模拟数据不同，本表记录为真实外部数据，is_simulated 恒为 false，
-- availability_status 默认为 unknown（来源不提供运行状态，不臆造）。
--
-- PostgREST 仅公开 api 架构；api.emergency_police_stations 是可更新的 CRUD 资源。
-- 种子数据见 backend/seed_police_station_tianditu.sql。

begin;

create extension if not exists postgis;

create schema if not exists emergency_resource;
create schema if not exists api;

create or replace function emergency_resource.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function emergency_resource.touch_updated_at() is '维护应急力量业务表的 updated_at 字段。';

-- -----------------------------------------------------------------------------
-- 警务工作站/警务站
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.police_station (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  station_type text not null
    check (station_type in ('workstation', 'station')),
  managing_unit_name text,
  contact_phone text,
  address text,
  county_name text,
  availability_status text not null default 'unknown'
    check (availability_status in ('available', 'unavailable', 'unknown')),
  is_simulated boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.police_station is '连云港市警务工作站与警务站点位；当前记录为天地图 POI 真实数据（is_simulated=false），用于事件处置闭环中的公安协同处置力量展示与调度参考。';
comment on column emergency_resource.police_station.source_code is '外部来源中的稳定记录编码，天地图 POI 取 TDT-<hotPointID>，用于幂等导入。';
comment on column emergency_resource.police_station.station_type is '站点类型：workstation 警务工作站、station 警务站。';
comment on column emergency_resource.police_station.managing_unit_name is '所属公安机关名称；仅从站点名称可可靠解析时填写，否则为空。';
comment on column emergency_resource.police_station.county_name is '所属区县名称，如东海县、赣榆区；由来源地址解析并结合查询来源补全。';
comment on column emergency_resource.police_station.availability_status is '可用状态：available 可调度、unavailable 不可用、unknown 未知（外部来源默认）。';
comment on column emergency_resource.police_station.metadata is '来源元数据 JSON，含 provider、hotPointID、keyword、疑似重复标注等。';
comment on column emergency_resource.police_station.geom is '站点位置，WGS84 Point（EPSG:4326；天地图 CGCS2000 按 WGS84 等同处理）。';

create index if not exists police_station_geom_gix on emergency_resource.police_station using gist (geom);
create index if not exists police_station_station_type_idx on emergency_resource.police_station (station_type);
create index if not exists police_station_county_name_idx on emergency_resource.police_station (county_name);

drop trigger if exists police_station_touch_updated_at on emergency_resource.police_station;
create trigger police_station_touch_updated_at
before update on emergency_resource.police_station
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 各类应急资源数量统计快照：并入 police_station 类别。
-- 因无法向既有物化视图追加 union 分支，此处整体重建；刷新函数与 api 视图同步重建。
-- -----------------------------------------------------------------------------
-- 先删除依赖物化视图的 api 门面对象，随后统一重建。
drop view if exists api.emergency_resource_category_statistics;
drop function if exists api.refresh_emergency_resource_category_statistics();
drop materialized view if exists emergency_resource.category_statistics;

create materialized view emergency_resource.category_statistics as
select
  'medical_resource'::text as category_code,
  '医疗资源'::text as category_name,
  count(*)::bigint as resource_count,
  now() as refreshed_at
from emergency_resource.medical_resource
union all
select
  'expert_force'::text as category_code,
  '专家力量'::text,
  count(*)::bigint,
  now()
from emergency_resource.expert_force
union all
select
  'shelter'::text as category_code,
  '避难场所'::text,
  count(*)::bigint,
  now()
from emergency_resource.shelter
union all
select
  'material_warehouse'::text as category_code,
  '物资仓库'::text,
  count(*)::bigint,
  now()
from emergency_resource.material_warehouse
union all
select
  'water_point'::text as category_code,
  '取水点'::text,
  count(*)::bigint,
  now()
from emergency_resource.water_point
union all
select
  'landing_site'::text as category_code,
  '起降点'::text,
  count(*)::bigint,
  now()
from emergency_resource.landing_site
union all
select
  'police_station'::text as category_code,
  '智慧警务站'::text,
  count(*)::bigint,
  now()
from emergency_resource.police_station
with data;

comment on materialized view emergency_resource.category_statistics is '各类应急资源记录数量的物化统计快照；调用 refresh_category_statistics 刷新。';
comment on column emergency_resource.category_statistics.category_code is '应急资源类别编码。';
comment on column emergency_resource.category_statistics.category_name is '应急资源类别中文名称。';
comment on column emergency_resource.category_statistics.resource_count is '该类别的资源记录数量。';
comment on column emergency_resource.category_statistics.refreshed_at is '物化统计快照刷新时间。';

create unique index if not exists category_statistics_category_code_key
  on emergency_resource.category_statistics (category_code);

create or replace function emergency_resource.refresh_category_statistics()
returns timestamptz
language plpgsql
security definer
set search_path = emergency_resource, public, pg_temp
as $$
declare
  v_refreshed_at timestamptz;
begin
  refresh materialized view emergency_resource.category_statistics;

  select max(refreshed_at)
  into v_refreshed_at
  from emergency_resource.category_statistics;

  return v_refreshed_at;
end;
$$;

comment on function emergency_resource.refresh_category_statistics() is '刷新各类应急资源数量物化统计快照，返回本次快照刷新时间（timestamptz）。';

-- -----------------------------------------------------------------------------
-- PostgREST API 门面：仅 api schema 对 HTTP 暴露。
-- -----------------------------------------------------------------------------
create or replace view api.emergency_police_stations as
select * from emergency_resource.police_station;

create or replace view api.emergency_resource_category_statistics as
select
  category_code,
  category_name,
  resource_count,
  refreshed_at
from emergency_resource.category_statistics;

create or replace function api.refresh_emergency_resource_category_statistics()
returns timestamptz
language sql
volatile
set search_path = emergency_resource, public, pg_temp
as $$
  select emergency_resource.refresh_category_statistics();
$$;

comment on view api.emergency_police_stations is '警务工作站/警务站 CRUD 资源；数据位于 emergency_resource.police_station，当前为天地图 POI 真实数据。';
comment on column api.emergency_police_stations.geom is '站点位置，WGS84 Point（EPSG:4326；天地图 CGCS2000 按 WGS84 等同处理）。';
comment on view api.emergency_resource_category_statistics is '各类应急资源数量物化统计快照只读资源。';
comment on column api.emergency_resource_category_statistics.category_code is '应急资源类别编码。';
comment on column api.emergency_resource_category_statistics.category_name is '应急资源类别中文名称。';
comment on column api.emergency_resource_category_statistics.resource_count is '该类别的资源记录数量。';
comment on column api.emergency_resource_category_statistics.refreshed_at is '物化统计快照刷新时间。';
comment on function api.refresh_emergency_resource_category_statistics() is '刷新各类应急资源数量统计快照，返回本次刷新时间（timestamptz）。';

-- -----------------------------------------------------------------------------
-- 权限与 schema cache 刷新。
-- -----------------------------------------------------------------------------
grant usage on schema emergency_resource to admin;
grant select, insert, update, delete on emergency_resource.police_station to admin;
grant select on emergency_resource.category_statistics to admin;
grant usage, select, update on sequence emergency_resource.police_station_id_seq to admin;
grant execute on function emergency_resource.refresh_category_statistics() to admin;

alter default privileges for role postgres in schema emergency_resource
  grant select, insert, update, delete on tables to admin;
alter default privileges for role postgres in schema emergency_resource
  grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema emergency_resource
  grant execute on functions to admin;

grant usage on schema api to admin;
grant select, insert, update, delete on api.emergency_police_stations to admin;
grant select on api.emergency_resource_category_statistics to admin;
grant execute on function api.refresh_emergency_resource_category_statistics() to admin;

notify pgrst, 'reload schema';

commit;
