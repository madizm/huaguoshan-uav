-- 应急力量模拟数据模型。
--
-- 数据范围：花果山风景区 WGS84 矩形范围
--   longitude: [119.23062143399773, 119.30584735009370]
--   latitude:  [34.630255366340634, 34.66401112992460]
--
-- 所有种子记录均明确标记为模拟数据，且 geometry 为 Point / EPSG:4326。
-- PostgREST 仅公开 api 架构；下方七个 api 视图是可更新的 CRUD 资源。

begin;

create extension if not exists postgis;

create schema if not exists emergency_resource;

comment on schema emergency_resource is '花果山景区应急力量、医疗资源、专家、避难场所、物资保障和应急保障点位的模拟数据。';

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
-- 救援力量
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.rescue_force (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  force_type text not null,
  unit_name text not null,
  commander_name text,
  contact_phone text,
  personnel_count integer not null default 0 check (personnel_count >= 0),
  availability_status text not null default 'available'
    check (availability_status in ('available', 'deployed', 'standby', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.rescue_force is '可用于灾害应急场景的救援队伍或保障力量；当前记录均为模拟数据。';
comment on column emergency_resource.rescue_force.source_code is '模拟或外部来源中的稳定记录编码。';
comment on column emergency_resource.rescue_force.force_type is '救援力量类型，如 forest_fire、rescue、ranger、volunteer。';
comment on column emergency_resource.rescue_force.availability_status is '可用状态：available 可调度、deployed 已出动、standby 待命、unavailable 不可用。';
comment on column emergency_resource.rescue_force.geom is '救援力量驻点位置，WGS84 Point（EPSG:4326）。';

create index if not exists rescue_force_geom_gix on emergency_resource.rescue_force using gist (geom);
create index if not exists rescue_force_status_idx on emergency_resource.rescue_force (availability_status);

drop trigger if exists rescue_force_touch_updated_at on emergency_resource.rescue_force;
create trigger rescue_force_touch_updated_at
before update on emergency_resource.rescue_force
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 医疗资源
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.medical_resource (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  resource_type text not null,
  unit_name text not null,
  contact_phone text,
  service_capacity integer not null default 0 check (service_capacity >= 0),
  ambulance_count integer not null default 0 check (ambulance_count >= 0),
  availability_status text not null default 'available'
    check (availability_status in ('available', 'busy', 'standby', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.medical_resource is '医疗救护站、医疗点和救护车辆等医疗保障资源；当前记录均为模拟数据。';
comment on column emergency_resource.medical_resource.resource_type is '医疗资源类型，如 clinic、first_aid_station、ambulance_station。';
comment on column emergency_resource.medical_resource.service_capacity is '单次可服务或接纳人数，用于应急态势估算。';
comment on column emergency_resource.medical_resource.geom is '医疗资源位置，WGS84 Point（EPSG:4326）。';

create index if not exists medical_resource_geom_gix on emergency_resource.medical_resource using gist (geom);
create index if not exists medical_resource_status_idx on emergency_resource.medical_resource (availability_status);

drop trigger if exists medical_resource_touch_updated_at on emergency_resource.medical_resource;
create trigger medical_resource_touch_updated_at
before update on emergency_resource.medical_resource
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 专家力量
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.expert_force (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  expertise text not null,
  organization_name text not null,
  professional_title text,
  contact_phone text,
  availability_status text not null default 'available'
    check (availability_status in ('available', 'consulting', 'standby', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.expert_force is '可参与灾害研判、现场处置和应急技术支持的专家力量；当前记录均为模拟数据。';
comment on column emergency_resource.expert_force.expertise is '专家专业方向，如森林防火、地质灾害、医疗救援、无人机巡查。';
comment on column emergency_resource.expert_force.geom is '专家常驻或集结位置，WGS84 Point（EPSG:4326）。';

create index if not exists expert_force_geom_gix on emergency_resource.expert_force using gist (geom);
create index if not exists expert_force_status_idx on emergency_resource.expert_force (availability_status);

drop trigger if exists expert_force_touch_updated_at on emergency_resource.expert_force;
create trigger expert_force_touch_updated_at
before update on emergency_resource.expert_force
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 避难场所
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.shelter (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  venue_type text not null,
  managing_unit_name text not null,
  contact_phone text,
  capacity integer not null check (capacity > 0),
  current_occupancy integer not null default 0 check (current_occupancy >= 0 and current_occupancy <= capacity),
  availability_status text not null default 'available'
    check (availability_status in ('available', 'preparing', 'occupied', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.shelter is '面向游客和受灾人员疏散安置的避难场所；当前记录均为模拟数据。';
comment on column emergency_resource.shelter.venue_type is '场所类型，如 square、parking_area、visitor_center、school。';
comment on column emergency_resource.shelter.capacity is '避难场所最大安置容量，单位为人。';
comment on column emergency_resource.shelter.geom is '避难场所中心位置，WGS84 Point（EPSG:4326）。';

create index if not exists shelter_geom_gix on emergency_resource.shelter using gist (geom);
create index if not exists shelter_status_idx on emergency_resource.shelter (availability_status);

drop trigger if exists shelter_touch_updated_at on emergency_resource.shelter;
create trigger shelter_touch_updated_at
before update on emergency_resource.shelter
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 物资仓库
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.material_warehouse (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  warehouse_type text not null,
  managing_unit_name text not null,
  contact_phone text,
  storage_capacity_t numeric(12, 2) not null default 0 check (storage_capacity_t >= 0),
  inventory_summary jsonb not null default '{}'::jsonb,
  availability_status text not null default 'available'
    check (availability_status in ('available', 'dispatching', 'restocking', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.material_warehouse is '储备应急物资并可向灾害现场调拨的仓库；当前记录均为模拟数据。';
comment on column emergency_resource.material_warehouse.warehouse_type is '仓库保障类型，如 comprehensive、firefighting、medical、daily_necessities。';
comment on column emergency_resource.material_warehouse.inventory_summary is '物资库存摘要 JSON，例如水、灭火器材、食品和医疗包数量。';
comment on column emergency_resource.material_warehouse.geom is '物资仓库位置，WGS84 Point（EPSG:4326）。';

create index if not exists material_warehouse_geom_gix on emergency_resource.material_warehouse using gist (geom);
create index if not exists material_warehouse_status_idx on emergency_resource.material_warehouse (availability_status);

drop trigger if exists material_warehouse_touch_updated_at on emergency_resource.material_warehouse;
create trigger material_warehouse_touch_updated_at
before update on emergency_resource.material_warehouse
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 取水点
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.water_point (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  water_source_type text not null,
  managing_unit_name text,
  contact_phone text,
  estimated_supply_m3_h numeric(12, 2) not null default 0 check (estimated_supply_m3_h >= 0),
  availability_status text not null default 'available'
    check (availability_status in ('available', 'limited', 'maintenance', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.water_point is '消防、救援或生活保障可使用的应急取水点；当前记录均为模拟数据。';
comment on column emergency_resource.water_point.water_source_type is '水源类型，如 reservoir、pond、hydrant、stream。';
comment on column emergency_resource.water_point.estimated_supply_m3_h is '估算供水能力，单位立方米/小时。';
comment on column emergency_resource.water_point.geom is '取水点位置，WGS84 Point（EPSG:4326）。';

create index if not exists water_point_geom_gix on emergency_resource.water_point using gist (geom);
create index if not exists water_point_status_idx on emergency_resource.water_point (availability_status);

drop trigger if exists water_point_touch_updated_at on emergency_resource.water_point;
create trigger water_point_touch_updated_at
before update on emergency_resource.water_point
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 起降点
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.landing_site (
  id bigserial primary key,
  source_code text not null unique,
  name text not null,
  site_type text not null,
  managing_unit_name text not null,
  contact_phone text,
  max_aircraft_count integer not null default 1 check (max_aircraft_count > 0),
  availability_status text not null default 'available'
    check (availability_status in ('available', 'occupied', 'standby', 'maintenance', 'unavailable')),
  is_simulated boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  geom geometry(Point, 4326) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.landing_site is '供应急无人机或直升机起飞、降落和临时集结的保障点位；当前记录均为模拟数据。';
comment on column emergency_resource.landing_site.site_type is '起降点类型，如 uav_pad、helicopter_pad、temporary_landing_zone。';
comment on column emergency_resource.landing_site.max_aircraft_count is '可同时保障的飞行器数量。';
comment on column emergency_resource.landing_site.geom is '起降点位置，WGS84 Point（EPSG:4326）。';

create index if not exists landing_site_geom_gix on emergency_resource.landing_site using gist (geom);
create index if not exists landing_site_status_idx on emergency_resource.landing_site (availability_status);

drop trigger if exists landing_site_touch_updated_at on emergency_resource.landing_site;
create trigger landing_site_touch_updated_at
before update on emergency_resource.landing_site
for each row execute function emergency_resource.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 花果山景区模拟数据。所有坐标均随机散落在脚本顶部声明的景区范围内。
-- -----------------------------------------------------------------------------
insert into emergency_resource.rescue_force (
  source_code, name, force_type, unit_name, commander_name, contact_phone,
  personnel_count, availability_status, metadata, geom
) values
  ('SIM-RESCUE-001', '花果山森林消防中队', 'forest_fire', '花果山景区应急管理中心', '张建军', '13800001001', 36, 'available', '{"scenario":"forest_fire","simulated":true}', ST_SetSRID(ST_MakePoint(119.24682, 34.65364), 4326)),
  ('SIM-RESCUE-002', '北坡山地救援队', 'rescue', '花果山景区应急管理中心', '李晨', '13800001002', 22, 'standby', '{"scenario":"mountain_rescue","simulated":true}', ST_SetSRID(ST_MakePoint(119.27351, 34.65982), 4326)),
  ('SIM-RESCUE-003', '南天门巡护救援组', 'ranger', '花果山森林防火巡查队', '王海', '13800001003', 16, 'available', '{"scenario":"forest_patrol","simulated":true}', ST_SetSRID(ST_MakePoint(119.29816, 34.63793), 4326)),
  ('SIM-RESCUE-004', '云台山应急救援队', 'rescue', '云台街道综合应急队', '赵强', '13800001004', 28, 'deployed', '{"scenario":"comprehensive_rescue","simulated":true}', ST_SetSRID(ST_MakePoint(119.23691, 34.64387), 4326)),
  ('SIM-RESCUE-005', '景区志愿救援服务队', 'volunteer', '花果山景区管理处', '陈敏', '13800001005', 45, 'available', '{"scenario":"tourist_evacuation","simulated":true}', ST_SetSRID(ST_MakePoint(119.28642, 34.65521), 4326))
on conflict (source_code) do update set
  name = excluded.name, force_type = excluded.force_type, unit_name = excluded.unit_name,
  commander_name = excluded.commander_name, contact_phone = excluded.contact_phone,
  personnel_count = excluded.personnel_count, availability_status = excluded.availability_status,
  metadata = excluded.metadata, geom = excluded.geom, is_simulated = true;

insert into emergency_resource.medical_resource (
  source_code, name, resource_type, unit_name, contact_phone, service_capacity,
  ambulance_count, availability_status, metadata, geom
) values
  ('SIM-MEDICAL-001', '花果山游客中心医疗点', 'clinic', '花果山景区医疗保障组', '13800002001', 24, 1, 'available', '{"simulated":true,"equipment":"AED、急救包"}', ST_SetSRID(ST_MakePoint(119.25814, 34.64827), 4326)),
  ('SIM-MEDICAL-002', '北坡森林防火医疗保障站', 'first_aid_station', '花果山景区医疗保障组', '13800002002', 12, 1, 'standby', '{"simulated":true,"equipment":"担架、氧气瓶"}', ST_SetSRID(ST_MakePoint(119.28175, 34.66109), 4326)),
  ('SIM-MEDICAL-003', '南坡应急救护站', 'first_aid_station', '花果山景区医疗保障组', '13800002003', 16, 1, 'available', '{"simulated":true,"equipment":"急救包、除颤仪"}', ST_SetSRID(ST_MakePoint(119.30234, 34.63498), 4326)),
  ('SIM-MEDICAL-004', '云台街道医疗救援点', 'clinic', '云台街道卫生服务中心', '13800002004', 30, 2, 'busy', '{"simulated":true,"equipment":"救护车、急救床位"}', ST_SetSRID(ST_MakePoint(119.24067, 34.63742), 4326))
on conflict (source_code) do update set
  name = excluded.name, resource_type = excluded.resource_type, unit_name = excluded.unit_name,
  contact_phone = excluded.contact_phone, service_capacity = excluded.service_capacity,
  ambulance_count = excluded.ambulance_count, availability_status = excluded.availability_status,
  metadata = excluded.metadata, geom = excluded.geom, is_simulated = true;

insert into emergency_resource.expert_force (
  source_code, name, expertise, organization_name, professional_title,
  contact_phone, availability_status, metadata, geom
) values
  ('SIM-EXPERT-001', '刘峰', '森林防火', '连云港市森林防火技术服务队', '高级工程师', '13800003001', 'available', '{"simulated":true,"on_call":true}', ST_SetSRID(ST_MakePoint(119.26788, 34.65594), 4326)),
  ('SIM-EXPERT-002', '周岚', '地质灾害', '连云港市地质环境监测中心', '高级工程师', '13800003002', 'consulting', '{"simulated":true,"on_call":true}', ST_SetSRID(ST_MakePoint(119.29451, 34.64673), 4326)),
  ('SIM-EXPERT-003', '孙伟', '医疗救援', '连云港市急救中心', '主任医师', '13800003003', 'available', '{"simulated":true,"on_call":true}', ST_SetSRID(ST_MakePoint(119.24893, 34.63246), 4326)),
  ('SIM-EXPERT-004', '吴宁', '无人机巡查', '低空应急技术保障组', '高级工程师', '13800003004', 'standby', '{"simulated":true,"on_call":true}', ST_SetSRID(ST_MakePoint(119.27624, 34.64155), 4326)),
  ('SIM-EXPERT-005', '马晓', '旅游疏散', '花果山景区管理处', '应急管理师', '13800003005', 'available', '{"simulated":true,"on_call":true}', ST_SetSRID(ST_MakePoint(119.23218, 34.65831), 4326))
on conflict (source_code) do update set
  name = excluded.name, expertise = excluded.expertise, organization_name = excluded.organization_name,
  professional_title = excluded.professional_title, contact_phone = excluded.contact_phone,
  availability_status = excluded.availability_status, metadata = excluded.metadata,
  geom = excluded.geom, is_simulated = true;

insert into emergency_resource.shelter (
  source_code, name, venue_type, managing_unit_name, contact_phone, capacity,
  current_occupancy, availability_status, metadata, geom
) values
  ('SIM-SHELTER-001', '花果山游客中心疏散广场', 'square', '花果山景区管理处', '13800004001', 1200, 80, 'available', '{"simulated":true,"facilities":"广播、照明、卫生间"}', ST_SetSRID(ST_MakePoint(119.26173, 34.64618), 4326)),
  ('SIM-SHELTER-002', '北坡停车场避难场所', 'parking_area', '花果山景区管理处', '13800004002', 800, 0, 'preparing', '{"simulated":true,"facilities":"停车位、应急照明"}', ST_SetSRID(ST_MakePoint(119.28537, 34.66018), 4326)),
  ('SIM-SHELTER-003', '玉女峰广场避难场所', 'square', '花果山景区管理处', '13800004003', 500, 135, 'available', '{"simulated":true,"facilities":"广播、饮水点"}', ST_SetSRID(ST_MakePoint(119.30042, 34.65132), 4326)),
  ('SIM-SHELTER-004', '南坡游客服务站避难场所', 'visitor_center', '花果山景区管理处', '13800004004', 320, 0, 'available', '{"simulated":true,"facilities":"医疗点、应急物资"}', ST_SetSRID(ST_MakePoint(119.24325, 34.63476), 4326))
on conflict (source_code) do update set
  name = excluded.name, venue_type = excluded.venue_type, managing_unit_name = excluded.managing_unit_name,
  contact_phone = excluded.contact_phone, capacity = excluded.capacity,
  current_occupancy = excluded.current_occupancy, availability_status = excluded.availability_status,
  metadata = excluded.metadata, geom = excluded.geom, is_simulated = true;

insert into emergency_resource.material_warehouse (
  source_code, name, warehouse_type, managing_unit_name, contact_phone,
  storage_capacity_t, inventory_summary, availability_status, metadata, geom
) values
  ('SIM-WAREHOUSE-001', '花果山综合应急物资仓库', 'comprehensive', '花果山景区应急管理中心', '13800005001', 85.00, '{"饮用水":1200,"应急照明":180,"帐篷":90,"食品包":600}', 'available', '{"simulated":true}', ST_SetSRID(ST_MakePoint(119.25264, 34.65092), 4326)),
  ('SIM-WAREHOUSE-002', '北坡森林消防物资库', 'firefighting', '花果山森林防火巡查队', '13800005002', 60.00, '{"高压水泵":8,"灭火器":160,"风力灭火机":35,"阻燃服":50}', 'dispatching', '{"simulated":true}', ST_SetSRID(ST_MakePoint(119.27866, 34.66315), 4326)),
  ('SIM-WAREHOUSE-003', '南坡医疗救灾物资库', 'medical', '花果山景区医疗保障组', '13800005003', 32.50, '{"急救包":150,"担架":30,"折叠床":80,"口罩":3000}', 'available', '{"simulated":true}', ST_SetSRID(ST_MakePoint(119.30428, 34.63974), 4326)),
  ('SIM-WAREHOUSE-004', '西入口生活保障仓库', 'daily_necessities', '花果山景区管理处', '13800005004', 48.00, '{"饮用水":800,"毛毯":300,"发电机":12,"食品包":450}', 'restocking', '{"simulated":true}', ST_SetSRID(ST_MakePoint(119.23486, 34.64541), 4326))
on conflict (source_code) do update set
  name = excluded.name, warehouse_type = excluded.warehouse_type, managing_unit_name = excluded.managing_unit_name,
  contact_phone = excluded.contact_phone, storage_capacity_t = excluded.storage_capacity_t,
  inventory_summary = excluded.inventory_summary, availability_status = excluded.availability_status,
  metadata = excluded.metadata, geom = excluded.geom, is_simulated = true;

insert into emergency_resource.water_point (
  source_code, name, water_source_type, managing_unit_name, contact_phone,
  estimated_supply_m3_h, availability_status, metadata, geom
) values
  ('SIM-WATER-001', '花果山水库取水点', 'reservoir', '花果山景区管理处', '13800006001', 120.00, 'available', '{"simulated":true,"pump_interface":true}', ST_SetSRID(ST_MakePoint(119.26415, 34.66076), 4326)),
  ('SIM-WATER-002', '北坡消防栓取水点', 'hydrant', '花果山景区应急管理中心', '13800006002', 35.00, 'available', '{"simulated":true,"pump_interface":true}', ST_SetSRID(ST_MakePoint(119.29018, 34.65844), 4326)),
  ('SIM-WATER-003', '南坡溪流取水点', 'stream', '花果山景区管理处', '13800006003', 18.50, 'limited', '{"simulated":true,"seasonal":true}', ST_SetSRID(ST_MakePoint(119.29678, 34.63168), 4326)),
  ('SIM-WATER-004', '西入口蓄水池取水点', 'pond', '花果山景区管理处', '13800006004', 42.00, 'available', '{"simulated":true,"pump_interface":true}', ST_SetSRID(ST_MakePoint(119.23874, 34.64022), 4326)),
  ('SIM-WATER-005', '中部景区消防水池', 'pond', '花果山景区管理处', '13800006005', 55.00, 'maintenance', '{"simulated":true,"pump_interface":true}', ST_SetSRID(ST_MakePoint(119.27193, 34.64686), 4326))
on conflict (source_code) do update set
  name = excluded.name, water_source_type = excluded.water_source_type, managing_unit_name = excluded.managing_unit_name,
  contact_phone = excluded.contact_phone, estimated_supply_m3_h = excluded.estimated_supply_m3_h,
  availability_status = excluded.availability_status, metadata = excluded.metadata,
  geom = excluded.geom, is_simulated = true;

insert into emergency_resource.landing_site (
  source_code, name, site_type, managing_unit_name, contact_phone,
  max_aircraft_count, availability_status, metadata, geom
) values
  ('SIM-LANDING-001', '花果山应急无人机起降场', 'uav_pad', '低空应急技术保障组', '13800007001', 6, 'available', '{"simulated":true,"surface":"hardstand"}', ST_SetSRID(ST_MakePoint(119.25936, 34.65446), 4326)),
  ('SIM-LANDING-002', '北坡临时直升机起降点', 'helicopter_pad', '花果山景区应急管理中心', '13800007002', 2, 'standby', '{"simulated":true,"surface":"grass"}', ST_SetSRID(ST_MakePoint(119.28893, 34.66218), 4326)),
  ('SIM-LANDING-003', '南坡无人机备降点', 'temporary_landing_zone', '低空应急技术保障组', '13800007003', 3, 'occupied', '{"simulated":true,"surface":"hardstand"}', ST_SetSRID(ST_MakePoint(119.30116, 34.63635), 4326)),
  ('SIM-LANDING-004', '西入口应急起降点', 'uav_pad', '低空应急技术保障组', '13800007004', 4, 'available', '{"simulated":true,"surface":"parking_area"}', ST_SetSRID(ST_MakePoint(119.23184, 34.65171), 4326))
on conflict (source_code) do update set
  name = excluded.name, site_type = excluded.site_type, managing_unit_name = excluded.managing_unit_name,
  contact_phone = excluded.contact_phone, max_aircraft_count = excluded.max_aircraft_count,
  availability_status = excluded.availability_status, metadata = excluded.metadata,
  geom = excluded.geom, is_simulated = true;

-- -----------------------------------------------------------------------------
-- PostgREST API 门面：仅 api schema 对 HTTP 暴露。
-- -----------------------------------------------------------------------------
create or replace view api.emergency_rescue_forces as
select * from emergency_resource.rescue_force;

create or replace view api.emergency_medical_resources as
select * from emergency_resource.medical_resource;

create or replace view api.emergency_experts as
select * from emergency_resource.expert_force;

create or replace view api.emergency_shelters as
select * from emergency_resource.shelter;

create or replace view api.emergency_material_warehouses as
select * from emergency_resource.material_warehouse;

create or replace view api.emergency_water_points as
select * from emergency_resource.water_point;

create or replace view api.emergency_landing_sites as
select * from emergency_resource.landing_site;

comment on view api.emergency_rescue_forces is '救援力量 CRUD 资源；数据位于 emergency_resource.rescue_force，当前为花果山景区模拟数据。';
comment on view api.emergency_medical_resources is '医疗资源 CRUD 资源；数据位于 emergency_resource.medical_resource，当前为花果山景区模拟数据。';
comment on view api.emergency_experts is '专家力量 CRUD 资源；数据位于 emergency_resource.expert_force，当前为花果山景区模拟数据。';
comment on view api.emergency_shelters is '避难场所 CRUD 资源；数据位于 emergency_resource.shelter，当前为花果山景区模拟数据。';
comment on view api.emergency_material_warehouses is '物资仓库 CRUD 资源；数据位于 emergency_resource.material_warehouse，当前为花果山景区模拟数据。';
comment on view api.emergency_water_points is '取水点 CRUD 资源；数据位于 emergency_resource.water_point，当前为花果山景区模拟数据。';
comment on view api.emergency_landing_sites is '起降点 CRUD 资源；数据位于 emergency_resource.landing_site，当前为花果山景区模拟数据。';

-- API schema 中的 geometry 字段均为 WGS84 Point，统一保留简洁中文说明。
comment on column api.emergency_rescue_forces.geom is '救援力量驻点位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_medical_resources.geom is '医疗资源位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_experts.geom is '专家常驻或集结位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_shelters.geom is '避难场所中心位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_material_warehouses.geom is '物资仓库位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_water_points.geom is '取水点位置，WGS84 Point（EPSG:4326）。';
comment on column api.emergency_landing_sites.geom is '起降点位置，WGS84 Point（EPSG:4326）。';

-- -----------------------------------------------------------------------------
-- 权限与 schema cache 刷新。
-- -----------------------------------------------------------------------------
grant usage on schema emergency_resource to admin;
grant select, insert, update, delete on all tables in schema emergency_resource to admin;
grant usage, select, update on all sequences in schema emergency_resource to admin;
grant execute on all functions in schema emergency_resource to admin;

alter default privileges for role postgres in schema emergency_resource
  grant select, insert, update, delete on tables to admin;
alter default privileges for role postgres in schema emergency_resource
  grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema emergency_resource
  grant execute on functions to admin;

revoke all on all tables in schema api from public;
revoke all on all tables in schema api from anonymous;
grant usage on schema api to admin;
grant select, insert, update, delete on api.emergency_rescue_forces to admin;
grant select, insert, update, delete on api.emergency_medical_resources to admin;
grant select, insert, update, delete on api.emergency_experts to admin;
grant select, insert, update, delete on api.emergency_shelters to admin;
grant select, insert, update, delete on api.emergency_material_warehouses to admin;
grant select, insert, update, delete on api.emergency_water_points to admin;
grant select, insert, update, delete on api.emergency_landing_sites to admin;

notify pgrst, 'reload schema';

commit;
