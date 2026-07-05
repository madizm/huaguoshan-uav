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
grant execute on function flight_path.require_planning_actor() to admin;
grant execute on function flight_path.assert_plan_access(bigint) to admin;
grant execute on function flight_path.assert_plan_ownership(bigint, text) to admin;
grant execute on function flight_path.list_plans(text, text, integer, integer) to admin;
grant execute on function flight_path.search_results_by_time(timestamp, timestamp, integer, integer) to admin;
grant execute on function flight_path.search_results_by_bbox(double precision, double precision, double precision, double precision, timestamp, timestamp, integer, integer) to admin;

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

create or replace view api.flight_obstacles as
select * from citydb_grid.flight_obstacles;

create or replace view api.flight_obstacles_codes_view as
select * from citydb_grid.flight_obstacles_codes_view;

create or replace view api.flight_path_plans as
select * from flight_path.plan;

create or replace view api.flight_path_plan_points as
select * from flight_path.plan_point;

create or replace view api.flight_path_plan_results as
select * from flight_path.plan_result;

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
  p_metadata jsonb default '{}'::jsonb,
  p_created_by text default null
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
    p_metadata,
    p_created_by
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

revoke all on all tables in schema api from public;
revoke all on all functions in schema api from public;
revoke all on all tables in schema api from anonymous;
revoke all on all functions in schema api from anonymous;

grant select, insert, update, delete on api.no_fly_zone to admin;
grant select, insert, update, delete on api.temp_control_zone to admin;
grant select on api.flight_obstacles to admin;
grant select on api.flight_obstacles_codes_view to admin;
grant select on api.flight_path_plans to admin;
grant select on api.flight_path_plan_points to admin;
grant select on api.flight_path_plan_results to admin;
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
