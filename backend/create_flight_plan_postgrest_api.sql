-- Flight plan display data model and PostgREST API facade.
--
-- Scope:
--   - This system is a large-screen display / decision-support application.
--   - `reported_flight` stores externally approved/reported flight data for display;
--     it is not an in-system approval workflow.
--   - `inspection_task` stores patrol / inspection tasks using the project term
--     巡查任务.
--   - Pilot information is kept as a source-data snapshot on reported flights and
--     is intentionally not normalized into a separate table.
--   - Route linkage is optional. When present, `route_result_id` references
--     `flight_path.plan_result` so the frontend can display GeoJSON and GGER grids.
--
-- PostgREST surface exposed through schema `api`:
--   Resource CRUD views:
--     /aircraft_assets
--     /reported_flights
--     /inspection_tasks
--   Read-only views:
--     /flight_activities
--     /flight_activity_route_previews
--   Aggregation RPC:
--     /rpc/get_flight_plan_stats

begin;

create extension if not exists postgis;
create extension if not exists best_geomgrid cascade;

create schema if not exists flight_plan;
comment on schema flight_plan is 'Flight plan display schema for reported flights, patrol tasks, aircraft assets, and large-screen statistics.';

create schema if not exists api;
comment on schema api is '花果山无人机平台稳定的 PostgREST API 门面；仅暴露前端需要的资源视图、只读组合视图和少量聚合 RPC。';

-- -----------------------------------------------------------------------------
-- Shared updated_at trigger
-- -----------------------------------------------------------------------------
create or replace function flight_plan.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function flight_plan.touch_updated_at() is 'Maintains updated_at on flight_plan mutable tables.';

-- -----------------------------------------------------------------------------
-- Aircraft assets
-- -----------------------------------------------------------------------------
create table if not exists flight_plan.aircraft_asset (
  id bigserial primary key,

  source_system text,
  source_aircraft_id text,

  asset_code text,
  name text not null,
  model text,
  serial_no text,
  owner_unit_name text,

  availability_status text not null default 'idle',
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table flight_plan.aircraft_asset is 'Registered UAV asset snapshot used by the large-screen flight plan module and aircraft availability statistics.';
comment on column flight_plan.aircraft_asset.source_system is 'External asset source system code, when the asset is synchronized from another system.';
comment on column flight_plan.aircraft_asset.source_aircraft_id is 'Aircraft identifier in the external source system.';
comment on column flight_plan.aircraft_asset.asset_code is 'Human-facing aircraft or asset code.';
comment on column flight_plan.aircraft_asset.name is 'Display name of the UAV asset.';
comment on column flight_plan.aircraft_asset.owner_unit_name is 'Owning or managing unit name as display text; units are not normalized in this module.';
comment on column flight_plan.aircraft_asset.availability_status is 'Current availability for display/statistics: idle, in_task, maintenance, offline, or unknown.';
comment on column flight_plan.aircraft_asset.metadata is 'Extension payload for source-specific attributes that do not deserve first-class columns.';

-- Add constraints idempotently so this script can be re-run in development.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'aircraft_asset_status_chk'
      and conrelid = 'flight_plan.aircraft_asset'::regclass
  ) then
    alter table flight_plan.aircraft_asset
      add constraint aircraft_asset_status_chk
      check (availability_status in ('idle', 'in_task', 'maintenance', 'offline', 'unknown'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'aircraft_asset_source_unique'
      and conrelid = 'flight_plan.aircraft_asset'::regclass
  ) then
    alter table flight_plan.aircraft_asset
      add constraint aircraft_asset_source_unique unique (source_system, source_aircraft_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'aircraft_asset_asset_code_unique'
      and conrelid = 'flight_plan.aircraft_asset'::regclass
  ) then
    alter table flight_plan.aircraft_asset
      add constraint aircraft_asset_asset_code_unique unique (asset_code);
  end if;
end;
$$;

create index if not exists aircraft_asset_status_idx
  on flight_plan.aircraft_asset(availability_status);

create index if not exists aircraft_asset_owner_unit_idx
  on flight_plan.aircraft_asset(owner_unit_name);

drop trigger if exists aircraft_asset_touch_updated_at on flight_plan.aircraft_asset;
create trigger aircraft_asset_touch_updated_at
before update on flight_plan.aircraft_asset
for each row execute function flight_plan.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Reported flights: external filing/approval data display only
-- -----------------------------------------------------------------------------
create table if not exists flight_plan.reported_flight (
  id bigserial primary key,

  source_system text not null,
  source_record_id text,

  report_no text,
  title text,
  reporting_unit_name text not null,

  -- Pilot is not modeled as a local account or permission subject. Keep a
  -- source-data snapshot because the large screen only needs display/filter text.
  pilot_name text,
  pilot_phone text,
  pilot_license_no text,

  aircraft_id bigint references flight_plan.aircraft_asset(id),
  aircraft_name_snapshot text,

  planned_start_at timestamptz not null,
  planned_end_at timestamptz not null,

  -- External status only. The platform does not approve/reject these records.
  filing_status text not null default 'approved',

  -- Display/runtime status used by the large-screen situation view.
  execution_status text not null default 'planned',

  -- Optional linkage to a computed route result. Null means the activity exists
  -- but no display route/GGER grid is available yet.
  route_result_id bigint references flight_path.plan_result(id),

  remark text,
  source_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  ingested_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table flight_plan.reported_flight is 'Externally reported/approved flight data displayed by this platform; not an in-system approval workflow.';
comment on column flight_plan.reported_flight.source_system is 'External reporting/filing system code.';
comment on column flight_plan.reported_flight.source_record_id is 'Stable record id in the external source system; use with source_system for PostgREST upsert.';
comment on column flight_plan.reported_flight.report_no is 'External report or filing number shown on the large screen.';
comment on column flight_plan.reported_flight.reporting_unit_name is 'Reporting unit name from the external data source.';
comment on column flight_plan.reported_flight.pilot_name is 'Pilot name snapshot from the source record; pilots are intentionally not normalized.';
comment on column flight_plan.reported_flight.filing_status is 'External filing/approval status for display only: reported, approved, rejected, cancelled, expired, or unknown.';
comment on column flight_plan.reported_flight.execution_status is 'Flight execution status for display/statistics: planned, ready, executing, completed, cancelled, or unknown.';
comment on column flight_plan.reported_flight.route_result_id is 'Optional flight_path.plan_result id used to preview the route and GGER grid.';
comment on column flight_plan.reported_flight.source_payload is 'Original or normalized external payload retained for traceability.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'reported_flight_time_chk'
      and conrelid = 'flight_plan.reported_flight'::regclass
  ) then
    alter table flight_plan.reported_flight
      add constraint reported_flight_time_chk check (planned_end_at > planned_start_at);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'reported_flight_filing_status_chk'
      and conrelid = 'flight_plan.reported_flight'::regclass
  ) then
    alter table flight_plan.reported_flight
      add constraint reported_flight_filing_status_chk
      check (filing_status in ('reported', 'approved', 'rejected', 'cancelled', 'expired', 'unknown'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'reported_flight_execution_status_chk'
      and conrelid = 'flight_plan.reported_flight'::regclass
  ) then
    alter table flight_plan.reported_flight
      add constraint reported_flight_execution_status_chk
      check (execution_status in ('planned', 'ready', 'executing', 'completed', 'cancelled', 'unknown'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'reported_flight_source_unique'
      and conrelid = 'flight_plan.reported_flight'::regclass
  ) then
    alter table flight_plan.reported_flight
      add constraint reported_flight_source_unique unique (source_system, source_record_id);
  end if;
end;
$$;

create index if not exists reported_flight_time_idx
  on flight_plan.reported_flight(planned_start_at, planned_end_at);

create index if not exists reported_flight_status_idx
  on flight_plan.reported_flight(filing_status, execution_status);

create index if not exists reported_flight_aircraft_idx
  on flight_plan.reported_flight(aircraft_id);

create index if not exists reported_flight_route_result_idx
  on flight_plan.reported_flight(route_result_id);

create index if not exists reported_flight_reporting_unit_idx
  on flight_plan.reported_flight(reporting_unit_name);

drop trigger if exists reported_flight_touch_updated_at on flight_plan.reported_flight;
create trigger reported_flight_touch_updated_at
before update on flight_plan.reported_flight
for each row execute function flight_plan.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Inspection tasks / 巡查任务
-- -----------------------------------------------------------------------------
create table if not exists flight_plan.inspection_task (
  id bigserial primary key,

  source_system text,
  source_task_id text,

  task_no text,
  task_name text not null,
  task_type text not null,
  responsible_unit_name text not null,

  aircraft_id bigint references flight_plan.aircraft_asset(id),
  aircraft_name_snapshot text,

  planned_start_at timestamptz not null,
  planned_end_at timestamptz not null,
  actual_start_at timestamptz,
  actual_end_at timestamptz,

  task_status text not null default 'planned',
  priority text not null default 'normal',

  -- Optional linkage to a computed route result. The task can be created before
  -- route planning is complete.
  route_result_id bigint references flight_path.plan_result(id),

  task_area geometry(MultiPolygon, 4326),

  remark text,
  source_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table flight_plan.inspection_task is '巡查任务: planned or synchronized UAV patrol/inspection task for large-screen display and decision support.';
comment on column flight_plan.inspection_task.source_system is 'External task source system code when synchronized; local/manual records may leave it null.';
comment on column flight_plan.inspection_task.source_task_id is 'Stable task id in the external source system; use with source_system for PostgREST upsert.';
comment on column flight_plan.inspection_task.task_no is 'Human-facing task number.';
comment on column flight_plan.inspection_task.task_name is '巡查任务名称 shown on the large screen.';
comment on column flight_plan.inspection_task.task_type is '巡查任务类型, such as forest_patrol, route_patrol, emergency_review, or other project-defined codes.';
comment on column flight_plan.inspection_task.responsible_unit_name is 'Responsible unit name as display text; units are not normalized in this module.';
comment on column flight_plan.inspection_task.task_status is 'Task execution status: planned, ready, executing, completed, cancelled, aborted, or unknown.';
comment on column flight_plan.inspection_task.priority is 'Display priority: low, normal, high, or urgent.';
comment on column flight_plan.inspection_task.route_result_id is 'Optional flight_path.plan_result id used to preview the route and GGER grid.';
comment on column flight_plan.inspection_task.task_area is 'Optional patrol responsibility area in WGS84; route_result_id remains the route preview source.';
comment on column flight_plan.inspection_task.source_payload is 'Original or normalized source payload retained for traceability.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inspection_task_time_chk'
      and conrelid = 'flight_plan.inspection_task'::regclass
  ) then
    alter table flight_plan.inspection_task
      add constraint inspection_task_time_chk check (planned_end_at > planned_start_at);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'inspection_task_actual_time_chk'
      and conrelid = 'flight_plan.inspection_task'::regclass
  ) then
    alter table flight_plan.inspection_task
      add constraint inspection_task_actual_time_chk
      check (actual_end_at is null or actual_start_at is null or actual_end_at >= actual_start_at);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'inspection_task_status_chk'
      and conrelid = 'flight_plan.inspection_task'::regclass
  ) then
    alter table flight_plan.inspection_task
      add constraint inspection_task_status_chk
      check (task_status in ('planned', 'ready', 'executing', 'completed', 'cancelled', 'aborted', 'unknown'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'inspection_task_priority_chk'
      and conrelid = 'flight_plan.inspection_task'::regclass
  ) then
    alter table flight_plan.inspection_task
      add constraint inspection_task_priority_chk
      check (priority in ('low', 'normal', 'high', 'urgent'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'inspection_task_source_unique'
      and conrelid = 'flight_plan.inspection_task'::regclass
  ) then
    alter table flight_plan.inspection_task
      add constraint inspection_task_source_unique unique (source_system, source_task_id);
  end if;
end;
$$;

create index if not exists inspection_task_time_idx
  on flight_plan.inspection_task(planned_start_at, planned_end_at);

create index if not exists inspection_task_status_idx
  on flight_plan.inspection_task(task_status);

create index if not exists inspection_task_type_idx
  on flight_plan.inspection_task(task_type);

create index if not exists inspection_task_aircraft_idx
  on flight_plan.inspection_task(aircraft_id);

create index if not exists inspection_task_route_result_idx
  on flight_plan.inspection_task(route_result_id);

create index if not exists inspection_task_responsible_unit_idx
  on flight_plan.inspection_task(responsible_unit_name);

create index if not exists inspection_task_area_gix
  on flight_plan.inspection_task using gist(task_area);

drop trigger if exists inspection_task_touch_updated_at on flight_plan.inspection_task;
create trigger inspection_task_touch_updated_at
before update on flight_plan.inspection_task
for each row execute function flight_plan.touch_updated_at();

-- -----------------------------------------------------------------------------
-- API facade: resource CRUD views
-- -----------------------------------------------------------------------------
create or replace view api.aircraft_assets as
select
  id,
  source_system,
  source_aircraft_id,
  asset_code,
  name,
  model,
  serial_no,
  owner_unit_name,
  availability_status,
  metadata,
  created_at,
  updated_at
from flight_plan.aircraft_asset;

create or replace view api.reported_flights as
select
  id,
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
  metadata,
  ingested_at,
  created_at,
  updated_at
from flight_plan.reported_flight;

create or replace view api.inspection_tasks as
select
  id,
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
  metadata,
  created_at,
  updated_at
from flight_plan.inspection_task;

-- -----------------------------------------------------------------------------
-- API facade: unified read models
-- -----------------------------------------------------------------------------
create or replace view api.flight_activities as
select
  'reported_flight'::text as activity_type,
  rf.id as activity_id,
  rf.report_no as activity_no,
  coalesce(rf.title, rf.report_no, '报备飞行') as activity_name,
  rf.reporting_unit_name as unit_name,
  rf.aircraft_id,
  coalesce(a.name, rf.aircraft_name_snapshot) as aircraft_name,
  rf.planned_start_at,
  rf.planned_end_at,
  null::timestamptz as actual_start_at,
  null::timestamptz as actual_end_at,
  rf.execution_status as activity_status,
  rf.filing_status,
  rf.route_result_id,
  pr.plan_id as route_plan_id,
  (rf.route_result_id is not null) as has_route,
  rf.created_at,
  rf.updated_at
from flight_plan.reported_flight rf
left join flight_plan.aircraft_asset a on a.id = rf.aircraft_id
left join flight_path.plan_result pr on pr.id = rf.route_result_id

union all

select
  'inspection_task'::text as activity_type,
  it.id as activity_id,
  it.task_no as activity_no,
  it.task_name as activity_name,
  it.responsible_unit_name as unit_name,
  it.aircraft_id,
  coalesce(a.name, it.aircraft_name_snapshot) as aircraft_name,
  it.planned_start_at,
  it.planned_end_at,
  it.actual_start_at,
  it.actual_end_at,
  it.task_status as activity_status,
  null::text as filing_status,
  it.route_result_id,
  pr.plan_id as route_plan_id,
  (it.route_result_id is not null) as has_route,
  it.created_at,
  it.updated_at
from flight_plan.inspection_task it
left join flight_plan.aircraft_asset a on a.id = it.aircraft_id
left join flight_path.plan_result pr on pr.id = it.route_result_id;

create or replace view api.flight_activity_route_previews as
select
  fa.activity_type,
  fa.activity_id,
  fa.activity_no,
  fa.activity_name,
  fa.unit_name,
  fa.aircraft_id,
  fa.aircraft_name,
  fa.planned_start_at,
  fa.planned_end_at,
  fa.activity_status,
  fa.filing_status,
  fa.has_route,

  fa.route_plan_id,
  fa.route_result_id,
  pr.result_status,
  pr.distance_m,
  pr.duration_s,
  pr.grid_cell_count,
  pr.traj_point_count,
  pr.segment_count,
  pr.error_message,

  case when pr.route_geom is null then null else ST_AsGeoJSON(pr.route_geom)::jsonb end as route_geojson,
  case when pr.smooth_route_geom is null then null else ST_AsGeoJSON(pr.smooth_route_geom)::jsonb end as smooth_route_geojson,
  case when pr.grid_path is null then null else ST_AsText(ST_AsGrids(pr.grid_path), 'GGER') end as route_grid_gger,
  case when pr.grid_path is null then null else ST_WithBox(ST_AsGrids(pr.grid_path), 'GGER')::jsonb end as route_grid_with_box,

  pr.created_at as route_created_at
from api.flight_activities fa
left join flight_path.plan_result pr on pr.id = fa.route_result_id;

comment on view api.aircraft_assets is '无人机资产 API 资源，支持 PostgREST 原生查询、新增、更新和删除，用于飞行计划展示和飞行器状态统计。';
comment on view api.reported_flights is '报备飞行 API 资源，保存外部接入的报备/审批结果展示数据；本系统不承载审批流程。';
comment on view api.inspection_tasks is '巡查任务 API 资源，保存大屏展示和辅助决策使用的无人机巡查任务。';
comment on view api.flight_activities is '统一飞行活动只读视图，将报备飞行和巡查任务合并为大屏列表与统计入口。';
comment on view api.flight_activity_route_previews is '飞行活动航线预览只读视图；当活动绑定 flight_path.plan_result 时返回 GeoJSON 航线和 GGER 网格包围盒。';

comment on column api.aircraft_assets.id is '无人机资产主键。';
comment on column api.aircraft_assets.source_system is '外部资产来源系统编码；本地维护的数据可为空。';
comment on column api.aircraft_assets.source_aircraft_id is '外部来源系统中的无人机资产 ID，可与 source_system 组成 upsert 键。';
comment on column api.aircraft_assets.asset_code is '面向业务展示的无人机资产编号。';
comment on column api.aircraft_assets.name is '无人机资产显示名称。';
comment on column api.aircraft_assets.model is '无人机型号。';
comment on column api.aircraft_assets.serial_no is '无人机序列号。';
comment on column api.aircraft_assets.owner_unit_name is '所属或管理单位名称快照。';
comment on column api.aircraft_assets.availability_status is '无人机可用状态：idle 空闲、in_task 任务中、maintenance 维护、offline 离线、unknown 未知。';
comment on column api.aircraft_assets.metadata is '扩展属性 JSON，用于保留暂未结构化的来源字段。';

comment on column api.reported_flights.id is '报备飞行主键。';
comment on column api.reported_flights.source_system is '外部报备来源系统编码。';
comment on column api.reported_flights.source_record_id is '外部来源系统中的报备记录 ID，可与 source_system 组成 upsert 键。';
comment on column api.reported_flights.report_no is '外部报备编号。';
comment on column api.reported_flights.title is '报备飞行展示标题。';
comment on column api.reported_flights.reporting_unit_name is '报备单位名称快照。';
comment on column api.reported_flights.pilot_name is '飞手姓名快照；飞手不在本系统单独建表。';
comment on column api.reported_flights.pilot_phone is '飞手联系电话快照。';
comment on column api.reported_flights.pilot_license_no is '飞手证照编号快照。';
comment on column api.reported_flights.aircraft_id is '关联的无人机资产 ID，可为空。';
comment on column api.reported_flights.aircraft_name_snapshot is '报备来源中的无人机名称快照，用于未匹配资产时展示。';
comment on column api.reported_flights.planned_start_at is '计划飞行开始时间。';
comment on column api.reported_flights.planned_end_at is '计划飞行结束时间。';
comment on column api.reported_flights.filing_status is '外部报备/审批状态，仅用于展示：reported、approved、rejected、cancelled、expired、unknown。';
comment on column api.reported_flights.execution_status is '飞行执行展示状态：planned、ready、executing、completed、cancelled、unknown。';
comment on column api.reported_flights.route_result_id is '可选航线结果 ID，关联 flight_path.plan_result；为空表示暂未绑定航线。';
comment on column api.reported_flights.remark is '备注。';
comment on column api.reported_flights.source_payload is '来源系统原始或归一化载荷 JSON，用于追溯。';
comment on column api.reported_flights.metadata is '扩展属性 JSON。';
comment on column api.reported_flights.ingested_at is '数据接入时间。';

comment on column api.inspection_tasks.id is '巡查任务主键。';
comment on column api.inspection_tasks.source_system is '外部任务来源系统编码；本地维护的数据可为空。';
comment on column api.inspection_tasks.source_task_id is '外部来源系统中的任务 ID，可与 source_system 组成 upsert 键。';
comment on column api.inspection_tasks.task_no is '巡查任务编号。';
comment on column api.inspection_tasks.task_name is '巡查任务名称。';
comment on column api.inspection_tasks.task_type is '巡查任务类型，例如 forest_patrol、route_patrol、emergency_review。';
comment on column api.inspection_tasks.responsible_unit_name is '责任单位名称快照。';
comment on column api.inspection_tasks.aircraft_id is '关联的无人机资产 ID，可为空。';
comment on column api.inspection_tasks.aircraft_name_snapshot is '任务来源中的无人机名称快照，用于未匹配资产时展示。';
comment on column api.inspection_tasks.planned_start_at is '计划巡查开始时间。';
comment on column api.inspection_tasks.planned_end_at is '计划巡查结束时间。';
comment on column api.inspection_tasks.actual_start_at is '实际开始时间，可为空。';
comment on column api.inspection_tasks.actual_end_at is '实际结束时间，可为空。';
comment on column api.inspection_tasks.task_status is '巡查任务状态：planned、ready、executing、completed、cancelled、aborted、unknown。';
comment on column api.inspection_tasks.priority is '任务优先级：low、normal、high、urgent。';
comment on column api.inspection_tasks.route_result_id is '可选航线结果 ID，关联 flight_path.plan_result；为空表示暂未绑定航线。';
comment on column api.inspection_tasks.task_area is '巡查责任区几何范围，WGS84 MultiPolygon，可为空。';
comment on column api.inspection_tasks.remark is '备注。';
comment on column api.inspection_tasks.source_payload is '来源系统原始或归一化载荷 JSON，用于追溯。';
comment on column api.inspection_tasks.metadata is '扩展属性 JSON。';

comment on column api.flight_activities.activity_type is '飞行活动类型：reported_flight 表示报备飞行，inspection_task 表示巡查任务。';
comment on column api.flight_activities.activity_id is '来源活动表中的主键 ID。';
comment on column api.flight_activities.activity_no is '统一活动编号，来自报备编号或任务编号。';
comment on column api.flight_activities.activity_name is '统一活动名称，来自报备标题或巡查任务名称。';
comment on column api.flight_activities.unit_name is '报备单位或巡查责任单位名称。';
comment on column api.flight_activities.aircraft_id is '关联无人机资产 ID。';
comment on column api.flight_activities.aircraft_name is '无人机展示名称，优先使用资产名称，缺失时使用来源快照名称。';
comment on column api.flight_activities.planned_start_at is '计划开始时间。';
comment on column api.flight_activities.planned_end_at is '计划结束时间。';
comment on column api.flight_activities.actual_start_at is '实际开始时间；报备飞行当前为空。';
comment on column api.flight_activities.actual_end_at is '实际结束时间；报备飞行当前为空。';
comment on column api.flight_activities.activity_status is '统一活动状态：报备飞行取 execution_status，巡查任务取 task_status。';
comment on column api.flight_activities.filing_status is '外部报备状态；巡查任务为空。';
comment on column api.flight_activities.route_result_id is '绑定的 flight_path.plan_result ID；为空表示无航线预览。';
comment on column api.flight_activities.route_plan_id is '绑定航线结果所属的 flight_path.plan ID。';
comment on column api.flight_activities.has_route is '是否已绑定航线结果。';
comment on column api.flight_activity_route_previews.route_grid_gger is '绑定航线网格路径的 GGER 文本表示；未绑定航线时为空。';
comment on column api.flight_activity_route_previews.route_grid_with_box is '带包围盒的 GGER 网格单元 JSON，供 Cesium/三维前端绘制；未绑定航线时为空。';

-- -----------------------------------------------------------------------------
-- API facade: one stats RPC for dashboard cards
-- -----------------------------------------------------------------------------
create or replace function api.get_flight_plan_stats(
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language sql
stable
set search_path = api, flight_plan, public, pg_temp
as $$
with bounds as (
  select p_start_at as start_at, p_end_at as end_at
), activity as (
  select fa.*
  from api.flight_activities fa, bounds b
  where fa.planned_start_at < b.end_at
    and fa.planned_end_at > b.start_at
), eligible_activity as (
  select *
  from activity
  where activity_status not in ('cancelled', 'aborted', 'unknown')
    and (
      activity_type <> 'reported_flight'
      or coalesce(filing_status, 'unknown') not in ('rejected', 'cancelled', 'expired', 'unknown')
    )
), aircraft_in_task as (
  select count(distinct aircraft_id) as value
  from activity
  where aircraft_id is not null
    and activity_status = 'executing'
), aircraft_idle as (
  select count(*) as value
  from flight_plan.aircraft_asset a
  where a.availability_status = 'idle'
    and not exists (
      select 1
      from api.flight_activities fa
      where fa.aircraft_id = a.id
        and fa.activity_status = 'executing'
    )
)
select jsonb_build_object(
  'approved_reported_flight_count', coalesce(count(*) filter (
    where activity_type = 'reported_flight'
      and filing_status = 'approved'
  ), 0),
  'total_flight_count', coalesce((select count(*) from eligible_activity), 0),
  'pending_flight_count', coalesce((
    select count(*)
    from eligible_activity
    where activity_status in ('planned', 'ready')
  ), 0),
  'inspection_task_count', coalesce((
    select count(*)
    from eligible_activity
    where activity_type = 'inspection_task'
  ), 0),
  'aircraft_in_task_count', (select value from aircraft_in_task),
  'aircraft_idle_count', (select value from aircraft_idle),
  'start_at', p_start_at,
  'end_at', p_end_at
)
from activity;
$$;

comment on function api.get_flight_plan_stats(timestamptz, timestamptz) is '按明确时间窗口返回飞行计划大屏统计指标。参数：p_start_at、p_end_at；统计采用时间区间重叠口径。';

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant usage on schema flight_plan to admin;
grant select, insert, update, delete on table flight_plan.aircraft_asset to admin;
grant select, insert, update, delete on table flight_plan.reported_flight to admin;
grant select, insert, update, delete on table flight_plan.inspection_task to admin;
grant usage, select, update on all sequences in schema flight_plan to admin;
grant execute on all functions in schema flight_plan to admin;

-- Keep the API facade JWT-protected. Anonymous can see the schema but receives
-- no business table/function privileges.
revoke all on all tables in schema api from public;
revoke all on all functions in schema api from public;
revoke all on all tables in schema api from anonymous;
revoke all on all functions in schema api from anonymous;

grant usage on schema api to anonymous;
grant usage on schema api to admin;
grant select, insert, update, delete on api.aircraft_assets to admin;
grant select, insert, update, delete on api.reported_flights to admin;
grant select, insert, update, delete on api.inspection_tasks to admin;
grant select on api.flight_activities to admin;
grant select on api.flight_activity_route_previews to admin;
grant execute on function api.get_flight_plan_stats(timestamptz, timestamptz) to admin;

alter default privileges for role postgres in schema flight_plan
  grant select, insert, update, delete on tables to admin;
alter default privileges for role postgres in schema flight_plan
  grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema flight_plan
  grant execute on functions to admin;

notify pgrst, 'reload schema';

commit;
