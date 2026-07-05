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

with today as (
  select * from flight_operation.today_window(now())
), demo_patrols(demo_key, status, name, unit, task_type, start_offset, end_offset, route_geometry, route_source) as (
  values
    ('today-patrol-east', 'pending', '花果山东线森林巡查', '连云港低空巡查队', '林火巡查', interval '10 hours', interval '11 hours 20 minutes', '{"type":"LineString","coordinates":[[119.302,34.646,130],[119.315,34.655,135],[119.328,34.651,130]]}'::jsonb, 'manual'),
    ('today-patrol-west', 'pending', '花果山西坡设施巡检', '花果山景区保障队', '设施巡检', interval '15 hours', interval '16 hours 10 minutes', '{"type":"Polygon","coordinates":[[[119.218,34.632,110],[119.238,34.633,110],[119.242,34.648,110],[119.216,34.650,110],[119.218,34.632,110]]]}'::jsonb, 'manual'),
    ('today-patrol-completed', 'completed', '云台山南麓例行巡查', '连云港低空巡查队', '例行巡查', interval '8 hours', interval '9 hours', '{"type":"LineString","coordinates":[[119.255,34.610,120],[119.272,34.618,120],[119.290,34.615,120]]}'::jsonb, 'manual'),
    ('today-patrol-abnormal', 'abnormal', '北侧通信塔复核任务', '花果山景区保障队', '设施复核', interval '11 hours 40 minutes', interval '12 hours 30 minutes', '{"type":"Point","coordinates":[119.274,34.672,140]}'::jsonb, 'manual')
), updated as (
  update flight_operation.flight_plan p
  set status = v.status,
      name = v.name,
      unit = v.unit,
      patrol_task_type = v.task_type,
      planned_start_at = today.start_at + v.start_offset,
      planned_end_at = today.start_at + v.end_offset,
      route_preview_geometry = v.route_geometry,
      route_preview_source = v.route_source,
      updated_at = now()
  from today, demo_patrols v
  where p.plan_type = 'patrol_task'
    and p.metadata ->> 'demo_key' = v.demo_key
  returning p.id
)
insert into flight_operation.flight_plan (
  plan_type, plan_source, status, name, unit, patrol_task_type,
  planned_start_at, planned_end_at, route_preview_geometry, route_preview_source, metadata
)
select 'patrol_task', 'platform', v.status, v.name, v.unit, v.task_type,
       today.start_at + v.start_offset, today.start_at + v.end_offset,
       v.route_geometry, v.route_source, jsonb_build_object('demo_key', v.demo_key)
from today, demo_patrols v
where not exists (
  select 1 from flight_operation.flight_plan p
  where p.plan_type = 'patrol_task'
    and p.metadata ->> 'demo_key' = v.demo_key
);

with today as (
  select * from flight_operation.today_window(now())
), demo_approvals(external_id, status, pilot, reporting_unit, approval_status, start_offset, end_offset, route_geometry) as (
  values
    ('HGSD-TODAY-002', 'pending', '李四', '海州区巡检服务队', 'approved', interval '10 hours 45 minutes', interval '12 hours', '{"type":"LineString","coordinates":[[119.230,34.660,145],[119.246,34.668,145],[119.260,34.662,145]]}'::jsonb),
    ('HGSD-TODAY-003', 'completed', '王五', '云台山通航服务队', 'reported', interval '7 hours 30 minutes', interval '8 hours 20 minutes', '{"type":"Polygon","coordinates":[[[119.300,34.620,100],[119.318,34.622,100],[119.320,34.636,100],[119.298,34.635,100],[119.300,34.620,100]]]}'::jsonb)
), upserted as (
  insert into flight_operation.flight_plan (
    plan_type, plan_source, status, pilot, reporting_unit, approval_status,
    planned_start_at, planned_end_at, route_preview_geometry, route_preview_source,
    external_source, external_id, external_raw_payload
  )
  select 'approval_reported', 'third_party', v.status, v.pilot, v.reporting_unit, v.approval_status,
         today.start_at + v.start_offset, today.start_at + v.end_offset,
         v.route_geometry, 'third_party', 'demo-third-party', v.external_id, jsonb_build_object('demo', true, 'external_id', v.external_id)
  from today, demo_approvals v
  on conflict (external_source, external_id) do update
  set status = excluded.status,
      pilot = excluded.pilot,
      reporting_unit = excluded.reporting_unit,
      approval_status = excluded.approval_status,
      planned_start_at = excluded.planned_start_at,
      planned_end_at = excluded.planned_end_at,
      route_preview_geometry = excluded.route_preview_geometry,
      route_preview_source = excluded.route_preview_source,
      external_raw_payload = excluded.external_raw_payload,
      updated_at = now()
  returning id
)
select count(*) from upserted;

with demo_routes(plan_key, lon1, lat1, h1, lon2, lat2, h2) as (
  values
    ('today-patrol-east', 119.302, 34.646, 130.0, 119.328, 34.651, 130.0),
    ('today-patrol-west', 119.218, 34.632, 110.0, 119.242, 34.648, 110.0),
    ('today-patrol-completed', 119.255, 34.610, 120.0, 119.290, 34.615, 120.0),
    ('today-patrol-abnormal', 119.274, 34.672, 140.0, 119.274, 34.672, 140.0)
), patrol_plans as (
  select p.id, p.route_preview_geometry, d.lon1, d.lat1, d.h1, d.lon2, d.lat2, d.h2
  from flight_operation.flight_plan p
  join demo_routes d on d.plan_key = p.metadata ->> 'demo_key'
), inserted_route as (
  insert into flight_operation.execution_route (
    flight_plan_id, source, is_active, route_geometry, route_grid_codes,
    platform_validated, metadata
  )
  select id, 'manual', true, route_preview_geometry,
         array[
           ST_AsGridcell3D(lon1, lat1, h1, 19),
           ST_AsGridcell3D(lon2, lat2, h2, 19)
         ]::gridcell[],
         false, '{"demo":true}'::jsonb
  from patrol_plans
  where not exists (
    select 1 from flight_operation.execution_route er
    where er.flight_plan_id = patrol_plans.id
      and er.is_active
  )
  returning id, flight_plan_id
)
update flight_operation.flight_plan p
set active_execution_route_id = r.id,
    route_preview_source = 'manual'
from inserted_route r
where p.id = r.flight_plan_id;

with approval_routes(external_id, lon1, lat1, h1, lon2, lat2, h2) as (
  values
    ('HGSD-TODAY-002', 119.230, 34.660, 145.0, 119.260, 34.662, 145.0),
    ('HGSD-TODAY-003', 119.300, 34.620, 100.0, 119.320, 34.636, 100.0)
), approval_plans as (
  select p.id, p.route_preview_geometry, p.external_source, p.external_id, p.external_raw_payload,
         r.lon1, r.lat1, r.h1, r.lon2, r.lat2, r.h2
  from flight_operation.flight_plan p
  join approval_routes r on r.external_id = p.external_id
  where p.external_source = 'demo-third-party'
), inserted_route as (
  insert into flight_operation.execution_route (
    flight_plan_id, source, is_active, route_geometry, route_grid_codes,
    external_source, external_id, external_raw_payload, platform_validated, metadata
  )
  select id, 'third_party', true, route_preview_geometry,
         array[
           ST_AsGridcell3D(lon1, lat1, h1, 19),
           ST_AsGridcell3D(lon2, lat2, h2, 19)
         ]::gridcell[],
         external_source, external_id, external_raw_payload, false, '{"demo":true}'::jsonb
  from approval_plans
  where not exists (
    select 1 from flight_operation.execution_route er
    where er.flight_plan_id = approval_plans.id
      and er.is_active
  )
  returning id, flight_plan_id
)
update flight_operation.flight_plan p
set active_execution_route_id = r.id
from inserted_route r
where p.id = r.flight_plan_id;

insert into flight_operation.flight_sortie (flight_plan_id, uav_asset_id, status, actual_start_at, actual_end_at, metadata)
select p.id, a.id, 'completed', p.planned_start_at + interval '5 minutes', p.planned_end_at - interval '5 minutes', '{"demo":true}'::jsonb
from flight_operation.flight_plan p
join flight_operation.uav_asset a on a.asset_code = 'HGS-UAV-002'
where p.metadata ->> 'demo_key' = 'today-patrol-completed'
  and not exists (select 1 from flight_operation.flight_sortie s where s.flight_plan_id = p.id);

insert into flight_operation.flight_sortie (flight_plan_id, uav_asset_id, status, actual_start_at, actual_end_at, metadata)
select p.id, a.id, 'aborted', p.planned_start_at + interval '8 minutes', p.planned_start_at + interval '22 minutes', '{"demo":true,"reason":"signal_loss"}'::jsonb
from flight_operation.flight_plan p
join flight_operation.uav_asset a on a.asset_code = 'HGS-UAV-003'
where p.metadata ->> 'demo_key' = 'today-patrol-abnormal'
  and not exists (select 1 from flight_operation.flight_sortie s where s.flight_plan_id = p.id);

insert into flight_operation.flight_sortie (flight_plan_id, uav_asset_id, status, actual_start_at, actual_end_at, metadata)
select p.id, a.id, 'completed', p.planned_start_at + interval '3 minutes', p.planned_end_at - interval '3 minutes', '{"demo":true}'::jsonb
from flight_operation.flight_plan p
join flight_operation.uav_asset a on a.asset_code = 'HGS-UAV-002'
where p.external_source = 'demo-third-party'
  and p.external_id = 'HGSD-TODAY-003'
  and not exists (select 1 from flight_operation.flight_sortie s where s.flight_plan_id = p.id);

commit;
