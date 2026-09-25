-- 云平台雷达/电侦数据接入、目标会话、航迹与态势查询。
-- 依赖 create_equipment_asset_schema.sql 和 migrate_equipment_detection_devices.sql。
-- 可重复执行；PostgREST 仅公开 api schema，situation 为内部数据层。

begin;

create extension if not exists postgis;
create schema if not exists situation;
create schema if not exists api;
comment on schema situation is '空域目标观测、来源会话、目标航迹和态势增量数据域。';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'detection_ingest') then
    create role detection_ingest nologin;
  end if;
end;
$$;

create table if not exists situation.detection_source_type (
  vendor_code smallint primary key,
  code text not null unique,
  name text not null,
  enabled boolean not null default true,
  description text
);
comment on table situation.detection_source_type is '厂商侦测来源类型与平台稳定编码的映射字典。';
comment on column situation.detection_source_type.vendor_code is '厂商 sourceType 数值。';
comment on column situation.detection_source_type.code is '平台内部稳定来源类型编码。';
comment on column situation.detection_source_type.name is '来源类型中文名称。';
comment on column situation.detection_source_type.enabled is '是否允许接收该来源类型。';
comment on column situation.detection_source_type.description is '来源类型说明。';
insert into situation.detection_source_type(vendor_code, code, name, description) values
  (10, 'radar', '雷达', '云平台 sourceType=10 的雷达侦测数据。'),
  (20, 'radio_detection', '电侦', '云平台 sourceType=20 的无线电侦测数据。')
on conflict (vendor_code) do update set code=excluded.code, name=excluded.name,
  enabled=true, description=excluded.description;

create table if not exists situation.detection_method (
  code text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name text not null check (btrim(name) <> ''),
  description text,
  lifecycle_status text not null default 'active' check (lifecycle_status in ('active','deprecated')),
  visible boolean not null default true,
  sort_order integer not null default 0,
  display_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table situation.detection_method is '平台稳定侦测方式字典，与设备类别、接入来源及厂商枚举相互独立。';
comment on column situation.detection_method.code is '不可变的平台稳定编码，如 radar、radio_detection。';
comment on column situation.detection_method.lifecycle_status is '生命周期状态；deprecated 仅阻止新映射，不删除历史引用。';
comment on column situation.detection_method.visible is '是否在管理端及业务筛选器中展示，不控制数据接入。';
comment on column situation.detection_method.display_metadata is '颜色、图标等非业务展示配置。';

create table if not exists situation.detection_method_mapping (
  id bigserial primary key,
  source_system text not null check (btrim(source_system) <> ''),
  vendor_code text not null check (btrim(vendor_code) <> ''),
  method_code text not null references situation.detection_method(code) on delete restrict,
  accept_ingest boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_system,vendor_code)
);
comment on table situation.detection_method_mapping is '各来源系统厂商枚举到平台稳定侦测方式的受控映射。';
comment on column situation.detection_method_mapping.source_system is '来源系统稳定编码。';
comment on column situation.detection_method_mapping.vendor_code is '厂商原始侦测方式编码，按文本保存以兼容数值和字符串枚举。';
comment on column situation.detection_method_mapping.method_code is '映射后的平台稳定侦测方式编码。';
comment on column situation.detection_method_mapping.accept_ingest is '是否允许该厂商类型继续接入，与前端可见性相互独立。';

create table if not exists situation.detection_method_mapping_history (
  id bigserial primary key,
  mapping_id bigint not null references situation.detection_method_mapping(id) on delete restrict,
  source_system text not null,
  vendor_code text not null,
  old_method_code text,
  new_method_code text not null,
  old_accept_ingest boolean,
  new_accept_ingest boolean not null,
  old_metadata jsonb,
  new_metadata jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by text
);
comment on table situation.detection_method_mapping_history is '厂商侦测方式映射的追加式审计历史。';
comment on column situation.detection_method_mapping_history.mapping_id is '发生变更的厂商映射 ID。';
comment on column situation.detection_method_mapping_history.old_method_code is '变更前平台侦测方式；首次创建时为空。';
comment on column situation.detection_method_mapping_history.new_method_code is '变更后平台侦测方式。';
comment on column situation.detection_method_mapping_history.changed_by is 'PostgREST JWT 主体或数据库会话用户。';

create or replace function situation.audit_detection_method_mapping()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare
  v_claims jsonb;
  v_actor text;
begin
  begin
    v_claims:=nullif(current_setting('request.jwt.claims',true),'')::jsonb;
  exception when others then
    v_claims:='{}'::jsonb;
  end;
  v_actor:=coalesce(v_claims->>'sub',v_claims->>'role',session_user);
  if tg_op='INSERT' or old.method_code is distinct from new.method_code
      or old.accept_ingest is distinct from new.accept_ingest
      or old.metadata is distinct from new.metadata then
    insert into situation.detection_method_mapping_history(
      mapping_id,source_system,vendor_code,old_method_code,new_method_code,
      old_accept_ingest,new_accept_ingest,old_metadata,new_metadata,changed_by
    ) values(
      new.id,new.source_system,new.vendor_code,
      case when tg_op='UPDATE' then old.method_code end,new.method_code,
      case when tg_op='UPDATE' then old.accept_ingest end,new.accept_ingest,
      case when tg_op='UPDATE' then old.metadata end,new.metadata,v_actor
    );
  end if;
  return new;
end;
$$;
comment on function situation.audit_detection_method_mapping() is '追加记录厂商侦测方式映射创建与有效配置变更；返回触发器新记录。';
drop trigger if exists detection_method_mapping_audit on situation.detection_method_mapping;
create trigger detection_method_mapping_audit after insert or update on situation.detection_method_mapping
for each row execute function situation.audit_detection_method_mapping();

insert into situation.detection_method(code,name,description,sort_order) values
  ('radar','雷达','通过雷达探测空域目标。',10),
  ('radio_detection','电侦','通过无线电信号侦测或测向发现目标。',20),
  ('electro_optical','光电','通过可见光、红外或热成像观测目标。',30),
  ('remote_id','Remote ID','接收并解析航空器远程身份广播。',40),
  ('network_sensing','网络感知','通过通信网络侧数据感知目标。',50),
  ('manual','人工上报','由人工报告形成目标观测。',60)
on conflict (code) do nothing;

insert into situation.detection_method_mapping(source_system,vendor_code,method_code,metadata) values
  ('radar_cloud','10','radar',jsonb_build_object('legacy_vendor_code',10)),
  ('radar_cloud','20','radio_detection',jsonb_build_object('legacy_vendor_code',20))
on conflict (source_system,vendor_code) do nothing;

create table if not exists situation.observation_source (
  id bigserial primary key,
  source_system text not null,
  external_station_id text not null,
  external_box_code text not null default '',
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  name text not null,
  source_timezone text not null default 'Asia/Shanghai',
  coordinate_system text not null default 'WGS84' check (coordinate_system = 'WGS84'),
  enabled boolean not null default true,
  lost_timeout_seconds integer not null default 30 check (lost_timeout_seconds between 5 and 3600),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_system, external_station_id, external_box_code)
);
comment on table situation.observation_source is '外部站点或边缘盒子的观测接入身份及规范化配置。';
comment on column situation.observation_source.source_system is '来源系统稳定编码。';
comment on column situation.observation_source.external_station_id is '来源系统站点 ID。';
comment on column situation.observation_source.external_box_code is '来源系统盒子编码。';
comment on column situation.observation_source.asset_id is '对应的统一设施设备资产 ID。';
comment on column situation.observation_source.source_timezone is '解释来源无时区时间字符串所用时区。';
comment on column situation.observation_source.coordinate_system is '来源坐标系，当前固定为 WGS84。';
comment on column situation.observation_source.lost_timeout_seconds is '目标缺失后判定丢失的宽限秒数。';
comment on column situation.observation_source.metadata is '不含密钥的来源扩展配置。';

create table if not exists situation.observation_source_status_current (
  observation_source_id bigint primary key references situation.observation_source(id) on delete cascade,
  connector_state text not null default 'unknown' check (connector_state in ('connected','disconnected','degraded','unknown')),
  last_connected_at timestamptz,
  last_disconnected_at timestamptz,
  last_message_at timestamptz,
  last_snapshot_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  details jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
comment on table situation.observation_source_status_current is '观测接入链路的当前连接和消息健康状态。';
comment on column situation.observation_source_status_current.connector_state is '连接器状态，不等同于物理雷达在线状态。';
comment on column situation.observation_source_status_current.last_message_at is '最近收到合法来源消息的时间。';
comment on column situation.observation_source_status_current.last_snapshot_at is '最近完成在线列表对账的时间。';
comment on column situation.observation_source_status_current.last_error_code is '最近错误编码，不保存敏感错误详情。';
comment on column situation.observation_source_status_current.details is '不含密码、令牌和控制密钥的状态扩展信息。';
create index if not exists observation_source_status_message_idx
  on situation.observation_source_status_current(last_message_at desc);

-- config_status 每两秒刷新资产心跳；仅业务状态、位置或载荷变化才应追加通用状态历史。
create or replace function equipment.record_status_history()
returns trigger language plpgsql as $$
begin
  if tg_op='UPDATE' and row(
    new.connectivity_status,new.dispatch_status,new.position_geom,
    new.position_height_amsl_m,new.height_datum,new.payload
  ) is not distinct from row(
    old.connectivity_status,old.dispatch_status,old.position_geom,
    old.position_height_amsl_m,old.height_datum,old.payload
  ) then
    return new;
  end if;
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
comment on function equipment.record_status_history() is '设备业务状态、位置或载荷发生变化时追加状态历史；仅心跳和观测时间刷新不重复写历史。返回触发器记录。';

create table if not exists equipment.counter_uas_telemetry_current (
  asset_id bigint primary key references equipment.counter_uas_profile(asset_id) on delete cascade,
  observed_at timestamptz not null,
  received_at timestamptz not null,
  unattended boolean,
  detection_device_online boolean,
  countermeasure_device_online boolean,
  counter_voltage_v numeric,
  counter_current_a numeric,
  counter_power_w numeric,
  counter_temperature_c numeric,
  detection_azimuth_deg numeric check (detection_azimuth_deg is null or detection_azimuth_deg between 0 and 360),
  detection_rotating boolean,
  counter_azimuth_deg numeric check (counter_azimuth_deg is null or counter_azimuth_deg between 0 and 360),
  counter_rotating boolean,
  active_frequencies_mhz numeric[] not null default '{}',
  radar_device_sn text,
  radar_asset_id bigint references equipment.asset(id) on delete restrict,
  radar_online boolean,
  radar_geom geometry(Point,4326),
  radar_altitude_amsl_m numeric,
  radar_heading_deg numeric check (radar_heading_deg is null or radar_heading_deg between 0 and 360),
  radar_base_heading_deg numeric check (radar_base_heading_deg is null or radar_base_heading_deg between 0 and 360),
  radar_gps_update_enabled boolean,
  quality_flags text[] not null default '{}',
  raw_payload jsonb not null,
  updated_at timestamptz not null default now()
);
comment on table equipment.counter_uas_telemetry_current is '反无综合设备最近一条规范化实时遥测快照，每次 config_status 覆盖更新。';
comment on column equipment.counter_uas_telemetry_current.asset_id is '产生遥测的反无综合设备资产 ID。';
comment on column equipment.counter_uas_telemetry_current.observed_at is '设备状态观测时间；来源未提供时间时使用平台接收时间。';
comment on column equipment.counter_uas_telemetry_current.received_at is '平台接收到 config_status 消息的时间。';
comment on column equipment.counter_uas_telemetry_current.unattended is '设备是否处于无人值守模式。';
comment on column equipment.counter_uas_telemetry_current.detection_device_online is '厂商 controlStatus 对应的侦测子系统在线状态。';
comment on column equipment.counter_uas_telemetry_current.countermeasure_device_online is '厂商 controlStatus99 对应的处置子系统在线状态。';
comment on column equipment.counter_uas_telemetry_current.counter_voltage_v is '处置子系统电压，单位 V。';
comment on column equipment.counter_uas_telemetry_current.counter_current_a is '处置子系统电流，单位 A。';
comment on column equipment.counter_uas_telemetry_current.counter_power_w is '处置子系统功率，单位 W。';
comment on column equipment.counter_uas_telemetry_current.counter_temperature_c is '处置子系统温度，单位摄氏度。';
comment on column equipment.counter_uas_telemetry_current.detection_azimuth_deg is '侦测转台方位角，单位度，范围 0 至 360。';
comment on column equipment.counter_uas_telemetry_current.detection_rotating is '侦测转台当前是否正在旋转。';
comment on column equipment.counter_uas_telemetry_current.counter_azimuth_deg is '处置转台方位角，单位度，范围 0 至 360。';
comment on column equipment.counter_uas_telemetry_current.counter_rotating is '处置转台当前是否正在旋转。';
comment on column equipment.counter_uas_telemetry_current.active_frequencies_mhz is '当前开启频段，统一转换为 MHz 数值数组。';
comment on column equipment.counter_uas_telemetry_current.radar_device_sn is '厂商上报的雷达设备序列号。';
comment on column equipment.counter_uas_telemetry_current.radar_asset_id is '能够确认独立物理身份时关联的雷达设备资产。';
comment on column equipment.counter_uas_telemetry_current.radar_online is '厂商上报的雷达设备在线状态。';
comment on column equipment.counter_uas_telemetry_current.radar_geom is '厂商上报的雷达 WGS84 地理位置。';
comment on column equipment.counter_uas_telemetry_current.radar_altitude_amsl_m is '厂商雷达海拔，统一按 AMSL 米保存。';
comment on column equipment.counter_uas_telemetry_current.radar_heading_deg is '雷达当前航向角，单位度，范围 0 至 360。';
comment on column equipment.counter_uas_telemetry_current.radar_base_heading_deg is '雷达安装基准航向角，单位度，范围 0 至 360。';
comment on column equipment.counter_uas_telemetry_current.radar_gps_update_enabled is '雷达是否启用 GPS 位置更新。';
comment on column equipment.counter_uas_telemetry_current.quality_flags is '规范化和数据质量标记数组。';
comment on column equipment.counter_uas_telemetry_current.raw_payload is '最近一次厂商 config_status 原始载荷。';
comment on column equipment.counter_uas_telemetry_current.updated_at is '当前遥测快照在平台中的更新时间。';

create table if not exists equipment.counter_uas_status_event (
  id bigserial primary key,
  asset_id bigint not null references equipment.counter_uas_profile(asset_id) on delete cascade,
  event_type text not null check (event_type in ('initialized','status_changed')),
  changed_fields text[] not null,
  previous_state jsonb,
  current_state jsonb not null,
  observed_at timestamptz not null,
  received_at timestamptz not null,
  created_at timestamptz not null default now()
);
comment on table equipment.counter_uas_status_event is '反无设备离散状态发生变化时追加保存的长期事件历史。';
comment on column equipment.counter_uas_status_event.changed_fields is '本次发生变化的规范化状态字段列表。';
comment on column equipment.counter_uas_status_event.previous_state is '变化前离散状态；初始化事件为空。';
comment on column equipment.counter_uas_status_event.current_state is '变化后的离散状态。';
create index if not exists counter_uas_status_event_asset_time_idx
  on equipment.counter_uas_status_event(asset_id,observed_at desc);

create table if not exists equipment.counter_uas_telemetry_sample (
  id bigserial primary key,
  asset_id bigint not null references equipment.counter_uas_profile(asset_id) on delete cascade,
  observed_at timestamptz not null,
  received_at timestamptz not null,
  counter_voltage_v numeric,
  counter_current_a numeric,
  counter_power_w numeric,
  counter_temperature_c numeric,
  detection_azimuth_deg numeric,
  counter_azimuth_deg numeric,
  active_frequencies_mhz numeric[] not null default '{}',
  radar_online boolean,
  radar_heading_deg numeric,
  quality_flags text[] not null default '{}',
  raw_payload jsonb not null,
  sampled_at timestamptz not null default now()
);
comment on table equipment.counter_uas_telemetry_sample is '反无设备连续遥测的限频采样历史，默认每个设备最多每 60 秒一条。';
comment on column equipment.counter_uas_telemetry_sample.sampled_at is '平台实际写入采样记录的时间。';
comment on column equipment.counter_uas_telemetry_sample.raw_payload is '采样时对应的厂商原始状态载荷。';
create index if not exists counter_uas_telemetry_sample_asset_time_idx
  on equipment.counter_uas_telemetry_sample(asset_id,observed_at desc);

create table if not exists situation.target_observation (
  observation_id bigint primary key references equipment.raw_observation(id) on delete restrict,
  observation_source_id bigint not null references situation.observation_source(id) on delete restrict,
  source_type_code smallint references situation.detection_source_type(vendor_code),
  detection_method_code text references situation.detection_method(code) on delete restrict,
  producer_asset_id bigint references equipment.asset(id) on delete restrict,
  source_target_id text not null,
  source_session_id text,
  event_type text not null check (event_type in ('online_upsert','snapshot','offline_remove')),
  model text,
  frequency_mhz numeric check (frequency_mhz is null or frequency_mhz >= 0),
  relative_height_m numeric,
  horizontal_distance_m numeric check (horizontal_distance_m is null or horizontal_distance_m >= 0),
  azimuth_deg numeric check (azimuth_deg is null or azimuth_deg between 0 and 360),
  elevation_deg numeric check (elevation_deg is null or elevation_deg between -90 and 90),
  speed_mps numeric check (speed_mps is null or speed_mps >= 0),
  list_type smallint,
  pilot_geom geometry(Point,4326),
  home_geom geometry(Point,4326),
  quality_flags text[] not null default '{}'
);
alter table situation.target_observation
  add column if not exists detection_method_code text references situation.detection_method(code) on delete restrict;
comment on table situation.target_observation is '原始设备观测的一对一目标侦测语义扩展。';
comment on column situation.target_observation.observation_id is '对应的追加式设备原始观测 ID。';
comment on column situation.target_observation.source_type_code is '兼容保留的厂商来源类型：雷达云 10 雷达、20 电侦；缺失时为空。';
comment on column situation.target_observation.detection_method_code is '规范化后的平台稳定侦测方式编码；无法确定时为空。';
comment on column situation.target_observation.source_target_id is '来源系统目标标识，当前对应 serial。';
comment on column situation.target_observation.source_session_id is '来源系统提供的目标会话 ID。';
comment on column situation.target_observation.frequency_mhz is '侦测频率，单位 MHz。';
comment on column situation.target_observation.relative_height_m is '来源相对高度，单位米，不作为 AMSL 高度。';
comment on column situation.target_observation.horizontal_distance_m is '站点到目标的水平距离，单位米。';
comment on column situation.target_observation.azimuth_deg is '站点到目标的方位角，单位度，不是目标航向。';
comment on column situation.target_observation.pilot_geom is '设备随目标观测上报的远程飞手 WGS84 位置；不作为空域目标航迹位置。';
comment on column situation.target_observation.home_geom is '设备随目标观测上报的起飞点 WGS84 位置；当前厂商未提供时为空。';
create index if not exists target_observation_pilot_geom_gix
  on situation.target_observation using gist(pilot_geom) where pilot_geom is not null;
comment on column situation.target_observation.quality_flags is '规范化过程发现的数据质量标记。';
create index if not exists target_observation_source_target_idx
  on situation.target_observation(observation_source_id, source_target_id, observation_id desc);
create index if not exists target_observation_source_type_idx
  on situation.target_observation(source_type_code, observation_id desc);
create index if not exists target_observation_method_idx
  on situation.target_observation(detection_method_code, observation_id desc);
update situation.target_observation o set detection_method_code=m.method_code
from situation.observation_source src,situation.detection_method_mapping m
where o.detection_method_code is null and src.id=o.observation_source_id
  and m.source_system=src.source_system and m.vendor_code=o.source_type_code::text;
create index if not exists target_observation_quality_gin
  on situation.target_observation using gin(quality_flags);

create table if not exists situation.airspace_target (
  id bigserial primary key,
  target_code text not null unique,
  target_class text not null default 'unknown',
  display_name text,
  identity_status text not null default 'unverified' check (identity_status in ('unverified','identified','conflicted')),
  confidence numeric check (confidence is null or confidence between 0 and 1),
  first_observed_at timestamptz not null,
  last_observed_at timestamptz not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table situation.airspace_target is '平台基于来源观测形成的当前空域目标解释。';
comment on column situation.airspace_target.target_code is '平台内部稳定目标编码。';
comment on column situation.airspace_target.target_class is '目标类别，如 uav、bird 或 unknown。';
comment on column situation.airspace_target.identity_status is '目标身份研判状态。';
comment on column situation.airspace_target.active is '目标当前是否活动。';

create table if not exists situation.source_target_session (
  id bigserial primary key,
  observation_source_id bigint not null references situation.observation_source(id) on delete restrict,
  source_type_code smallint references situation.detection_source_type(vendor_code),
  source_target_id text not null,
  source_session_id text,
  session_key text not null,
  target_id bigint not null references situation.airspace_target(id) on delete restrict,
  state text not null default 'active' check (state in ('active','lost','closed')),
  started_at timestamptz not null,
  last_observed_at timestamptz not null,
  ended_at timestamptz,
  end_reason text,
  current_observation_id bigint references equipment.raw_observation(id) on delete restrict,
  version bigint not null default 1,
  unique (observation_source_id, session_key)
);
comment on table situation.source_target_session is '来源目标从首次发现到离线的一次连续发现会话。';
comment on column situation.source_target_session.session_key is '来源会话 ID 或平台生成的确定性会话键。';
comment on column situation.source_target_session.state is '会话状态：active、lost 或 closed。';
comment on column situation.source_target_session.end_reason is '会话结束原因，如 source_remove、timeout 或 reconciled_absent。';
create index if not exists source_target_session_active_idx
  on situation.source_target_session(observation_source_id, source_target_id, last_observed_at desc)
  where state = 'active';
create index if not exists source_target_session_state_time_idx
  on situation.source_target_session(state, last_observed_at);

create table if not exists situation.target_track (
  id bigserial primary key,
  track_code text not null unique,
  target_id bigint not null references situation.airspace_target(id) on delete restrict,
  source_session_id bigint unique references situation.source_target_session(id) on delete restrict,
  status text not null default 'tracking' check (status in ('tracking','lost','closed')),
  first_observed_at timestamptz not null,
  last_observed_at timestamptz not null,
  lost_at timestamptz,
  current_observation_id bigint references equipment.raw_observation(id) on delete restrict,
  track_confidence numeric check (track_confidence is null or track_confidence between 0 and 1),
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);
comment on table situation.target_track is '空域目标在一段时间内的连续跟踪结果和当前状态。';
comment on column situation.target_track.track_code is '平台内部稳定航迹编码。';
comment on column situation.target_track.current_observation_id is '最新有效空间位置观测 ID，无坐标观测不覆盖该字段。';
comment on column situation.target_track.track_confidence is '航迹关联可信度，范围 0 到 1。';
create index if not exists target_track_status_time_idx
  on situation.target_track(status, last_observed_at desc);

create table if not exists situation.track_observation (
  track_id bigint not null references situation.target_track(id) on delete cascade,
  observation_id bigint not null unique references equipment.raw_observation(id) on delete restrict,
  association_method text not null check (association_method in ('source_session','manual','fused')),
  association_confidence numeric check (association_confidence is null or association_confidence between 0 and 1),
  associated_at timestamptz not null default now(),
  primary key (track_id, observation_id)
);
comment on table situation.track_observation is '目标航迹与雷达、电侦及后续其他来源观测的证据关联。';
comment on column situation.track_observation.association_method is '观测关联方式：来源会话、人工或融合。';
comment on column situation.track_observation.association_confidence is '观测与航迹的关联可信度。';

create table if not exists situation.change_event (
  id bigserial primary key,
  event_type text not null check (event_type in ('target_upsert','target_remove','source_status','risk_changed')),
  aggregate_type text not null check (aggregate_type in ('target_track','observation_source')),
  aggregate_id bigint not null,
  observation_source_id bigint references situation.observation_source(id) on delete restrict,
  occurred_at timestamptz not null,
  payload jsonb not null,
  created_at timestamptz not null default now()
);
comment on table situation.change_event is '供态势客户端按游标补读的持久化增量变更，不是业务空域事件。';
comment on column situation.change_event.id is '单调递增的增量读取游标。';
comment on column situation.change_event.event_type is '增量类型：目标更新、目标移除、来源状态或风险变化。';
comment on column situation.change_event.payload is '内部稳定事件载荷 JSON。';
create index if not exists change_event_source_cursor_idx
  on situation.change_event(observation_source_id, id);
create index if not exists change_event_created_idx on situation.change_event(created_at);

-- 登记已通过厂商接口验证的站点 90 实体盒子。
insert into equipment.asset(
  asset_code,category_code,type_code,name,source_system,source_asset_id,deployment_mode,
  lifecycle_status,geom,height_datum,manufacturer,model,is_simulated,metadata
) values (
  'RADAR-CLOUD-BOX-90','counter_uas','edge_detection_box','连云港雷达云平台站点 90 边缘盒子',
  'radar_cloud','b260705174118582','fixed','active',
  ST_SetSRID(ST_MakePoint(119.1929320,34.5919520),4326),'AMSL','边缘盒子','D007-V',false,
  jsonb_build_object('station_id',90,'vendor_box_code','b260705174118582','counter_device',2)
)
on conflict (source_system,source_asset_id) do update set
  name=excluded.name,geom=excluded.geom,model=excluded.model,
  metadata=equipment.asset.metadata||excluded.metadata,updated_at=now();

insert into equipment.counter_uas_profile(asset_id,detection_mode,identification_mode,tracking_mode,recommendation_notes)
select id,'radar_and_radio','vendor_identification','vendor_track','只接收侦测数据，不接入真实控制指令。'
from equipment.asset where source_system='radar_cloud' and source_asset_id='b260705174118582'
on conflict (asset_id) do update set detection_mode=excluded.detection_mode,
  identification_mode=excluded.identification_mode,tracking_mode=excluded.tracking_mode,
  recommendation_notes=excluded.recommendation_notes;

insert into equipment.asset_capability(asset_id,capability_code,access_level,enabled,parameters)
select a.id,v.capability_code,'observable',true,
  jsonb_build_object('configuration_status','range_pending','parameter_source','vendor_confirmation_required')
from equipment.asset a
cross join (values('microwave_detection'),('radio_detection')) v(capability_code)
where a.source_system='radar_cloud' and a.source_asset_id='b260705174118582'
on conflict (asset_id,capability_code) do nothing;

insert into equipment.capability(code,name,capability_type,description) values
  ('remote_pilot_localization','远程飞手定位','detection','通过遥控链路、Remote ID 或厂商识别结果获得远程飞手位置。')
on conflict(code) do update set name=excluded.name,capability_type=excluded.capability_type,description=excluded.description;

insert into equipment.asset_capability(asset_id,capability_code,access_level,enabled,parameters)
select id,'remote_pilot_localization','observable',true,jsonb_build_object(
  'position_source','vendor_reported','coordinate_system','WGS84',
  'supports_realtime',true,'supports_history',true,'accuracy_m',null
)
from equipment.asset where source_system='radar_cloud' and source_asset_id='b260705174118582'
on conflict(asset_id,capability_code) do update set
  enabled=excluded.enabled,parameters=excluded.parameters;

-- 建立站点 90 的观测来源映射。
insert into situation.observation_source(
  source_system, external_station_id, external_box_code, asset_id, name, metadata
)
select 'radar_cloud', '90', 'b260705174118582', id, '连云港雷达云平台站点 90',
       jsonb_build_object('vendor_host', '47.110.44.5', 'vendor_port', 8003)
from equipment.asset
where source_system = 'radar_cloud' and source_asset_id = 'b260705174118582'
order by id limit 1
on conflict (source_system, external_station_id, external_box_code) do update set
  asset_id=excluded.asset_id, name=excluded.name, metadata=excluded.metadata, updated_at=now();

create or replace function situation.safe_numeric(p_value text)
returns numeric language plpgsql immutable as $$
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  return p_value::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;
comment on function situation.safe_numeric(text) is '将来源字符串安全转换为数值，非法值返回空。';

with remote_pilot_candidates as (
  select o.observation_id,
    situation.safe_numeric(split_part(r.raw_payload->>'pilotGps','/',1)) longitude,
    situation.safe_numeric(split_part(r.raw_payload->>'pilotGps','/',2)) latitude
  from situation.target_observation o
  join equipment.raw_observation r on r.id=o.observation_id
  where o.pilot_geom is null and nullif(btrim(r.raw_payload->>'pilotGps'),'') is not null
), valid_remote_pilots as (
  select * from remote_pilot_candidates
  where longitude between -180 and 180 and latitude between -90 and 90
    and (longitude<>0 or latitude<>0)
)
update situation.target_observation o set
  pilot_geom=ST_SetSRID(ST_MakePoint(p.longitude,p.latitude),4326)
from valid_remote_pilots p where p.observation_id=o.observation_id;

drop function if exists situation.source_timestamp(text,text,timestamptz);

drop function if exists situation.ingest_detection_message(text,text,text,text,timestamptz,jsonb);

create or replace function situation.ingest_target_observation(p_observation jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, equipment, situation
as $$
declare
  v_source situation.observation_source%rowtype;
  v_source_system text := p_observation->>'sourceSystem';
  v_station_id text := p_observation->>'stationId';
  v_observation_key text := p_observation->>'sourceObservationId';
  v_serial text := nullif(btrim(p_observation->>'sourceTargetId'),'');
  v_source_type smallint := situation.safe_numeric(p_observation->>'sourceTypeCode')::smallint;
  v_detection_method text := nullif(btrim(p_observation->>'detectionMethodCode'),'');
  v_mapped_method text;
  v_source_producer_asset_id text := nullif(btrim(p_observation->>'sourceProducerAssetId'),'');
  v_producer_asset_id bigint;
  v_event_type text := p_observation->>'eventType';
  v_observed_at timestamptz;
  v_received_at timestamptz;
  v_lng numeric := situation.safe_numeric(p_observation->>'longitude');
  v_lat numeric := situation.safe_numeric(p_observation->>'latitude');
  v_pilot_lng numeric := situation.safe_numeric(p_observation#>>'{remotePilotLocation,longitude}');
  v_pilot_lat numeric := situation.safe_numeric(p_observation#>>'{remotePilotLocation,latitude}');
  v_pilot_geom geometry(Point,4326);
  v_geom geometry(Point,4326);
  v_quality text[];
  v_observation_id bigint;
  v_session situation.source_target_session%rowtype;
  v_target_id bigint;
  v_track_id bigint;
  v_change_cursor bigint;
begin
  if p_observation is null or jsonb_typeof(p_observation)<>'object' then
    raise exception 'normalized observation must be a JSON object';
  end if;
  if p_observation->>'schemaVersion' is distinct from '1' then
    raise exception 'unsupported normalized observation schemaVersion';
  end if;
  if v_source_system is null or v_station_id is null or v_observation_key is null or v_serial is null then
    raise exception 'sourceSystem, stationId, sourceObservationId and sourceTargetId are required';
  end if;
  if v_event_type not in ('online_upsert','snapshot','offline_remove') then
    raise exception 'invalid normalized eventType %',v_event_type;
  end if;
  begin
    v_observed_at := (p_observation->>'observedAt')::timestamptz;
    v_received_at := (p_observation->>'receivedAt')::timestamptz;
  exception when others then
    raise exception 'observedAt and receivedAt must be ISO 8601 timestamps with timezone';
  end;
  if v_observed_at is null or v_received_at is null then
    raise exception 'observedAt and receivedAt are required';
  end if;
  if jsonb_typeof(coalesce(p_observation->'rawPayload','null'::jsonb))<>'object' then
    raise exception 'rawPayload must be a JSON object';
  end if;
  if v_source_type is not null and not exists(
    select 1 from situation.detection_source_type where vendor_code=v_source_type and enabled
  ) then raise exception 'unsupported sourceTypeCode %',v_source_type; end if;
  if v_source_type is not null then
    select method_code into v_mapped_method from situation.detection_method_mapping
    where source_system=v_source_system and vendor_code=v_source_type::text and accept_ingest;
    if not found then
      raise exception 'source type %.% is not configured for ingestion',v_source_system,v_source_type;
    end if;
    if v_detection_method is not null and v_detection_method<>v_mapped_method then
      raise exception 'detectionMethodCode % conflicts with source type mapping %',v_detection_method,v_mapped_method;
    end if;
    v_detection_method:=coalesce(v_detection_method,v_mapped_method);
  end if;
  if v_detection_method is not null and not exists(
    select 1 from situation.detection_method where code=v_detection_method
  ) then raise exception 'unsupported detectionMethodCode %',v_detection_method; end if;
  if (v_lng is null)<>(v_lat is null) or (v_lng is not null and
      (v_lng not between -180 and 180 or v_lat not between -90 and 90 or (v_lng=0 and v_lat=0))) then
    raise exception 'longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_geom := case when v_lng is not null then ST_SetSRID(ST_MakePoint(v_lng,v_lat),4326) end;
  if p_observation ? 'remotePilotLocation'
     and p_observation->'remotePilotLocation' <> 'null'::jsonb
     and jsonb_typeof(p_observation->'remotePilotLocation') <> 'object' then
    raise exception 'remotePilotLocation must be an object or null';
  end if;
  if (v_pilot_lng is null)<>(v_pilot_lat is null) or (v_pilot_lng is not null and
      (v_pilot_lng not between -180 and 180 or v_pilot_lat not between -90 and 90
       or (v_pilot_lng=0 and v_pilot_lat=0))) then
    raise exception 'remote pilot longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_pilot_geom := case when v_pilot_lng is not null then
    ST_SetSRID(ST_MakePoint(v_pilot_lng,v_pilot_lat),4326) end;
  select coalesce(array_agg(value),array[]::text[]) into v_quality
  from jsonb_array_elements_text(coalesce(p_observation->'qualityFlags','[]'::jsonb));

  select * into v_source from situation.observation_source
  where source_system=v_source_system and external_station_id=v_station_id and enabled
  order by (external_box_code<>'') desc,id limit 1;
  if not found then raise exception 'enabled observation source %.% is not configured',v_source_system,v_station_id; end if;

  if v_source_producer_asset_id is not null then
    select id into v_producer_asset_id from equipment.asset
    where source_system=v_source_system and source_asset_id=v_source_producer_asset_id;
    if not found then
      raise exception 'producer asset %.% is not registered',v_source_system,v_source_producer_asset_id;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_source.id::text||':'||v_serial,0));
  insert into situation.observation_source_status_current(observation_source_id,connector_state,last_message_at,updated_at)
  values(v_source.id,'connected',v_received_at,now())
  on conflict(observation_source_id) do update set connector_state='connected',
    last_message_at=greatest(situation.observation_source_status_current.last_message_at,excluded.last_message_at),updated_at=now();

  insert into equipment.raw_observation(
    asset_id,source_system,source_observation_id,observation_type,observed_at,received_at,
    geom,height_amsl_m,height_datum,processing_status,raw_payload,is_simulated
  ) values(
    v_source.asset_id,v_source_system,v_observation_key,'detection_'||v_event_type,
    v_observed_at,v_received_at,v_geom,situation.safe_numeric(p_observation->>'altitudeAmslM'),'AMSL',
    case when cardinality(v_quality)>0 then 'needs_review' else 'normalized' end,
    p_observation->'rawPayload'||jsonb_build_object('_normalized',p_observation-'rawPayload'),false
  ) on conflict(source_system,source_observation_id) do nothing returning id into v_observation_id;
  if v_observation_id is null then
    select id into v_observation_id from equipment.raw_observation
    where source_system=v_source_system and source_observation_id=v_observation_key;
    return jsonb_build_object('status','duplicate','observationId',v_observation_id,'changeCursor',null);
  end if;

  insert into situation.target_observation(
    observation_id,observation_source_id,source_type_code,detection_method_code,producer_asset_id,source_target_id,source_session_id,event_type,
    model,frequency_mhz,relative_height_m,horizontal_distance_m,azimuth_deg,elevation_deg,speed_mps,list_type,pilot_geom,quality_flags
  ) values(
    v_observation_id,v_source.id,v_source_type,v_detection_method,v_producer_asset_id,v_serial,nullif(p_observation->>'sourceSessionId',''),v_event_type,
    nullif(p_observation->>'model',''),situation.safe_numeric(p_observation->>'frequencyMhz'),
    situation.safe_numeric(p_observation->>'relativeHeightM'),situation.safe_numeric(p_observation->>'horizontalDistanceM'),
    situation.safe_numeric(p_observation->>'azimuthDeg'),situation.safe_numeric(p_observation->>'elevationDeg'),
    situation.safe_numeric(p_observation->>'speedMps'),situation.safe_numeric(p_observation->>'listType')::smallint,v_pilot_geom,v_quality
  );

  select * into v_session from situation.source_target_session
  where observation_source_id=v_source.id and source_target_id=v_serial and state='active'
  order by last_observed_at desc limit 1 for update;
  if not found and v_event_type<>'offline_remove' then
    insert into situation.airspace_target(target_code,target_class,display_name,first_observed_at,last_observed_at)
    values('TGT-'||nextval('situation.airspace_target_id_seq'),
      case when p_observation->>'model' is null then 'unknown' else 'uav' end,
      p_observation->>'model',v_observed_at,v_observed_at) returning id into v_target_id;
    insert into situation.source_target_session(
      observation_source_id,source_type_code,source_target_id,source_session_id,session_key,target_id,
      started_at,last_observed_at,current_observation_id
    ) values(v_source.id,v_source_type,v_serial,nullif(p_observation->>'sourceSessionId',''),
      coalesce(nullif(p_observation->>'sourceSessionId',''),v_serial||':'||v_observation_id),
      v_target_id,v_observed_at,v_observed_at,v_observation_id) returning * into v_session;
    insert into situation.target_track(
      track_code,target_id,source_session_id,first_observed_at,last_observed_at,current_observation_id
    ) values('TRK-'||nextval('situation.target_track_id_seq'),v_target_id,v_session.id,
      v_observed_at,v_observed_at,case when v_geom is not null then v_observation_id end) returning id into v_track_id;
  elsif found then
    v_target_id:=v_session.target_id;
    select id into v_track_id from situation.target_track where source_session_id=v_session.id for update;
    if v_event_type='offline_remove' and v_observed_at>=v_session.last_observed_at then
      update situation.source_target_session set state='closed',ended_at=v_observed_at,
        end_reason=coalesce(nullif(p_observation->>'endReason',''),'source_remove'),
        current_observation_id=v_observation_id,version=version+1 where id=v_session.id;
      update situation.target_track set status='closed',lost_at=v_observed_at,
        last_observed_at=greatest(last_observed_at,v_observed_at),version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=false,
        last_observed_at=greatest(last_observed_at,v_observed_at),updated_at=now() where id=v_target_id;
    elsif v_event_type<>'offline_remove' then
      update situation.source_target_session set source_type_code=coalesce(source_type_code,v_source_type),
        source_session_id=coalesce(source_session_id,nullif(p_observation->>'sourceSessionId','')),
        last_observed_at=greatest(last_observed_at,v_observed_at),
        current_observation_id=case when v_observed_at>=last_observed_at then v_observation_id else current_observation_id end,
        version=version+1 where id=v_session.id;
      update situation.target_track set status='tracking',last_observed_at=greatest(last_observed_at,v_observed_at),
        current_observation_id=case when v_geom is not null and v_observed_at>=last_observed_at then v_observation_id else current_observation_id end,
        version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=true,last_observed_at=greatest(last_observed_at,v_observed_at),
        updated_at=now() where id=v_target_id;
    end if;
  end if;

  if v_track_id is not null then
    insert into situation.track_observation(track_id,observation_id,association_method,association_confidence)
    values(v_track_id,v_observation_id,'source_session',1);
    insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
    values(case when v_event_type='offline_remove' then 'target_remove' else 'target_upsert' end,
      'target_track',v_track_id,v_source.id,v_observed_at,
      jsonb_build_object('track_id',v_track_id,'target_id',v_target_id,'observation_id',v_observation_id))
    returning id into v_change_cursor;
  end if;
  return jsonb_build_object('status','accepted','observationId',v_observation_id,
    'targetId',v_target_id,'trackId',v_track_id,'changeCursor',v_change_cursor);
end;
$$;
comment on function situation.ingest_target_observation(jsonb) is '写入单条版本化规范目标观测，原子维护原始证据、来源会话、目标航迹和增量事件；返回 JSON：status、observationId、targetId、trackId、changeCursor。';


create or replace function situation.ingest_detection_config_status(p_status jsonb)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,equipment,situation
as $$
declare
  v_source situation.observation_source%rowtype;
  v_old equipment.counter_uas_telemetry_current%rowtype;
  v_had_old boolean;
  v_source_system text := p_status->>'sourceSystem';
  v_station_id text := p_status->>'stationId';
  v_source_asset_id text := nullif(btrim(p_status->>'sourceAssetId'),'');
  v_observed_at timestamptz;
  v_received_at timestamptz;
  v_box_online boolean := nullif(p_status->>'boxOnline','')::boolean;
  v_unattended boolean := nullif(p_status->>'unattended','')::boolean;
  v_detection_online boolean := nullif(p_status->>'detectionDeviceOnline','')::boolean;
  v_counter_online boolean := nullif(p_status->>'countermeasureDeviceOnline','')::boolean;
  v_detection_rotating boolean := nullif(p_status->>'detectionRotating','')::boolean;
  v_counter_rotating boolean := nullif(p_status->>'counterRotating','')::boolean;
  v_radar_online boolean := nullif(p_status->>'radarOnline','')::boolean;
  v_radar_gps_enabled boolean := nullif(p_status->>'radarGpsUpdateEnabled','')::boolean;
  v_active_frequencies numeric[];
  v_quality text[];
  v_radar_geom geometry(Point,4326);
  v_radar_asset_id bigint;
  v_changed_fields text[];
  v_previous_state jsonb;
  v_current_state jsonb;
  v_event_id bigint;
  v_sampled boolean := false;
begin
  if p_status is null or jsonb_typeof(p_status)<>'object' then raise exception 'normalized config status must be a JSON object'; end if;
  if p_status->>'schemaVersion' is distinct from '1' then raise exception 'unsupported normalized config status schemaVersion'; end if;
  if v_source_system is null or v_station_id is null or v_source_asset_id is null then
    raise exception 'sourceSystem, stationId and sourceAssetId are required';
  end if;
  if jsonb_typeof(coalesce(p_status->'rawPayload','null'::jsonb))<>'object' then raise exception 'rawPayload must be a JSON object'; end if;
  if jsonb_typeof(coalesce(p_status->'activeFrequenciesMhz','[]'::jsonb))<>'array' then
    raise exception 'activeFrequenciesMhz must be an array';
  end if;
  begin
    v_observed_at:=(p_status->>'observedAt')::timestamptz;
    v_received_at:=(p_status->>'receivedAt')::timestamptz;
  exception when others then
    raise exception 'observedAt and receivedAt must be ISO 8601 timestamps with timezone';
  end;
  if v_observed_at is null or v_received_at is null then raise exception 'observedAt and receivedAt are required'; end if;
  select coalesce(array_agg(value::numeric order by ordinality),array[]::numeric[])
    into v_active_frequencies
  from jsonb_array_elements_text(coalesce(p_status->'activeFrequenciesMhz','[]'::jsonb)) with ordinality;
  select coalesce(array_agg(value),array[]::text[]) into v_quality
  from jsonb_array_elements_text(coalesce(p_status->'qualityFlags','[]'::jsonb));
  if not ('missing_source_time'=any(v_quality)) then
    raise exception 'config status without source timestamp must include missing_source_time';
  end if;
  if situation.safe_numeric(p_status->>'radarLongitude') is not null
     and situation.safe_numeric(p_status->>'radarLatitude') is not null then
    v_radar_geom:=ST_SetSRID(ST_MakePoint(
      situation.safe_numeric(p_status->>'radarLongitude'),
      situation.safe_numeric(p_status->>'radarLatitude')
    ),4326);
    if not ST_X(v_radar_geom) between -180 and 180 or not ST_Y(v_radar_geom) between -90 and 90
       or (ST_X(v_radar_geom)=0 and ST_Y(v_radar_geom)=0) then
      raise exception 'radar position must be valid non-zero WGS84 coordinates';
    end if;
  elsif (p_status->>'radarLongitude') is not null or (p_status->>'radarLatitude') is not null then
    raise exception 'radar longitude and latitude must be supplied together';
  end if;

  select * into v_source from situation.observation_source
  where source_system=v_source_system and external_station_id=v_station_id
    and external_box_code=v_source_asset_id and enabled;
  if not found then raise exception 'enabled observation source %.%.% is not configured',v_source_system,v_station_id,v_source_asset_id; end if;
  if not exists(select 1 from equipment.counter_uas_profile where asset_id=v_source.asset_id) then
    raise exception 'observation source asset % is not a counter-UAS device',v_source.asset_id;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('config-status:'||v_source.asset_id::text,0));
  select * into v_old from equipment.counter_uas_telemetry_current where asset_id=v_source.asset_id for update;
  v_had_old:=found;

  if nullif(p_status->>'radarDeviceSn','') is not null then
    select id into v_radar_asset_id from equipment.asset
    where source_system=v_source_system and category_code='microwave_radar'
      and (source_asset_id=p_status->>'radarDeviceSn' or serial_no=p_status->>'radarDeviceSn')
    order by id limit 1;
  end if;

  v_previous_state:=case when v_had_old then jsonb_build_object(
    'unattended',v_old.unattended,'detectionDeviceOnline',v_old.detection_device_online,
    'countermeasureDeviceOnline',v_old.countermeasure_device_online,
    'detectionRotating',v_old.detection_rotating,'counterRotating',v_old.counter_rotating,
    'activeFrequenciesMhz',to_jsonb(v_old.active_frequencies_mhz),'radarOnline',v_old.radar_online,
    'radarGpsUpdateEnabled',v_old.radar_gps_update_enabled
  ) end;
  v_current_state:=jsonb_build_object(
    'unattended',v_unattended,'detectionDeviceOnline',v_detection_online,
    'countermeasureDeviceOnline',v_counter_online,
    'detectionRotating',v_detection_rotating,'counterRotating',v_counter_rotating,
    'activeFrequenciesMhz',to_jsonb(v_active_frequencies),'radarOnline',v_radar_online,
    'radarGpsUpdateEnabled',v_radar_gps_enabled
  );
  if v_had_old then
    v_changed_fields:=array_remove(array[
      case when v_old.unattended is distinct from v_unattended then 'unattended' end,
      case when v_old.detection_device_online is distinct from v_detection_online then 'detectionDeviceOnline' end,
      case when v_old.countermeasure_device_online is distinct from v_counter_online then 'countermeasureDeviceOnline' end,
      case when v_old.detection_rotating is distinct from v_detection_rotating then 'detectionRotating' end,
      case when v_old.counter_rotating is distinct from v_counter_rotating then 'counterRotating' end,
      case when v_old.active_frequencies_mhz is distinct from v_active_frequencies then 'activeFrequenciesMhz' end,
      case when v_old.radar_online is distinct from v_radar_online then 'radarOnline' end,
      case when v_old.radar_gps_update_enabled is distinct from v_radar_gps_enabled then 'radarGpsUpdateEnabled' end
    ],null);
  else
    v_changed_fields:=array['unattended','detectionDeviceOnline','countermeasureDeviceOnline',
      'detectionRotating','counterRotating','activeFrequenciesMhz','radarOnline','radarGpsUpdateEnabled'];
  end if;

  insert into equipment.counter_uas_telemetry_current(
    asset_id,observed_at,received_at,unattended,detection_device_online,countermeasure_device_online,
    counter_voltage_v,counter_current_a,counter_power_w,counter_temperature_c,
    detection_azimuth_deg,detection_rotating,counter_azimuth_deg,counter_rotating,
    active_frequencies_mhz,radar_device_sn,radar_asset_id,radar_online,radar_geom,
    radar_altitude_amsl_m,radar_heading_deg,radar_base_heading_deg,radar_gps_update_enabled,
    quality_flags,raw_payload,updated_at
  ) values(
    v_source.asset_id,v_observed_at,v_received_at,v_unattended,v_detection_online,v_counter_online,
    situation.safe_numeric(p_status->>'counterVoltageV'),situation.safe_numeric(p_status->>'counterCurrentA'),
    situation.safe_numeric(p_status->>'counterPowerW'),situation.safe_numeric(p_status->>'counterTemperatureC'),
    situation.safe_numeric(p_status->>'detectionAzimuthDeg'),v_detection_rotating,
    situation.safe_numeric(p_status->>'counterAzimuthDeg'),v_counter_rotating,v_active_frequencies,
    nullif(p_status->>'radarDeviceSn',''),v_radar_asset_id,v_radar_online,v_radar_geom,
    situation.safe_numeric(p_status->>'radarAltitudeAmslM'),situation.safe_numeric(p_status->>'radarHeadingDeg'),
    situation.safe_numeric(p_status->>'radarBaseHeadingDeg'),v_radar_gps_enabled,v_quality,p_status->'rawPayload',now()
  ) on conflict(asset_id) do update set
    observed_at=excluded.observed_at,received_at=excluded.received_at,unattended=excluded.unattended,
    detection_device_online=excluded.detection_device_online,countermeasure_device_online=excluded.countermeasure_device_online,
    counter_voltage_v=excluded.counter_voltage_v,counter_current_a=excluded.counter_current_a,
    counter_power_w=excluded.counter_power_w,counter_temperature_c=excluded.counter_temperature_c,
    detection_azimuth_deg=excluded.detection_azimuth_deg,detection_rotating=excluded.detection_rotating,
    counter_azimuth_deg=excluded.counter_azimuth_deg,counter_rotating=excluded.counter_rotating,
    active_frequencies_mhz=excluded.active_frequencies_mhz,radar_device_sn=excluded.radar_device_sn,
    radar_asset_id=excluded.radar_asset_id,radar_online=excluded.radar_online,radar_geom=excluded.radar_geom,
    radar_altitude_amsl_m=excluded.radar_altitude_amsl_m,radar_heading_deg=excluded.radar_heading_deg,
    radar_base_heading_deg=excluded.radar_base_heading_deg,radar_gps_update_enabled=excluded.radar_gps_update_enabled,
    quality_flags=excluded.quality_flags,raw_payload=excluded.raw_payload,updated_at=now();

  insert into equipment.asset_status_current(
    asset_id,connectivity_status,dispatch_status,position_geom,last_heartbeat_at,observed_at,payload
  ) values(
    v_source.asset_id,case when v_box_online then 'online' when v_box_online=false then 'offline' else 'unknown' end,
    'unknown',(select geom from equipment.asset where id=v_source.asset_id),v_received_at,v_observed_at,
    jsonb_build_object('status_source','config_status')
  ) on conflict(asset_id) do update set
    connectivity_status=excluded.connectivity_status,last_heartbeat_at=excluded.last_heartbeat_at,
    observed_at=excluded.observed_at,payload=excluded.payload,updated_at=now();
  insert into situation.observation_source_status_current(observation_source_id,connector_state,last_message_at,updated_at)
  values(v_source.id,'connected',v_received_at,now())
  on conflict(observation_source_id) do update set connector_state='connected',
    last_message_at=greatest(situation.observation_source_status_current.last_message_at,excluded.last_message_at),updated_at=now();

  if cardinality(v_changed_fields)>0 then
    insert into equipment.counter_uas_status_event(
      asset_id,event_type,changed_fields,previous_state,current_state,observed_at,received_at
    ) values(v_source.asset_id,case when v_had_old then 'status_changed' else 'initialized' end,
      v_changed_fields,v_previous_state,v_current_state,v_observed_at,v_received_at)
    returning id into v_event_id;
  end if;
  if not exists(
    select 1 from equipment.counter_uas_telemetry_sample
    where asset_id=v_source.asset_id and received_at>v_received_at-interval '60 seconds'
  ) then
    insert into equipment.counter_uas_telemetry_sample(
      asset_id,observed_at,received_at,counter_voltage_v,counter_current_a,counter_power_w,
      counter_temperature_c,detection_azimuth_deg,counter_azimuth_deg,active_frequencies_mhz,
      radar_online,radar_heading_deg,quality_flags,raw_payload
    ) values(
      v_source.asset_id,v_observed_at,v_received_at,situation.safe_numeric(p_status->>'counterVoltageV'),
      situation.safe_numeric(p_status->>'counterCurrentA'),situation.safe_numeric(p_status->>'counterPowerW'),
      situation.safe_numeric(p_status->>'counterTemperatureC'),situation.safe_numeric(p_status->>'detectionAzimuthDeg'),
      situation.safe_numeric(p_status->>'counterAzimuthDeg'),v_active_frequencies,v_radar_online,
      situation.safe_numeric(p_status->>'radarHeadingDeg'),v_quality,p_status->'rawPayload'
    );
    v_sampled:=true;
  end if;
  return jsonb_build_object('status','accepted','assetId',v_source.asset_id,
    'sourceAssetId',v_source_asset_id,'eventId',v_event_id,'sampled',v_sampled);
end;
$$;
comment on function situation.ingest_detection_config_status(jsonb) is '接收规范化 config_status，更新盒子资产状态和反无设备当前遥测，仅在离散状态变化时追加事件并按 60 秒限频采样；返回 JSON：status、assetId、sourceAssetId、eventId、sampled。';

drop function if exists situation.sync_detection_box(jsonb);

create or replace function situation.sync_detection_source_asset(p_asset jsonb)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,equipment,situation
as $$
declare
  v_source situation.observation_source%rowtype;
  v_asset equipment.asset%rowtype;
  v_source_system text := p_asset->>'sourceSystem';
  v_station_id text := p_asset->>'stationId';
  v_source_asset_id text := nullif(btrim(p_asset->>'sourceAssetId'),'');
  v_connectivity_status text := p_asset->>'connectivityStatus';
  v_lng numeric := situation.safe_numeric(p_asset->>'longitude');
  v_lat numeric := situation.safe_numeric(p_asset->>'latitude');
  v_observed_at timestamptz;
  v_heartbeat_at timestamptz;
  v_geom geometry(Point,4326);
  v_metadata jsonb := p_asset->'metadata';
  v_status_payload jsonb := p_asset->'statusPayload';
begin
  if p_asset is null or jsonb_typeof(p_asset)<>'object' then
    raise exception 'normalized source asset must be a JSON object';
  end if;
  if p_asset->>'schemaVersion' is distinct from '1' then
    raise exception 'unsupported normalized source asset schemaVersion';
  end if;
  if v_source_system is null or v_station_id is null or v_source_asset_id is null then
    raise exception 'sourceSystem, stationId and sourceAssetId are required';
  end if;
  if v_connectivity_status not in ('online','offline','unknown') then
    raise exception 'connectivityStatus must be online, offline or unknown';
  end if;
  if jsonb_typeof(coalesce(v_metadata,'null'::jsonb))<>'object' then
    raise exception 'metadata must be a JSON object';
  end if;
  if jsonb_typeof(coalesce(v_status_payload,'null'::jsonb))<>'object' then
    raise exception 'statusPayload must be a JSON object';
  end if;
  begin
    v_observed_at := (p_asset->>'observedAt')::timestamptz;
    v_heartbeat_at := nullif(p_asset->>'heartbeatAt','')::timestamptz;
  exception when others then
    raise exception 'observedAt and heartbeatAt must be ISO 8601 timestamps with timezone';
  end;
  if v_observed_at is null then raise exception 'observedAt is required'; end if;
  if (v_lng is null)<>(v_lat is null) or (v_lng is not null and
      (v_lng not between -180 and 180 or v_lat not between -90 and 90 or (v_lng=0 and v_lat=0))) then
    raise exception 'longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_geom := case when v_lng is not null then ST_SetSRID(ST_MakePoint(v_lng,v_lat),4326) end;

  select * into v_source from situation.observation_source
  where source_system=v_source_system and external_station_id=v_station_id
    and external_box_code=v_source_asset_id and enabled;
  if not found then
    raise exception 'enabled observation source %.%.% is not configured',
      v_source_system,v_station_id,v_source_asset_id;
  end if;

  update equipment.asset set
    name=coalesce(nullif(btrim(p_asset->>'name'),''),name),
    manufacturer=coalesce(nullif(btrim(p_asset->>'manufacturer'),''),manufacturer),
    model=coalesce(nullif(btrim(p_asset->>'model'),''),model),
    geom=coalesce(v_geom,geom),
    metadata=metadata||jsonb_strip_nulls(v_metadata),
    updated_at=now()
  where id=v_source.asset_id
  returning * into v_asset;
  if not found then raise exception 'mapped equipment asset does not exist'; end if;

  insert into equipment.asset_status_current(
    asset_id,connectivity_status,dispatch_status,position_geom,last_heartbeat_at,observed_at,payload
  ) values(
    v_asset.id,v_connectivity_status,'unknown',v_asset.geom,v_heartbeat_at,v_observed_at,v_status_payload
  )
  on conflict(asset_id) do update set
    connectivity_status=excluded.connectivity_status,
    position_geom=excluded.position_geom,
    last_heartbeat_at=excluded.last_heartbeat_at,
    observed_at=excluded.observed_at,
    payload=excluded.payload;

  return jsonb_build_object('status','accepted','assetId',v_asset.id,
    'sourceAssetId',v_source_asset_id,'connectivityStatus',v_connectivity_status);
end;
$$;
comment on function situation.sync_detection_source_asset(jsonb) is '持久化已规范化且已配置的侦测来源资产台账、WGS84 登记位置和当前状态；返回 JSON：status、assetId、sourceAssetId、connectivityStatus。';


create or replace function situation.update_detection_connector_status(
  p_source_system text,p_station_id text,p_state text,p_observed_at timestamptz,
  p_last_message_at timestamptz default null,p_error_code text default null,p_details jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_source_id bigint; v_cursor bigint;
begin
  if p_state not in ('connected','disconnected','degraded','unknown') then raise exception 'invalid connector state'; end if;
  if p_details ?| array['password','token','secret','credential'] then raise exception 'connector details contain a forbidden key'; end if;
  select id into v_source_id from situation.observation_source
    where source_system=p_source_system and external_station_id=p_station_id and enabled order by id limit 1;
  if v_source_id is null then raise exception 'observation source is not configured'; end if;
  insert into situation.observation_source_status_current(
    observation_source_id,connector_state,last_connected_at,last_disconnected_at,last_message_at,
    last_error_code,last_error_at,details,updated_at
  ) values(v_source_id,p_state,case when p_state='connected' then p_observed_at end,
    case when p_state='disconnected' then p_observed_at end,p_last_message_at,p_error_code,
    case when p_error_code is not null then p_observed_at end,p_details,now())
  on conflict(observation_source_id) do update set connector_state=excluded.connector_state,
    last_connected_at=coalesce(excluded.last_connected_at,situation.observation_source_status_current.last_connected_at),
    last_disconnected_at=coalesce(excluded.last_disconnected_at,situation.observation_source_status_current.last_disconnected_at),
    last_message_at=coalesce(excluded.last_message_at,situation.observation_source_status_current.last_message_at),
    last_error_code=excluded.last_error_code,last_error_at=coalesce(excluded.last_error_at,situation.observation_source_status_current.last_error_at),
    details=excluded.details,updated_at=now();
  insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
  values('source_status','observation_source',v_source_id,v_source_id,p_observed_at,
    jsonb_build_object('source_id',v_source_id,'connector_state',p_state,'last_message_at',p_last_message_at)) returning id into v_cursor;
  return jsonb_build_object('status','accepted','sourceId',v_source_id,'changeCursor',v_cursor);
end;
$$;
comment on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) is '更新侦测连接器状态并生成来源状态增量；返回 JSON：status、sourceId、changeCursor。';

create or replace function situation.reconcile_detection_targets(
  p_source_system text,p_station_id text,p_observed_at timestamptz,p_present_target_ids text[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_source situation.observation_source%rowtype; v_row record; v_closed int:=0; v_cursor bigint;
begin
  select * into v_source from situation.observation_source where source_system=p_source_system
    and external_station_id=p_station_id and enabled order by id limit 1;
  if not found then raise exception 'observation source is not configured'; end if;
  update situation.observation_source_status_current set last_snapshot_at=p_observed_at,updated_at=now()
    where observation_source_id=v_source.id;
  for v_row in select s.id session_id,s.target_id,t.id track_id from situation.source_target_session s
    join situation.target_track t on t.source_session_id=s.id
    where s.observation_source_id=v_source.id and s.state='active'
      and not (s.source_target_id=any(coalesce(p_present_target_ids,array[]::text[])))
      and s.last_observed_at < p_observed_at-make_interval(secs=>v_source.lost_timeout_seconds)
    for update of s,t
  loop
    update situation.source_target_session set state='lost',ended_at=p_observed_at,end_reason='reconciled_absent',version=version+1
      where id=v_row.session_id;
    update situation.target_track set status='lost',lost_at=p_observed_at,version=version+1,updated_at=now() where id=v_row.track_id;
    update situation.airspace_target set active=false,updated_at=now() where id=v_row.target_id;
    insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
    values('target_remove','target_track',v_row.track_id,v_source.id,p_observed_at,
      jsonb_build_object('track_id',v_row.track_id,'target_id',v_row.target_id,'reason','reconciled_absent')) returning id into v_cursor;
    v_closed:=v_closed+1;
  end loop;
  return jsonb_build_object('status','accepted','closedSessions',v_closed,'changeCursor',v_cursor);
end;
$$;
comment on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) is '按在线目标快照和来源宽限时间关闭缺失会话；返回 JSON：status、closedSessions、changeCursor。';

create or replace view api.counter_uas_telemetry_current as
select t.asset_id,a.asset_code,a.name as asset_name,t.observed_at,t.received_at,
  t.unattended,t.detection_device_online,t.countermeasure_device_online,
  t.counter_voltage_v,t.counter_current_a,t.counter_power_w,t.counter_temperature_c,
  t.detection_azimuth_deg,t.detection_rotating,t.counter_azimuth_deg,t.counter_rotating,
  t.active_frequencies_mhz,t.radar_device_sn,t.radar_asset_id,t.radar_online,
  case when t.radar_geom is null then null else ST_AsGeoJSON(t.radar_geom)::jsonb end as radar_position,
  t.radar_altitude_amsl_m,t.radar_heading_deg,t.radar_base_heading_deg,
  t.radar_gps_update_enabled,t.quality_flags,t.raw_payload,t.updated_at,
  coalesce(ast.connectivity_status,'unknown') as asset_connectivity_status,
  src.observation_source_id,src.station_id,src.box_code,
  coalesce(src.connector_state,'unknown') as connector_state,src.last_message_at,
  15 as telemetry_stale_after_seconds,
  t.received_at < now()-interval '15 seconds' as telemetry_stale
from equipment.counter_uas_telemetry_current t
join equipment.asset a on a.id=t.asset_id
left join equipment.asset_status_current ast on ast.asset_id=t.asset_id
left join lateral (
  select os.id as observation_source_id,os.external_station_id as station_id,
    os.external_box_code as box_code,sc.connector_state,sc.last_message_at
  from situation.observation_source os
  left join situation.observation_source_status_current sc on sc.observation_source_id=os.id
  where os.asset_id=t.asset_id and os.enabled
  order by os.id
  limit 1
) src on true;
comment on view api.counter_uas_telemetry_current is '管理员查询反无综合设备最新 config_status 遥测的只读资源。';
comment on column api.counter_uas_telemetry_current.asset_id is '产生遥测的反无综合设备资产 ID。';
comment on column api.counter_uas_telemetry_current.asset_code is '反无综合设备资产编码。';
comment on column api.counter_uas_telemetry_current.asset_name is '反无综合设备资产名称。';
comment on column api.counter_uas_telemetry_current.observed_at is '设备状态观测时间；来源未提供时间时使用平台接收时间。';
comment on column api.counter_uas_telemetry_current.received_at is '平台接收到 config_status 消息的时间。';
comment on column api.counter_uas_telemetry_current.unattended is '设备是否处于无人值守模式。';
comment on column api.counter_uas_telemetry_current.detection_device_online is '厂商 controlStatus 对应的侦测子系统在线状态。';
comment on column api.counter_uas_telemetry_current.countermeasure_device_online is '厂商 controlStatus99 对应的处置子系统在线状态。';
comment on column api.counter_uas_telemetry_current.counter_voltage_v is '处置子系统电压，单位 V。';
comment on column api.counter_uas_telemetry_current.counter_current_a is '处置子系统电流，单位 A。';
comment on column api.counter_uas_telemetry_current.counter_power_w is '处置子系统功率，单位 W。';
comment on column api.counter_uas_telemetry_current.counter_temperature_c is '处置子系统温度，单位摄氏度。';
comment on column api.counter_uas_telemetry_current.detection_azimuth_deg is '侦测转台方位角，单位度，范围 0 至 360。';
comment on column api.counter_uas_telemetry_current.detection_rotating is '侦测转台当前是否正在旋转。';
comment on column api.counter_uas_telemetry_current.counter_azimuth_deg is '处置转台方位角，单位度，范围 0 至 360。';
comment on column api.counter_uas_telemetry_current.counter_rotating is '处置转台当前是否正在旋转。';
comment on column api.counter_uas_telemetry_current.active_frequencies_mhz is '当前开启频段，统一转换为 MHz 数值数组。';
comment on column api.counter_uas_telemetry_current.radar_device_sn is '厂商上报的雷达设备序列号。';
comment on column api.counter_uas_telemetry_current.radar_asset_id is '能够确认独立物理身份时关联的雷达设备资产。';
comment on column api.counter_uas_telemetry_current.radar_online is '厂商上报的雷达设备在线状态。';
comment on column api.counter_uas_telemetry_current.radar_position is '厂商上报雷达位置的 WGS84 GeoJSON Point；无有效位置时为空。';
comment on column api.counter_uas_telemetry_current.radar_altitude_amsl_m is '厂商雷达海拔，统一按 AMSL 米保存。';
comment on column api.counter_uas_telemetry_current.radar_heading_deg is '雷达当前航向角，单位度，范围 0 至 360。';
comment on column api.counter_uas_telemetry_current.radar_base_heading_deg is '雷达安装基准航向角，单位度，范围 0 至 360。';
comment on column api.counter_uas_telemetry_current.radar_gps_update_enabled is '雷达是否启用 GPS 位置更新。';
comment on column api.counter_uas_telemetry_current.quality_flags is '规范化和数据质量标记数组。';
comment on column api.counter_uas_telemetry_current.raw_payload is '最近一次厂商 config_status 原始载荷。';
comment on column api.counter_uas_telemetry_current.updated_at is '当前遥测快照在平台中的更新时间。';
comment on column api.counter_uas_telemetry_current.asset_connectivity_status is '盒子资产当前连通状态，不等同于接入链路或子系统状态。';
comment on column api.counter_uas_telemetry_current.observation_source_id is '遥测绑定的观测来源 ID。';
comment on column api.counter_uas_telemetry_current.station_id is '遥测来源的外部站点 ID。';
comment on column api.counter_uas_telemetry_current.box_code is '遥测来源的外部盒子编码。';
comment on column api.counter_uas_telemetry_current.connector_state is '绑定观测来源的接入链路状态。';
comment on column api.counter_uas_telemetry_current.last_message_at is '接入链路最近收到合法来源消息的时间。';
comment on column api.counter_uas_telemetry_current.telemetry_stale_after_seconds is '后台判定实时遥测过期的秒数阈值。';
comment on column api.counter_uas_telemetry_current.telemetry_stale is '最近遥测是否已超过后台展示的新鲜度阈值。';

create or replace view api.counter_uas_status_events as
select e.id,e.asset_id,a.asset_code,a.name as asset_name,e.event_type,e.changed_fields,
  e.previous_state,e.current_state,e.observed_at,e.received_at,e.created_at
from equipment.counter_uas_status_event e join equipment.asset a on a.id=e.asset_id;
comment on view api.counter_uas_status_events is '管理员查询反无设备离散状态变化历史的只读资源。';
comment on column api.counter_uas_status_events.changed_fields is '本次状态事件发生变化的字段列表。';

create or replace view api.counter_uas_telemetry_samples as
select s.id,s.asset_id,a.asset_code,a.name as asset_name,s.observed_at,s.received_at,
  s.counter_voltage_v,s.counter_current_a,s.counter_power_w,s.counter_temperature_c,
  s.detection_azimuth_deg,s.counter_azimuth_deg,s.active_frequencies_mhz,
  s.radar_online,s.radar_heading_deg,s.quality_flags,s.raw_payload,s.sampled_at
from equipment.counter_uas_telemetry_sample s join equipment.asset a on a.id=s.asset_id;
comment on view api.counter_uas_telemetry_samples is '管理员查询反无设备每 60 秒限频遥测采样的只读资源。';
comment on column api.counter_uas_telemetry_samples.sampled_at is '平台写入采样记录的时间。';

create or replace view api.detection_methods as
select m.code,m.name,m.description,m.lifecycle_status,m.visible,m.sort_order,m.display_metadata,
  m.created_at,m.updated_at,count(o.observation_id) as observation_count
from situation.detection_method m
left join situation.target_observation o on o.detection_method_code=m.code
group by m.code;
comment on view api.detection_methods is '后台和业务筛选器使用的平台稳定侦测方式只读字典，含历史观测引用数量。';
comment on column api.detection_methods.code is '不可变的平台稳定侦测方式编码。';
comment on column api.detection_methods.observation_count is '引用该侦测方式的目标观测数量。';

create or replace view api.detection_method_mappings as
select x.id,x.source_system,x.vendor_code,x.method_code,m.name as method_name,
  x.accept_ingest,x.metadata,x.created_at,x.updated_at
from situation.detection_method_mapping x
join situation.detection_method m on m.code=x.method_code;
comment on view api.detection_method_mappings is '后台维护的厂商侦测枚举到平台稳定侦测方式的只读映射。';
comment on column api.detection_method_mappings.vendor_code is '厂商原始编码文本。';
comment on column api.detection_method_mappings.accept_ingest is '该厂商编码是否允许继续接入。';

create or replace view api.detection_method_mapping_history as
select id,mapping_id,source_system,vendor_code,old_method_code,new_method_code,
  old_accept_ingest,new_accept_ingest,old_metadata,new_metadata,changed_at,changed_by
from situation.detection_method_mapping_history;
comment on view api.detection_method_mapping_history is '管理员只读查询的厂商侦测方式映射追加审计历史。';
comment on column api.detection_method_mapping_history.changed_by is '执行映射变更的 JWT 主体或数据库会话用户。';

create or replace function api.create_detection_method(
  p_code text,p_name text,p_description text default null,p_visible boolean default true,
  p_sort_order integer default 0,p_display_metadata jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_method situation.detection_method%rowtype;
begin
  p_code:=lower(btrim(p_code));
  if p_code is null or p_code !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'detection method code must use lowercase letters, numbers and underscores';
  end if;
  if nullif(btrim(p_name),'') is null then raise exception 'detection method name is required'; end if;
  if p_display_metadata is null or jsonb_typeof(p_display_metadata)<>'object' then
    raise exception 'display metadata must be a JSON object';
  end if;
  insert into situation.detection_method(code,name,description,visible,sort_order,display_metadata)
  values(p_code,btrim(p_name),nullif(btrim(p_description),''),coalesce(p_visible,true),coalesce(p_sort_order,0),p_display_metadata)
  returning * into v_method;
  return to_jsonb(v_method);
exception when unique_violation then
  raise exception 'detection method code % already exists',p_code;
end;
$$;
comment on function api.create_detection_method(text,text,text,boolean,integer,jsonb) is '创建平台稳定侦测方式；编码创建后不可修改；返回 JSON：code、name、description、lifecycle_status、visible、sort_order、display_metadata 和时间。';

create or replace function api.update_detection_method(p_code text,p_changes jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_method situation.detection_method%rowtype;
begin
  if p_changes is null or jsonb_typeof(p_changes)<>'object' then raise exception 'changes must be a JSON object'; end if;
  if p_changes ? 'code' then raise exception 'detection method code is immutable'; end if;
  if p_changes - array['name','description','lifecycle_status','visible','sort_order','display_metadata']::text[] <> '{}'::jsonb then
    raise exception 'changes contain unsupported detection method fields';
  end if;
  if p_changes ? 'name' and nullif(btrim(p_changes->>'name'),'') is null then raise exception 'detection method name is required'; end if;
  if p_changes ? 'lifecycle_status' and p_changes->>'lifecycle_status' not in ('active','deprecated') then
    raise exception 'lifecycle status must be active or deprecated';
  end if;
  if p_changes ? 'display_metadata' and jsonb_typeof(p_changes->'display_metadata')<>'object' then
    raise exception 'display metadata must be a JSON object';
  end if;
  update situation.detection_method set
    name=case when p_changes ? 'name' then btrim(p_changes->>'name') else name end,
    description=case when p_changes ? 'description' then nullif(btrim(p_changes->>'description'),'') else description end,
    lifecycle_status=case when p_changes ? 'lifecycle_status' then p_changes->>'lifecycle_status' else lifecycle_status end,
    visible=case when p_changes ? 'visible' then (p_changes->>'visible')::boolean else visible end,
    sort_order=case when p_changes ? 'sort_order' then (p_changes->>'sort_order')::integer else sort_order end,
    display_metadata=case when p_changes ? 'display_metadata' then p_changes->'display_metadata' else display_metadata end,
    updated_at=now()
  where code=p_code returning * into v_method;
  if not found then raise exception 'detection method % does not exist',p_code; end if;
  return to_jsonb(v_method);
end;
$$;
comment on function api.update_detection_method(text,jsonb) is '更新侦测方式名称、说明、生命周期和展示配置，稳定编码不可修改；返回更新后的侦测方式 JSON。';

create or replace function api.upsert_detection_method_mapping(
  p_source_system text,p_vendor_code text,p_method_code text,
  p_accept_ingest boolean default true,p_metadata jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_mapping situation.detection_method_mapping%rowtype;
begin
  p_source_system:=nullif(btrim(p_source_system),'');
  p_vendor_code:=nullif(btrim(p_vendor_code),'');
  if p_source_system is null or p_vendor_code is null then raise exception 'source system and vendor code are required'; end if;
  if not exists(select 1 from situation.detection_method where code=p_method_code and lifecycle_status='active') then
    raise exception 'active detection method % does not exist',p_method_code;
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' then raise exception 'metadata must be a JSON object'; end if;
  insert into situation.detection_method_mapping(source_system,vendor_code,method_code,accept_ingest,metadata)
  values(p_source_system,p_vendor_code,p_method_code,coalesce(p_accept_ingest,true),p_metadata)
  on conflict(source_system,vendor_code) do update set
    method_code=excluded.method_code,accept_ingest=excluded.accept_ingest,
    metadata=excluded.metadata,updated_at=now()
  returning * into v_mapping;
  return to_jsonb(v_mapping);
end;
$$;
comment on function api.upsert_detection_method_mapping(text,text,text,boolean,jsonb) is '新增或更新来源系统厂商编码到活动侦测方式的映射；返回 JSON：id、source_system、vendor_code、method_code、accept_ingest、metadata 和时间。';

create or replace view api.detection_source_types as
select vendor_code as source_type_code,code,name,description from situation.detection_source_type where enabled;
comment on view api.detection_source_types is '雷达和电侦来源类型只读字典。';
comment on column api.detection_source_types.source_type_code is '厂商来源类型数值，10 雷达、20 电侦。';

create or replace view api.detection_observation_sources as
select s.id,s.source_system,s.external_station_id as station_id,s.external_box_code as box_code,
  s.name,s.coordinate_system,s.enabled,st.connector_state,st.last_message_at,st.last_snapshot_at,st.updated_at,
  s.asset_id,a.asset_code,a.name as asset_name,a.lifecycle_status as asset_lifecycle_status,
  s.source_timezone,s.lost_timeout_seconds,st.last_connected_at,st.last_disconnected_at,
  st.last_error_code,st.last_error_at,st.details,
  coalesce(cap.capability_codes,array[]::text[]) capability_codes
from situation.observation_source s
join equipment.asset a on a.id=s.asset_id
left join situation.observation_source_status_current st on st.observation_source_id=s.id
left join lateral (
  select array_agg(ac.capability_code order by ac.capability_code) capability_codes
  from equipment.asset_capability ac where ac.asset_id=s.asset_id and ac.enabled
) cap on true;
comment on view api.detection_observation_sources is '侦测观测来源、设备资产映射和接入链路状态只读资源。';
comment on column api.detection_observation_sources.station_id is '来源系统站点 ID。';
comment on column api.detection_observation_sources.connector_state is '接入连接器状态，不等同于物理设备在线状态。';
comment on column api.detection_observation_sources.asset_id is '来源映射的统一设备资产 ID。';
comment on column api.detection_observation_sources.lost_timeout_seconds is '目标未出现在来源快照后判定丢失的宽限秒数。';
comment on column api.detection_observation_sources.last_error_code is '连接器最近一次错误编码，不包含敏感错误详情。';
comment on column api.detection_observation_sources.capability_codes is '来源映射设备当前启用的能力编码；仅描述能力，不代表每条观测均有对应结果。';

create or replace function api.get_detection_situation_snapshot(
  p_station_ids text[] default null,p_source_type_codes smallint[] default null,
  p_west double precision default null,p_south double precision default null,
  p_east double precision default null,p_north double precision default null,
  p_active_within_seconds integer default 30,p_limit integer default 1000
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_result jsonb;
begin
  if p_active_within_seconds not between 5 and 3600 then raise exception 'active window must be between 5 and 3600 seconds'; end if;
  if p_limit not between 1 and 5000 then raise exception 'limit must be between 1 and 5000'; end if;
  if (p_west is null)<>(p_south is null) or (p_west is null)<>(p_east is null) or (p_west is null)<>(p_north is null) then
    raise exception 'bbox requires west, south, east and north';
  end if;
  with current_rows as (
    select t.id track_id,t.track_code,t.status,t.target_id,s.source_target_id,s.source_type_code,
      dt.name source_type_name,o.model,o.frequency_mhz,o.relative_height_m,o.horizontal_distance_m,
      o.azimuth_deg,o.elevation_deg,o.speed_mps,o.quality_flags,r.observed_at,r.geom,r.height_amsl_m,
      src.external_station_id station_id
    from situation.target_track t join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    left join equipment.raw_observation r on r.id=t.current_observation_id
    left join situation.target_observation o on o.observation_id=coalesce(t.current_observation_id,s.current_observation_id)
    left join situation.detection_source_type dt on dt.vendor_code=s.source_type_code
    where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      and (p_station_ids is null or src.external_station_id=any(p_station_ids))
      and (p_source_type_codes is null or s.source_type_code=any(p_source_type_codes))
  ), bounded as (
    select * from current_rows where geom is null or p_west is null or ST_Intersects(geom,ST_MakeEnvelope(p_west,p_south,p_east,p_north,4326))
    order by observed_at desc nulls last limit p_limit
  ) select jsonb_build_object('generated_at',now(),'cursor',coalesce((select max(id) from situation.change_event),0),
    'targets',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'target_id',target_id,'track_id',track_id,'track_code',track_code,'status',status,
      'source_target_id',source_target_id,'source_type_code',source_type_code,'source_type_name',source_type_name,
      'model',model,'observed_at',observed_at,'position',ST_AsGeoJSON(geom)::jsonb,'altitude_amsl_m',height_amsl_m,
      'relative_height_m',relative_height_m,'speed_mps',speed_mps,'azimuth_deg',azimuth_deg,
      'elevation_deg',elevation_deg,'horizontal_distance_m',horizontal_distance_m,'frequency_mhz',frequency_mhz,
      'position_status','valid','quality_flags',quality_flags)) order by observed_at desc) from bounded where geom is not null),'[]'::jsonb),
    'non_spatial_detections',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'target_id',target_id,'track_id',track_id,'source_target_id',source_target_id,'source_type_code',source_type_code,
      'source_type_name',source_type_name,'model',model,'frequency_mhz',frequency_mhz,'observed_at',observed_at,
      'quality_flags',quality_flags)) order by observed_at desc) from bounded where geom is null),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(v) order by station_id) from api.detection_observation_sources v
      where p_station_ids is null or station_id=any(p_station_ids)),'[]'::jsonb)) into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) is '返回 JSON：generated_at、cursor、targets（有位置活动目标）、non_spatial_detections（无位置侦测）和 sources（来源状态）；支持站点、来源类型、WGS84 bbox、活动窗口和数量上限。';

create or replace function api.get_detection_live_tracks(
  p_station_ids text[] default null,p_source_type_codes smallint[] default null,
  p_active_within_seconds integer default 120,p_trail_seconds integer default 300,
  p_max_tracks integer default 1000,p_max_points_per_track integer default 300
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_result jsonb;
begin
  if p_active_within_seconds not between 5 and 3600 then raise exception 'active window must be between 5 and 3600 seconds'; end if;
  if p_trail_seconds not between 30 and 1800 then raise exception 'trail window must be between 30 and 1800 seconds'; end if;
  if p_max_tracks not between 1 and 5000 then raise exception 'max tracks must be between 1 and 5000'; end if;
  if p_max_points_per_track not between 2 and 1000 then raise exception 'max points per track must be between 2 and 1000'; end if;
  with active_tracks as (
    select t.id track_id,t.track_code,t.target_id,t.status,s.source_target_id,s.source_type_code,
      dt.name source_type_name,src.external_station_id station_id,t.last_observed_at,
      o.model,o.frequency_mhz,o.quality_flags
    from situation.target_track t
    join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    left join situation.detection_source_type dt on dt.vendor_code=s.source_type_code
    left join situation.target_observation o on o.observation_id=t.current_observation_id
    where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      and (p_station_ids is null or src.external_station_id=any(p_station_ids))
      and (p_source_type_codes is null or s.source_type_code=any(p_source_type_codes))
    order by t.last_observed_at desc,t.id desc limit p_max_tracks
  ), live_tracks as (
    select a.*,coalesce(points.items,'[]'::jsonb) points
    from active_tracks a
    left join lateral (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'observation_id',p.id,'observed_at',p.observed_at,'position',ST_AsGeoJSON(p.geom)::jsonb,
        'altitude_amsl_m',p.height_amsl_m,'source_type_code',p.source_type_code,
        'speed_mps',p.speed_mps,'quality_flags',p.quality_flags
      )) order by p.observed_at,p.id) items
      from (
        select r.id,r.observed_at,r.geom,r.height_amsl_m,to2.source_type_code,to2.speed_mps,to2.quality_flags
        from situation.track_observation x
        join equipment.raw_observation r on r.id=x.observation_id
        join situation.target_observation to2 on to2.observation_id=r.id
        where x.track_id=a.track_id and r.geom is not null
          and r.observed_at>=now()-make_interval(secs=>p_trail_seconds)
        order by r.observed_at desc,r.id desc limit p_max_points_per_track
      ) p
    ) points on true
  )
  select jsonb_build_object(
    'generated_at',now(),'cursor',coalesce((select max(id) from situation.change_event),0),
    'trail_seconds',p_trail_seconds,
    'tracks',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'track_id',track_id,'track_code',track_code,'target_id',target_id,'status',status,
      'station_id',station_id,'source_target_id',source_target_id,'source_type_code',source_type_code,
      'source_type_name',source_type_name,'model',model,'frequency_mhz',frequency_mhz,
      'quality_flags',quality_flags,'last_observed_at',last_observed_at,'points',points
    )) order by last_observed_at desc) from live_tracks),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(v) order by station_id)
      from api.detection_observation_sources v
      where p_station_ids is null or station_id=any(p_station_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_live_tracks(text[],smallint[],integer,integer,integer,integer) is '返回 JSON：generated_at、cursor、trail_seconds、tracks 和 sources；批量返回当前活动目标及最近一段空间尾迹，每条航迹点数有界。';

create or replace function api.get_detection_live_tracks_v2(
  p_observation_source_ids bigint[] default null,p_producer_asset_ids bigint[] default null,
  p_detection_method_codes text[] default null,p_active_within_seconds integer default 120,
  p_trail_seconds integer default 300,p_max_tracks integer default 1000,
  p_max_points_per_track integer default 300
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_result jsonb;
begin
  if p_active_within_seconds not between 5 and 3600 then raise exception 'active window must be between 5 and 3600 seconds'; end if;
  if p_trail_seconds not between 30 and 1800 then raise exception 'trail window must be between 30 and 1800 seconds'; end if;
  if p_max_tracks not between 1 and 5000 then raise exception 'max tracks must be between 1 and 5000'; end if;
  if p_max_points_per_track not between 2 and 1000 then raise exception 'max points per track must be between 2 and 1000'; end if;
  with active_tracks as (
    select t.id track_id,t.track_code,t.target_id,t.status,s.source_target_id,
      src.id observation_source_id,src.external_station_id station_id,src.asset_id source_asset_id,
      t.last_observed_at
    from situation.target_track t
    join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      and (p_observation_source_ids is null or src.id=any(p_observation_source_ids))
      and (p_detection_method_codes is null or exists(
        select 1 from situation.track_observation fx
        join situation.target_observation fo on fo.observation_id=fx.observation_id
        join equipment.raw_observation fr on fr.id=fx.observation_id
        where fx.track_id=t.id and fo.detection_method_code=any(p_detection_method_codes)
          and fr.observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      ))
      and (p_producer_asset_ids is null or exists(
        select 1 from situation.track_observation px
        join situation.target_observation po on po.observation_id=px.observation_id
        join equipment.raw_observation pr on pr.id=px.observation_id
        where px.track_id=t.id and po.producer_asset_id=any(p_producer_asset_ids)
          and pr.observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      ))
    order by t.last_observed_at desc,t.id desc limit p_max_tracks
  ), live_tracks as (
    select a.*,coalesce(points.items,'[]'::jsonb) points,
      coalesce(methods.items,'[]'::jsonb) observation_methods,
      latest.detection_method_code latest_observation_method_code,
      latest.detection_method_name latest_observation_method_name,
      latest.producer_asset_id,latest.model,latest.frequency_mhz,latest.quality_flags
    from active_tracks a
    left join lateral (
      select jsonb_agg(jsonb_build_object('code',q.code,'name',q.name) order by q.sort_order,q.code) items
      from (
        select distinct dm.code,dm.name,dm.sort_order
        from situation.track_observation mx
        join equipment.raw_observation mr on mr.id=mx.observation_id
        join situation.target_observation mo on mo.observation_id=mx.observation_id
        join situation.detection_method dm on dm.code=mo.detection_method_code
        where mx.track_id=a.track_id and mr.observed_at>=now()-make_interval(secs=>p_trail_seconds)
      ) q
    ) methods on true
    left join lateral (
      select lo.detection_method_code,dm.name detection_method_name,lo.producer_asset_id,
        lo.model,lo.frequency_mhz,lo.quality_flags
      from situation.track_observation lx
      join equipment.raw_observation lr on lr.id=lx.observation_id
      join situation.target_observation lo on lo.observation_id=lx.observation_id
      left join situation.detection_method dm on dm.code=lo.detection_method_code
      where lx.track_id=a.track_id
      order by lr.observed_at desc,lr.id desc limit 1
    ) latest on true
    left join lateral (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'observation_id',p.id,'observed_at',p.observed_at,'position',ST_AsGeoJSON(p.geom)::jsonb,
        'altitude_amsl_m',p.height_amsl_m,'detection_method_code',p.detection_method_code,
        'detection_method_name',p.detection_method_name,'producer_asset_id',p.producer_asset_id,
        'speed_mps',p.speed_mps,'quality_flags',p.quality_flags
      )) order by p.observed_at,p.id) items
      from (
        select r.id,r.observed_at,r.geom,r.height_amsl_m,o.detection_method_code,
          dm.name detection_method_name,o.producer_asset_id,o.speed_mps,o.quality_flags
        from situation.track_observation x
        join equipment.raw_observation r on r.id=x.observation_id
        join situation.target_observation o on o.observation_id=r.id
        left join situation.detection_method dm on dm.code=o.detection_method_code
        where x.track_id=a.track_id and r.geom is not null
          and r.observed_at>=now()-make_interval(secs=>p_trail_seconds)
        order by r.observed_at desc,r.id desc limit p_max_points_per_track
      ) p
    ) points on true
  )
  select jsonb_build_object(
    'generated_at',now(),'cursor',coalesce((select max(id) from situation.change_event),0),
    'trail_seconds',p_trail_seconds,
    'detection_methods',coalesce((select jsonb_agg(jsonb_build_object(
      'code',code,'name',name,'description',description,'display_metadata',display_metadata
    ) order by sort_order,code) from situation.detection_method where visible),'[]'::jsonb),
    'tracks',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'track_id',track_id,'track_code',track_code,'target_id',target_id,'status',status,
      'observation_source_id',observation_source_id,'station_id',station_id,
      'source_asset_id',source_asset_id,'source_target_id',source_target_id,
      'producer_asset_id',producer_asset_id,'observation_methods',observation_methods,
      'latest_observation_method_code',latest_observation_method_code,
      'latest_observation_method_name',latest_observation_method_name,'model',model,
      'frequency_mhz',frequency_mhz,'quality_flags',quality_flags,
      'last_observed_at',last_observed_at,'points',points
    )) order by last_observed_at desc) from live_tracks),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(v) order by id)
      from api.detection_observation_sources v
      where p_observation_source_ids is null or id=any(p_observation_source_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_live_tracks_v2(bigint[],bigint[],text[],integer,integer,integer,integer) is '返回 JSON：generated_at、cursor、trail_seconds、detection_methods、tracks 和 sources；按观测来源、实际生产设备及平台稳定侦测方式过滤活动航迹，并返回多方式证据与有界空间尾迹。';

create or replace function api.get_detection_live_tracks_v3(
  p_observation_source_ids bigint[] default null,p_producer_asset_ids bigint[] default null,
  p_detection_method_codes text[] default null,p_active_within_seconds integer default 120,
  p_trail_seconds integer default 300,p_max_tracks integer default 1000,
  p_max_points_per_track integer default 300
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_result jsonb;
begin
  if p_active_within_seconds not between 5 and 3600 then raise exception 'active window must be between 5 and 3600 seconds'; end if;
  if p_trail_seconds not between 30 and 1800 then raise exception 'trail window must be between 30 and 1800 seconds'; end if;
  if p_max_tracks not between 1 and 5000 then raise exception 'max tracks must be between 1 and 5000'; end if;
  if p_max_points_per_track not between 2 and 1000 then raise exception 'max observations per track must be between 2 and 1000'; end if;
  with active_tracks as (
    select t.id track_id,t.track_code,t.target_id,t.status,s.source_target_id,
      src.id observation_source_id,src.external_station_id station_id,src.asset_id source_asset_id,
      t.last_observed_at
    from situation.target_track t
    join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      and (p_observation_source_ids is null or src.id=any(p_observation_source_ids))
      and (p_detection_method_codes is null or exists(
        select 1 from situation.track_observation fx
        join situation.target_observation fo on fo.observation_id=fx.observation_id
        join equipment.raw_observation fr on fr.id=fx.observation_id
        where fx.track_id=t.id and fo.detection_method_code=any(p_detection_method_codes)
          and fr.observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      ))
      and (p_producer_asset_ids is null or exists(
        select 1 from situation.track_observation px
        join situation.target_observation po on po.observation_id=px.observation_id
        join equipment.raw_observation pr on pr.id=px.observation_id
        where px.track_id=t.id and po.producer_asset_id=any(p_producer_asset_ids)
          and pr.observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      ))
    order by t.last_observed_at desc,t.id desc limit p_max_tracks
  ), live_tracks as (
    select a.*,coalesce(observations.items,'[]'::jsonb) observations,
      coalesce(methods.items,'[]'::jsonb) observation_methods,
      latest.detection_method_code latest_observation_method_code,
      latest.detection_method_name latest_observation_method_name,
      latest.producer_asset_id,latest.model,latest.frequency_mhz,latest.quality_flags
    from active_tracks a
    left join lateral (
      select jsonb_agg(jsonb_build_object('code',q.code,'name',q.name) order by q.sort_order,q.code) items
      from (
        select distinct dm.code,dm.name,dm.sort_order
        from situation.track_observation mx
        join equipment.raw_observation mr on mr.id=mx.observation_id
        join situation.target_observation mo on mo.observation_id=mx.observation_id
        join situation.detection_method dm on dm.code=mo.detection_method_code
        where mx.track_id=a.track_id and mr.observed_at>=now()-make_interval(secs=>p_trail_seconds)
      ) q
    ) methods on true
    left join lateral (
      select lo.detection_method_code,dm.name detection_method_name,lo.producer_asset_id,
        lo.model,lo.frequency_mhz,lo.quality_flags
      from situation.track_observation lx
      join equipment.raw_observation lr on lr.id=lx.observation_id
      join situation.target_observation lo on lo.observation_id=lx.observation_id
      left join situation.detection_method dm on dm.code=lo.detection_method_code
      where lx.track_id=a.track_id order by lr.observed_at desc,lr.id desc limit 1
    ) latest on true
    left join lateral (
      select jsonb_agg(jsonb_build_object(
        'observation_id',p.id,'observed_at',p.observed_at,
        'target_location',case when p.geom is null then null else jsonb_build_object(
          'position',ST_AsGeoJSON(p.geom)::jsonb,'altitude_amsl_m',p.height_amsl_m,
          'relative_height_m',p.relative_height_m) end,
        'remote_pilot_location',case when p.pilot_geom is null then null else jsonb_build_object(
          'position',ST_AsGeoJSON(p.pilot_geom)::jsonb,'source','vendor_reported','accuracy_m',null) end,
        'detection_method_code',p.detection_method_code,
        'detection_method_name',p.detection_method_name,'producer_asset_id',p.producer_asset_id,
        'speed_mps',p.speed_mps,'quality_flags',p.quality_flags
      ) order by p.observed_at,p.id) items
      from (
        select r.id,r.observed_at,r.geom,r.height_amsl_m,o.pilot_geom,o.relative_height_m,
          o.detection_method_code,dm.name detection_method_name,o.producer_asset_id,o.speed_mps,o.quality_flags
        from situation.track_observation x
        join equipment.raw_observation r on r.id=x.observation_id
        join situation.target_observation o on o.observation_id=r.id
        left join situation.detection_method dm on dm.code=o.detection_method_code
        where x.track_id=a.track_id and r.observed_at>=now()-make_interval(secs=>p_trail_seconds)
        order by r.observed_at desc,r.id desc limit p_max_points_per_track
      ) p
    ) observations on true
  )
  select jsonb_build_object(
    'generated_at',now(),'cursor',coalesce((select max(id) from situation.change_event),0),
    'trail_seconds',p_trail_seconds,
    'detection_methods',coalesce((select jsonb_agg(jsonb_build_object(
      'code',code,'name',name,'description',description,'display_metadata',display_metadata
    ) order by sort_order,code) from situation.detection_method where visible),'[]'::jsonb),
    'tracks',coalesce((select jsonb_agg(jsonb_build_object(
      'track_id',track_id,'track_code',track_code,'target_id',target_id,'status',status,
      'observation_source_id',observation_source_id,'station_id',station_id,
      'source_asset_id',source_asset_id,'source_target_id',source_target_id,
      'producer_asset_id',producer_asset_id,'observation_methods',observation_methods,
      'latest_observation_method_code',latest_observation_method_code,
      'latest_observation_method_name',latest_observation_method_name,'model',model,
      'frequency_mhz',frequency_mhz,'quality_flags',quality_flags,
      'last_observed_at',last_observed_at,'observations',observations,
      'riskAssessment',event_response.risk_assessment_json(track_id)
    ) order by last_observed_at desc) from live_tracks),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(v) order by id)
      from api.detection_observation_sources v
      where p_observation_source_ids is null or id=any(p_observation_source_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_live_tracks_v3(bigint[],bigint[],text[],integer,integer,integer,integer) is '返回 JSON：generated_at、cursor、trail_seconds、detection_methods、tracks、observations 和 sources；每条航迹包含当前 riskAssessment，每条观测分别表达目标位置与远程飞手位置。';

create or replace function api.get_detection_situation_changes(
  p_after_cursor bigint,p_station_ids text[] default null,p_limit integer default 500
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,event_response as $$
declare v_result jsonb;
begin
  if p_after_cursor is null or p_after_cursor<0 then raise exception 'after cursor must be non-negative'; end if;
  if p_limit not between 1 and 1000 then raise exception 'limit must be between 1 and 1000'; end if;
  with filtered as (
    select e.* from situation.change_event e left join situation.observation_source s on s.id=e.observation_source_id
    where e.id>p_after_cursor and (p_station_ids is null or s.external_station_id=any(p_station_ids)) order by e.id limit p_limit+1
  ), page as (select * from filtered order by id limit p_limit), enriched as (
    select p.id,p.event_type,p.aggregate_type,p.aggregate_id,p.occurred_at,
      p.payload||jsonb_strip_nulls(jsonb_build_object(
        'observation_id',r.id,'observed_at',r.observed_at,
        'observation',case when r.id is null then null else jsonb_build_object(
          'observation_id',r.id,'observed_at',r.observed_at,
          'target_location',case when r.geom is null then null else jsonb_build_object(
            'position',ST_AsGeoJSON(r.geom)::jsonb,'altitude_amsl_m',r.height_amsl_m,
            'relative_height_m',o.relative_height_m) end,
          'remote_pilot_location',case when o.pilot_geom is null then null else jsonb_build_object(
            'position',ST_AsGeoJSON(o.pilot_geom)::jsonb,'source','vendor_reported','accuracy_m',null) end,
          'detection_method_code',o.detection_method_code,'detection_method_name',dm.name,
          'producer_asset_id',o.producer_asset_id,'speed_mps',o.speed_mps,
          'quality_flags',o.quality_flags
        ) end,

        'position',case when r.geom is null then null else ST_AsGeoJSON(r.geom)::jsonb end,
        'altitude_amsl_m',r.height_amsl_m,'source_type_code',o.source_type_code,
        'detection_method_code',o.detection_method_code,'detection_method_name',dm.name,
        'producer_asset_id',o.producer_asset_id,'speed_mps',o.speed_mps,'quality_flags',o.quality_flags,
        'track_code',t.track_code,'source_target_id',s.source_target_id,'model',o.model
      )) payload
    from page p
    left join equipment.raw_observation r on r.id=(p.payload->>'observation_id')::bigint
    left join situation.target_observation o on o.observation_id=r.id
    left join situation.target_track t on t.id=p.aggregate_id and p.aggregate_type='target_track'
    left join situation.detection_method dm on dm.code=o.detection_method_code
    left join situation.source_target_session s on s.id=t.source_session_id
  )
  select jsonb_build_object('from_cursor',p_after_cursor,'next_cursor',coalesce((select max(id) from page),p_after_cursor),
    'has_more',(select count(*)>p_limit from filtered),'changes',coalesce((select jsonb_agg(
      jsonb_build_object('cursor',id,'type',event_type,'aggregate_type',aggregate_type,
        'aggregate_id',aggregate_id,'occurred_at',occurred_at,'payload',payload,
        'riskAssessment',case
          when event_type='risk_changed' then payload->'risk_assessment'
          when aggregate_type='target_track' then event_response.risk_assessment_json(aggregate_id)
          else null end) order by id) from enriched),'[]'::jsonb))
  into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_situation_changes(bigint,text[],integer) is '返回 JSON：from_cursor、next_cursor、has_more 和 changes；按持久化游标补读目标、来源状态、risk_changed 及当前 riskAssessment，单次最多 1000 条。';

create or replace function api.list_detection_target_tracks(
  p_start_at timestamptz,p_end_at timestamptz,p_station_ids text[] default null,
  p_source_type_codes smallint[] default null,p_limit integer default 200
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,event_response as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '7 days' then raise exception 'track list window cannot exceed 7 days'; end if;
  if p_limit not between 1 and 1000 then raise exception 'limit must be between 1 and 1000'; end if;
  with matching_tracks as (
    select t.id,t.track_code,t.status,t.first_observed_at,t.last_observed_at,t.lost_at,
      s.source_target_id,s.source_type_code,dt.name source_type_name,src.external_station_id station_id,
      row_number() over(order by t.last_observed_at desc,t.id desc) result_order
    from situation.target_track t
    join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    left join situation.detection_source_type dt on dt.vendor_code=s.source_type_code
    where t.first_observed_at<p_end_at and t.last_observed_at>=p_start_at
      and (p_station_ids is null or src.external_station_id=any(p_station_ids))
      and (p_source_type_codes is null or s.source_type_code=any(p_source_type_codes))
    order by t.last_observed_at desc,t.id desc limit p_limit
  ), summaries as (
    select mt.*,coalesce(count(r.id),0) observation_count,
      coalesce(count(r.geom),0) spatial_point_count,
      coalesce(count(r.id) filter(where cardinality(o.quality_flags)>0),0) flagged_observation_count,
      min(r.height_amsl_m) min_altitude_amsl_m,max(r.height_amsl_m) max_altitude_amsl_m,
      (array_agg(o.model order by r.observed_at desc,r.id desc) filter(where nullif(o.model,'') is not null))[1] model,
      st_extent(r.geom) spatial_extent
    from matching_tracks mt
    left join situation.track_observation x on x.track_id=mt.id
    left join equipment.raw_observation r on r.id=x.observation_id
      and r.observed_at>=p_start_at and r.observed_at<p_end_at
    left join situation.target_observation o on o.observation_id=r.id
    group by mt.id,mt.track_code,mt.status,mt.first_observed_at,mt.last_observed_at,mt.lost_at,
      mt.source_target_id,mt.source_type_code,mt.source_type_name,mt.station_id,mt.result_order
  )
  select jsonb_build_object(
    'start_at',p_start_at,'end_at_exclusive',p_end_at,'limit',p_limit,
    'tracks',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'track_id',id,'track_code',track_code,'status',status,'station_id',station_id,
      'source_target_id',source_target_id,'source_type_code',source_type_code,'source_type_name',source_type_name,
      'model',model,'first_observed_at',first_observed_at,'last_observed_at',last_observed_at,'lost_at',lost_at,
      'observation_count',observation_count,'spatial_point_count',spatial_point_count,
      'flagged_observation_count',flagged_observation_count,'min_altitude_amsl_m',min_altitude_amsl_m,
      'max_altitude_amsl_m',max_altitude_amsl_m,
      'riskAssessment',event_response.risk_assessment_json(id),
      'bounds',case when spatial_extent is null then null else jsonb_build_object(
        'west',st_xmin(spatial_extent),'south',st_ymin(spatial_extent),
        'east',st_xmax(spatial_extent),'north',st_ymax(spatial_extent)) end
    )) order by result_order),'[]'::jsonb)
  ) into v_result from summaries;
  return v_result;
end;
$$;
comment on function api.list_detection_target_tracks(timestamptz,timestamptz,text[],smallint[],integer) is '返回 JSON：start_at、end_at_exclusive、limit 和 tracks；每条航迹包含当前 riskAssessment，窗口最大 7 天，最多 1000 条。';

create or replace function event_response.observation_risk_assessment_json(p_observation_id bigint) returns jsonb
language sql stable security definer set search_path=pg_catalog,public,event_response as $$
select null::jsonb;
$$;
comment on function event_response.observation_risk_assessment_json(bigint) is '返回单条观测的精简风险属性；风险评估迁移安装前返回 null。';
revoke all on function event_response.observation_risk_assessment_json(bigint) from public,anonymous;

create or replace function api.get_target_track_detail(
  p_track_id bigint,p_start_at timestamptz,p_end_at timestamptz,p_max_points integer default 2000
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,event_response as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '7 days' then raise exception 'track detail window cannot exceed 7 days'; end if;
  if p_max_points not between 1 and 5000 then raise exception 'max points must be between 1 and 5000'; end if;
  with observations as (
    select r.id,r.observed_at,r.geom,r.height_amsl_m,o.pilot_geom,o.source_type_code,o.detection_method_code,o.frequency_mhz,o.relative_height_m,
      o.horizontal_distance_m,o.azimuth_deg,o.elevation_deg,o.speed_mps,o.quality_flags,
      row_number() over(order by r.observed_at,r.id) rn,count(*) over() total
    from situation.track_observation x join equipment.raw_observation r on r.id=x.observation_id
    join situation.target_observation o on o.observation_id=r.id
    where x.track_id=p_track_id and r.observed_at>=p_start_at and r.observed_at<p_end_at
  ), sampled as (select * from observations where total<=p_max_points or mod(rn-1,ceil(total::numeric/p_max_points)::bigint)=0 limit p_max_points)
  select jsonb_build_object('track',(select jsonb_build_object('id',t.id,'track_code',t.track_code,'status',t.status,
      'first_observed_at',t.first_observed_at,'last_observed_at',t.last_observed_at,'lost_at',t.lost_at,
      'riskAssessment',event_response.risk_assessment_json(t.id)) from situation.target_track t where t.id=p_track_id),
    'observations',coalesce((select jsonb_agg(jsonb_build_object(
      'observation_id',id,'observed_at',observed_at,
      'target_location',case when geom is null then null else jsonb_build_object(
        'position',ST_AsGeoJSON(geom)::jsonb,'altitude_amsl_m',height_amsl_m,'relative_height_m',relative_height_m) end,
      'remote_pilot_location',case when pilot_geom is null then null else jsonb_build_object(
        'position',ST_AsGeoJSON(pilot_geom)::jsonb,'source','vendor_reported','accuracy_m',null) end,
      'detection_method_code',detection_method_code,'quality_flags',quality_flags,
      'riskAssessment',event_response.observation_risk_assessment_json(id)
    ) order by observed_at,id) from sampled),'[]'::jsonb),
    'points',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('observation_id',id,'observed_at',observed_at,
      'position',ST_AsGeoJSON(geom)::jsonb,'altitude_amsl_m',height_amsl_m,'source_type_code',source_type_code,
      'frequency_mhz',frequency_mhz,'relative_height_m',relative_height_m,'horizontal_distance_m',horizontal_distance_m,
      'azimuth_deg',azimuth_deg,'elevation_deg',elevation_deg,'speed_mps',speed_mps,'quality_flags',quality_flags)) order by observed_at,id)
      from sampled where geom is not null),'[]'::jsonb),
    'non_spatial_observations',coalesce((select jsonb_agg(jsonb_build_object('observation_id',id,'observed_at',observed_at,
      'source_type_code',source_type_code,'frequency_mhz',frequency_mhz,'quality_flags',quality_flags) order by observed_at,id)
      from sampled where geom is null),'[]'::jsonb),
    'evidence',jsonb_build_object('observation_count',coalesce((select max(total) from observations),0),
      'returned_count',(select count(*) from sampled),'sampled',coalesce((select max(total) from observations),0)>p_max_points)) into v_result;
  if v_result->'track'='null'::jsonb then raise exception 'target track % does not exist',p_track_id; end if;
  return v_result;
end;
$$;
comment on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) is '返回 JSON：track、observations、兼容 points、non_spatial_observations 和 evidence；track 包含当前 riskAssessment，每个 observation 包含可空的精简 riskAssessment，窗口最大 7 天，最多返回 5000 条抽样观测。';

create or replace function api.update_detection_observation_source(
  p_source_id bigint,p_name text,p_asset_id bigint,p_source_timezone text,
  p_lost_timeout_seconds integer,p_enabled boolean
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_source situation.observation_source%rowtype;
begin
  if p_source_id is null then raise exception 'source ID is required'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'source name is required'; end if;
  if p_lost_timeout_seconds not between 5 and 3600 then
    raise exception 'lost timeout must be between 5 and 3600 seconds';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_source_timezone) then
    raise exception 'unknown source timezone %',p_source_timezone;
  end if;
  if not exists(
    select 1 from equipment.asset where id=p_asset_id
      and (not p_enabled or lifecycle_status='active')
  ) then
    raise exception 'mapped asset does not exist or is not active';
  end if;

  update situation.observation_source set
    name=btrim(p_name),asset_id=p_asset_id,source_timezone=p_source_timezone,
    lost_timeout_seconds=p_lost_timeout_seconds,enabled=p_enabled,updated_at=now()
  where id=p_source_id returning * into v_source;
  if not found then raise exception 'observation source % does not exist',p_source_id; end if;

  if not p_enabled then
    insert into situation.observation_source_status_current(observation_source_id,connector_state,updated_at)
    values(v_source.id,'unknown',now())
    on conflict(observation_source_id) do update set connector_state='unknown',updated_at=now();
  end if;
  insert into situation.change_event(
    event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload
  ) values(
    'source_status','observation_source',v_source.id,v_source.id,now(),
    jsonb_build_object('source_id',v_source.id,'configuration_updated',true,'enabled',v_source.enabled)
  );
  return jsonb_build_object(
    'id',v_source.id,'name',v_source.name,'asset_id',v_source.asset_id,
    'source_timezone',v_source.source_timezone,'lost_timeout_seconds',v_source.lost_timeout_seconds,
    'enabled',v_source.enabled
  );
end;
$$;
comment on function api.update_detection_observation_source(bigint,text,bigint,text,integer,boolean) is '管理员更新侦测来源名称、资产映射、来源时区、目标丢失宽限和启停状态；返回 JSON：id、name、asset_id、source_timezone、lost_timeout_seconds、enabled。';

revoke all on schema situation from public,anonymous,admin,detection_ingest;
revoke all on all tables in schema situation from public,anonymous,admin,detection_ingest;
revoke all on all functions in schema situation from public,anonymous,admin,detection_ingest;
revoke all on function situation.ingest_target_observation(jsonb) from public,anonymous,admin,detection_ingest;
revoke all on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) from public,anonymous,admin,detection_ingest;
revoke all on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) from public,anonymous,admin,detection_ingest;
revoke all on function situation.sync_detection_source_asset(jsonb) from public,anonymous,admin,detection_ingest;
revoke all on function situation.ingest_detection_config_status(jsonb) from public,anonymous,admin,detection_ingest;
revoke all on equipment.counter_uas_telemetry_current,equipment.counter_uas_status_event,equipment.counter_uas_telemetry_sample from public,anonymous,admin,detection_ingest;
grant usage on schema situation to detection_ingest;
grant execute on function situation.ingest_target_observation(jsonb) to detection_ingest;
grant execute on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) to detection_ingest;
grant execute on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) to detection_ingest;
grant execute on function situation.sync_detection_source_asset(jsonb) to detection_ingest;
grant execute on function situation.ingest_detection_config_status(jsonb) to detection_ingest;

revoke all on api.detection_source_types,api.detection_methods,api.detection_method_mappings,api.detection_method_mapping_history,api.detection_observation_sources,api.counter_uas_telemetry_current,api.counter_uas_status_events,api.counter_uas_telemetry_samples from public,anonymous;
revoke all on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) from public,anonymous;
revoke all on function api.get_detection_live_tracks(text[],smallint[],integer,integer,integer,integer) from public,anonymous;
revoke all on function api.get_detection_live_tracks_v2(bigint[],bigint[],text[],integer,integer,integer,integer) from public,anonymous;
revoke all on function api.get_detection_live_tracks_v3(bigint[],bigint[],text[],integer,integer,integer,integer) from public,anonymous;

revoke all on function api.get_detection_situation_changes(bigint,text[],integer) from public,anonymous;
revoke all on function api.list_detection_target_tracks(timestamptz,timestamptz,text[],smallint[],integer) from public,anonymous;
revoke all on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) from public,anonymous;
revoke all on function api.update_detection_observation_source(bigint,text,bigint,text,integer,boolean) from public,anonymous;
revoke all on function api.create_detection_method(text,text,text,boolean,integer,jsonb) from public,anonymous;
revoke all on function api.update_detection_method(text,jsonb) from public,anonymous;
revoke all on function api.upsert_detection_method_mapping(text,text,text,boolean,jsonb) from public,anonymous;
grant select on api.detection_source_types,api.detection_methods,api.detection_method_mappings,api.detection_method_mapping_history,api.detection_observation_sources,api.counter_uas_telemetry_current,api.counter_uas_status_events,api.counter_uas_telemetry_samples to admin;
grant execute on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) to admin;
grant execute on function api.get_detection_live_tracks(text[],smallint[],integer,integer,integer,integer) to admin;
grant execute on function api.get_detection_live_tracks_v2(bigint[],bigint[],text[],integer,integer,integer,integer) to admin;
grant execute on function api.get_detection_live_tracks_v3(bigint[],bigint[],text[],integer,integer,integer,integer) to admin;
grant execute on function api.get_detection_situation_changes(bigint,text[],integer) to admin;
grant execute on function api.list_detection_target_tracks(timestamptz,timestamptz,text[],smallint[],integer) to admin;
grant execute on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) to admin;
grant execute on function api.update_detection_observation_source(bigint,text,bigint,text,integer,boolean) to admin;
grant execute on function api.create_detection_method(text,text,text,boolean,integer,jsonb) to admin;
grant execute on function api.update_detection_method(text,jsonb) to admin;
grant execute on function api.upsert_detection_method_mapping(text,text,text,boolean,jsonb) to admin;

notify pgrst,'reload schema';
commit;
