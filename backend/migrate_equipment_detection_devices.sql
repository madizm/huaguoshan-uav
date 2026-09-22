-- 扩展侦测与处置设备模型：干扰、AOA、微波、RemoteID、激光/定向能和光电设备。
-- 6G 继续复用 equipment.base_station_6g_profile，不新增 6G 类别。
-- 依赖 create_equipment_asset_schema.sql；可安全重复执行。

begin;

-- 统一资产类别约束。兼容历史脚本可能生成的两种约束名称。
alter table equipment.asset
  drop constraint if exists asset_category_code_check;
alter table equipment.asset
  drop constraint if exists equipment_asset_category_code_check;
alter table equipment.asset
  add constraint equipment_asset_category_code_check check (category_code in (
    'base_station_6g', 'counter_uas', 'video_surveillance', 'uav',
    'unmanned_vehicle', 'vehicle_surveillance', 'sensor',
    'jamming_device', 'aoa_direction_finder', 'microwave_radar',
    'remote_id_receiver', 'directed_energy_device', 'electro_optical_device'
  ));
comment on column equipment.asset.category_code is '设施设备类别编码，包含既有设备及干扰、AOA、微波、RemoteID、定向能和光电设备。';
create table if not exists equipment.asset_category (
  code text primary key,
  name text not null,
  category_group text not null,
  description text,
  enabled boolean not null default true,
  sort_order integer not null default 0
);
comment on table equipment.asset_category is '设施设备类别字典，维护设备类别编码、中文名称、分组和展示顺序。';
comment on column equipment.asset_category.code is '设备类别唯一编码，与 equipment.asset.category_code 对应。';
comment on column equipment.asset_category.name is '设备类别中文名称。';
comment on column equipment.asset_category.category_group is '设备类别业务分组。';
comment on column equipment.asset_category.description is '设备类别说明。';
comment on column equipment.asset_category.enabled is '类别是否启用。';
comment on column equipment.asset_category.sort_order is '类别展示排序值。';

insert into equipment.asset_category(code, name, category_group, description, sort_order) values
  ('base_station_6g', '6G 基站', 'infrastructure', '6G 通信或通感一体化基站。', 10),
  ('counter_uas', '反无设备', 'countermeasure', '反无综合设备，仅用于展示和推荐。', 20),
  ('video_surveillance', '视频监控', 'observation', '视频监控设备。', 30),
  ('uav', '无人机', 'dispatchable', '平台受管理的无人机资产。', 40),
  ('unmanned_vehicle', '无人车', 'dispatchable', '平台受管理的无人车资产。', 50),
  ('vehicle_surveillance', '车载监控', 'observation', '车载监控逻辑设备。', 60),
  ('sensor', '传感设备', 'observation', '通用环境或状态传感设备。', 70),
  ('jamming_device', '干扰设备', 'countermeasure', '无线电干扰设备，仅用于展示和处置方案推荐。', 80),
  ('aoa_direction_finder', 'AOA 到达角测向设备', 'detection', '无线电到达角测向设备。', 90),
  ('microwave_radar', '微波探测设备', 'detection', '微波雷达或微波目标探测设备。', 100),
  ('remote_id_receiver', 'RemoteID 接收设备', 'identification', '远程身份识别接收设备。', 110),
  ('directed_energy_device', '激光定向能设备', 'countermeasure', '激光或其他定向能处置设备，仅用于推荐和模拟联动。', 120),
  ('electro_optical_device', '光电设备', 'observation', '可见光、红外或热成像观测设备。', 130)
on conflict (code) do update set name = excluded.name, category_group = excluded.category_group,
  description = excluded.description, enabled = excluded.enabled, sort_order = excluded.sort_order;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'equipment_asset_category_fk' and conrelid = 'equipment.asset'::regclass) then
    alter table equipment.asset add constraint equipment_asset_category_fk
      foreign key (category_code) references equipment.asset_category(code);
  end if;
end;
$$;

create table if not exists equipment.jamming_device_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  jamming_modes text[],
  frequency_range text,
  max_effective_range_m numeric check (max_effective_range_m is null or max_effective_range_m >= 0),
  directional_supported boolean not null default false,
  target_protocols text[],
  authorization_required boolean not null default true,
  recommendation_notes text
);
comment on table equipment.jamming_device_profile is '干扰设备专业属性，仅用于能力展示、研判和处置方案推荐，不保存控制命令。';

create table if not exists equipment.aoa_direction_finder_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  frequency_range text,
  azimuth_min_deg numeric check (azimuth_min_deg is null or azimuth_min_deg >= 0 and azimuth_min_deg <= 360),
  azimuth_max_deg numeric check (azimuth_max_deg is null or azimuth_max_deg >= 0 and azimuth_max_deg <= 360),
  azimuth_accuracy_deg numeric check (azimuth_accuracy_deg is null or azimuth_accuracy_deg >= 0),
  elevation_supported boolean not null default false,
  localization_mode text,
  antenna_count integer check (antenna_count is null or antenna_count > 0),
  recommendation_notes text
);
comment on table equipment.aoa_direction_finder_profile is 'AOA 无线电到达角测向设备专业属性。';

create table if not exists equipment.microwave_radar_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  frequency_band text,
  detection_mode text,
  max_detection_range_m numeric check (max_detection_range_m is null or max_detection_range_m >= 0),
  min_detection_range_m numeric check (min_detection_range_m is null or min_detection_range_m >= 0),
  min_target_speed_mps numeric,
  max_target_speed_mps numeric,
  range_accuracy_m numeric check (range_accuracy_m is null or range_accuracy_m >= 0),
  speed_accuracy_mps numeric check (speed_accuracy_mps is null or speed_accuracy_mps >= 0),
  multi_target_supported boolean not null default false,
  recommendation_notes text,
  check (min_detection_range_m is null or max_detection_range_m is null or min_detection_range_m <= max_detection_range_m)
);
comment on table equipment.microwave_radar_profile is '微波雷达或微波目标探测设备专业属性。';

create table if not exists equipment.remote_id_receiver_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  protocol_codes text[],
  receive_mode text,
  max_receive_range_m numeric check (max_receive_range_m is null or max_receive_range_m >= 0),
  identity_resolution_mode text,
  time_synchronization_source text,
  recommendation_notes text
);
comment on table equipment.remote_id_receiver_profile is 'RemoteID 远程身份识别接收设备专业属性。';

create table if not exists equipment.directed_energy_device_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  effect_type text,
  effective_range_m numeric check (effective_range_m is null or effective_range_m >= 0),
  azimuth_coverage_deg numeric check (azimuth_coverage_deg is null or azimuth_coverage_deg >= 0 and azimuth_coverage_deg <= 360),
  elevation_coverage_deg numeric check (elevation_coverage_deg is null or elevation_coverage_deg >= 0 and elevation_coverage_deg <= 180),
  tracking_supported boolean not null default false,
  authorization_required boolean not null default true,
  simulated_linkage_only boolean not null default true,
  recommendation_notes text
);
comment on table equipment.directed_energy_device_profile is '激光或其他定向能处置设备属性，仅用于展示、推荐和模拟联动。';

create table if not exists equipment.electro_optical_device_profile (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  optical_modes text[],
  camera_type text,
  thermal_supported boolean not null default false,
  ptz_supported boolean not null default false,
  optical_zoom numeric check (optical_zoom is null or optical_zoom >= 0),
  detection_range_m numeric check (detection_range_m is null or detection_range_m >= 0),
  recognition_range_m numeric check (recognition_range_m is null or recognition_range_m >= 0),
  identification_range_m numeric check (identification_range_m is null or identification_range_m >= 0),
  tracking_supported boolean not null default false,
  stream_ref text,
  recommendation_notes text
);
comment on table equipment.electro_optical_device_profile is '光电观测设备专业属性，视频流仅保存安全引用。';

-- 专业扩展表与统一资产类别的数据库级一致性校验。
do $$
declare r record;
begin
  for r in select * from (values
    ('jamming_device_profile','jamming_device'),
    ('aoa_direction_finder_profile','aoa_direction_finder'),
    ('microwave_radar_profile','microwave_radar'),
    ('remote_id_receiver_profile','remote_id_receiver'),
    ('directed_energy_device_profile','directed_energy_device'),
    ('electro_optical_device_profile','electro_optical_device')
  ) v(table_name, category_code)
  loop
    execute format('drop trigger if exists profile_category_guard on equipment.%I', r.table_name);
    execute format('create trigger profile_category_guard before insert or update on equipment.%I for each row execute function equipment.require_profile_category(%L)', r.table_name, r.category_code);
  end loop;
end;
$$;

-- 能力字典：设备类别表达“是什么”，能力表达“能做什么”。
insert into equipment.capability(code, name, capability_type, description) values
  ('network_sensing_6g', '6G 网络感知', 'detection', '基于 6G 网络侧数据提供目标或环境感知。'),
  ('radio_jamming', '无线电干扰', 'countermeasure', '提供无线电干扰能力，仅用于能力展示和处置方案推荐。'),
  ('aoa_measurement', '到达角测向', 'detection', '估计无线电信号到达方向。'),
  ('radio_detection', '无线电侦测', 'detection', '通过无线电信号发现目标；不要求具备到达角测向能力。'),
  ('remote_pilot_localization', '远程飞手定位', 'detection', '通过遥控链路、Remote ID 或厂商识别结果获得远程飞手位置。'),
  ('microwave_detection', '微波探测', 'detection', '通过微波感知低空目标。'),
  ('range_measurement', '距离测量', 'detection', '提供目标距离估计。'),
  ('velocity_measurement', '速度测量', 'detection', '提供目标速度估计。'),
  ('remote_id_identification', 'RemoteID 身份识别', 'identification', '接收并解析远程身份广播。'),
  ('electro_optical_observation', '光电观测', 'observation', '通过可见光、红外或热成像观测目标。'),
  ('electro_optical_tracking', '光电跟踪', 'tracking', '持续跟踪光电视场内目标。'),
  ('directed_energy_response', '定向能处置', 'countermeasure', '提供定向能处置能力，仅用于推荐或模拟联动。')
on conflict (code) do update set
  name = excluded.name, capability_type = excluded.capability_type, description = excluded.description;

-- 敏感处置设备不允许通过通用能力表获得直接控制级别。
create or replace function equipment.limit_sensitive_device_access()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id = new.asset_id;
  if v_category in ('counter_uas', 'jamming_device', 'directed_energy_device')
     and new.access_level not in ('observable', 'recommendable') then
    raise exception 'sensitive equipment capability access level cannot exceed recommendable';
  end if;
  return new;
end;
$$;
comment on function equipment.limit_sensitive_device_access() is '限制反无、干扰和定向能设备最高为可推荐接入级别。返回触发器记录。';
drop trigger if exists sensitive_device_access_guard on equipment.asset_capability;
create trigger sensitive_device_access_guard before insert or update on equipment.asset_capability
for each row execute function equipment.limit_sensitive_device_access();

-- 新 profile 的 API 只读门面。
create or replace view api.equipment_jamming_device_profiles as select * from equipment.jamming_device_profile;
create or replace view api.equipment_aoa_direction_finder_profiles as select * from equipment.aoa_direction_finder_profile;
create or replace view api.equipment_microwave_radar_profiles as select * from equipment.microwave_radar_profile;
create or replace view api.equipment_remote_id_receiver_profiles as select * from equipment.remote_id_receiver_profile;
create or replace view api.equipment_directed_energy_device_profiles as select * from equipment.directed_energy_device_profile;
create or replace view api.equipment_electro_optical_device_profiles as select * from equipment.electro_optical_device_profile;

comment on view api.equipment_jamming_device_profiles is '干扰设备专业属性只读资源。';
comment on view api.equipment_aoa_direction_finder_profiles is 'AOA 到达角测向设备专业属性只读资源。';
comment on view api.equipment_microwave_radar_profiles is '微波雷达设备专业属性只读资源。';
comment on view api.equipment_remote_id_receiver_profiles is 'RemoteID 接收设备专业属性只读资源。';
comment on view api.equipment_directed_energy_device_profiles is '定向能处置设备专业属性只读资源。';
comment on view api.equipment_electro_optical_device_profiles is '光电设备专业属性只读资源。';
create or replace view api.equipment_asset_categories as
select code, name, category_group, description, enabled, sort_order
from equipment.asset_category;

create or replace view api.equipment_online_statistics as
select
  a.category_code,
  count(*)::bigint as total_count,
  count(*) filter (where s.connectivity_status = 'online')::bigint as online_count,
  round(
    count(*) filter (where s.connectivity_status = 'online') * 100.0 / nullif(count(*), 0),
    2
  )::numeric(5, 2) as online_rate,
  c.name as catalog_name
from equipment.asset a
join equipment.asset_category c on c.code = a.category_code
left join equipment.asset_status_current s on s.asset_id = a.id
group by a.category_code, c.name;

comment on view api.equipment_electro_optical_device_profiles is '光电设备专业属性只读资源。';
comment on view api.equipment_asset_categories is '设施设备类别字典只读资源。';
comment on view api.equipment_online_statistics is '按设备类别统计设备总数、类别名称、在线设备数和在线率的只读资源。';
comment on column api.equipment_online_statistics.category_code is '设备类别编码。';
comment on column api.equipment_online_statistics.catalog_name is '设备类别中文名称，来自设施设备类别字典。';

comment on column equipment.jamming_device_profile.asset_id is '干扰设备对应的统一资产 ID。';
comment on column equipment.jamming_device_profile.max_effective_range_m is '最大有效作用距离，单位米。';
comment on column equipment.jamming_device_profile.authorization_required is '是否要求授权后参与处置方案。';
comment on column equipment.aoa_direction_finder_profile.asset_id is 'AOA 设备对应的统一资产 ID。';
comment on column equipment.aoa_direction_finder_profile.azimuth_accuracy_deg is '方位角精度，单位度。';
comment on column equipment.microwave_radar_profile.asset_id is '微波设备对应的统一资产 ID。';
comment on column equipment.microwave_radar_profile.max_detection_range_m is '最大探测距离，单位米。';
comment on column equipment.remote_id_receiver_profile.asset_id is 'RemoteID 接收设备对应的统一资产 ID。';
comment on column equipment.directed_energy_device_profile.asset_id is '定向能设备对应的统一资产 ID。';
comment on column equipment.directed_energy_device_profile.simulated_linkage_only is '是否仅允许模拟联动。';
comment on column equipment.electro_optical_device_profile.asset_id is '光电设备对应的统一资产 ID。';
comment on column equipment.electro_optical_device_profile.stream_ref is '不含密码的视频流安全引用。';

-- 权限：profile 由数据库技术角色维护，HTTP 通过 api 只读暴露。
grant select on api.equipment_asset_categories,
  api.equipment_jamming_device_profiles,
  api.equipment_aoa_direction_finder_profiles,
  api.equipment_microwave_radar_profiles,
  api.equipment_remote_id_receiver_profiles,
  api.equipment_directed_energy_device_profiles,
  api.equipment_electro_optical_device_profiles to admin;
grant select on equipment.asset_category,
  equipment.jamming_device_profile,
  equipment.aoa_direction_finder_profile,
  equipment.microwave_radar_profile,
  equipment.remote_id_receiver_profile,
  equipment.directed_energy_device_profile,
  equipment.electro_optical_device_profile to admin;
grant execute on function equipment.limit_sensitive_device_access() to admin;

notify pgrst, 'reload schema';
commit;
