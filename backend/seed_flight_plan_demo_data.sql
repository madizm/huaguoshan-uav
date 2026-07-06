-- Seed demo data for the flight plan large-screen module.
--
-- What this script does:
--   1. Upserts demo UAV assets into flight_plan.aircraft_asset.
--   2. Upserts demo reported flights into flight_plan.reported_flight.
--   3. Upserts demo 巡查任务 into flight_plan.inspection_task.
--   4. Randomly assigns route_result_id from existing successful
--      flight_path.plan_result rows that have grid_path data.
--   5. Recomputes demo aircraft availability from currently executing demo
--      activities so the dashboard statistics have meaningful values.
--
-- Notes:
--   - The script is idempotent for source_system = 'seed_flight_plan'. Re-running
--     it updates the same demo records and randomizes route_result_id again.
--   - If no eligible flight_path.plan_result exists, route_result_id remains null.
--   - Pilot information remains a reported-flight snapshot; no pilot table is used.

begin;

-- -----------------------------------------------------------------------------
-- 1. Demo aircraft assets
-- -----------------------------------------------------------------------------
with seed_assets(source_aircraft_id, asset_code, name, model, serial_no, owner_unit_name, availability_status) as (
  values
    ('UAV-001', 'HGS-UAV-001', '花果山一号', 'DJI Matrice 350 RTK', 'SN-HGS-001', '花果山景区管理处', 'idle'),
    ('UAV-002', 'HGS-UAV-002', '花果山二号', 'DJI Matrice 350 RTK', 'SN-HGS-002', '花果山景区管理处', 'idle'),
    ('UAV-003', 'HGS-UAV-003', '云台巡查一号', 'DJI Mavic 3T', 'SN-HGS-003', '森林防火巡查队', 'idle'),
    ('UAV-004', 'HGS-UAV-004', '云台巡查二号', 'DJI Mavic 3T', 'SN-HGS-004', '森林防火巡查队', 'idle'),
    ('UAV-005', 'HGS-UAV-005', '应急复核一号', 'Autel EVO Max 4T', 'SN-HGS-005', '应急联动中心', 'idle'),
    ('UAV-006', 'HGS-UAV-006', '应急复核二号', 'Autel EVO Max 4T', 'SN-HGS-006', '应急联动中心', 'idle'),
    ('UAV-007', 'HGS-UAV-007', '北坡巡护一号', 'DJI M30T', 'SN-HGS-007', '北坡巡护站', 'idle'),
    ('UAV-008', 'HGS-UAV-008', '南坡巡护一号', 'DJI M30T', 'SN-HGS-008', '南坡巡护站', 'idle'),
    ('UAV-009', 'HGS-UAV-009', '备用机一号', 'DJI Mavic 3E', 'SN-HGS-009', '花果山景区管理处', 'maintenance'),
    ('UAV-010', 'HGS-UAV-010', '备用机二号', 'DJI Mavic 3E', 'SN-HGS-010', '花果山景区管理处', 'offline')
)
insert into flight_plan.aircraft_asset(
  source_system,
  source_aircraft_id,
  asset_code,
  name,
  model,
  serial_no,
  owner_unit_name,
  availability_status,
  metadata
)
select
  'seed_flight_plan',
  source_aircraft_id,
  asset_code,
  name,
  model,
  serial_no,
  owner_unit_name,
  availability_status,
  jsonb_build_object('seed', true, 'scenario', 'flight_plan_large_screen')
from seed_assets
on conflict (source_system, source_aircraft_id) do update
set asset_code = excluded.asset_code,
    name = excluded.name,
    model = excluded.model,
    serial_no = excluded.serial_no,
    owner_unit_name = excluded.owner_unit_name,
    availability_status = excluded.availability_status,
    metadata = excluded.metadata;

-- -----------------------------------------------------------------------------
-- 2. Demo reported flights, with random optional route_result_id assignment.
-- -----------------------------------------------------------------------------
with params as (
  select date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai' as today_start
), route_pool as (
  select id
  from flight_path.plan_result
  where result_status = 'success'
    and grid_path is not null
), seed_rows(seq, source_record_id, report_no, title, reporting_unit_name, pilot_name, pilot_phone, aircraft_source_id, start_offset, duration_m, filing_status, execution_status) as (
  values
    (1,  'RF-001', '报备-20260706-001', '花果山景区航拍报备',       '花果山景区管理处', '张伟', '13800000001', 'UAV-001', interval '08 hours 00 minutes', 90,  'approved',  'ready'),
    (2,  'RF-002', '报备-20260706-002', '云台山片区巡航报备',       '文旅综合保障中心', '李强', '13800000002', 'UAV-002', interval '09 hours 30 minutes', 120, 'approved',  'executing'),
    (3,  'RF-003', '报备-20260706-003', '重点区域低空巡检报备',     '城市运行保障中心', '王磊', '13800000003', 'UAV-005', interval '10 hours 00 minutes', 60,  'approved',  'planned'),
    (4,  'RF-004', '报备-20260706-004', '景区游客流量观察报备',     '花果山景区管理处', '赵敏', '13800000004', 'UAV-006', interval '11 hours 15 minutes', 75,  'reported',  'planned'),
    (5,  'RF-005', '报备-20260706-005', '东侧山脊飞行报备',         '第三方测绘单位',   '陈杰', '13800000005', 'UAV-007', interval '13 hours 00 minutes', 80,  'approved',  'planned'),
    (6,  'RF-006', '报备-20260706-006', '南坡临时观察报备',         '南坡巡护站',       '刘洋', '13800000006', 'UAV-008', interval '14 hours 30 minutes', 90,  'approved',  'ready'),
    (7,  'RF-007', '报备-20260706-007', '昨日完成飞行报备',         '花果山景区管理处', '周明', '13800000007', 'UAV-003', interval '-1 day 15 hours',    60,  'approved',  'completed'),
    (8,  'RF-008', '报备-20260706-008', '明日预约飞行报备',         '文旅综合保障中心', '吴迪', '13800000008', 'UAV-004', interval '1 day 09 hours',     100, 'approved',  'planned'),
    (9,  'RF-009', '报备-20260706-009', '取消的飞行报备',           '第三方测绘单位',   '马超', '13800000009', 'UAV-001', interval '15 hours 30 minutes', 60,  'cancelled', 'cancelled'),
    (10, 'RF-010', '报备-20260706-010', '傍晚景区边界观察报备',     '花果山景区管理处', '孙浩', '13800000010', 'UAV-002', interval '17 hours 00 minutes', 70,  'approved',  'planned')
), prepared as (
  select
    r.*,
    a.id as aircraft_id,
    a.name as aircraft_name_snapshot,
    p.today_start + r.start_offset as planned_start_at,
    p.today_start + r.start_offset + make_interval(mins => r.duration_m) as planned_end_at
  from seed_rows r
  cross join params p
  left join flight_plan.aircraft_asset a
    on a.source_system = 'seed_flight_plan'
   and a.source_aircraft_id = r.aircraft_source_id
)
insert into flight_plan.reported_flight(
  source_system,
  source_record_id,
  report_no,
  title,
  reporting_unit_name,
  pilot_name,
  pilot_phone,
  pilot_license_no,
  aircraft_id,
  aircraft_name_snapshot,
  planned_start_at,
  planned_end_at,
  filing_status,
  execution_status,
  route_result_id,
  remark,
  source_payload,
  metadata
)
select
  'seed_flight_plan',
  p.source_record_id,
  p.report_no,
  p.title,
  p.reporting_unit_name,
  p.pilot_name,
  p.pilot_phone,
  'SEED-LICENSE-' || lpad(p.seq::text, 3, '0'),
  p.aircraft_id,
  p.aircraft_name_snapshot,
  p.planned_start_at,
  p.planned_end_at,
  p.filing_status,
  p.execution_status,
  case when random() < 0.85 then rp.id else null end as route_result_id,
  'Seed demo reported flight. route_result_id is randomized on each run when route results exist.',
  jsonb_build_object('seed', true, 'seq', p.seq, 'aircraft_source_id', p.aircraft_source_id),
  jsonb_build_object('seed', true, 'route_randomized', true)
from prepared p
left join lateral (
  select id
  from route_pool
  where p.seq = p.seq
  order by random()
  limit 1
) rp on true
on conflict (source_system, source_record_id) do update
set report_no = excluded.report_no,
    title = excluded.title,
    reporting_unit_name = excluded.reporting_unit_name,
    pilot_name = excluded.pilot_name,
    pilot_phone = excluded.pilot_phone,
    pilot_license_no = excluded.pilot_license_no,
    aircraft_id = excluded.aircraft_id,
    aircraft_name_snapshot = excluded.aircraft_name_snapshot,
    planned_start_at = excluded.planned_start_at,
    planned_end_at = excluded.planned_end_at,
    filing_status = excluded.filing_status,
    execution_status = excluded.execution_status,
    route_result_id = excluded.route_result_id,
    remark = excluded.remark,
    source_payload = excluded.source_payload,
    metadata = excluded.metadata;

-- -----------------------------------------------------------------------------
-- 3. Demo inspection tasks / 巡查任务, also with random optional route_result_id.
-- -----------------------------------------------------------------------------
with params as (
  select date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai' as today_start
), route_pool as (
  select id
  from flight_path.plan_result
  where result_status = 'success'
    and grid_path is not null
), seed_rows(seq, source_task_id, task_no, task_name, task_type, responsible_unit_name, start_offset, aircraft_source_id, duration_m, task_status, priority) as (
  values
    (1, 'IT-001', '巡查-20260706-001', '花果山核心景区晨间巡查',     'forest_patrol',    '森林防火巡查队', interval '07 hours 30 minutes', 'UAV-003', 90,  'completed', 'normal'),
    (2, 'IT-002', '巡查-20260706-002', '北坡林区例行巡查',           'forest_patrol',    '北坡巡护站',     interval '08 hours 45 minutes', 'UAV-007', 80,  'executing', 'high'),
    (3, 'IT-003', '巡查-20260706-003', '南坡林区例行巡查',           'forest_patrol',    '南坡巡护站',     interval '09 hours 15 minutes', 'UAV-008', 80,  'ready',     'normal'),
    (4, 'IT-004', '巡查-20260706-004', '景区边界航线巡查',           'route_patrol',     '花果山景区管理处', interval '10 hours 30 minutes', 'UAV-004', 90, 'planned',   'normal'),
    (5, 'IT-005', '巡查-20260706-005', '疑似火点复核任务',           'emergency_review', '应急联动中心',   interval '11 hours 00 minutes', 'UAV-005', 45,  'executing', 'urgent'),
    (6, 'IT-006', '巡查-20260706-006', '下午重点区域巡查',           'forest_patrol',    '森林防火巡查队', interval '15 hours 00 minutes', 'UAV-006', 90,  'planned',   'high'),
    (7, 'IT-007', '巡查-20260706-007', '傍晚游客密集区观察',         'route_patrol',     '花果山景区管理处', interval '18 hours 00 minutes', 'UAV-001', 60, 'planned',   'normal'),
    (8, 'IT-008', '巡查-20260706-008', '昨日夜间热源复查',           'emergency_review', '应急联动中心',   interval '-1 day 21 hours',    'UAV-002', 50,  'completed', 'high'),
    (9, 'IT-009', '巡查-20260706-009', '明日核心区常规巡查',         'forest_patrol',    '森林防火巡查队', interval '1 day 08 hours',     'UAV-003', 90,  'planned',   'normal'),
    (10,'IT-010', '巡查-20260706-010', '取消的巡查任务',             'route_patrol',     '南坡巡护站',     interval '12 hours 30 minutes', 'UAV-008', 60,  'cancelled', 'normal')
), prepared as (
  select
    r.*,
    a.id as aircraft_id,
    a.name as aircraft_name_snapshot,
    p.today_start + r.start_offset as planned_start_at,
    p.today_start + r.start_offset + make_interval(mins => r.duration_m) as planned_end_at,
    case when r.task_status in ('executing', 'completed') then p.today_start + r.start_offset + interval '5 minutes' else null end as actual_start_at,
    case when r.task_status = 'completed' then p.today_start + r.start_offset + make_interval(mins => r.duration_m) - interval '5 minutes' else null end as actual_end_at
  from seed_rows r
  cross join params p
  left join flight_plan.aircraft_asset a
    on a.source_system = 'seed_flight_plan'
   and a.source_aircraft_id = r.aircraft_source_id
)
insert into flight_plan.inspection_task(
  source_system,
  source_task_id,
  task_no,
  task_name,
  task_type,
  responsible_unit_name,
  aircraft_id,
  aircraft_name_snapshot,
  planned_start_at,
  planned_end_at,
  actual_start_at,
  actual_end_at,
  task_status,
  priority,
  route_result_id,
  task_area,
  remark,
  source_payload,
  metadata
)
select
  'seed_flight_plan',
  p.source_task_id,
  p.task_no,
  p.task_name,
  p.task_type,
  p.responsible_unit_name,
  p.aircraft_id,
  p.aircraft_name_snapshot,
  p.planned_start_at,
  p.planned_end_at,
  p.actual_start_at,
  p.actual_end_at,
  p.task_status,
  p.priority,
  case when random() < 0.90 then rp.id else null end as route_result_id,
  ST_SetSRID(ST_Multi(ST_MakeEnvelope(119.235 + p.seq * 0.001, 34.635 + p.seq * 0.001, 119.245 + p.seq * 0.001, 34.645 + p.seq * 0.001, 4326)), 4326),
  'Seed demo inspection task. route_result_id is randomized on each run when route results exist.',
  jsonb_build_object('seed', true, 'seq', p.seq, 'aircraft_source_id', p.aircraft_source_id),
  jsonb_build_object('seed', true, 'route_randomized', true)
from prepared p
left join lateral (
  select id
  from route_pool
  where p.seq = p.seq
  order by random()
  limit 1
) rp on true
on conflict (source_system, source_task_id) do update
set task_no = excluded.task_no,
    task_name = excluded.task_name,
    task_type = excluded.task_type,
    responsible_unit_name = excluded.responsible_unit_name,
    aircraft_id = excluded.aircraft_id,
    aircraft_name_snapshot = excluded.aircraft_name_snapshot,
    planned_start_at = excluded.planned_start_at,
    planned_end_at = excluded.planned_end_at,
    actual_start_at = excluded.actual_start_at,
    actual_end_at = excluded.actual_end_at,
    task_status = excluded.task_status,
    priority = excluded.priority,
    route_result_id = excluded.route_result_id,
    task_area = excluded.task_area,
    remark = excluded.remark,
    source_payload = excluded.source_payload,
    metadata = excluded.metadata;

-- -----------------------------------------------------------------------------
-- 4. Set demo aircraft availability from executing demo activities.
-- -----------------------------------------------------------------------------
update flight_plan.aircraft_asset a
set availability_status = case
  when exists (
    select 1
    from flight_plan.reported_flight rf
    where rf.aircraft_id = a.id
      and rf.source_system = 'seed_flight_plan'
      and rf.execution_status = 'executing'
  ) or exists (
    select 1
    from flight_plan.inspection_task it
    where it.aircraft_id = a.id
      and it.source_system = 'seed_flight_plan'
      and it.task_status = 'executing'
  ) then 'in_task'
  when a.source_aircraft_id = 'UAV-009' then 'maintenance'
  when a.source_aircraft_id = 'UAV-010' then 'offline'
  else 'idle'
end
where a.source_system = 'seed_flight_plan';

-- -----------------------------------------------------------------------------
-- 5. Human-readable seed summary.
-- -----------------------------------------------------------------------------
select jsonb_pretty(jsonb_build_object(
  'aircraft_assets', (
    select count(*) from flight_plan.aircraft_asset where source_system = 'seed_flight_plan'
  ),
  'reported_flights', (
    select count(*) from flight_plan.reported_flight where source_system = 'seed_flight_plan'
  ),
  'reported_flights_with_route', (
    select count(*) from flight_plan.reported_flight where source_system = 'seed_flight_plan' and route_result_id is not null
  ),
  'inspection_tasks', (
    select count(*) from flight_plan.inspection_task where source_system = 'seed_flight_plan'
  ),
  'inspection_tasks_with_route', (
    select count(*) from flight_plan.inspection_task where source_system = 'seed_flight_plan' and route_result_id is not null
  ),
  'eligible_route_results', (
    select count(*) from flight_path.plan_result where result_status = 'success' and grid_path is not null
  )
)) as seed_summary;

commit;
