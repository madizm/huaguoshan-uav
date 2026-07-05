-- PostgREST RPC: flight path planning, persistence, and iBEST-DB trajectory result management.
--
-- Main RPC endpoints through this project's default PostgREST schema (`citydb`):
--   POST /rpc/create_flight_path_plan
--   POST /rpc/update_flight_path_plan
--   POST /rpc/list_flight_path_plans
--   POST /rpc/get_flight_path_plan
--   POST /rpc/archive_flight_path_plan
--   POST /rpc/delete_flight_path_plan
--   POST /rpc/compute_flight_path_plan
--   POST /rpc/get_latest_flight_path_result
--   POST /rpc/search_flight_path_results_by_time
--   POST /rpc/search_flight_path_results_by_bbox
--
-- The implementation schema is `flight_path`; `citydb.*` functions are thin
-- wrappers so the existing pgrest.conf (`db-schemas = "citydb, public, terrain,
-- airspace"`) can expose these functions without requiring a config change.

begin;

create extension if not exists postgis;
create extension if not exists best_geomgrid cascade;
create extension if not exists best_iot cascade;
create extension if not exists best_geotrack cascade;

create schema if not exists flight_path;

grant usage on schema flight_path to admin;

create table if not exists flight_path.plan (
  id bigserial primary key,
  name text not null,
  description text,
  status text not null default 'draft',
  detail_level integer not null default 19,
  cruise_height_m double precision,
  height_datum text not null default 'AMSL',
  planning_time timestamptz not null default now(),
  has_below boolean not null default false,
  safety_buffer_m double precision not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_computed_at timestamptz
);

create table if not exists flight_path.plan_point (
  id bigserial primary key,
  plan_id bigint not null references flight_path.plan(id) on delete cascade,
  point_role text not null,
  seq integer not null,
  name text,
  lon double precision not null,
  lat double precision not null,
  height_m double precision,
  height_datum text not null default 'AMSL',
  geom geometry(PointZ, 4326),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(plan_id, seq)
);

create table if not exists flight_path.plan_result (
  id bigserial primary key,
  plan_id bigint not null references flight_path.plan(id) on delete cascade,
  result_status text not null,
  detail_level integer not null,
  planning_time timestamptz not null,
  obstacle_table text not null default 'flight_obstacles',
  obstacle_field text not null default 'grids',
  grid_path gridcell[],
  route_geom geometry,
  smooth_route_geom geometry,
  route_traj trajectory,
  smooth_route_traj trajectory,
  segment_count integer not null default 0,
  grid_cell_count integer,
  traj_point_count integer,
  distance_m double precision,
  duration_s double precision,
  error_message text,
  params jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table flight_path.plan_result
  alter column obstacle_table set default 'flight_obstacles',
  alter column obstacle_field set default 'grids',
  alter column route_geom type geometry using route_geom::geometry,
  alter column smooth_route_geom type geometry using smooth_route_geom::geometry;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_status_chk'
      and conrelid = 'flight_path.plan'::regclass
  ) then
    alter table flight_path.plan
      add constraint flight_path_plan_status_chk
      check (status in ('draft', 'planned', 'computed', 'failed', 'archived'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_height_datum_chk'
      and conrelid = 'flight_path.plan'::regclass
  ) then
    alter table flight_path.plan
      add constraint flight_path_plan_height_datum_chk
      check (height_datum in ('AMSL', 'AGL', 'ELLIPSOID'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_point_role_chk'
      and conrelid = 'flight_path.plan_point'::regclass
  ) then
    alter table flight_path.plan_point
      add constraint flight_path_plan_point_role_chk
      check (point_role in ('start', 'waypoint', 'end'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_point_height_datum_chk'
      and conrelid = 'flight_path.plan_point'::regclass
  ) then
    alter table flight_path.plan_point
      add constraint flight_path_plan_point_height_datum_chk
      check (height_datum in ('AMSL', 'AGL', 'ELLIPSOID'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_point_lon_chk'
      and conrelid = 'flight_path.plan_point'::regclass
  ) then
    alter table flight_path.plan_point
      add constraint flight_path_plan_point_lon_chk
      check (lon >= -180 and lon <= 180);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_point_lat_chk'
      and conrelid = 'flight_path.plan_point'::regclass
  ) then
    alter table flight_path.plan_point
      add constraint flight_path_plan_point_lat_chk
      check (lat >= -90 and lat <= 90);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'flight_path_plan_result_status_chk'
      and conrelid = 'flight_path.plan_result'::regclass
  ) then
    alter table flight_path.plan_result
      add constraint flight_path_plan_result_status_chk
      check (result_status in ('success', 'failed'));
  end if;
end;
$$;

create index if not exists flight_path_plan_status_idx
  on flight_path.plan(status);

create index if not exists flight_path_plan_updated_at_idx
  on flight_path.plan(updated_at desc);

create index if not exists flight_path_plan_point_plan_seq_idx
  on flight_path.plan_point(plan_id, seq);

create unique index if not exists flight_path_plan_point_one_start_idx
  on flight_path.plan_point(plan_id)
  where point_role = 'start';

create unique index if not exists flight_path_plan_point_one_end_idx
  on flight_path.plan_point(plan_id)
  where point_role = 'end';

create index if not exists flight_path_plan_point_geom_gix
  on flight_path.plan_point using gist(geom);

create index if not exists flight_path_plan_result_plan_idx
  on flight_path.plan_result(plan_id, created_at desc);

create index if not exists flight_path_plan_result_route_gix
  on flight_path.plan_result using gist(route_geom);

create index if not exists flight_path_plan_result_route_traj_2dt_gix
  on flight_path.plan_result using gist(route_traj trajgist_ops_2dt);

create or replace function flight_path.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function flight_path.plan_point_set_geom()
returns trigger
language plpgsql
as $$
begin
  new.point_role := lower(new.point_role);
  new.height_datum := upper(coalesce(new.height_datum, 'AMSL'));
  new.geom := ST_SetSRID(ST_MakePoint(new.lon, new.lat, coalesce(new.height_m, 0)), 4326);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists flight_path_plan_touch_updated_at on flight_path.plan;
create trigger flight_path_plan_touch_updated_at
before update on flight_path.plan
for each row execute function flight_path.touch_updated_at();

drop trigger if exists flight_path_plan_point_set_geom on flight_path.plan_point;
create trigger flight_path_plan_point_set_geom
before insert or update on flight_path.plan_point
for each row execute function flight_path.plan_point_set_geom();

create or replace function flight_path.speed_from_metadata(p_metadata jsonb, p_default double precision default 10)
returns double precision
language plpgsql
immutable
as $$
declare
  v_text text;
  v_speed double precision;
begin
  v_text := p_metadata ->> 'cruise_speed_mps';
  if v_text is not null and v_text ~ '^[0-9]+(\.[0-9]+)?$' then
    v_speed := v_text::double precision;
  end if;
  return greatest(coalesce(nullif(v_speed, 0), p_default, 10), 0.1);
end;
$$;

create or replace function flight_path.route_timeline(
  p_geom geometry,
  p_start_time timestamptz,
  p_duration_s double precision
)
returns timestamp[]
language sql
stable
as $$
with n as (
  select greatest(coalesce(ST_NPoints(p_geom), 0), 0) as point_count
), series as (
  select i, point_count
  from n, generate_series(1, greatest(point_count, 1)) as g(i)
)
select array_agg(
  (
    p_start_time
    + (
      case
        when point_count <= 1 then 0
        else coalesce(p_duration_s, 0) * ((i - 1)::double precision / (point_count - 1)::double precision)
      end * interval '1 second'
    )
  )::timestamp
  order by i
)
from series;
$$;

create or replace function flight_path.trajectory_attrs_json(
  p_geom geometry,
  p_speed_mps double precision
)
returns text
language sql
stable
as $$
with n as (
  select greatest(coalesce(ST_NPoints(p_geom), 0), 0) as point_count
), vals as (
  select
    coalesce(jsonb_agg(i - 1 order by i), '[]'::jsonb) as seq_values,
    coalesce(jsonb_agg(coalesce(ST_Z((dp).geom), 0.0) order by i), '[]'::jsonb) as height_values,
    coalesce(jsonb_agg(coalesce(p_speed_mps, 0.0) order by i), '[]'::jsonb) as speed_values,
    coalesce(jsonb_agg('path'::text order by i), '[]'::jsonb) as point_kind_values
  from n
  left join lateral (
    select dumped.geom, dumped.i
    from ST_DumpPoints(p_geom) with ordinality as dumped(path, geom, i)
  ) dp on true
)
select jsonb_build_object(
  'leafcount', n.point_count,
  'attributes', jsonb_build_object(
    'seq', jsonb_build_object(
      'type', 'integer', 'length', 4, 'nullable', false, 'value', vals.seq_values
    ),
    'height_m', jsonb_build_object(
      'type', 'float', 'length', 8, 'nullable', true, 'value', vals.height_values
    ),
    'speed_mps', jsonb_build_object(
      'type', 'float', 'length', 8, 'nullable', true, 'value', vals.speed_values
    ),
    'point_kind', jsonb_build_object(
      'type', 'string', 'length', 16, 'nullable', true, 'value', vals.point_kind_values
    )
  )
)::text
from n, vals;
$$;

create or replace function flight_path.make_route_trajectory(
  p_geom geometry,
  p_start_time timestamptz,
  p_duration_s double precision,
  p_speed_mps double precision
)
returns trajectory
language plpgsql
stable
as $$
declare
  v_timeline timestamp[];
  v_attrs text;
  v_traj trajectory;
begin
  if p_geom is null or ST_IsEmpty(p_geom) or coalesce(ST_NPoints(p_geom), 0) < 2 then
    return null;
  end if;

  v_timeline := flight_path.route_timeline(p_geom, p_start_time, p_duration_s);
  v_attrs := flight_path.trajectory_attrs_json(p_geom, p_speed_mps);

  execute 'select GT_MakeTrajectory($1, $2, $3::cstring)'
    into v_traj
    using p_geom, v_timeline, v_attrs;

  return v_traj;
exception when others then
  -- Keep path planning usable even if trajectory construction fails because of
  -- extension-specific strictness. The caller still stores route geometry.
  return null;
end;
$$;

create or replace function flight_path.sample_terrain_height_amsl(
  p_lon double precision,
  p_lat double precision
)
returns double precision
language sql
stable
as $$
select ST_Value(t.rast, ST_Transform(ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), ST_SRID(t.extent)))::double precision
from terrain.dem_tile t
where ST_Intersects(t.extent, ST_Transform(ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), ST_SRID(t.extent)))
order by t.id
limit 1;
$$;

create or replace function flight_path.effective_height_amsl(
  p_lon double precision,
  p_lat double precision,
  p_height_m double precision,
  p_height_datum text,
  p_plan_cruise_height_m double precision,
  p_plan_height_datum text
)
returns double precision
language plpgsql
stable
as $$
declare
  v_height double precision := coalesce(p_height_m, p_plan_cruise_height_m, 0);
  v_datum text := upper(coalesce(p_height_datum, p_plan_height_datum, 'AMSL'));
  v_terrain double precision;
begin
  if v_datum = 'AGL' then
    v_terrain := flight_path.sample_terrain_height_amsl(p_lon, p_lat);
    return coalesce(v_terrain, 0) + v_height;
  end if;

  -- ELLIPSOID is currently treated as the same numeric height as AMSL. A
  -- geoid conversion can be added later once the project has a datum grid.
  return v_height;
end;
$$;

create or replace function flight_path.clear_terrain_obstacle_height_amsl(
  p_lon double precision,
  p_lat double precision,
  p_initial_height_amsl double precision,
  p_detail_level integer,
  p_step_m double precision default 10,
  p_max_extra_m double precision default 1000
)
returns double precision
language plpgsql
stable
as $$
declare
  v_height double precision := coalesce(p_initial_height_amsl, 0);
  v_start double precision := coalesce(p_initial_height_amsl, 0);
  v_step double precision := greatest(coalesce(p_step_m, 10), 1);
  v_has_terrain boolean;
begin
  loop
    select exists (
      select 1
      from citydb_grid.flight_obstacles fo
      where fo.source_kind = 'terrain'
        and fo.grids && ST_AsGridcell3D(p_lon, p_lat, v_height, p_detail_level)
    ) into v_has_terrain;

    if not v_has_terrain then
      return v_height;
    end if;

    v_height := v_height + v_step;
    if v_height > v_start + greatest(coalesce(p_max_extra_m, 1000), v_step) then
      return v_height;
    end if;
  end loop;
end;
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

create or replace function flight_path.replace_plan_points(
  p_plan_id bigint,
  p_points jsonb
)
returns void
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
declare
  v_plan flight_path.plan%rowtype;
  v_point jsonb;
  v_ord bigint;
  v_role text;
  v_height_datum text;
  v_lon double precision;
  v_lat double precision;
  v_first_role text;
  v_last_role text;
  v_count integer;
  v_waypoint_bad integer;
begin
  select * into v_plan
  from flight_path.plan
  where id = p_plan_id;

  if not found then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;

  if p_points is null or jsonb_typeof(p_points) <> 'array' or jsonb_array_length(p_points) < 2 then
    raise exception 'p_points must be a JSON array with at least start and end points';
  end if;

  delete from flight_path.plan_point where plan_id = p_plan_id;

  for v_point, v_ord in
    select value, ordinality
    from jsonb_array_elements(p_points) with ordinality
  loop
    v_role := lower(coalesce(v_point ->> 'role', v_point ->> 'point_role'));
    v_height_datum := upper(coalesce(v_point ->> 'height_datum', v_plan.height_datum, 'AMSL'));

    if v_role not in ('start', 'waypoint', 'end') then
      raise exception 'invalid point role at index %: %', v_ord - 1, v_role;
    end if;

    if v_height_datum not in ('AMSL', 'AGL', 'ELLIPSOID') then
      raise exception 'invalid height_datum at index %: %', v_ord - 1, v_height_datum;
    end if;

    v_lon := (v_point ->> 'lon')::double precision;
    v_lat := (v_point ->> 'lat')::double precision;

    insert into flight_path.plan_point(
      plan_id,
      point_role,
      seq,
      name,
      lon,
      lat,
      height_m,
      height_datum,
      metadata
    ) values (
      p_plan_id,
      v_role,
      (v_ord - 1)::integer,
      nullif(v_point ->> 'name', ''),
      v_lon,
      v_lat,
      nullif(v_point ->> 'height_m', '')::double precision,
      v_height_datum,
      coalesce(v_point -> 'metadata', '{}'::jsonb)
    );
  end loop;

  select count(*) into v_count
  from flight_path.plan_point
  where plan_id = p_plan_id;

  select point_role into v_first_role
  from flight_path.plan_point
  where plan_id = p_plan_id
  order by seq asc
  limit 1;

  select point_role into v_last_role
  from flight_path.plan_point
  where plan_id = p_plan_id
  order by seq desc
  limit 1;

  select count(*) into v_waypoint_bad
  from flight_path.plan_point
  where plan_id = p_plan_id
    and seq > 0
    and seq < v_count - 1
    and point_role <> 'waypoint';

  if v_first_role <> 'start' then
    raise exception 'first point must be role=start';
  end if;

  if v_last_role <> 'end' then
    raise exception 'last point must be role=end';
  end if;

  if v_waypoint_bad > 0 then
    raise exception 'middle points must be role=waypoint';
  end if;
end;
$$;

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

create or replace function flight_path.update_plan(
  p_plan_id bigint,
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
returns void
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
declare
  v_height_datum text := upper(coalesce(p_height_datum, 'AMSL'));
begin
  if nullif(trim(p_name), '') is null then
    raise exception 'p_name is required';
  end if;

  if v_height_datum not in ('AMSL', 'AGL', 'ELLIPSOID') then
    raise exception 'invalid p_height_datum: %', p_height_datum;
  end if;

  update flight_path.plan
  set name = trim(p_name),
      description = p_description,
      status = 'planned',
      detail_level = coalesce(p_detail_level, detail_level),
      cruise_height_m = p_cruise_height_m,
      height_datum = v_height_datum,
      planning_time = coalesce(p_planning_time, planning_time),
      has_below = coalesce(p_has_below, has_below),
      safety_buffer_m = coalesce(p_safety_buffer_m, safety_buffer_m),
      metadata = coalesce(p_metadata, '{}'::jsonb)
  where id = p_plan_id;

  if not found then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;

  perform flight_path.replace_plan_points(p_plan_id, p_points);
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
with filtered as (
  select p.*
  from flight_path.plan p
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

create or replace function flight_path.get_plan(p_plan_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
select jsonb_build_object(
  'plan', to_jsonb(p),
  'points', coalesce((
    select jsonb_agg(to_jsonb(pp) - 'geom' order by pp.seq)
    from flight_path.plan_point pp
    where pp.plan_id = p.id
  ), '[]'::jsonb),
  'latest_result', (
    select jsonb_strip_nulls(jsonb_build_object(
      'id', pr.id,
      'result_status', pr.result_status,
      'distance_m', pr.distance_m,
      'duration_s', pr.duration_s,
      'grid_cell_count', pr.grid_cell_count,
      'traj_point_count', pr.traj_point_count,
      'error_message', pr.error_message,
      'created_at', pr.created_at
    ))
    from flight_path.plan_result pr
    where pr.plan_id = p.id
    order by pr.created_at desc, pr.id desc
    limit 1
  )
)
from flight_path.plan p
where p.id = p_plan_id;
$$;

create or replace function flight_path.archive_plan(p_plan_id bigint)
returns void
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
begin
  update flight_path.plan
  set status = 'archived'
  where id = p_plan_id;

  if not found then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;
end;
$$;

create or replace function flight_path.delete_plan(p_plan_id bigint)
returns void
language plpgsql
security definer
set search_path = flight_path, public, pg_temp
as $$
begin
  delete from flight_path.plan
  where id = p_plan_id;

  if not found then
    raise exception 'flight path plan % does not exist', p_plan_id;
  end if;
end;
$$;

create or replace function flight_path.compute_plan(p_plan_id bigint)
returns bigint
language plpgsql
security definer
-- Put citydb_grid before public so ST_FindGridsPath('flight_obstacles', ...)
-- resolves to the indexed materialized view instead of the public compatibility
-- view. The public view works functionally but makes this 5-8 km E2E case take
-- ~95s because the geomgrids GIN index cannot be used directly.
set search_path = flight_path, citydb_grid, public, pg_temp
as $$
declare
  v_plan flight_path.plan%rowtype;
  v_prev flight_path.plan_point%rowtype;
  v_curr flight_path.plan_point%rowtype;
  v_first flight_path.plan_point%rowtype;
  v_last flight_path.plan_point%rowtype;
  v_point_count integer;
  v_segment_path gridcell[];
  v_segment_len integer;
  v_grid_path gridcell[] := array[]::gridcell[];
  v_segment_count integer := 0;
  v_route_geom geometry;
  v_smooth_route_geom geometry;
  v_route_traj trajectory;
  v_smooth_route_traj trajectory;
  v_speed_mps double precision;
  v_duration_s double precision;
  v_distance_m double precision;
  v_traj_point_count integer;
  v_result_id bigint;
  v_error text;
  v_prev_blockers text;
  v_curr_blockers text;
  v_prev_height_amsl double precision;
  v_curr_height_amsl double precision;
  v_first_height_amsl double precision;
  v_last_height_amsl double precision;
begin
  select * into v_plan
  from flight_path.plan
  where id = p_plan_id
    and status <> 'archived';

  if not found then
    raise exception 'flight path plan % does not exist or is archived', p_plan_id;
  end if;

  select count(*) into v_point_count
  from flight_path.plan_point
  where plan_id = p_plan_id;

  if v_point_count < 2 then
    raise exception 'plan % must contain at least start and end points', p_plan_id;
  end if;

  select * into v_first
  from flight_path.plan_point
  where plan_id = p_plan_id
  order by seq asc
  limit 1;

  select * into v_last
  from flight_path.plan_point
  where plan_id = p_plan_id
  order by seq desc
  limit 1;

  if v_first.point_role <> 'start' or v_last.point_role <> 'end' then
    raise exception 'plan % points must start with role=start and end with role=end', p_plan_id;
  end if;

  v_prev := null;
  for v_curr in
    select *
    from flight_path.plan_point
    where plan_id = p_plan_id
    order by seq
  loop
    if v_prev.id is null then
      v_prev := v_curr;
      continue;
    end if;

    v_prev_height_amsl := flight_path.effective_height_amsl(
      v_prev.lon, v_prev.lat, v_prev.height_m, v_prev.height_datum,
      v_plan.cruise_height_m, v_plan.height_datum
    );
    v_curr_height_amsl := flight_path.effective_height_amsl(
      v_curr.lon, v_curr.lat, v_curr.height_m, v_curr.height_datum,
      v_plan.cruise_height_m, v_plan.height_datum
    );

    -- AGL means clear terrain. Because terrain obstacles are stored as conservative
    -- geomgrid prisms, the sampled DEM height at the exact click point can still
    -- fall inside the terrain block. Lift AGL-derived effective height until the
    -- point's gridcell clears terrain obstacles, while still allowing buildings /
    -- airspace to block the point normally.
    if upper(coalesce(v_prev.height_datum, v_plan.height_datum, 'AMSL')) = 'AGL' then
      v_prev_height_amsl := flight_path.clear_terrain_obstacle_height_amsl(
        v_prev.lon, v_prev.lat, v_prev_height_amsl, v_plan.detail_level
      );
    end if;
    if upper(coalesce(v_curr.height_datum, v_plan.height_datum, 'AMSL')) = 'AGL' then
      v_curr_height_amsl := flight_path.clear_terrain_obstacle_height_amsl(
        v_curr.lon, v_curr.lat, v_curr_height_amsl, v_plan.detail_level
      );
    end if;

    select string_agg(source_kind || ':' || source_id, '; ' order by priority desc, source_kind, source_id)
      into v_prev_blockers
    from citydb_grid.flight_obstacles
    where grids && ST_AsGridcell3D(v_prev.lon, v_prev.lat, v_prev_height_amsl, v_plan.detail_level);

    select string_agg(source_kind || ':' || source_id, '; ' order by priority desc, source_kind, source_id)
      into v_curr_blockers
    from citydb_grid.flight_obstacles
    where grids && ST_AsGridcell3D(v_curr.lon, v_curr.lat, v_curr_height_amsl, v_plan.detail_level);

    if v_prev_blockers is not null then
      raise exception 'segment % start point seq % (%, %, %m) intersects flight obstacle(s): %',
        v_segment_count, v_prev.seq, round(v_prev.lon::numeric, 6), round(v_prev.lat::numeric, 6), round(v_prev_height_amsl::numeric, 1), v_prev_blockers;
    end if;

    if v_curr_blockers is not null then
      raise exception 'segment % end point seq % (%, %, %m) intersects flight obstacle(s): %',
        v_segment_count, v_curr.seq, round(v_curr.lon::numeric, 6), round(v_curr.lat::numeric, 6), round(v_curr_height_amsl::numeric, 1), v_curr_blockers;
    end if;

    v_segment_path := ST_FindGridsPath(
      ST_AsGridcell3D(v_prev.lon, v_prev.lat, v_prev_height_amsl, v_plan.detail_level),
      ST_AsGridcell3D(v_curr.lon, v_curr.lat, v_curr_height_amsl, v_plan.detail_level),
      'flight_obstacles',
      'grids',
      v_plan.has_below
    );

    v_segment_len := coalesce(array_length(v_segment_path, 1), 0);
    if v_segment_len = 0 then
      raise exception 'segment % (% -> %) is unreachable', v_segment_count, v_prev.seq, v_curr.seq;
    end if;

    if coalesce(array_length(v_grid_path, 1), 0) = 0 then
      v_grid_path := v_segment_path;
    elsif v_segment_len > 1 then
      v_grid_path := v_grid_path || v_segment_path[2:v_segment_len];
    end if;

    v_segment_count := v_segment_count + 1;
    v_prev := v_curr;
  end loop;

  v_first_height_amsl := flight_path.effective_height_amsl(
    v_first.lon, v_first.lat, v_first.height_m, v_first.height_datum,
    v_plan.cruise_height_m, v_plan.height_datum
  );
  v_last_height_amsl := flight_path.effective_height_amsl(
    v_last.lon, v_last.lat, v_last.height_m, v_last.height_datum,
    v_plan.cruise_height_m, v_plan.height_datum
  );
  if upper(coalesce(v_first.height_datum, v_plan.height_datum, 'AMSL')) = 'AGL' then
    v_first_height_amsl := flight_path.clear_terrain_obstacle_height_amsl(
      v_first.lon, v_first.lat, v_first_height_amsl, v_plan.detail_level
    );
  end if;
  if upper(coalesce(v_last.height_datum, v_plan.height_datum, 'AMSL')) = 'AGL' then
    v_last_height_amsl := flight_path.clear_terrain_obstacle_height_amsl(
      v_last.lon, v_last.lat, v_last_height_amsl, v_plan.detail_level
    );
  end if;

  v_route_geom := ST_SetSRID(ST_RouteFromGridsPath(
    ST_SetSRID(ST_MakePoint(v_first.lon, v_first.lat, v_first_height_amsl), 4326),
    ST_SetSRID(ST_MakePoint(v_last.lon, v_last.lat, v_last_height_amsl), 4326),
    v_grid_path
  ), 4326);

  begin
    v_smooth_route_geom := ST_SetSRID(ST_SmoothRouteFromGridsPath(v_grid_path, 'flight_obstacles', 'grids'), 4326);
  exception when others then
    v_smooth_route_geom := null;
  end;

  if v_route_geom is null or ST_IsEmpty(v_route_geom) then
    raise exception 'ST_RouteFromGridsPath returned empty geometry';
  end if;

  -- Very short paths can collapse to a single grid cell and ST_RouteFromGridsPath
  -- may return Point. Persist a minimal start-end LineString so result storage,
  -- GeoJSON display, and trajectory construction remain consistent.
  if ST_GeometryType(v_route_geom) <> 'ST_LineString' or coalesce(ST_NPoints(v_route_geom), 0) < 2 then
    v_route_geom := ST_SetSRID(ST_MakeLine(
      ST_SetSRID(ST_MakePoint(v_first.lon, v_first.lat, v_first_height_amsl), 4326),
      ST_SetSRID(ST_MakePoint(v_last.lon, v_last.lat, v_last_height_amsl), 4326)
    ), 4326);
  end if;

  if v_smooth_route_geom is not null and (
    ST_IsEmpty(v_smooth_route_geom)
    or ST_GeometryType(v_smooth_route_geom) <> 'ST_LineString'
    or coalesce(ST_NPoints(v_smooth_route_geom), 0) < 2
  ) then
    v_smooth_route_geom := null;
  end if;

  v_speed_mps := flight_path.speed_from_metadata(v_plan.metadata, 10);
  v_distance_m := ST_Length(ST_Force2D(v_route_geom)::geography);
  v_duration_s := case when v_speed_mps > 0 then v_distance_m / v_speed_mps else null end;

  v_route_traj := flight_path.make_route_trajectory(v_route_geom, v_plan.planning_time, v_duration_s, v_speed_mps);
  if v_smooth_route_geom is not null and not ST_IsEmpty(v_smooth_route_geom) then
    v_smooth_route_traj := flight_path.make_route_trajectory(v_smooth_route_geom, v_plan.planning_time, v_duration_s, v_speed_mps);
  end if;

  if v_route_traj is not null then
    v_distance_m := GT_length(v_route_traj);
    v_traj_point_count := GT_leafCount(v_route_traj);
    v_duration_s := extract(epoch from GT_duration(v_route_traj));
  else
    v_traj_point_count := ST_NPoints(v_route_geom);
  end if;

  insert into flight_path.plan_result(
    plan_id,
    result_status,
    detail_level,
    planning_time,
    grid_path,
    route_geom,
    smooth_route_geom,
    route_traj,
    smooth_route_traj,
    segment_count,
    grid_cell_count,
    traj_point_count,
    distance_m,
    duration_s,
    params
  ) values (
    p_plan_id,
    'success',
    v_plan.detail_level,
    v_plan.planning_time,
    v_grid_path,
    v_route_geom,
    v_smooth_route_geom,
    v_route_traj,
    v_smooth_route_traj,
    v_segment_count,
    coalesce(array_length(v_grid_path, 1), 0),
    v_traj_point_count,
    v_distance_m,
    v_duration_s,
    jsonb_build_object(
      'has_below', v_plan.has_below,
      'height_datum', v_plan.height_datum,
      'agl_terrain_clearance', true,
      'cruise_speed_mps', v_speed_mps,
      'obstacle_table', 'flight_obstacles',
      'obstacle_field', 'grids'
    )
  ) returning id into v_result_id;

  update flight_path.plan
  set status = 'computed',
      last_computed_at = now()
  where id = p_plan_id;

  return v_result_id;
exception when others then
  v_error := sqlerrm;

  if v_plan.id is not null then
    insert into flight_path.plan_result(
      plan_id,
      result_status,
      detail_level,
      planning_time,
      segment_count,
      error_message,
      params
    ) values (
      p_plan_id,
      'failed',
      v_plan.detail_level,
      v_plan.planning_time,
      v_segment_count,
      v_error,
      jsonb_build_object('sqlstate', sqlstate)
    ) returning id into v_result_id;

    update flight_path.plan
    set status = 'failed',
        last_computed_at = now()
    where id = p_plan_id;

    return v_result_id;
  end if;

  raise;
end;
$$;

create or replace function flight_path.get_latest_result(p_plan_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
select jsonb_strip_nulls(jsonb_build_object(
  'plan_id', pr.plan_id,
  'result_id', pr.id,
  'result_status', pr.result_status,
  'route_geojson', case when pr.route_geom is not null then ST_AsGeoJSON(pr.route_geom)::jsonb else null end,
  'smooth_route_geojson', case when pr.smooth_route_geom is not null then ST_AsGeoJSON(pr.smooth_route_geom)::jsonb else null end,
  'route_grid_gger', case when pr.grid_path is not null then ST_AsText(ST_AsGrids(pr.grid_path), 'GGER') else null end,
  'route_grid_with_box', case when pr.grid_path is not null then ST_WithBox(ST_AsGrids(pr.grid_path), 'GGER')::jsonb else null end,
  'distance_m', pr.distance_m,
  'duration_s', pr.duration_s,
  'grid_cell_count', pr.grid_cell_count,
  'traj_point_count', pr.traj_point_count,
  'segment_count', pr.segment_count,
  'error_message', pr.error_message,
  'params', pr.params,
  'created_at', pr.created_at
))
from flight_path.plan_result pr
where pr.plan_id = p_plan_id
order by pr.created_at desc, pr.id desc
limit 1;
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
with filtered as (
  select pr.*
  from flight_path.plan_result pr
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
with box as (
  select ST_MakeEnvelope(p_xmin, p_ymin, p_xmax, p_ymax, 4326) as geom
), filtered as (
  select pr.*
  from flight_path.plan_result pr, box
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

-- Expose through citydb RPC schema.
create or replace function citydb.create_flight_path_plan(
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
language sql
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.create_plan(
    p_name, p_description, p_detail_level, p_cruise_height_m, p_height_datum,
    p_planning_time, p_points, p_has_below, p_safety_buffer_m, p_metadata
  );
$$;

create or replace function citydb.update_flight_path_plan(
  p_plan_id bigint,
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
returns void
language sql
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.update_plan(
    p_plan_id, p_name, p_description, p_detail_level, p_cruise_height_m,
    p_height_datum, p_planning_time, p_points, p_has_below, p_safety_buffer_m, p_metadata
  );
$$;

create or replace function citydb.list_flight_path_plans(
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
  select flight_path.list_plans(p_keyword, p_status, p_limit, p_offset);
$$;

create or replace function citydb.get_flight_path_plan(p_plan_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.get_plan(p_plan_id);
$$;

create or replace function citydb.archive_flight_path_plan(p_plan_id bigint)
returns void
language sql
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.archive_plan(p_plan_id);
$$;

create or replace function citydb.delete_flight_path_plan(p_plan_id bigint)
returns void
language sql
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.delete_plan(p_plan_id);
$$;

create or replace function citydb.compute_flight_path_plan(p_plan_id bigint)
returns bigint
language sql
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.compute_plan(p_plan_id);
$$;

create or replace function citydb.get_latest_flight_path_result(p_plan_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = flight_path, public, pg_temp
as $$
  select flight_path.get_latest_result(p_plan_id);
$$;

create or replace function citydb.search_flight_path_results_by_time(
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
  select flight_path.search_results_by_time(p_start_time, p_end_time, p_limit, p_offset);
$$;

create or replace function citydb.search_flight_path_results_by_bbox(
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
  select flight_path.search_results_by_bbox(
    p_xmin, p_ymin, p_xmax, p_ymax, p_start_time, p_end_time, p_limit, p_offset
  );
$$;

grant select, insert, update, delete on table flight_path.plan to admin;
grant select, insert, update, delete on table flight_path.plan_point to admin;
grant select, insert, update, delete on table flight_path.plan_result to admin;
grant usage, select on all sequences in schema flight_path to admin;

grant execute on all functions in schema flight_path to admin;
grant execute on function citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) to admin;
grant execute on function citydb.update_flight_path_plan(bigint, text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) to admin;
grant execute on function citydb.list_flight_path_plans(text, text, integer, integer) to admin;
grant execute on function citydb.get_flight_path_plan(bigint) to admin;
grant execute on function citydb.archive_flight_path_plan(bigint) to admin;
grant execute on function citydb.delete_flight_path_plan(bigint) to admin;
grant execute on function citydb.compute_flight_path_plan(bigint) to admin;
grant execute on function citydb.get_latest_flight_path_result(bigint) to admin;
grant execute on function citydb.search_flight_path_results_by_time(timestamp, timestamp, integer, integer) to admin;
grant execute on function citydb.search_flight_path_results_by_bbox(double precision, double precision, double precision, double precision, timestamp, timestamp, integer, integer) to admin;

comment on schema flight_path is 'Flight path planning, control points, planned route geometry, and iBEST-DB trajectory results.';
comment on function citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb)
is 'Create a persisted flight path plan with start/end/waypoint JSON control points.';
comment on function citydb.compute_flight_path_plan(bigint)
is 'Compute a flight path through all control points using ST_FindGridsPath, then store geometry and trajectory results.';

notify pgrst, 'reload schema';

commit;
