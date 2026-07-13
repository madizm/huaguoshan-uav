-- 统一设施设备资产、状态、原始观测、能力覆盖及无人机迁移。
-- 依赖 create_flight_plan_postgrest_api.sql；可安全重复执行。

begin;

create extension if not exists postgis;
create schema if not exists equipment;
create schema if not exists emergency_resource;
create schema if not exists api;

comment on schema equipment is '统一设施设备资产、状态、原始观测和能力覆盖数据域。';

create or replace function equipment.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
comment on function equipment.touch_updated_at() is '更新可变设备记录的 updated_at 时间。返回触发器记录。';

create table if not exists equipment.asset (
  id bigserial primary key,
  asset_code text not null,
  category_code text not null check (category_code in (
    'base_station_6g', 'counter_uas', 'video_surveillance', 'uav',
    'unmanned_vehicle', 'vehicle_surveillance', 'sensor'
  )),
  type_code text,
  name text not null,
  source_system text not null,
  source_asset_id text not null,
  managing_unit_name text,
  deployment_mode text,
  lifecycle_status text not null default 'active',
  geom geometry(Point, 4326) not null,
  elevation_amsl_m numeric,
  height_datum text not null default 'AMSL' check (height_datum = 'AMSL'),
  manufacturer text,
  model text,
  serial_no text,
  is_simulated boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint equipment_asset_code_unique unique (asset_code),
  constraint equipment_asset_source_unique unique (source_system, source_asset_id)
);
comment on table equipment.asset is '七类设施设备共用的统一资产台账。';
comment on column equipment.asset.category_code is '设备类别编码，限定为七类设施设备。';
comment on column equipment.asset.geom is '资产登记位置，WGS84 Point（EPSG:4326）。';
comment on column equipment.asset.elevation_amsl_m is '资产登记位置的 AMSL 高度，单位米。';
comment on column equipment.asset.height_datum is '高度基准，固定为 AMSL。';
comment on column equipment.asset.is_simulated is '是否为模拟资产或使用模拟位置。';
create index if not exists asset_geom_gix on equipment.asset using gist (geom);
create index if not exists asset_category_idx on equipment.asset (category_code);
create index if not exists asset_lifecycle_idx on equipment.asset (lifecycle_status);
drop trigger if exists asset_touch_updated_at on equipment.asset;
create trigger asset_touch_updated_at before update on equipment.asset
for each row execute function equipment.touch_updated_at();

create table if not exists equipment.base_station_6g_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  operator_name text, frequency_band text, bandwidth_mhz numeric check (bandwidth_mhz is null or bandwidth_mhz >= 0), backhaul_type text
);
comment on table equipment.base_station_6g_profile is '6G 基站专业属性。';
create table if not exists equipment.counter_uas_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  detection_mode text, identification_mode text, tracking_mode text, recommendation_notes text
);
comment on table equipment.counter_uas_profile is '反无设备展示与推荐属性，不保存控制命令或密钥。';
create table if not exists equipment.video_surveillance_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  camera_type text, ptz_supported boolean not null default false, optical_zoom numeric check (optical_zoom is null or optical_zoom >= 0), stream_ref text
);
comment on table equipment.video_surveillance_profile is '视频监控专业属性，视频流仅保存安全引用。';
create table if not exists equipment.uav_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  max_takeoff_weight_kg numeric check (max_takeoff_weight_kg is null or max_takeoff_weight_kg >= 0),
  endurance_min integer check (endurance_min is null or endurance_min > 0),
  max_payload_kg numeric check (max_payload_kg is null or max_payload_kg >= 0)
);
comment on table equipment.uav_profile is '平台受管理无人机的专业属性和类型约束入口。';
create table if not exists equipment.unmanned_vehicle_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  vehicle_type text, max_speed_kph numeric check (max_speed_kph is null or max_speed_kph >= 0),
  endurance_min integer check (endurance_min is null or endurance_min > 0),
  max_payload_kg numeric check (max_payload_kg is null or max_payload_kg >= 0)
);
comment on table equipment.unmanned_vehicle_profile is '无人车专业属性。';
create table if not exists equipment.vehicle_surveillance_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  camera_count integer check (camera_count is null or camera_count >= 0),
  sensor_count integer check (sensor_count is null or sensor_count >= 0), stream_ref text
);
comment on table equipment.vehicle_surveillance_profile is '车载监控逻辑设备属性，不关联独立载体车辆。';
create table if not exists equipment.sensor_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  sensor_type text, sampling_interval_s integer check (sampling_interval_s is null or sampling_interval_s > 0)
);
comment on table equipment.sensor_profile is '通用传感设备专业属性。';
create table if not exists equipment.sensor_channel (
  id bigserial primary key,
  asset_id bigint not null references equipment.sensor_profile(asset_id) on delete cascade,
  channel_code text not null, metric_code text not null, unit text, warning_threshold jsonb not null default '{}'::jsonb,
  unique (asset_id, channel_code)
);
comment on table equipment.sensor_channel is '传感设备的测量通道和预警阈值。';

create or replace function equipment.require_profile_category()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id = new.asset_id;
  if v_category is distinct from tg_argv[0] then
    raise exception 'asset % category must be %, got %', new.asset_id, tg_argv[0], v_category;
  end if;
  return new;
end;
$$;
comment on function equipment.require_profile_category() is '校验分类扩展表与统一资产类别一致。返回触发器记录。';

do $$
declare r record;
begin
  for r in select * from (values
    ('base_station_6g_profile','base_station_6g'), ('counter_uas_profile','counter_uas'),
    ('video_surveillance_profile','video_surveillance'), ('uav_profile','uav'),
    ('unmanned_vehicle_profile','unmanned_vehicle'), ('vehicle_surveillance_profile','vehicle_surveillance'),
    ('sensor_profile','sensor')
  ) v(table_name, category_code)
  loop
    execute format('drop trigger if exists profile_category_guard on equipment.%I', r.table_name);
    execute format('create trigger profile_category_guard before insert or update on equipment.%I for each row execute function equipment.require_profile_category(%L)', r.table_name, r.category_code);
  end loop;
end;
$$;

create or replace function equipment.prevent_profile_category_change()
returns trigger language plpgsql as $$
begin
  if new.category_code is distinct from old.category_code then
    raise exception 'equipment asset category is immutable; recreate the asset to change category';
  end if;
  return new;
end;
$$;
comment on function equipment.prevent_profile_category_change() is '禁止修改设备类别，避免分类扩展、能力和应急资源关系失配。返回触发器记录。';
drop trigger if exists asset_category_immutable on equipment.asset;
create trigger asset_category_immutable before update of category_code on equipment.asset
for each row execute function equipment.prevent_profile_category_change();

create table if not exists equipment.asset_status_current (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  connectivity_status text not null default 'unknown' check (connectivity_status in ('online', 'offline', 'unknown')),
  dispatch_status text not null default 'unknown' check (dispatch_status in ('available', 'assigned', 'maintenance', 'unavailable', 'unknown')),
  position_geom geometry(Point, 4326), position_height_amsl_m numeric,
  height_datum text not null default 'AMSL' check (height_datum = 'AMSL'),
  last_heartbeat_at timestamptz, observed_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now()
);
comment on table equipment.asset_status_current is '每个设施设备资产的最新连接、调度和位置状态快照。';
comment on column equipment.asset_status_current.position_height_amsl_m is '设备当前位置 AMSL 高度，单位米。';
create index if not exists asset_status_position_gix on equipment.asset_status_current using gist (position_geom);
create index if not exists asset_status_codes_idx on equipment.asset_status_current (connectivity_status, dispatch_status);
drop trigger if exists asset_status_current_touch_updated_at on equipment.asset_status_current;
create trigger asset_status_current_touch_updated_at before update on equipment.asset_status_current
for each row execute function equipment.touch_updated_at();

create table if not exists equipment.asset_status_history (
  id bigserial primary key,
  asset_id bigint not null references equipment.asset(id) on delete cascade,
  connectivity_status text not null check (connectivity_status in ('online', 'offline', 'unknown')),
  dispatch_status text not null check (dispatch_status in ('available', 'assigned', 'maintenance', 'unavailable', 'unknown')),
  position_geom geometry(Point, 4326), position_height_amsl_m numeric,
  height_datum text not null default 'AMSL' check (height_datum = 'AMSL'),
  last_heartbeat_at timestamptz, observed_at timestamptz not null, payload jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default now()
);
comment on table equipment.asset_status_history is '设施设备状态变化的追加历史记录。';
create index if not exists asset_status_history_asset_time_idx on equipment.asset_status_history (asset_id, observed_at desc);
create index if not exists asset_status_history_position_gix on equipment.asset_status_history using gist (position_geom);

create or replace function equipment.record_status_history()
returns trigger language plpgsql as $$
begin
  insert into equipment.asset_status_history(
    asset_id, connectivity_status, dispatch_status, position_geom, position_height_amsl_m,
    height_datum, last_heartbeat_at, observed_at, payload
  ) values (
    new.asset_id, new.connectivity_status, new.dispatch_status, new.position_geom,
    new.position_height_amsl_m, new.height_datum, new.last_heartbeat_at, new.observed_at, new.payload
  );
  return new;
end;
$$;
comment on function equipment.record_status_history() is '在当前状态写入后追加一条状态历史。返回触发器记录。';
drop trigger if exists asset_status_history_append on equipment.asset_status_current;
create trigger asset_status_history_append after insert or update on equipment.asset_status_current
for each row execute function equipment.record_status_history();

create table if not exists equipment.raw_observation (
  id bigserial primary key,
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  source_system text not null, source_observation_id text not null, observation_type text not null,
  observed_at timestamptz not null, received_at timestamptz not null default now(),
  geom geometry(Point, 4326), height_amsl_m numeric,
  height_datum text not null default 'AMSL' check (height_datum = 'AMSL'),
  confidence numeric check (confidence is null or (confidence >= 0 and confidence <= 1)),
  processing_status text not null default 'received', raw_payload jsonb not null,
  is_simulated boolean not null default false,
  unique (source_system, source_observation_id)
);
comment on table equipment.raw_observation is '设备产生的可追溯追加式原始观测。';
comment on column equipment.raw_observation.raw_payload is '外部来源或模拟器提供的原始 JSON 载荷。';
create index if not exists raw_observation_asset_time_idx on equipment.raw_observation (asset_id, observed_at desc);
create index if not exists raw_observation_geom_gix on equipment.raw_observation using gist (geom);

create or replace function equipment.reject_raw_observation_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'equipment raw observations are append-only';
end;
$$;
comment on function equipment.reject_raw_observation_mutation() is '拒绝原始观测更新和删除，保证追加写入。';
drop trigger if exists raw_observation_append_only on equipment.raw_observation;
create trigger raw_observation_append_only before update or delete on equipment.raw_observation
for each row execute function equipment.reject_raw_observation_mutation();

create or replace function equipment.reject_status_history_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'equipment status history is append-only';
end;
$$;
comment on function equipment.reject_status_history_mutation() is '拒绝设备状态历史更新和删除，保证追加写入。';
drop trigger if exists asset_status_history_append_only on equipment.asset_status_history;
create trigger asset_status_history_append_only before update or delete on equipment.asset_status_history
for each row execute function equipment.reject_status_history_mutation();

create table if not exists equipment.capability (
  code text primary key, name text not null, capability_type text not null, description text
);
comment on table equipment.capability is '设备能力字典。';
create table if not exists equipment.asset_capability (
  id bigserial primary key,
  asset_id bigint not null references equipment.asset(id) on delete cascade,
  capability_code text not null references equipment.capability(code),
  access_level text not null default 'observable' check (access_level in ('observable', 'recommendable', 'linkable', 'controllable')),
  enabled boolean not null default true, parameters jsonb not null default '{}'::jsonb,
  unique (asset_id, capability_code)
);
comment on table equipment.asset_capability is '资产拥有的能力、接入级别和参数。';

create or replace function equipment.limit_counter_uas_access()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id = new.asset_id;
  if v_category = 'counter_uas' and new.access_level not in ('observable', 'recommendable') then
    raise exception 'counter-UAS capability access level cannot exceed recommendable';
  end if;
  return new;
end;
$$;
comment on function equipment.limit_counter_uas_access() is '限制反无设备最高为可推荐接入级别。返回触发器记录。';
drop trigger if exists counter_uas_access_guard on equipment.asset_capability;
create trigger counter_uas_access_guard before insert or update on equipment.asset_capability
for each row execute function equipment.limit_counter_uas_access();

create table if not exists equipment.asset_coverage (
  id bigserial primary key,
  asset_capability_id bigint not null references equipment.asset_capability(id) on delete cascade,
  coverage_geom geometry(MultiPolygon, 4326) not null,
  min_height_amsl_m numeric, max_height_amsl_m numeric,
  height_datum text not null default 'AMSL' check (height_datum = 'AMSL'),
  valid_from timestamptz, valid_to timestamptz, metadata jsonb not null default '{}'::jsonb,
  check (min_height_amsl_m is null or max_height_amsl_m is null or min_height_amsl_m <= max_height_amsl_m),
  check (valid_from is null or valid_to is null or valid_from < valid_to)
);
comment on table equipment.asset_coverage is '具体设备能力的 WGS84 空间覆盖和 AMSL 高度范围。';
create index if not exists asset_coverage_geom_gix on equipment.asset_coverage using gist (coverage_geom);
create index if not exists asset_coverage_height_idx on equipment.asset_coverage (min_height_amsl_m, max_height_amsl_m);

create table if not exists emergency_resource.equipment_resource (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  resource_role text not null, active boolean not null default true,
  available_from timestamptz, available_to timestamptz, metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (available_from is null or available_to is null or available_from < available_to)
);
comment on table emergency_resource.equipment_resource is '可参与资源匹配和方案推荐的可调度设施设备。';

create or replace function emergency_resource.require_dispatchable_equipment()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id = new.asset_id;
  if v_category not in ('uav', 'unmanned_vehicle', 'vehicle_surveillance', 'video_surveillance') then
    raise exception 'equipment category % is not dispatchable', v_category;
  end if;
  return new;
end;
$$;
comment on function emergency_resource.require_dispatchable_equipment() is '限制应急资源关联为四类可调度设备。返回触发器记录。';
drop trigger if exists equipment_resource_category_guard on emergency_resource.equipment_resource;
create trigger equipment_resource_category_guard before insert or update on emergency_resource.equipment_resource
for each row execute function emergency_resource.require_dispatchable_equipment();
drop trigger if exists equipment_resource_touch_updated_at on emergency_resource.equipment_resource;
create trigger equipment_resource_touch_updated_at before update on emergency_resource.equipment_resource
for each row execute function equipment.touch_updated_at();

-- 新增业务字段均提供中文注释，明确单位、基准和用途。
comment on column equipment.asset.id is '统一设备资产主键。';
comment on column equipment.asset.asset_code is '面向业务展示的唯一资产编码。';
comment on column equipment.asset.type_code is '类别内的设备类型编码。';
comment on column equipment.asset.name is '设备显示名称。';
comment on column equipment.asset.source_system is '设备来源系统编码，与来源设备 ID 组成幂等键。';
comment on column equipment.asset.source_asset_id is '来源系统中的稳定设备 ID。';
comment on column equipment.asset.managing_unit_name is '管理单位名称快照。';
comment on column equipment.asset.deployment_mode is '部署方式，如固定或移动。';
comment on column equipment.asset.lifecycle_status is '资产生命周期状态。';
comment on column equipment.asset.manufacturer is '设备制造商。';
comment on column equipment.asset.model is '设备型号。';
comment on column equipment.asset.serial_no is '设备序列号。';
comment on column equipment.asset.metadata is '设备来源扩展属性 JSON。';
comment on column equipment.asset.created_at is '设备资产创建时间。';
comment on column equipment.asset.updated_at is '设备资产最后更新时间。';

comment on column equipment.base_station_6g_profile.asset_id is '6G 基站对应的统一资产 ID。';
comment on column equipment.base_station_6g_profile.operator_name is '6G 基站运营单位名称。';
comment on column equipment.base_station_6g_profile.frequency_band is '模拟或来源系统提供的频段描述。';
comment on column equipment.base_station_6g_profile.bandwidth_mhz is '带宽，单位 MHz。';
comment on column equipment.base_station_6g_profile.backhaul_type is '回传链路类型。';
comment on column equipment.counter_uas_profile.asset_id is '反无设备对应的统一资产 ID。';
comment on column equipment.counter_uas_profile.detection_mode is '探测方式描述。';
comment on column equipment.counter_uas_profile.identification_mode is '识别方式描述。';
comment on column equipment.counter_uas_profile.tracking_mode is '跟踪方式描述。';
comment on column equipment.counter_uas_profile.recommendation_notes is '仅用于展示和推荐的说明。';
comment on column equipment.video_surveillance_profile.asset_id is '视频监控对应的统一资产 ID。';
comment on column equipment.video_surveillance_profile.camera_type is '摄像机类型。';
comment on column equipment.video_surveillance_profile.ptz_supported is '是否支持云台控制能力描述。';
comment on column equipment.video_surveillance_profile.optical_zoom is '光学变焦倍数。';
comment on column equipment.video_surveillance_profile.stream_ref is '不含密码的视频流安全引用。';
comment on column equipment.uav_profile.asset_id is '受管理无人机对应的统一资产 ID。';
comment on column equipment.uav_profile.max_takeoff_weight_kg is '最大起飞重量，单位千克。';
comment on column equipment.uav_profile.endurance_min is '续航时间，单位分钟。';
comment on column equipment.uav_profile.max_payload_kg is '最大载荷，单位千克。';
comment on column equipment.unmanned_vehicle_profile.asset_id is '无人车对应的统一资产 ID。';
comment on column equipment.unmanned_vehicle_profile.vehicle_type is '无人车类型。';
comment on column equipment.unmanned_vehicle_profile.max_speed_kph is '最大速度，单位千米每小时。';
comment on column equipment.unmanned_vehicle_profile.endurance_min is '续航时间，单位分钟。';
comment on column equipment.unmanned_vehicle_profile.max_payload_kg is '最大载荷，单位千克。';
comment on column equipment.vehicle_surveillance_profile.asset_id is '车载监控逻辑设备对应的统一资产 ID。';
comment on column equipment.vehicle_surveillance_profile.camera_count is '摄像机数量。';
comment on column equipment.vehicle_surveillance_profile.sensor_count is '附属传感器数量。';
comment on column equipment.vehicle_surveillance_profile.stream_ref is '不含密码的视频流安全引用。';
comment on column equipment.sensor_profile.asset_id is '传感设备对应的统一资产 ID。';
comment on column equipment.sensor_profile.sensor_type is '传感设备类型。';
comment on column equipment.sensor_profile.sampling_interval_s is '采样间隔，单位秒。';
comment on column equipment.sensor_channel.id is '传感通道主键。';
comment on column equipment.sensor_channel.asset_id is '所属传感设备资产 ID。';
comment on column equipment.sensor_channel.channel_code is '设备内唯一通道编码。';
comment on column equipment.sensor_channel.metric_code is '测量指标编码。';
comment on column equipment.sensor_channel.unit is '测量单位。';
comment on column equipment.sensor_channel.warning_threshold is '来源系统提供的预警阈值 JSON。';

comment on column equipment.asset_status_current.asset_id is '当前状态对应的设备资产 ID。';
comment on column equipment.asset_status_current.connectivity_status is '连接状态：online、offline 或 unknown。';
comment on column equipment.asset_status_current.dispatch_status is '调度状态：available、assigned、maintenance、unavailable 或 unknown。';
comment on column equipment.asset_status_current.position_geom is '移动设备当前位置，WGS84 Point（EPSG:4326）。';
comment on column equipment.asset_status_current.height_datum is '当前位置高度基准，固定为 AMSL。';
comment on column equipment.asset_status_current.last_heartbeat_at is '最近心跳时间。';
comment on column equipment.asset_status_current.observed_at is '当前状态观测时间。';
comment on column equipment.asset_status_current.payload is '状态来源扩展载荷 JSON。';
comment on column equipment.asset_status_current.updated_at is '当前状态最后更新时间。';
comment on column equipment.asset_status_history.id is '状态历史主键。';
comment on column equipment.asset_status_history.asset_id is '状态历史对应的设备资产 ID。';
comment on column equipment.asset_status_history.connectivity_status is '历史连接状态。';
comment on column equipment.asset_status_history.dispatch_status is '历史调度状态。';
comment on column equipment.asset_status_history.position_geom is '历史位置，WGS84 Point（EPSG:4326）。';
comment on column equipment.asset_status_history.position_height_amsl_m is '历史位置 AMSL 高度，单位米。';
comment on column equipment.asset_status_history.height_datum is '历史位置高度基准，固定为 AMSL。';
comment on column equipment.asset_status_history.last_heartbeat_at is '该状态的最近心跳时间。';
comment on column equipment.asset_status_history.observed_at is '该状态的观测时间。';
comment on column equipment.asset_status_history.payload is '该状态的来源扩展载荷 JSON。';
comment on column equipment.asset_status_history.recorded_at is '状态历史入库时间。';

comment on column equipment.raw_observation.id is '原始观测主键。';
comment on column equipment.raw_observation.asset_id is '产生观测的设备资产 ID。';
comment on column equipment.raw_observation.source_system is '观测来源系统编码。';
comment on column equipment.raw_observation.source_observation_id is '来源系统中的稳定观测 ID。';
comment on column equipment.raw_observation.observation_type is '原始观测类型。';
comment on column equipment.raw_observation.observed_at is '来源设备观测时间。';
comment on column equipment.raw_observation.received_at is '平台接收时间。';
comment on column equipment.raw_observation.geom is '观测位置，WGS84 Point（EPSG:4326）。';
comment on column equipment.raw_observation.height_amsl_m is '观测 AMSL 高度，单位米。';
comment on column equipment.raw_observation.height_datum is '观测高度基准，固定为 AMSL。';
comment on column equipment.raw_observation.confidence is '来源可信度，范围 0 到 1。';
comment on column equipment.raw_observation.processing_status is '观测处理状态。';
comment on column equipment.raw_observation.is_simulated is '是否为模拟观测。';
comment on column equipment.capability.code is '能力唯一编码。';
comment on column equipment.capability.name is '能力中文名称。';
comment on column equipment.capability.capability_type is '能力类型编码。';
comment on column equipment.capability.description is '能力说明。';
comment on column equipment.asset_capability.id is '资产能力主键。';
comment on column equipment.asset_capability.asset_id is '拥有该能力的设备资产 ID。';
comment on column equipment.asset_capability.capability_code is '能力字典编码。';
comment on column equipment.asset_capability.access_level is '接入级别：可观测、可推荐、可联动或可控制。';
comment on column equipment.asset_capability.enabled is '该资产能力是否启用。';
comment on column equipment.asset_capability.parameters is '能力来源参数 JSON。';
comment on column equipment.asset_coverage.id is '能力覆盖主键。';
comment on column equipment.asset_coverage.asset_capability_id is '覆盖范围对应的具体资产能力 ID。';
comment on column equipment.asset_coverage.coverage_geom is '能力覆盖范围，WGS84 MultiPolygon（EPSG:4326）。';
comment on column equipment.asset_coverage.min_height_amsl_m is '覆盖最低 AMSL 高度，单位米。';
comment on column equipment.asset_coverage.max_height_amsl_m is '覆盖最高 AMSL 高度，单位米。';
comment on column equipment.asset_coverage.height_datum is '覆盖高度基准，固定为 AMSL。';
comment on column equipment.asset_coverage.valid_from is '覆盖范围生效时间。';
comment on column equipment.asset_coverage.valid_to is '覆盖范围失效时间。';
comment on column equipment.asset_coverage.metadata is '覆盖范围扩展属性 JSON。';
comment on column emergency_resource.equipment_resource.asset_id is '可调度设备资产 ID。';
comment on column emergency_resource.equipment_resource.resource_role is '设备在应急资源中的业务角色。';
comment on column emergency_resource.equipment_resource.active is '应急资源关联是否启用。';
comment on column emergency_resource.equipment_resource.available_from is '资源可用时间窗开始时间。';
comment on column emergency_resource.equipment_resource.available_to is '资源可用时间窗结束时间。';
comment on column emergency_resource.equipment_resource.metadata is '应急资源关联扩展属性 JSON。';
comment on column emergency_resource.equipment_resource.created_at is '关联创建时间。';
comment on column emergency_resource.equipment_resource.updated_at is '关联最后更新时间。';

-- 先移除依赖旧无人机关系的 API 视图，迁移后以统一模型重建。
drop view if exists api.flight_activity_route_previews;
drop view if exists api.flight_activities;
drop view if exists api.reported_flights;
drop view if exists api.inspection_tasks;
drop view if exists api.aircraft_assets;

-- 保留旧 ID，并仅在首次迁移时生成确定性的花果山模拟坐标。
insert into equipment.asset(
  id, asset_code, category_code, type_code, name, source_system, source_asset_id,
  managing_unit_name, lifecycle_status, geom, elevation_amsl_m, height_datum,
  model, serial_no, is_simulated, metadata, created_at, updated_at
)
select
  legacy.id, coalesce(legacy.asset_code, 'LEGACY-UAV-' || legacy.id), 'uav', 'legacy_uav', legacy.name,
  coalesce(legacy.source_system, 'flight_plan_legacy'), coalesce(legacy.source_aircraft_id, legacy.id::text),
  legacy.owner_unit_name, 'active',
  ST_SetSRID(ST_MakePoint(
    119.235 + mod(legacy.id * 7919, 6500)::numeric / 100000,
    34.634 + mod(legacy.id * 3571, 2600)::numeric / 100000
  ), 4326), null, 'AMSL', legacy.model, legacy.serial_no, true,
  legacy.metadata || jsonb_build_object('migrated_from', 'flight_plan.aircraft_asset', 'legacy_availability_status', legacy.availability_status),
  legacy.created_at, legacy.updated_at
from flight_plan.aircraft_asset legacy
on conflict (id) do update set
  name = excluded.name, model = excluded.model, serial_no = excluded.serial_no,
  managing_unit_name = excluded.managing_unit_name,
  metadata = equipment.asset.metadata || excluded.metadata;

select setval(pg_get_serial_sequence('equipment.asset', 'id'), greatest(coalesce((select max(id) from equipment.asset), 1), 1), true);

insert into equipment.uav_profile(asset_id)
select id from equipment.asset where category_code = 'uav'
on conflict (asset_id) do nothing;

insert into equipment.asset_status_current(
  asset_id, connectivity_status, dispatch_status, position_geom, position_height_amsl_m,
  height_datum, observed_at, payload
)
select
  legacy.id,
  case when legacy.availability_status = 'offline' then 'offline' else 'unknown' end,
  case legacy.availability_status
    when 'idle' then 'available' when 'in_task' then 'assigned'
    when 'maintenance' then 'maintenance' when 'offline' then 'unavailable' else 'unknown'
  end,
  asset.geom, asset.elevation_amsl_m, 'AMSL', legacy.updated_at,
  jsonb_build_object('migrated_from', 'flight_plan.aircraft_asset', 'legacy_status', legacy.availability_status)
from flight_plan.aircraft_asset legacy join equipment.asset asset on asset.id = legacy.id
on conflict (asset_id) do nothing;

-- Reported Flight 只保留来源名称快照。动态 SQL 使重复执行时不再引用已删除字段。
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'flight_plan' and table_name = 'reported_flight' and column_name = 'aircraft_id'
  ) then
    execute 'update flight_plan.reported_flight rf set aircraft_name_snapshot = a.name from flight_plan.aircraft_asset a where rf.aircraft_id = a.id and rf.aircraft_name_snapshot is null';
    execute 'drop index if exists flight_plan.reported_flight_aircraft_idx';
    execute 'alter table flight_plan.reported_flight drop column aircraft_id';
  end if;
end;
$$;
comment on column flight_plan.reported_flight.aircraft_name_snapshot is '报备来源中的无人机名称快照，不关联平台受管理资产。';

-- Inspection Task 的资产外键改为无人机扩展表，从数据库层保证类型。
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid = 'flight_plan.inspection_task'::regclass
      and contype = 'f'
      and conkey = array[(select attnum from pg_attribute where attrelid = 'flight_plan.inspection_task'::regclass and attname = 'aircraft_id')]
  loop
    execute format('alter table flight_plan.inspection_task drop constraint %I', r.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'inspection_task_equipment_uav_fk' and conrelid = 'flight_plan.inspection_task'::regclass) then
    alter table flight_plan.inspection_task add constraint inspection_task_equipment_uav_fk
      foreign key (aircraft_id) references equipment.uav_profile(asset_id);
  end if;
end;
$$;

-- API 门面。
create or replace view api.equipment_assets as select * from equipment.asset;
create or replace view api.equipment_asset_status as select * from equipment.asset_status_current;
create or replace view api.equipment_raw_observations as select * from equipment.raw_observation;
create or replace view api.equipment_asset_capabilities as
select ac.id, ac.asset_id, a.asset_code, a.category_code, ac.capability_code,
       c.name as capability_name, c.capability_type, ac.access_level, ac.enabled, ac.parameters
from equipment.asset_capability ac
join equipment.asset a on a.id = ac.asset_id
join equipment.capability c on c.code = ac.capability_code;
create or replace view api.equipment_asset_coverages as
select cov.id, ac.asset_id, ac.capability_code, cov.asset_capability_id, cov.coverage_geom,
       cov.min_height_amsl_m, cov.max_height_amsl_m, cov.height_datum,
       cov.valid_from, cov.valid_to, cov.metadata
from equipment.asset_coverage cov
join equipment.asset_capability ac on ac.id = cov.asset_capability_id;
create or replace view api.equipment_statistics as
select a.category_code, coalesce(s.connectivity_status, 'unknown') as connectivity_status,
       coalesce(s.dispatch_status, 'unknown') as dispatch_status, count(*)::bigint as asset_count
from equipment.asset a left join equipment.asset_status_current s on s.asset_id = a.id
group by a.category_code, coalesce(s.connectivity_status, 'unknown'), coalesce(s.dispatch_status, 'unknown');

create or replace view api.aircraft_assets as
select
  a.id, a.source_system, a.source_asset_id as source_aircraft_id, a.asset_code, a.name,
  a.model, a.serial_no, a.managing_unit_name as owner_unit_name,
  case
    when s.connectivity_status = 'offline' then 'offline'
    when s.dispatch_status = 'assigned' then 'in_task'
    when s.dispatch_status = 'maintenance' then 'maintenance'
    when s.dispatch_status = 'available' then 'idle'
    else 'unknown'
  end as availability_status,
  a.metadata, a.created_at, a.updated_at
from equipment.asset a
join equipment.uav_profile u on u.asset_id = a.id
left join equipment.asset_status_current s on s.asset_id = a.id;

create or replace view api.reported_flights as
select id, source_system, source_record_id, report_no, title, reporting_unit_name,
       pilot_name, pilot_phone, pilot_license_no, aircraft_name_snapshot,
       planned_start_at, planned_end_at, filing_status, execution_status, route_result_id,
       remark, source_payload, metadata, ingested_at, created_at, updated_at
from flight_plan.reported_flight;
create or replace view api.inspection_tasks as select * from flight_plan.inspection_task;

create or replace view api.flight_activities as
select
  'reported_flight'::text as activity_type, rf.id as activity_id, rf.report_no as activity_no,
  coalesce(rf.title, rf.report_no, '报备飞行') as activity_name, rf.reporting_unit_name as unit_name,
  null::bigint as aircraft_id, rf.aircraft_name_snapshot as aircraft_name,
  rf.planned_start_at, rf.planned_end_at, null::timestamptz as actual_start_at,
  null::timestamptz as actual_end_at, rf.execution_status as activity_status,
  rf.filing_status, rf.route_result_id, pr.plan_id as route_plan_id,
  rf.route_result_id is not null as has_route, rf.created_at, rf.updated_at
from flight_plan.reported_flight rf
left join flight_path.plan_result pr on pr.id = rf.route_result_id
union all
select
  'inspection_task'::text, it.id, it.task_no, it.task_name, it.responsible_unit_name,
  it.aircraft_id, coalesce(a.name, it.aircraft_name_snapshot), it.planned_start_at,
  it.planned_end_at, it.actual_start_at, it.actual_end_at, it.task_status, null::text,
  it.route_result_id, pr.plan_id, it.route_result_id is not null, it.created_at, it.updated_at
from flight_plan.inspection_task it
left join equipment.asset a on a.id = it.aircraft_id
left join flight_path.plan_result pr on pr.id = it.route_result_id;

create or replace view api.flight_activity_route_previews as
select fa.activity_type, fa.activity_id, fa.activity_no, fa.activity_name, fa.unit_name,
       fa.aircraft_id, fa.aircraft_name, fa.planned_start_at, fa.planned_end_at,
       fa.activity_status, fa.filing_status, fa.has_route, fa.route_plan_id, fa.route_result_id,
       pr.result_status, pr.distance_m, pr.duration_s, pr.grid_cell_count, pr.traj_point_count,
       pr.segment_count, pr.error_message,
       case when pr.route_geom is null then null else ST_AsGeoJSON(pr.route_geom)::jsonb end as route_geojson,
       case when pr.smooth_route_geom is null then null else ST_AsGeoJSON(pr.smooth_route_geom)::jsonb end as smooth_route_geojson,
       case when pr.grid_path is null then null else ST_AsText(ST_AsGrids(pr.grid_path), 'GGER') end as route_grid_gger,
       case when pr.grid_path is null then null else ST_WithBox(ST_AsGrids(pr.grid_path), 'GGER')::jsonb end as route_grid_with_box,
       pr.created_at as route_created_at
from api.flight_activities fa left join flight_path.plan_result pr on pr.id = fa.route_result_id;

comment on view api.equipment_assets is '统一设施设备资产 CRUD 与分类查询资源。';
comment on view api.equipment_asset_status is '设备当前连接、调度和位置状态 CRUD 资源。';
comment on view api.equipment_raw_observations is '设备原始观测查询与追加资源，禁止更新和删除。';
comment on view api.equipment_asset_capabilities is '设备能力及接入级别只读资源。';
comment on view api.equipment_asset_coverages is '设备能力空间覆盖及 AMSL 高度范围只读资源。';
comment on view api.equipment_statistics is '按类别、连接状态和调度状态分组的设备统计资源。';
comment on view api.aircraft_assets is '基于统一设备模型的既有无人机兼容查询资源。';
comment on view api.reported_flights is '外部报备飞行资源，仅保留来源无人机名称快照。';
comment on view api.inspection_tasks is '关联平台受管理无人机的巡查任务 CRUD 资源。';
comment on view api.flight_activities is '报备飞行与巡查任务合并的只读飞行架次资源。';
comment on view api.flight_activity_route_previews is '飞行架次航线和 GGER 网格预览只读资源。';

comment on column api.equipment_assets.id is '统一设备资产主键。';
comment on column api.equipment_assets.category_code is '七类设施设备类别编码。';
comment on column api.equipment_assets.geom is '资产登记位置，WGS84 Point（EPSG:4326）。';
comment on column api.equipment_assets.elevation_amsl_m is '资产登记 AMSL 高度，单位米。';
comment on column api.equipment_assets.height_datum is '高度基准，固定为 AMSL。';
comment on column api.equipment_asset_status.connectivity_status is '设备当前连接状态。';
comment on column api.equipment_asset_status.dispatch_status is '设备当前调度状态。';
comment on column api.equipment_asset_status.position_geom is '设备当前位置，WGS84 Point（EPSG:4326）。';
comment on column api.equipment_raw_observations.raw_payload is '可追溯的原始 JSON 载荷。';
comment on column api.equipment_raw_observations.is_simulated is '是否为模拟原始观测。';
comment on column api.equipment_asset_capabilities.access_level is '设备能力接入级别。';
comment on column api.equipment_asset_coverages.coverage_geom is '能力覆盖范围，WGS84 MultiPolygon（EPSG:4326）。';
comment on column api.equipment_asset_coverages.height_datum is '覆盖高度基准，固定为 AMSL。';
comment on column api.equipment_statistics.asset_count is '该类别和状态组合下的设备数量。';

-- 统计仅用受管理无人机和 Inspection Task 计算任务中/空闲数量。
create or replace function api.get_flight_plan_stats(p_start_at timestamptz, p_end_at timestamptz)
returns api.flight_plan_stats_result
language sql stable
set search_path = api, equipment, flight_plan, public, pg_temp
as $$
with activity as (
  select * from api.flight_activities
  where planned_start_at < p_end_at and planned_end_at > p_start_at
), eligible as (
  select * from activity
  where activity_status not in ('cancelled', 'aborted', 'unknown')
    and (activity_type <> 'reported_flight' or coalesce(filing_status, 'unknown') not in ('rejected','cancelled','expired','unknown'))
), managed_in_task as (
  select count(distinct it.aircraft_id)::bigint as asset_count
  from flight_plan.inspection_task it
  join equipment.uav_profile u on u.asset_id = it.aircraft_id
  where it.aircraft_id is not null and it.task_status = 'executing'
), managed_idle as (
  select count(*)::bigint as asset_count
  from equipment.uav_profile u join equipment.asset_status_current s on s.asset_id = u.asset_id
  where s.dispatch_status = 'available'
    and not exists (select 1 from flight_plan.inspection_task it where it.aircraft_id = u.asset_id and it.task_status = 'executing')
)
select
  count(*) filter (where activity_type = 'reported_flight' and filing_status = 'approved'),
  (select count(*) from eligible),
  (select count(*) from eligible where activity_status in ('planned','ready')),
  (select count(*) from eligible where activity_type = 'inspection_task'),
  (select asset_count from managed_in_task), (select asset_count from managed_idle), p_start_at, p_end_at
from activity;
$$;
comment on function api.get_flight_plan_stats(timestamptz, timestamptz) is '返回飞行计划统计 JSON：报备数、总架次、待执行数、巡查数、任务中和空闲受管理无人机数及时间窗口。';

-- 权限：底层技术角色可管理，HTTP 只暴露 api schema；anonymous 无业务数据权限。
grant usage on schema equipment, emergency_resource to admin;
grant select, insert, update, delete on all tables in schema equipment to admin;
grant usage, select, update on all sequences in schema equipment to admin;
grant execute on all functions in schema equipment to admin;
grant select, insert, update, delete on emergency_resource.equipment_resource to admin;
grant execute on function emergency_resource.require_dispatchable_equipment() to admin;
revoke all on all tables in schema equipment from public;
revoke all on all tables in schema equipment from anonymous;
revoke all on all sequences in schema equipment from public;
revoke all on all sequences in schema equipment from anonymous;
revoke all on all functions in schema equipment from public;
revoke all on all functions in schema equipment from anonymous;
revoke all on emergency_resource.equipment_resource from public, anonymous;

revoke all on all tables in schema api from public, anonymous;
revoke all on all functions in schema api from public, anonymous;
grant usage on schema api to anonymous, admin;
grant select, insert, update, delete on api.equipment_assets to admin;
grant select, insert, update, delete on api.equipment_asset_status to admin;
grant select, insert on api.equipment_raw_observations to admin;
grant select on api.equipment_asset_capabilities, api.equipment_asset_coverages, api.equipment_statistics, api.aircraft_assets to admin;
grant select, insert, update, delete on api.reported_flights, api.inspection_tasks to admin;
grant select on api.flight_activities, api.flight_activity_route_previews to admin;
grant execute on function api.get_flight_plan_stats(timestamptz, timestamptz) to admin;

alter default privileges for role postgres in schema equipment grant select, insert, update, delete on tables to admin;
alter default privileges for role postgres in schema equipment grant usage, select, update on sequences to admin;
alter default privileges for role postgres in schema equipment grant execute on functions to admin;

notify pgrst, 'reload schema';
commit;
