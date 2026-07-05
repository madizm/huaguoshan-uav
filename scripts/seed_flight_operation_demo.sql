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
    planned_start_at, planned_end_at, planned_sortie_count,
    route_preview_geometry, route_preview_source,
    external_source, external_id, external_raw_payload
  )
  select
    'approval_reported', 'third_party', 'pending', '张三', '花果山通航服务队', 'approved',
    start_at + interval '9 hours', start_at + interval '10 hours 30 minutes', 1,
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
    planned_start_at, planned_end_at, planned_sortie_count,
    route_preview_geometry, route_preview_source, metadata
  )
  select
    'patrol_task', 'platform', 'in_progress', '花果山北坡林火巡查', '连云港低空巡查队', '林火巡查',
    start_at + interval '13 hours 30 minutes', start_at + interval '18 hours', 3,
    '{"type":"Polygon","coordinates":[[[119.255,34.635,120],[119.292,34.637,120],[119.296,34.661,120],[119.252,34.662,120],[119.255,34.635,120]]]}'::jsonb,
    'platform', '{"demo_key":"today-patrol"}'::jsonb
  from today
  where not exists (
    select 1 from flight_operation.flight_plan p
    where p.plan_type = 'patrol_task'
      and p.metadata ->> 'demo_key' = 'today-patrol'
  )
  returning id
)
insert into flight_operation.flight_sortie (flight_plan_id, uav_asset_id, status, actual_start_at)
select p.id, a.id, 'in_progress', now() - interval '25 minutes'
from flight_operation.flight_plan p
join flight_operation.uav_asset a on a.asset_code = 'HGS-UAV-001'
where p.metadata ->> 'demo_key' = 'today-patrol'
  and not exists (
    select 1 from flight_operation.flight_sortie s
    where s.flight_plan_id = p.id
      and s.uav_asset_id = a.id
      and s.status = 'in_progress'
  );

commit;
