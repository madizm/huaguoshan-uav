-- Simplify PostgREST roles and expose a single api schema.
--
-- Target model:
--   authenticator LOGIN NOINHERIT  - PostgREST database connection role
--   anonymous     NOLOGIN          - unauthenticated HTTP role, no business object access
--   admin         NOLOGIN          - authenticated JWT role with business DML/RPC access
--
-- PostgREST should expose only the api schema. Business schemas remain the data
-- layer and are not exposed directly over HTTP.

begin;

create schema if not exists api;
comment on schema api is 'Stable PostgREST API facade for the Huaguoshan UAV application.';

-- Roles ----------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'admin') then
    create role admin nologin;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'anonymous') then
    create role anonymous nologin;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit password 'authenticator';
  end if;
end;
$$;

alter role admin nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
alter role anonymous nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
alter role authenticator login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls password 'authenticator';

grant admin to authenticator;
grant anonymous to authenticator;

-- Keep public from acquiring default access to the API facade.
revoke all on schema api from public;
grant usage on schema api to anonymous;
grant usage on schema api to admin;

-- Business data privileges ----------------------------------------------------
-- `admin` can read/write business data but cannot create/alter/drop schema
-- objects. public is intentionally excluded from business DML; only extension
-- function execution and spatial_ref_sys reads are granted where needed.
grant usage on schema citydb, terrain, airspace, citydb_grid, flight_path to admin;
grant select, insert, update, delete, truncate, references, trigger
  on all tables in schema citydb, terrain, airspace, citydb_grid, flight_path to admin;
grant usage, select, update on all sequences in schema citydb, terrain, airspace, citydb_grid, flight_path to admin;
grant execute on all functions in schema citydb, terrain, airspace, citydb_grid, flight_path to admin;

grant usage on schema public to admin;
grant execute on all functions in schema public to admin;
grant select on table public.spatial_ref_sys to admin;

alter default privileges for role postgres in schema citydb, terrain, airspace, citydb_grid, flight_path
  grant select, insert, update, delete, truncate, references, trigger on tables to admin;
alter default privileges for role postgres in schema citydb, terrain, airspace, citydb_grid, flight_path
  grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema citydb, terrain, airspace, citydb_grid, flight_path
  grant execute on functions to admin;

-- Flight path authorization compatibility -------------------------------------
-- Earlier flight-path RPC migrations encoded a two-role planner model inside
-- `flight_path.*` helper functions (`flight_planner` owns its own plans,
-- `airspace_admin` sees all plans). This migration intentionally replaces that
-- model with the single PostgREST business role from ADR-0004: authenticated
-- JWT requests run as `admin`, and `admin` can manage all flight-path plans.
-- Keep the actor requirement so anonymous requests still fail inside RPCs even
-- if a function is accidentally granted later.
create or replace function flight_path.current_actor_id()
returns text
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub';
$$;

create or replace function flight_path.current_actor_role()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user);
$$;
create or replace function flight_path.current_actor_name()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'username', ''),
    nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
    current_user
  );
$$;


create or replace function flight_path.require_planning_actor()
returns text
language plpgsql
stable
as $$
declare
  v_actor text := flight_path.current_actor_id();
  v_role text := flight_path.current_actor_role();
begin
  if v_actor is null or v_actor = '' then
    raise exception 'flight path planning requires a JWT actor' using errcode = '42501';
  end if;

  if v_role <> 'admin' then
    raise exception 'role % cannot manage flight path plans', v_role using errcode = '42501';
  end if;

  return v_actor;
end;
$$;

create or replace function flight_path.assert_plan_access(p_plan_id bigint)
returns void
language plpgsql
stable
as $$
begin
  perform flight_path.require_planning_actor();

  if not exists (select 1 from flight_path.plan where id = p_plan_id) then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;
end;
$$;

create or replace function flight_path.assert_plan_ownership(p_plan_id bigint, p_operation text)
returns bigint
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
begin
  perform flight_path.require_planning_actor();

  if not exists (select 1 from flight_path.plan where id = p_plan_id) then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;

  return p_plan_id;
end;
$$;

create or replace function flight_path.list_plans(
  p_keyword text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
with actor as (
  select flight_path.require_planning_actor() as subject
), filtered as (
  select p.*
  from flight_path.plan p, actor a
  where (p_status is null or p.status = p_status)
    and p.status <> 'archived'
    and (
      p_keyword is null
      or p.name ilike '%' || p_keyword || '%'
      or p.description ilike '%' || p_keyword || '%'
    )
), counted as (
  select count(*) as total from filtered
), items as (
  select
    p.id,
    p.name,
    p.description,
    p.status,
    p.detail_level,
    p.cruise_height_m,
    p.height_datum,
    p.planning_time,
    p.has_below,
    p.safety_buffer_m,
    p.created_by,
    (select count(*) from flight_path.plan_point pp where pp.plan_id = p.id) as point_count,
    (select count(*) from flight_path.plan_point pp where pp.plan_id = p.id and pp.point_role = 'waypoint') as waypoint_count,
    p.last_computed_at,
    p.created_at,
    p.updated_at
  from filtered p
  order by p.updated_at desc, p.id desc
  limit greatest(0, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0))
)
select jsonb_build_object(
  'total', (select total from counted),
  'items', coalesce(jsonb_agg(to_jsonb(items) order by updated_at desc, id desc), '[]'::jsonb)
)
from items;
$$;

create or replace function flight_path.search_results_by_time(
  p_start_time timestamp,
  p_end_time timestamp,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
with actor as (
  select flight_path.require_planning_actor() as subject
), filtered as (
  select pr.*
  from flight_path.plan_result pr
  join flight_path.plan p on p.id = pr.plan_id
  cross join actor a
  where pr.route_traj is not null
    and pr.result_status = 'success'
    and pr.route_traj #&# GT_MakeBoxT(p_start_time, p_end_time)
), counted as (
  select count(*) as total from filtered
), items as (
  select
    pr.plan_id,
    pr.id as result_id,
    pr.result_status,
    pr.distance_m,
    pr.duration_s,
    pr.grid_cell_count,
    pr.traj_point_count,
    pr.segment_count,
    pr.created_at
  from filtered pr
  order by pr.created_at desc, pr.id desc
  limit greatest(0, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0))
)
select jsonb_build_object(
  'total', (select total from counted),
  'items', coalesce(jsonb_agg(to_jsonb(items) order by created_at desc, result_id desc), '[]'::jsonb)
)
from items;
$$;

create or replace function flight_path.search_results_by_bbox(
  p_xmin double precision,
  p_ymin double precision,
  p_xmax double precision,
  p_ymax double precision,
  p_start_time timestamp default '-infinity',
  p_end_time timestamp default 'infinity',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
with actor as (
  select flight_path.require_planning_actor() as subject
), box as (
  select ST_MakeEnvelope(p_xmin, p_ymin, p_xmax, p_ymax, 4326) as geom
), filtered as (
  select pr.*
  from flight_path.plan_result pr
  join flight_path.plan p on p.id = pr.plan_id
  cross join box
  cross join actor a
  where pr.route_traj is not null
    and pr.result_status = 'success'
    and GT_2DIntersects(pr.route_traj, box.geom, p_start_time, p_end_time)
), counted as (
  select count(*) as total from filtered
), items as (
  select
    pr.plan_id,
    pr.id as result_id,
    pr.result_status,
    pr.distance_m,
    pr.duration_s,
    pr.grid_cell_count,
    pr.traj_point_count,
    pr.segment_count,
    pr.created_at
  from filtered pr
  order by pr.created_at desc, pr.id desc
  limit greatest(0, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0))
)
select jsonb_build_object(
  'total', (select total from counted),
  'items', coalesce(jsonb_agg(to_jsonb(items) order by created_at desc, result_id desc), '[]'::jsonb)
)
from items;
$$;

grant execute on function flight_path.current_actor_id() to admin;
grant execute on function flight_path.current_actor_role() to admin;
grant execute on function flight_path.current_actor_name() to admin;
grant execute on function flight_path.require_planning_actor() to admin;
grant execute on function flight_path.assert_plan_access(bigint) to admin;
grant execute on function flight_path.assert_plan_ownership(bigint, text) to admin;
grant execute on function flight_path.list_plans(text, text, integer, integer) to admin;
grant execute on function flight_path.search_results_by_time(timestamp, timestamp, integer, integer) to admin;
grant execute on function flight_path.search_results_by_bbox(double precision, double precision, double precision, double precision, timestamp, timestamp, integer, integer) to admin;

-- Remove direct PostgREST table facades for flight-path internals. Flight-path
-- planning is exposed only through lifecycle RPCs so callers cannot bypass plan
-- validation, audit actor derivation, and result construction semantics.
drop view if exists api.flight_path_plan_results;
drop view if exists api.flight_path_plan_points;
drop view if exists api.flight_path_plans;

-- Ensure the two-dimensional suitable-airspace footprint source exists before
-- exposing its read-only API facade. The KML importer also creates this table;
-- this migration keeps a fresh database able to expose the view before data is
-- imported.
create table if not exists airspace.suitable_fly_zone (
  id bigint generated by default as identity primary key,
  name text not null,
  source_file text not null,
  source_feature_id text not null,
  source_layer text,
  source_properties jsonb not null default '{}'::jsonb,
  geom geometry(MultiPolygon, 4326) not null,
  imported_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_file, source_feature_id)
);

create index if not exists suitable_fly_zone_geom_gix
  on airspace.suitable_fly_zone using gist (geom);

-- API views ------------------------------------------------------------------
-- Simple views over airspace configuration tables are intentionally updatable,
-- preserving resource-style PostgREST CRUD while keeping PostgREST scoped to api.
create or replace view api.no_fly_zone as
select
  id,
  name,
  geom,
  min_height,
  max_height,
  safety_buffer_m,
  enabled,
  created_at,
  updated_at,
  height_datum,
  intake_evidence
from airspace.no_fly_zone;

create or replace view api.temp_control_zone as
select
  id,
  name,
  geom,
  min_height,
  max_height,
  safety_buffer_m,
  valid_from,
  valid_to,
  status,
  created_at,
  updated_at,
  height_datum,
  intake_evidence
from airspace.temp_control_zone;
create or replace view api.suitable_fly_zone_footprints as
select
  id,
  name,
  geom
from airspace.suitable_fly_zone;

create or replace view api.flight_obstacles as
select * from citydb_grid.flight_obstacles;

create or replace view api.flight_obstacles_codes_view as
select * from citydb_grid.flight_obstacles_codes_view;

-- API RPC wrappers ------------------------------------------------------------
create or replace function api.get_citydb_feature_properties(p_feature_identifier text)
returns jsonb
language sql
stable
set search_path = public, citydb, pg_temp
as $$
  select public.get_citydb_feature_properties(p_feature_identifier);
$$;

create or replace function api.get_citydb_feature_gger_grids(p_feature_identifier text)
returns jsonb
language sql
stable
set search_path = public, citydb, citydb_grid, pg_temp
as $$
  select public.get_citydb_feature_gger_grids(p_feature_identifier);
$$;

create or replace function api.list_flight_obstacles_gger(
  p_source_kind text default null,
  p_limit integer default 200,
  p_include_boxes boolean default true
)
returns jsonb
language sql
stable
set search_path = public, citydb_grid, pg_temp
as $$
  select public.list_flight_obstacles_gger(p_source_kind, p_limit, p_include_boxes);
$$;

create or replace function api.list_flight_obstacles_gger_lod(
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
set search_path = public, citydb_grid, pg_temp
as $$
  select public.list_flight_obstacles_gger_lod(
    p_source_kind,
    p_lod_level,
    p_west,
    p_south,
    p_east,
    p_north,
    p_center_lon,
    p_center_lat,
    p_limit,
    p_include_boxes
  );
$$;

drop function if exists api.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text);
drop function if exists citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text);
drop function if exists flight_path.create_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text);

create or replace function flight_path.create_plan(
  p_name text,
  p_description text default null,
  p_detail_level integer default 19,
  p_cruise_height_m double precision default null,
  p_height_datum text default 'AMSL',
  p_planning_time timestamptz default now(),
  p_points jsonb default '[]'::jsonb,
  p_has_below boolean default false,
  p_safety_buffer_m double precision default 0,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
declare
  v_plan_id bigint;
  v_height_datum text := upper(coalesce(p_height_datum, 'AMSL'));
begin
  perform flight_path.require_planning_actor();

  if nullif(trim(p_name), '') is null then
    raise exception 'p_name is required';
  end if;

  if v_height_datum not in ('AMSL', 'AGL', 'ELLIPSOID') then
    raise exception 'invalid p_height_datum: %', p_height_datum;
  end if;

  insert into flight_path.plan(
    name,
    description,
    status,
    detail_level,
    cruise_height_m,
    height_datum,
    planning_time,
    has_below,
    safety_buffer_m,
    metadata,
    created_by
  ) values (
    trim(p_name),
    p_description,
    'draft',
    coalesce(p_detail_level, 19),
    p_cruise_height_m,
    v_height_datum,
    coalesce(p_planning_time, now()),
    coalesce(p_has_below, false),
    coalesce(p_safety_buffer_m, 0),
    coalesce(p_metadata, '{}'::jsonb),
    flight_path.current_actor_name()
  ) returning id into v_plan_id;

  perform flight_path.replace_plan_points(v_plan_id, p_points);

  update flight_path.plan
  set status = 'planned'
  where id = v_plan_id;

  return v_plan_id;
end;
$$;

grant execute on function flight_path.create_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) to admin;

create or replace function api.create_flight_path_plan(
  p_name text,
  p_description text default null,
  p_detail_level integer default 16,
  p_cruise_height_m double precision default 120,
  p_height_datum text default 'AMSL',
  p_planning_time timestamptz default now(),
  p_points jsonb default '[]'::jsonb,
  p_has_below boolean default false,
  p_safety_buffer_m double precision default 0,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language sql
volatile
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.create_plan(
    p_name,
    p_description,
    p_detail_level,
    p_cruise_height_m,
    p_height_datum,
    p_planning_time,
    p_points,
    p_has_below,
    p_safety_buffer_m,
    p_metadata
  );
$$;

create or replace function api.update_flight_path_plan(
  p_plan_id bigint,
  p_name text default null,
  p_description text default null,
  p_detail_level integer default null,
  p_cruise_height_m double precision default null,
  p_height_datum text default null,
  p_planning_time timestamptz default null,
  p_points jsonb default null,
  p_has_below boolean default null,
  p_safety_buffer_m double precision default null,
  p_metadata jsonb default null
)
returns void
language sql
volatile
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.update_plan(
    p_plan_id,
    p_name,
    p_description,
    p_detail_level,
    p_cruise_height_m,
    p_height_datum,
    p_planning_time,
    p_points,
    p_has_below,
    p_safety_buffer_m,
    p_metadata
  );
$$;

create or replace function api.list_flight_path_plans(
  p_keyword text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.list_plans(p_keyword, p_status, p_limit, p_offset);
$$;

create or replace function api.get_flight_path_plan(p_plan_id bigint)
returns jsonb
language sql
stable
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.get_plan(p_plan_id);
$$;

create or replace function api.archive_flight_path_plan(p_plan_id bigint)
returns void
language sql
volatile
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.archive_plan(p_plan_id);
$$;

create or replace function api.delete_flight_path_plan(p_plan_id bigint)
returns void
language sql
volatile
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.delete_plan(p_plan_id);
$$;

create or replace function api.compute_flight_path_plan(p_plan_id bigint)
returns bigint
language sql
volatile
set search_path = flight_path, citydb_grid, public, pg_temp
as $$
  select flight_path.compute_plan(p_plan_id);
$$;

create or replace function api.get_latest_flight_path_result(p_plan_id bigint)
returns jsonb
language sql
stable
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.get_latest_result(p_plan_id);
$$;

create or replace function api.search_flight_path_results_by_time(
  p_start_time timestamp,
  p_end_time timestamp,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.search_results_by_time(p_start_time, p_end_time, p_limit, p_offset);
$$;

create or replace function api.search_flight_path_results_by_bbox(
  p_xmin double precision,
  p_ymin double precision,
  p_xmax double precision,
  p_ymax double precision,
  p_start_time timestamp default '-infinity',
  p_end_time timestamp default 'infinity',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.search_results_by_bbox(
    p_xmin,
    p_ymin,
    p_xmax,
    p_ymax,
    p_start_time,
    p_end_time,
    p_limit,
    p_offset
  );
$$;

-- OpenAPI descriptions -------------------------------------------------------
-- PostgREST copies PostgreSQL object comments into /openapi.json. Keep these
-- comments short so API callers can understand each endpoint without reading
-- implementation schemas.
comment on schema api is '花果山无人机应用的稳定 HTTP API 门面；仅暴露可调用的视图和 RPC。';

comment on view api.no_fly_zone is '长期禁飞区 CRUD 资源。用于维护持续生效的禁飞空域。';
comment on column api.no_fly_zone.id is '禁飞区主键。';
comment on column api.no_fly_zone.name is '禁飞区名称，便于前端展示和检索。';
comment on column api.no_fly_zone.geom is '禁飞区水平范围，WGS84 MultiPolygon。';
comment on column api.no_fly_zone.min_height is '禁飞区下限高度，单位米，基准见 height_datum。';
comment on column api.no_fly_zone.max_height is '禁飞区上限高度，单位米；为空表示不设上限。';
comment on column api.no_fly_zone.safety_buffer_m is '水平安全缓冲距离，单位米。';
comment on column api.no_fly_zone.enabled is '是否启用；false 表示暂不参与障碍计算。';
comment on column api.no_fly_zone.created_at is '记录创建时间。';
comment on column api.no_fly_zone.updated_at is '记录最后更新时间。';
comment on column api.no_fly_zone.height_datum is '高度基准：AMSL、AGL 或 ELLIPSOID。';
comment on column api.no_fly_zone.intake_evidence is '数据来源、审批材料或导入证据，JSON 格式。';

comment on view api.temp_control_zone is '临时管制区 CRUD 资源。用于维护限定时间内生效的禁飞或管制空域。';
comment on column api.temp_control_zone.id is '临时管制区主键。';
comment on column api.temp_control_zone.name is '临时管制区名称，便于前端展示和检索。';
comment on column api.temp_control_zone.geom is '临时管制区水平范围，WGS84 MultiPolygon。';
comment on column api.temp_control_zone.min_height is '管制区下限高度，单位米，基准见 height_datum。';
comment on column api.temp_control_zone.max_height is '管制区上限高度，单位米；为空表示不设上限。';
comment on column api.temp_control_zone.safety_buffer_m is '水平安全缓冲距离，单位米。';
comment on column api.temp_control_zone.valid_from is '管制开始时间。';
comment on column api.temp_control_zone.valid_to is '管制结束时间。';
comment on column api.temp_control_zone.status is '状态：planned、active 或 cancelled。';
comment on column api.temp_control_zone.created_at is '记录创建时间。';
comment on column api.temp_control_zone.updated_at is '记录最后更新时间。';
comment on column api.temp_control_zone.height_datum is '高度基准：AMSL、AGL 或 ELLIPSOID。';
comment on column api.temp_control_zone.intake_evidence is '数据来源、审批材料或导入证据，JSON 格式。';
comment on view api.suitable_fly_zone_footprints is '适飞空域基底范围只读视图；用于前端以 application/geo+json 获取二维 MultiPolygon。';
comment on column api.suitable_fly_zone_footprints.id is '适飞基底主键。';
comment on column api.suitable_fly_zone_footprints.name is '适飞基底名称，便于前端图例和拾取展示。';
comment on column api.suitable_fly_zone_footprints.geom is '适飞空域二维基底范围，WGS84 MultiPolygon；不包含高度语义。';

comment on view api.flight_obstacles is '统一飞行障碍网格视图，汇总建筑、地形、禁飞区和临时管制区。';
comment on column api.flight_obstacles.source_kind is '障碍来源类型：building、terrain、no_fly_zone 或 temp_control。';
comment on column api.flight_obstacles.source_id is '来源对象在对应业务表或数据集中的唯一标识。';
comment on column api.flight_obstacles.source_name is '来源对象名称或展示标签。';
comment on column api.flight_obstacles.dimension is '网格维度，通常为 3 表示三维障碍。';
comment on column api.flight_obstacles.detail_level is 'GGER 网格精度等级，数值越大网格越细。';
comment on column api.flight_obstacles.is_agg is '是否为聚合网格。';
comment on column api.flight_obstacles.grids is '障碍占用的原生 gridcell 集合，用于路径规划。';
comment on column api.flight_obstacles.valid_from is '障碍生效开始时间；长期障碍为空。';
comment on column api.flight_obstacles.valid_to is '障碍生效结束时间；长期障碍为空。';
comment on column api.flight_obstacles.priority is '障碍优先级，数值越大越优先。';
comment on column api.flight_obstacles.generated_at is '障碍网格生成或刷新时间。';

comment on view api.flight_obstacles_codes_view is '统一飞行障碍的可读 GGER 编码视图，供前端展示和调试。';
comment on column api.flight_obstacles_codes_view.source_kind is '障碍来源类型。';
comment on column api.flight_obstacles_codes_view.source_id is '来源对象唯一标识。';
comment on column api.flight_obstacles_codes_view.source_name is '来源对象名称或展示标签。';
comment on column api.flight_obstacles_codes_view.dimension is '网格维度。';
comment on column api.flight_obstacles_codes_view.detail_level is 'GGER 网格精度等级。';
comment on column api.flight_obstacles_codes_view.cell_count is '障碍包含的网格单元数量。';
comment on column api.flight_obstacles_codes_view.gger_grids is 'GGER 文本编码数组，不包含 BGC 编码。';
comment on column api.flight_obstacles_codes_view.valid_from is '障碍生效开始时间；长期障碍为空。';
comment on column api.flight_obstacles_codes_view.valid_to is '障碍生效结束时间；长期障碍为空。';
comment on column api.flight_obstacles_codes_view.priority is '障碍优先级，数值越大越优先。';
comment on column api.flight_obstacles_codes_view.generated_at is '障碍网格生成或刷新时间。';

comment on function api.get_citydb_feature_properties(text) is '按 3DCityDB feature identifier 查询建筑或地物属性，返回 JSON。参数：p_feature_identifier。';
comment on function api.get_citydb_feature_gger_grids(text) is '按 3DCityDB feature identifier 查询对应飞行障碍 GGER 网格，返回 JSON。参数：p_feature_identifier。';
comment on function api.list_flight_obstacles_gger(text, integer, boolean) is '按来源类型分页列出飞行障碍 GGER 编码。参数：p_source_kind 可为空，p_limit 最大 1000，p_include_boxes 控制是否返回包围盒。';
comment on function api.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean) is '按来源、LOD 和空间范围列出飞行障碍 GGER 编码，适合前端按视野加载。参数包含 bbox、中心点、p_limit 和 p_include_boxes。';
comment on function api.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) is '创建飞行路径规划方案并写入控制点，返回 plan_id。p_points 为控制点数组。';
comment on function api.update_flight_path_plan(bigint, text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) is '更新飞行路径规划方案；传 null 的可选参数保持原值不变。p_points 非 null 时替换全部控制点。';
comment on function api.list_flight_path_plans(text, text, integer, integer) is '分页查询飞行路径规划方案。参数：p_keyword 名称或说明关键字，p_status 状态过滤，p_limit/p_offset 分页。';
comment on function api.get_flight_path_plan(bigint) is '查询单个飞行路径规划方案详情，包含控制点和最新结果。参数：p_plan_id。';
comment on function api.archive_flight_path_plan(bigint) is '归档飞行路径规划方案，使其不再出现在默认列表中。参数：p_plan_id。';
comment on function api.delete_flight_path_plan(bigint) is '删除飞行路径规划方案及其控制点和计算结果。参数：p_plan_id。';
comment on function api.compute_flight_path_plan(bigint) is '执行飞行路径规划计算并保存结果，返回 result_id。参数：p_plan_id。';
comment on function api.get_latest_flight_path_result(bigint) is '查询规划方案最新一次计算结果。参数：p_plan_id。';
comment on function api.search_flight_path_results_by_time(timestamp, timestamp, integer, integer) is '按轨迹时间范围分页查询成功的路径计算结果。参数：p_start_time、p_end_time、p_limit、p_offset。';
comment on function api.search_flight_path_results_by_bbox(double precision, double precision, double precision, double precision, timestamp, timestamp, integer, integer) is '按 WGS84 bbox 和可选时间范围分页查询成功的路径计算结果。参数：p_xmin、p_ymin、p_xmax、p_ymax、p_start_time、p_end_time、p_limit、p_offset。';

revoke all on all tables in schema api from public;
revoke all on all functions in schema api from public;
revoke all on all tables in schema api from anonymous;
revoke all on all functions in schema api from anonymous;

grant select, insert, update, delete on api.no_fly_zone to admin;
grant select, insert, update, delete on api.temp_control_zone to admin;
grant select on api.suitable_fly_zone_footprints to admin;
grant select on api.flight_obstacles to admin;
grant select on api.flight_obstacles_codes_view to admin;
grant execute on all functions in schema api to admin;

alter default privileges for role postgres in schema api revoke execute on functions from public;
alter default privileges for role postgres in schema api grant execute on functions to admin;
alter default privileges for role postgres in schema api grant select, insert, update, delete on tables to admin;

-- Drop obsolete role model ----------------------------------------------------
-- DROP OWNED revokes grants made to these roles in the current database. The
-- previous inventory found no objects owned by these roles.
do $$
declare
  v_role text;
  v_roles text[] := array[
    'anon',
    'web_anon',
    'web_admin',
    'pgrst_anonymous',
    'postgrest_authenticator',
    'airspace_reader',
    'airspace_admin',
    'flight_planner'
  ];
begin
  foreach v_role in array v_roles loop
    if exists (select 1 from pg_roles where rolname = v_role) then
      execute 'drop owned by ' || quote_ident(v_role);
    end if;
  end loop;

  -- Revoke memberships involving obsolete roles before dropping them.
  for v_role in
    select format('revoke %I from %I', parent.rolname, member.rolname)
    from pg_auth_members am
    join pg_roles parent on parent.oid = am.roleid
    join pg_roles member on member.oid = am.member
    where parent.rolname = any(v_roles) or member.rolname = any(v_roles)
  loop
    execute v_role;
  end loop;

  foreach v_role in array v_roles loop
    if exists (select 1 from pg_roles where rolname = v_role) then
      execute 'drop role ' || quote_ident(v_role);
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

commit;
