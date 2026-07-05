-- Demo records for 今日飞行运营看板.
-- Run after backend/create_flight_operation_api.sql in a development database.

begin;

insert into flight_operation.uav_asset (asset_code, name, availability_status, metadata) values
  ('HGS-UAV-001', '花果山一号', 'available', '{"model":"demo"}'::jsonb),
  ('HGS-UAV-002', '花果山二号', 'available', '{"model":"demo"}'::jsonb),
  ('HGS-UAV-003', '维护备机', 'maintenance', '{"model":"demo"}'::jsonb)
on conflict (asset_code) do update
set name = excluded.name,
    availability_status = excluded.availability_status,
    metadata = excluded.metadata,
    updated_at = now();

with today as (
  select * from flight_operation.today_window(now())
), upsert_approval as (
  insert into flight_operation.flight_plan (
    plan_type, plan_source, status, pilot, reporting_unit, approval_status,
    planned_start_at, planned_end_at,
    route_preview_geometry, route_preview_source,
    external_source, external_id, external_raw_payload
  )
  select
    'approval_reported', 'third_party', 'pending', '张三', '花果山通航服务队', 'approved',
    start_at + interval '9 hours', start_at + interval '10 hours 30 minutes',
    '{"type":"LineString","coordinates":[[119.245,34.642,150],[119.268,34.651,150],[119.286,34.646,150]]}'::jsonb,
    'third_party', 'demo-third-party', 'HGSD-TODAY-001', '{"demo":true}'::jsonb
  from today
  on conflict (external_source, external_id) do update
  set planned_start_at = excluded.planned_start_at,
      planned_end_at = excluded.planned_end_at,
      approval_status = excluded.approval_status,
      route_preview_geometry = excluded.route_preview_geometry,
      updated_at = now()
  returning id
), upsert_patrol as (
  insert into flight_operation.flight_plan (
    plan_type, plan_source, status, name, unit, patrol_task_type,
    planned_start_at, planned_end_at,
    route_preview_geometry, route_preview_source, metadata
  )
  select
    'patrol_task', 'platform', 'in_progress', '花果山北坡林火巡查', '连云港低空巡查队', '林火巡查',
    start_at + interval '13 hours 30 minutes', start_at + interval '18 hours',
    '{"type":"Polygon","coordinates":[[[119.255,34.635,120],[119.292,34.637,120],[119.296,34.661,120],[119.252,34.662,120],[119.255,34.635,120]]]}'::jsonb,
    'platform', '{"demo_key":"today-patrol"}'::jsonb
  from today
  where not exists (
    select 1 from flight_operation.flight_plan p
    where p.plan_type = 'patrol_task'
      and p.metadata ->> 'demo_key' = 'today-patrol'
  )
  returning id
), patrol_plan as (
  select id from upsert_patrol
  union all
  select p.id
  from flight_operation.flight_plan p
  where p.plan_type = 'patrol_task'
    and p.metadata ->> 'demo_key' = 'today-patrol'
    and not exists (select 1 from upsert_patrol)
  order by id
  limit 1
)
insert into flight_operation.flight_sortie (flight_plan_id, uav_asset_id, status, actual_start_at)
select p.id, a.id, 'in_progress', now() - interval '25 minutes'
from patrol_plan p
join flight_operation.uav_asset a on a.asset_code = 'HGS-UAV-001'
where not exists (
  select 1 from flight_operation.flight_sortie s
  where s.flight_plan_id = p.id
    and s.uav_asset_id = a.id
    and s.status = 'in_progress'
);

with approval_plan as (
  select id,
         route_preview_geometry,
         external_source,
         external_id,
         external_raw_payload
  from flight_operation.flight_plan
  where external_source = 'demo-third-party'
    and external_id = 'HGSD-TODAY-001'
  limit 1
), inserted_route as (
  insert into flight_operation.execution_route (
    flight_plan_id, source, is_active, route_geometry, route_grid_codes,
    external_source, external_id, external_raw_payload, platform_validated, metadata
  )
  select id, 'third_party', true, route_preview_geometry,
         array[
           ST_AsGridcell3D(119.245, 34.642, 150, 19),
           ST_AsGridcell3D(119.286, 34.646, 150, 19)
         ]::gridcell[],
         external_source, external_id, external_raw_payload, false, '{"demo":true}'::jsonb
  from approval_plan
  where not exists (
    select 1 from flight_operation.execution_route er
    where er.flight_plan_id = approval_plan.id
      and er.is_active
  )
  returning id, flight_plan_id
)
update flight_operation.flight_plan p
set active_execution_route_id = r.id
from inserted_route r
where p.id = r.flight_plan_id;

with patrol_plan as (
  select id, route_preview_geometry
  from flight_operation.flight_plan
  where plan_type = 'patrol_task'
    and metadata ->> 'demo_key' = 'today-patrol'
  order by id
  limit 1
), inserted_route as (
  insert into flight_operation.execution_route (
    flight_plan_id, source, is_active, route_geometry, route_grid_codes,
    platform_validated, metadata
  )
  select id, 'manual', true, route_preview_geometry,
         array[
           ST_AsGridcell3D(119.255, 34.635, 120, 19),
           ST_AsGridcell3D(119.296, 34.661, 120, 19)
         ]::gridcell[],
         false, '{"demo":true}'::jsonb
  from patrol_plan
  where not exists (
    select 1 from flight_operation.execution_route er
    where er.flight_plan_id = patrol_plan.id
      and er.is_active
  )
  returning id, flight_plan_id
)
update flight_operation.flight_plan p
set active_execution_route_id = r.id,
    route_preview_source = 'manual'
from inserted_route r
where p.id = r.flight_plan_id;

commit;
