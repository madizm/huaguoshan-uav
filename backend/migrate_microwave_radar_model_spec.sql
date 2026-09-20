-- 低慢小探测雷达型号字典与规格：JBHT JBRM200/JBRM300/JBRP200/JBRP300。
-- 复用既有 microwave_radar 类别与 microwave_radar_profile，不新增设备类别。
-- 思路：静态规格归型号（device_model + radar_model_spec），实例扩展表只补部署姿态与网络接入。
-- 依赖 migrate_equipment_detection_devices.sql；可安全重复执行。
-- 规格数据来源：docs/低慢小探测雷达-JBHT.pdf。

begin;

-- 一、设备型号字典：静态规格归型号管理，避免每台实例重复抄录。
create table if not exists equipment.device_model (
  model_code text primary key,
  category_code text not null references equipment.asset_category(code),
  name text not null,
  manufacturer text,
  specs jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table equipment.device_model is '设备型号字典，静态规格归型号管理。';
comment on column equipment.device_model.model_code is '型号唯一编码，如 JBRM200。';
comment on column equipment.device_model.category_code is '该型号所属设备类别编码，关联设备类别字典。';
comment on column equipment.device_model.name is '型号中文名称，如 JBRM200型雷达。';
comment on column equipment.device_model.manufacturer is '制造商。';
comment on column equipment.device_model.specs is '未建模的扩展规格 JSON。';
drop trigger if exists device_model_touch_updated_at on equipment.device_model;
create trigger device_model_touch_updated_at before update on equipment.device_model
for each row execute function equipment.touch_updated_at();

-- 二、雷达型号规格：覆盖计算和选型比对的高频字段保持强类型，成组小三元组用 jsonb。
create table if not exists equipment.radar_model_spec (
  model_code text primary key references equipment.device_model(model_code) on delete cascade,
  work_system text not null,
  frequency_band text not null,
  scan_mode text not null check (scan_mode in ('az_mech_el_phase', 'four_face_phase')),
  azimuth_coverage_deg numeric not null check (azimuth_coverage_deg > 0 and azimuth_coverage_deg <= 360),
  azimuth_coverage_phase_deg numeric check (azimuth_coverage_phase_deg is null or (azimuth_coverage_phase_deg > 0 and azimuth_coverage_phase_deg <= 360)),
  elevation_search_deg numeric not null check (elevation_search_deg > 0),
  elevation_track_deg numeric not null check (elevation_track_deg > 0),
  range_search_m integer not null check (range_search_m > 0),
  range_phase_search_m integer check (range_phase_search_m is null or range_phase_search_m > 0),
  ref_rcs_sqm numeric not null default 0.01 check (ref_rcs_sqm > 0),
  coverage_height_m integer not null check (coverage_height_m > 0),
  target_speed_min_mps numeric not null check (target_speed_min_mps >= 0),
  target_speed_max_mps numeric not null check (target_speed_max_mps > target_speed_min_mps),
  data_rate_search_s numeric not null check (data_rate_search_s > 0),
  data_rate_track_s numeric not null check (data_rate_track_s > 0),
  accuracy_search jsonb not null,
  accuracy_track jsonb not null,
  capacity_search integer not null check (capacity_search > 0),
  capacity_track integer not null check (capacity_track > 0),
  fault_detection_rate numeric check (fault_detection_rate is null or (fault_detection_rate >= 0 and fault_detection_rate <= 1)),
  power_supply text,
  power_w numeric check (power_w is null or power_w >= 0),
  control_interface text,
  dimensions jsonb
);
comment on table equipment.radar_model_spec is '微波探测雷达型号静态规格，来源为厂商产品资料。';
comment on column equipment.radar_model_spec.model_code is '对应设备型号编码。';
comment on column equipment.radar_model_spec.work_system is '工作体制原文描述。';
comment on column equipment.radar_model_spec.frequency_band is '工作频率波段，如 Ku。';
comment on column equipment.radar_model_spec.scan_mode is '扫描体制：az_mech_el_phase 方位机扫+俯仰相扫，four_face_phase 四面全固态相扫。';
comment on column equipment.radar_model_spec.azimuth_coverage_deg is '方位覆盖角度，单位度，机扫或四面为 360。';
comment on column equipment.radar_model_spec.azimuth_coverage_phase_deg is '相扫模式方位覆盖角度，单位度，仅机扫型号有效。';
comment on column equipment.radar_model_spec.elevation_search_deg is '搜索俯仰覆盖角度，单位度。';
comment on column equipment.radar_model_spec.elevation_track_deg is '跟踪俯仰覆盖角度，单位度。';
comment on column equipment.radar_model_spec.range_search_m is '机扫或单面搜索作用距离，单位米。';
comment on column equipment.radar_model_spec.range_phase_search_m is '相扫搜索作用距离，单位米，仅机扫型号有效。';
comment on column equipment.radar_model_spec.ref_rcs_sqm is '作用距离参考目标 RCS，单位平方米。';
comment on column equipment.radar_model_spec.coverage_height_m is '覆盖高度，单位米。';
comment on column equipment.radar_model_spec.target_speed_min_mps is '可监视目标最小速度，单位米每秒。';
comment on column equipment.radar_model_spec.target_speed_max_mps is '可监视目标最大速度，单位米每秒。';
comment on column equipment.radar_model_spec.data_rate_search_s is '搜索数据率，单位秒每批。';
comment on column equipment.radar_model_spec.data_rate_track_s is '跟踪数据率，单位秒每批。';
comment on column equipment.radar_model_spec.accuracy_search is '搜索定位精度 JSON：azimuth_deg、elevation_deg、range_m。';
comment on column equipment.radar_model_spec.accuracy_track is '跟踪定位精度 JSON：azimuth_deg、elevation_deg、range_m。';
comment on column equipment.radar_model_spec.capacity_search is '搜索目标处理容量，单位批。';
comment on column equipment.radar_model_spec.capacity_track is '跟踪目标处理容量，单位批。';
comment on column equipment.radar_model_spec.fault_detection_rate is '故障检知率，范围 0 到 1。';
comment on column equipment.radar_model_spec.power_supply is '供电电源规格。';
comment on column equipment.radar_model_spec.power_w is '功耗，单位瓦，四面型号为单面功耗。';
comment on column equipment.radar_model_spec.control_interface is '控制接口方式。';
comment on column equipment.radar_model_spec.dimensions is '外形尺寸 JSON：array 单阵面尺寸、turntable 转台尺寸。';

-- 三、微波雷达实例扩展表补齐部署姿态与网络接入字段（实例级信息）。
alter table equipment.microwave_radar_profile add column if not exists model_code text;
alter table equipment.microwave_radar_profile add column if not exists face_count smallint not null default 1;
alter table equipment.microwave_radar_profile add column if not exists install_azimuth_deg numeric;
alter table equipment.microwave_radar_profile add column if not exists install_tilt_deg numeric;
alter table equipment.microwave_radar_profile add column if not exists control_host inet;
alter table equipment.microwave_radar_profile add column if not exists control_port integer;
alter table equipment.microwave_radar_profile add column if not exists protocol text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'microwave_radar_profile_model_fk'
                 and conrelid = 'equipment.microwave_radar_profile'::regclass) then
    alter table equipment.microwave_radar_profile add constraint microwave_radar_profile_model_fk
      foreign key (model_code) references equipment.radar_model_spec(model_code);
  end if;
end;
$$;
alter table equipment.microwave_radar_profile
  drop constraint if exists microwave_radar_profile_face_count_check;
alter table equipment.microwave_radar_profile
  add constraint microwave_radar_profile_face_count_check check (face_count between 1 and 4);
alter table equipment.microwave_radar_profile
  drop constraint if exists microwave_radar_profile_install_azimuth_check;
alter table equipment.microwave_radar_profile
  add constraint microwave_radar_profile_install_azimuth_check
  check (install_azimuth_deg is null or (install_azimuth_deg >= 0 and install_azimuth_deg < 360));
alter table equipment.microwave_radar_profile
  drop constraint if exists microwave_radar_profile_install_tilt_check;
alter table equipment.microwave_radar_profile
  add constraint microwave_radar_profile_install_tilt_check
  check (install_tilt_deg is null or (install_tilt_deg >= -90 and install_tilt_deg <= 90));

comment on column equipment.microwave_radar_profile.model_code is '雷达型号编码，关联型号静态规格。';
comment on column equipment.microwave_radar_profile.face_count is '阵面数量，机扫型号为 1，四面固态型号为 4。';
comment on column equipment.microwave_radar_profile.install_azimuth_deg is '安装方位角，单位度，机扫型号决定相扫值守扇区朝向。';
comment on column equipment.microwave_radar_profile.install_tilt_deg is '安装俯仰角，单位度。';
comment on column equipment.microwave_radar_profile.control_host is '雷达控制网口 IP 地址。';
comment on column equipment.microwave_radar_profile.control_port is '雷达控制端口。';
comment on column equipment.microwave_radar_profile.protocol is '对接协议标识，对应侦测接口文档。';

-- 四、能力字典补充雷达特有维护与组网能力（探测能力已有 microwave_detection 等）。
insert into equipment.capability(code, name, capability_type, description) values
  ('multi_target_tracking', '多目标跟踪', 'tracking', '对多批目标同时保持跟踪的能力。'),
  ('self_calibration', '快速自校准', 'maintenance', '设备快速自校准能力。'),
  ('fault_diagnosis', '自动故障诊断', 'maintenance', '设备自动故障诊断能力。'),
  ('radar_networking', '雷达组网', 'integration', '适应雷达组网需要的接口兼容与扩展能力。')
on conflict (code) do update set
  name = excluded.name, capability_type = excluded.capability_type, description = excluded.description;

-- 五、型号种子数据，来源 docs/低慢小探测雷达-JBHT.pdf。
insert into equipment.device_model (model_code, category_code, name, manufacturer) values
  ('JBRM200', 'microwave_radar', 'JBRM200型雷达', 'JBHT'),
  ('JBRM300', 'microwave_radar', 'JBRM300型雷达', 'JBHT'),
  ('JBRP200', 'microwave_radar', 'JBRP200型雷达', 'JBHT'),
  ('JBRP300', 'microwave_radar', 'JBRP300型雷达', 'JBHT')
on conflict (model_code) do update set
  category_code = excluded.category_code, name = excluded.name, manufacturer = excluded.manufacturer;

insert into equipment.radar_model_spec (
  model_code, work_system, frequency_band, scan_mode,
  azimuth_coverage_deg, azimuth_coverage_phase_deg, elevation_search_deg, elevation_track_deg,
  range_search_m, range_phase_search_m, ref_rcs_sqm, coverage_height_m,
  target_speed_min_mps, target_speed_max_mps, data_rate_search_s, data_rate_track_s,
  accuracy_search, accuracy_track, capacity_search, capacity_track,
  fault_detection_rate, power_supply, power_w, control_interface, dimensions
) values
  ('JBRM200', '方位机扫、全相参、有源二维相控阵体制', 'Ku', 'az_mech_el_phase',
   360, 90, 40, 60,
   3000, 5000, 0.01, 1000,
   1, 200, 3, 0.2,
   '{"azimuth_deg": 0.4, "elevation_deg": 0.6, "range_m": 10}',
   '{"azimuth_deg": 0.3, "elevation_deg": 0.5, "range_m": 7.5}',
   100, 4,
   0.9, 'DC/24V', 360, '千兆以太网',
   '{"array": "339mm*347mm*120mm", "turntable": "Φ216mm×173mm"}'),
  ('JBRM300', '方位机扫、全相参、有源二维相控阵体制', 'Ku', 'az_mech_el_phase',
   360, 90, 40, 60,
   5000, 7000, 0.01, 1000,
   1, 200, 4, 0.2,
   '{"azimuth_deg": 0.4, "elevation_deg": 0.6, "range_m": 10}',
   '{"azimuth_deg": 0.3, "elevation_deg": 0.5, "range_m": 7.5}',
   100, 4,
   0.9, 'DC/24V', 400, '千兆以太网',
   '{"array": "390mm*390mm*120mm", "turntable": "Φ216mm×173mm"}'),
  ('JBRP200', '三坐标全固态、全相参、有源二维相控阵体制', 'Ku', 'four_face_phase',
   360, null, 40, 60,
   5000, null, 0.01, 1000,
   1, 200, 3, 0.2,
   '{"azimuth_deg": 0.4, "elevation_deg": 0.6, "range_m": 10}',
   '{"azimuth_deg": 0.2, "elevation_deg": 0.3, "range_m": 5}',
   400, 16,
   0.9, 'DC/24V', 260, '千兆以太网',
   '{"array": "339mm*347mm*120mm"}'),
  ('JBRP300', '三坐标全固态、全相参、有源二维相控阵体制', 'Ku', 'four_face_phase',
   360, null, 40, 60,
   7000, null, 0.01, 1000,
   1, 200, 3, 0.2,
   '{"azimuth_deg": 0.4, "elevation_deg": 0.6, "range_m": 10}',
   '{"azimuth_deg": 0.2, "elevation_deg": 0.3, "range_m": 5}',
   400, 16,
   0.9, 'DC/24V', 325, '千兆以太网',
   '{"array": "390mm*390mm*120mm"}')
on conflict (model_code) do update set
  work_system = excluded.work_system, frequency_band = excluded.frequency_band,
  scan_mode = excluded.scan_mode,
  azimuth_coverage_deg = excluded.azimuth_coverage_deg,
  azimuth_coverage_phase_deg = excluded.azimuth_coverage_phase_deg,
  elevation_search_deg = excluded.elevation_search_deg,
  elevation_track_deg = excluded.elevation_track_deg,
  range_search_m = excluded.range_search_m,
  range_phase_search_m = excluded.range_phase_search_m,
  ref_rcs_sqm = excluded.ref_rcs_sqm, coverage_height_m = excluded.coverage_height_m,
  target_speed_min_mps = excluded.target_speed_min_mps,
  target_speed_max_mps = excluded.target_speed_max_mps,
  data_rate_search_s = excluded.data_rate_search_s,
  data_rate_track_s = excluded.data_rate_track_s,
  accuracy_search = excluded.accuracy_search, accuracy_track = excluded.accuracy_track,
  capacity_search = excluded.capacity_search, capacity_track = excluded.capacity_track,
  fault_detection_rate = excluded.fault_detection_rate,
  power_supply = excluded.power_supply, power_w = excluded.power_w,
  control_interface = excluded.control_interface, dimensions = excluded.dimensions;

-- 六、API 门面。重建 profile 视图以纳入新增列，新增型号与联合台账视图。
create or replace view api.equipment_microwave_radar_profiles as select * from equipment.microwave_radar_profile;
comment on view api.equipment_microwave_radar_profiles is '微波雷达设备专业属性只读资源，含型号、部署姿态与网络接入。';

create or replace view api.equipment_radar_models as
select m.model_code, m.category_code, m.name, m.manufacturer, m.specs as model_specs,
       s.work_system, s.frequency_band, s.scan_mode,
       s.azimuth_coverage_deg, s.azimuth_coverage_phase_deg,
       s.elevation_search_deg, s.elevation_track_deg,
       s.range_search_m, s.range_phase_search_m, s.ref_rcs_sqm, s.coverage_height_m,
       s.target_speed_min_mps, s.target_speed_max_mps,
       s.data_rate_search_s, s.data_rate_track_s,
       s.accuracy_search, s.accuracy_track,
       s.capacity_search, s.capacity_track, s.fault_detection_rate,
       s.power_supply, s.power_w, s.control_interface, s.dimensions
from equipment.device_model m
join equipment.radar_model_spec s on s.model_code = m.model_code;
comment on view api.equipment_radar_models is '微波探测雷达型号及静态规格只读资源。';

create or replace view api.equipment_microwave_radar_assets as
select a.id as asset_id, a.asset_code, a.name, a.category_code,
       a.geom, a.elevation_amsl_m, a.height_datum,
       a.managing_unit_name, a.deployment_mode, a.lifecycle_status,
       p.model_code, m.name as model_name, p.face_count,
       p.install_azimuth_deg, p.install_tilt_deg,
       p.control_host, p.control_port, p.protocol,
       p.detection_mode, p.multi_target_supported,
       s.scan_mode, s.range_search_m, s.range_phase_search_m,
       s.azimuth_coverage_deg, s.azimuth_coverage_phase_deg,
       s.elevation_search_deg, s.coverage_height_m,
       st.connectivity_status, st.dispatch_status, st.last_heartbeat_at,
       a.created_at, a.updated_at
from equipment.asset a
join equipment.microwave_radar_profile p on p.asset_id = a.id
left join equipment.radar_model_spec s on s.model_code = p.model_code
left join equipment.device_model m on m.model_code = p.model_code
left join equipment.asset_status_current st on st.asset_id = a.id;
comment on view api.equipment_microwave_radar_assets is '微波雷达资产台账、型号关键规格与当前状态的只读联合资源。';
comment on column api.equipment_microwave_radar_assets.geom is '雷达阵地位置，WGS84 Point（EPSG:4326）。';
comment on column api.equipment_microwave_radar_assets.elevation_amsl_m is '雷达阵地 AMSL 高度，单位米。';
comment on column api.equipment_microwave_radar_assets.install_azimuth_deg is '安装方位角，机扫型号决定相扫值守扇区朝向。';

-- 七、权限：型号由数据库技术角色维护，HTTP 通过 api 只读暴露。
grant select on api.equipment_radar_models, api.equipment_microwave_radar_assets to admin;
grant select on equipment.device_model, equipment.radar_model_spec to admin;

notify pgrst, 'reload schema';
commit;
