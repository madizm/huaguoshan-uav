-- Flight operation domain and PostgREST API facade for 今日飞行运营看板.
--
-- A flight plan is the business execution plan. It is intentionally separate
-- from low-level flight_path route-planning schemes; route preview GeoJSON here
-- is display/provenance data, not proof that the platform computed a route.

begin;

create schema if not exists flight_operation;
create schema if not exists api;

comment on schema flight_operation is 'Business execution model for today flight operation dashboard.';

create table if not exists flight_operation.flight_plan (
  id bigserial primary key,
  plan_type text not null,
  plan_source text not null,
  status text not null default 'pending',
  name text,
  unit text,
  patrol_task_type text,
  pilot text,
  reporting_unit text,
  approval_status text,
  planned_start_at timestamptz not null,
  planned_end_at timestamptz not null,
  planned_sortie_count integer,
  route_preview_geometry jsonb,
  route_preview_source text,
  external_source text,
  external_id text,
  external_raw_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flight_operation_plan_type_chk
    check (plan_type in ('approval_reported', 'patrol_task')),
  constraint flight_operation_plan_source_chk
    check (plan_source in ('third_party', 'platform')),
  constraint flight_operation_plan_status_chk
    check (status in ('pending', 'in_progress', 'completed', 'cancelled', 'abnormal', 'expired')),
  constraint flight_operation_plan_approval_status_chk
    check (approval_status is null or approval_status in ('reported', 'approved', 'rejected', 'revoked', 'unknown')),
  constraint flight_operation_plan_route_source_chk
    check (route_preview_source is null or route_preview_source in ('third_party', 'platform', 'manual')),
  constraint flight_operation_plan_interval_chk
    check (planned_start_at < planned_end_at),
  constraint flight_operation_plan_external_identity_uniq
    unique (external_source, external_id),
  constraint flight_operation_plan_type_fields_chk
    check (
      (
        plan_type = 'approval_reported'
        and plan_source = 'third_party'
        and pilot is not null
        and reporting_unit is not null
        and approval_status is not null
        and patrol_task_type is null
      )
      or
      (
        plan_type = 'patrol_task'
        and plan_source = 'platform'
        and name is not null
        and unit is not null
        and patrol_task_type is not null
        and approval_status is null
      )
    )
);

comment on column flight_operation.flight_plan.planned_sortie_count is
  'Deprecated compatibility field; one flight plan always represents one planned sortie and dashboard statistics never read this value.';

create table if not exists flight_operation.uav_asset (
  id bigserial primary key,
  asset_code text not null unique,
  name text not null,
  availability_status text not null default 'available',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flight_operation_uav_asset_availability_chk
    check (availability_status in ('available', 'unavailable', 'maintenance'))
);

create table if not exists flight_operation.flight_sortie (
  id bigserial primary key,
  flight_plan_id bigint not null references flight_operation.flight_plan(id) on delete restrict,
  uav_asset_id bigint references flight_operation.uav_asset(id) on delete set null,
  status text not null default 'scheduled',
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz,
  actual_start_at timestamptz,
  actual_end_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flight_operation_sortie_status_chk
    check (status in ('scheduled', 'in_progress', 'completed', 'aborted')),
  constraint flight_operation_sortie_schedule_interval_chk
    check (scheduled_start_at is null or scheduled_end_at is null or scheduled_start_at < scheduled_end_at),
  constraint flight_operation_sortie_timestamps_chk
    check (
      (status = 'scheduled' and actual_start_at is null and actual_end_at is null)
      or (status = 'in_progress' and actual_start_at is not null and actual_end_at is null)
      or (status = 'completed' and actual_start_at is not null and actual_end_at is not null and actual_start_at <= actual_end_at)
      or (status = 'aborted' and actual_start_at is not null and (actual_end_at is null or actual_start_at <= actual_end_at))
    ),
  constraint flight_operation_sortie_plan_one_to_one_uniq
    unique (flight_plan_id)
);
do $$
declare
  v_plan_fk_name text;
begin
  if exists (
    select 1 from flight_operation.flight_sortie where flight_plan_id is null
  ) then
    raise exception 'cannot enforce one-plan-one-sortie: flight_sortie.flight_plan_id contains nulls';
  end if;

  if exists (
    select 1
    from flight_operation.flight_sortie
    group by flight_plan_id
    having count(*) > 1
  ) then
    raise exception 'cannot enforce one-plan-one-sortie: duplicate flight_sortie rows exist for a flight plan';
  end if;

  select c.conname into v_plan_fk_name
  from pg_constraint c
  join pg_attribute a
    on a.attrelid = c.conrelid
   and a.attnum = any(c.conkey)
  where c.conrelid = 'flight_operation.flight_sortie'::regclass
    and c.contype = 'f'
    and a.attname = 'flight_plan_id'
  limit 1;

  if v_plan_fk_name is not null then
    execute format('alter table flight_operation.flight_sortie drop constraint %I', v_plan_fk_name);
  end if;

  alter table flight_operation.flight_sortie
    alter column flight_plan_id set not null;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'flight_operation.flight_sortie'::regclass
      and conname = 'flight_operation_sortie_plan_fk'
  ) then
    alter table flight_operation.flight_sortie
      add constraint flight_operation_sortie_plan_fk
      foreign key (flight_plan_id) references flight_operation.flight_plan(id) on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'flight_operation.flight_sortie'::regclass
      and conname = 'flight_operation_sortie_plan_one_to_one_uniq'
  ) then
    alter table flight_operation.flight_sortie
      add constraint flight_operation_sortie_plan_one_to_one_uniq unique (flight_plan_id);
  end if;
end;
$$;


create index if not exists flight_operation_plan_today_window_idx
  on flight_operation.flight_plan (planned_start_at, planned_end_at);
create index if not exists flight_operation_plan_type_status_idx
  on flight_operation.flight_plan (plan_type, status);
create index if not exists flight_operation_plan_approval_status_idx
  on flight_operation.flight_plan (approval_status)
  where plan_type = 'approval_reported';
create index if not exists flight_operation_sortie_uav_status_idx
  on flight_operation.flight_sortie (uav_asset_id, status);
create index if not exists flight_operation_sortie_actual_start_idx
  on flight_operation.flight_sortie (actual_start_at)
  where actual_start_at is not null;
create index if not exists flight_operation_sortie_actual_end_idx
  on flight_operation.flight_sortie (actual_end_at)
  where actual_end_at is not null;

create or replace function flight_operation.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists flight_operation_plan_touch_updated_at on flight_operation.flight_plan;
create trigger flight_operation_plan_touch_updated_at
before update on flight_operation.flight_plan
for each row execute function flight_operation.touch_updated_at();

drop trigger if exists flight_operation_uav_asset_touch_updated_at on flight_operation.uav_asset;
create trigger flight_operation_uav_asset_touch_updated_at
before update on flight_operation.uav_asset
for each row execute function flight_operation.touch_updated_at();

drop trigger if exists flight_operation_sortie_touch_updated_at on flight_operation.flight_sortie;
create trigger flight_operation_sortie_touch_updated_at
before update on flight_operation.flight_sortie
for each row execute function flight_operation.touch_updated_at();

create or replace function flight_operation.current_actor_role()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user);
$$;

create or replace function flight_operation.require_admin()
returns text
language plpgsql
stable
as $$
declare
  v_role text := flight_operation.current_actor_role();
begin
  if v_role <> 'admin' then
    raise exception 'role % cannot manage flight operation data', v_role using errcode = '42501';
  end if;
  return v_role;
end;
$$;

create or replace function flight_operation.today_window(p_now timestamptz default now())
returns table(start_at timestamptz, end_at timestamptz)
language sql
stable
as $$
  select
    date_trunc('day', p_now at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai' as start_at,
    (date_trunc('day', p_now at time zone 'Asia/Shanghai') + interval '1 day') at time zone 'Asia/Shanghai' as end_at;
$$;

create or replace function api.get_today_flight_operation_dashboard(p_now timestamptz default now())
returns jsonb
language sql
stable
security definer
set search_path = flight_operation, public, pg_temp
as $$
with auth as (
  select flight_operation.require_admin() as role
), w as (
  select * from flight_operation.today_window(p_now)
), today_plans as (
  select p.*
  from flight_operation.flight_plan p, w, auth
  where planned_start_at < w.end_at
    and planned_end_at > w.start_at
), actionable_plans as (
  select *
  from today_plans
  where plan_type <> 'approval_reported'
     or approval_status not in ('rejected', 'revoked')
), statistic_sorties as (
  select s.*
  from flight_operation.flight_sortie s
  join actionable_plans p on p.id = s.flight_plan_id
), cumulative_actual as (
  select count(*)::integer as value
  from statistic_sorties s, w
  where s.status in ('in_progress', 'completed', 'aborted')
    and actual_start_at >= w.start_at
    and actual_start_at < w.end_at
), completed_actual as (
  select count(*)::integer as value
  from statistic_sorties s, w
  where s.status = 'completed'
    and actual_end_at >= w.start_at
    and actual_end_at < w.end_at
), planned as (
  select count(*)::integer as value
  from actionable_plans
), pending_plan_side as (
  select count(*)::integer as value
  from actionable_plans
  where status not in ('completed', 'cancelled')
), patrol as (
  select count(*)::integer as value
  from actionable_plans
  where plan_type = 'patrol_task'
), aircraft_on_mission as (
  select count(distinct uav_asset_id)::integer as value
  from flight_operation.flight_sortie s, auth
  where s.status = 'in_progress'
    and s.uav_asset_id is not null
), idle_aircraft as (
  select count(*)::integer as value
  from flight_operation.uav_asset a, auth
  where a.availability_status = 'available'
    and not exists (
      select 1
      from flight_operation.flight_sortie s
      where s.uav_asset_id = a.id
        and s.status = 'in_progress'
    )
), summary as (
  select
    (select value from planned) as planned_sortie_count,
    (select value from completed_actual) as completed_actual_sortie_count,
    (select value from cumulative_actual) as cumulative_actual_sortie_count,
    (select value from pending_plan_side) as pending_planned_sortie_count,
    (select value from patrol) as patrol_count,
    (select value from aircraft_on_mission) as aircraft_on_mission_count,
    (select value from idle_aircraft) as idle_aircraft_count
), approval_items as (
  select jsonb_agg(
    jsonb_build_object(
      'id', id,
      'plan_type', plan_type,
      'plan_source', plan_source,
      'status', status,
      'pilot', pilot,
      'reporting_unit', reporting_unit,
      'planned_start_at', planned_start_at,
      'planned_end_at', planned_end_at,
      'planned_sortie_count', 1,
      'approval_status', approval_status,
      'route_preview_geometry', route_preview_geometry,
      'route_preview_source', route_preview_source,
      'external_source', external_source,
      'external_id', external_id,
      'external_raw_payload', external_raw_payload
    ) order by planned_start_at, id
  ) as items
  from today_plans
  where plan_type = 'approval_reported'
), patrol_items as (
  select jsonb_agg(
    jsonb_build_object(
      'id', id,
      'plan_type', plan_type,
      'plan_source', plan_source,
      'status', status,
      'name', name,
      'unit', unit,
      'task_type', patrol_task_type,
      'planned_start_at', planned_start_at,
      'planned_end_at', planned_end_at,
      'planned_sortie_count', 1,
      'route_preview_geometry', route_preview_geometry,
      'route_preview_source', route_preview_source
    ) order by planned_start_at, id
  ) as items
  from today_plans
  where plan_type = 'patrol_task'
)
select jsonb_build_object(
  'business_window', jsonb_build_object('time_zone', 'Asia/Shanghai', 'start_at', (select start_at from w), 'end_at', (select end_at from w)),
  'summary', jsonb_build_object(
    'planned_sortie_count', (select planned_sortie_count from summary),
    'completed_actual_sortie_count', (select completed_actual_sortie_count from summary),
    'cumulative_actual_sortie_count', (select cumulative_actual_sortie_count from summary),
    'pending_planned_sortie_count', (select pending_planned_sortie_count from summary),
    'execution_rate', (select completed_actual_sortie_count::numeric / nullif((select planned_sortie_count from summary), 0) from summary),
    'patrol_count', (select patrol_count from summary),
    'aircraft_on_mission_count', (select aircraft_on_mission_count from summary),
    'idle_aircraft_count', (select idle_aircraft_count from summary)
  ),
  'approval_reported_flights', coalesce((select items from approval_items), '[]'::jsonb),
  'patrol_tasks', coalesce((select items from patrol_items), '[]'::jsonb)
);
$$;

create or replace function api.import_approval_reported_flight(
  p_external_source text default null,
  p_external_id text default null,
  p_pilot text default null,
  p_reporting_unit text default null,
  p_planned_start_at timestamptz default null,
  p_planned_end_at timestamptz default null,
  p_approval_status text default 'unknown',
  p_route_preview_geometry jsonb default null,
  p_external_raw_payload jsonb default '{}'::jsonb,
  p_status text default 'pending',
  p_planned_sortie_count integer default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = flight_operation, public, pg_temp
as $$
declare
  v_plan flight_operation.flight_plan;
begin
  perform flight_operation.require_admin();

  if p_external_source is null or p_external_id is null then
    raise exception 'external_source and external_id are required for approval-reported imports';
  end if;

  insert into flight_operation.flight_plan (
    plan_type, plan_source, status,
    pilot, reporting_unit, approval_status,
    planned_start_at, planned_end_at, planned_sortie_count,
    route_preview_geometry, route_preview_source,
    external_source, external_id, external_raw_payload, metadata
  ) values (
    'approval_reported', 'third_party', coalesce(p_status, 'pending'),
    p_pilot, p_reporting_unit, coalesce(p_approval_status, 'unknown'),
    p_planned_start_at, p_planned_end_at, null,
    p_route_preview_geometry, case when p_route_preview_geometry is null then null else 'third_party' end,
    p_external_source, p_external_id, coalesce(p_external_raw_payload, '{}'::jsonb), coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (external_source, external_id) do update
  set status = excluded.status,
      pilot = excluded.pilot,
      reporting_unit = excluded.reporting_unit,
      approval_status = excluded.approval_status,
      planned_start_at = excluded.planned_start_at,
      planned_end_at = excluded.planned_end_at,
      planned_sortie_count = null,
      route_preview_geometry = excluded.route_preview_geometry,
      route_preview_source = excluded.route_preview_source,
      external_raw_payload = excluded.external_raw_payload,
      metadata = excluded.metadata,
      updated_at = now()
  returning * into v_plan;

  return to_jsonb(v_plan);
end;
$$;

revoke all on schema flight_operation from public;
grant usage on schema flight_operation to admin;
grant select, insert, update, delete, truncate, references, trigger
  on all tables in schema flight_operation to admin;
grant usage, select, update on all sequences in schema flight_operation to admin;
grant execute on all functions in schema flight_operation to admin;

revoke all on function api.get_today_flight_operation_dashboard(timestamptz) from public, anonymous;
revoke all on function api.import_approval_reported_flight(text, text, text, text, timestamptz, timestamptz, text, jsonb, jsonb, text, integer, jsonb) from public, anonymous;
grant execute on function api.get_today_flight_operation_dashboard(timestamptz) to admin;
grant execute on function api.import_approval_reported_flight(text, text, text, text, timestamptz, timestamptz, text, jsonb, jsonb, text, integer, jsonb) to admin;

alter default privileges for role postgres in schema flight_operation
  grant select, insert, update, delete, truncate, references, trigger on tables to admin;
alter default privileges for role postgres in schema flight_operation
  grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema flight_operation
  grant execute on functions to admin;

commit;
