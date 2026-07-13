-- 花果山七类设施设备模拟数据。
-- 景区范围：longitude [119.23062143399773, 119.30584735009370]
--           latitude  [34.630255366340634, 34.66401112992460]
-- 来源键固定，冲突更新不修改已持久化坐标，可安全重复执行。

begin;

insert into equipment.asset(
  asset_code, category_code, type_code, name, source_system, source_asset_id,
  managing_unit_name, deployment_mode, lifecycle_status, geom, elevation_amsl_m,
  height_datum, manufacturer, model, serial_no, is_simulated, metadata
) values
  ('HGS-6G-001', 'base_station_6g', 'macro_station', '花果山 6G 试验基站', 'seed_equipment', '6G-001', '花果山景区管理处', 'fixed', 'active', ST_SetSRID(ST_MakePoint(119.25814,34.64827),4326), 126, 'AMSL', '模拟厂商', '6G-Macro-X1', 'SIM-6G-001', true, '{"scenario":"communications"}'),
  ('HGS-CUAS-001', 'counter_uas', 'integrated_detection', '北坡低空探测设备', 'seed_equipment', 'CUAS-001', '低空应急技术保障组', 'fixed', 'active', ST_SetSRID(ST_MakePoint(119.28175,34.66109),4326), 212, 'AMSL', '模拟厂商', 'Detect-R1', 'SIM-CUAS-001', true, '{"display_and_recommend_only":true}'),
  ('HGS-VIDEO-001', 'video_surveillance', 'thermal_ptz', '核心景区热成像监控', 'seed_equipment', 'VIDEO-001', '花果山景区管理处', 'fixed', 'active', ST_SetSRID(ST_MakePoint(119.26788,34.65594),4326), 168, 'AMSL', '模拟厂商', 'Thermal-PTZ-8', 'SIM-VIDEO-001', true, '{}'),
  ('HGS-UAV-011', 'uav', 'inspection_uav', '花果山统一设备演示无人机', 'seed_equipment', 'UAV-011', '低空应急技术保障组', 'mobile', 'active', ST_SetSRID(ST_MakePoint(119.25936,34.65446),4326), 154, 'AMSL', 'DJI', 'Matrice 350 RTK', 'SIM-UAV-011', true, '{}'),
  ('HGS-UGV-001', 'unmanned_vehicle', 'tracked_ugv', '南坡应急无人车', 'seed_equipment', 'UGV-001', '花果山景区应急管理中心', 'mobile', 'active', ST_SetSRID(ST_MakePoint(119.29678,34.63168),4326), 92, 'AMSL', '模拟厂商', 'UGV-T1', 'SIM-UGV-001', true, '{}'),
  ('HGS-VEHVIDEO-001', 'vehicle_surveillance', 'mobile_surveillance', '西入口车载监控系统', 'seed_equipment', 'VEHVIDEO-001', '花果山景区管理处', 'mobile', 'active', ST_SetSRID(ST_MakePoint(119.23874,34.64022),4326), 71, 'AMSL', '模拟厂商', 'Mobile-Eye-4', 'SIM-VEHVIDEO-001', true, '{}'),
  ('HGS-SENSOR-001', 'sensor', 'weather_station', '玉女峰气象传感设备', 'seed_equipment', 'SENSOR-001', '花果山景区管理处', 'fixed', 'active', ST_SetSRID(ST_MakePoint(119.30042,34.65132),4326), 588, 'AMSL', '模拟厂商', 'Weather-M1', 'SIM-SENSOR-001', true, '{}')
on conflict (source_system, source_asset_id) do update set
  asset_code = excluded.asset_code, category_code = excluded.category_code, type_code = excluded.type_code,
  name = excluded.name, managing_unit_name = excluded.managing_unit_name,
  deployment_mode = excluded.deployment_mode, lifecycle_status = excluded.lifecycle_status,
  elevation_amsl_m = excluded.elevation_amsl_m, height_datum = excluded.height_datum,
  manufacturer = excluded.manufacturer, model = excluded.model, serial_no = excluded.serial_no,
  is_simulated = excluded.is_simulated, metadata = excluded.metadata;

insert into equipment.base_station_6g_profile(asset_id, operator_name, frequency_band, bandwidth_mhz, backhaul_type)
select id, '花果山景区管理处', 'sub-THz-simulated', 400, 'fiber' from equipment.asset where source_system='seed_equipment' and source_asset_id='6G-001'
on conflict (asset_id) do update set operator_name=excluded.operator_name, frequency_band=excluded.frequency_band, bandwidth_mhz=excluded.bandwidth_mhz, backhaul_type=excluded.backhaul_type;
insert into equipment.counter_uas_profile(asset_id, detection_mode, identification_mode, tracking_mode, recommendation_notes)
select id, 'radio_and_radar', 'manual_review', 'multi_target', '仅展示探测覆盖和处置建议，不提供直接控制。' from equipment.asset where source_system='seed_equipment' and source_asset_id='CUAS-001'
on conflict (asset_id) do update set detection_mode=excluded.detection_mode, identification_mode=excluded.identification_mode, tracking_mode=excluded.tracking_mode, recommendation_notes=excluded.recommendation_notes;
insert into equipment.video_surveillance_profile(asset_id, camera_type, ptz_supported, optical_zoom, stream_ref)
select id, 'thermal_ptz', true, 30, 'vault://streams/hgs-video-001' from equipment.asset where source_system='seed_equipment' and source_asset_id='VIDEO-001'
on conflict (asset_id) do update set camera_type=excluded.camera_type, ptz_supported=excluded.ptz_supported, optical_zoom=excluded.optical_zoom, stream_ref=excluded.stream_ref;
insert into equipment.uav_profile(asset_id, max_takeoff_weight_kg, endurance_min, max_payload_kg)
select id, 9.2, 55, 2.7 from equipment.asset where source_system='seed_equipment' and source_asset_id='UAV-011'
on conflict (asset_id) do update set max_takeoff_weight_kg=excluded.max_takeoff_weight_kg, endurance_min=excluded.endurance_min, max_payload_kg=excluded.max_payload_kg;
insert into equipment.unmanned_vehicle_profile(asset_id, vehicle_type, max_speed_kph, endurance_min, max_payload_kg)
select id, 'tracked', 18, 180, 80 from equipment.asset where source_system='seed_equipment' and source_asset_id='UGV-001'
on conflict (asset_id) do update set vehicle_type=excluded.vehicle_type, max_speed_kph=excluded.max_speed_kph, endurance_min=excluded.endurance_min, max_payload_kg=excluded.max_payload_kg;
insert into equipment.vehicle_surveillance_profile(asset_id, camera_count, sensor_count, stream_ref)
select id, 4, 2, 'vault://streams/hgs-vehicle-video-001' from equipment.asset where source_system='seed_equipment' and source_asset_id='VEHVIDEO-001'
on conflict (asset_id) do update set camera_count=excluded.camera_count, sensor_count=excluded.sensor_count, stream_ref=excluded.stream_ref;
insert into equipment.sensor_profile(asset_id, sensor_type, sampling_interval_s)
select id, 'weather', 60 from equipment.asset where source_system='seed_equipment' and source_asset_id='SENSOR-001'
on conflict (asset_id) do update set sensor_type=excluded.sensor_type, sampling_interval_s=excluded.sampling_interval_s;
insert into equipment.sensor_channel(asset_id, channel_code, metric_code, unit, warning_threshold)
select id, 'temperature', 'air_temperature', '°C', '{"high":38}' from equipment.asset where source_system='seed_equipment' and source_asset_id='SENSOR-001'
on conflict (asset_id, channel_code) do update set metric_code=excluded.metric_code, unit=excluded.unit, warning_threshold=excluded.warning_threshold;

insert into equipment.asset_status_current(asset_id, connectivity_status, dispatch_status, position_geom, position_height_amsl_m, height_datum, last_heartbeat_at, observed_at, payload)
select id,
  case source_asset_id when 'CUAS-001' then 'unknown' when 'UGV-001' then 'offline' else 'online' end,
  case category_code when 'base_station_6g' then 'unavailable' when 'counter_uas' then 'unavailable' when 'sensor' then 'unavailable' when 'unmanned_vehicle' then 'maintenance' else 'available' end,
  geom, elevation_amsl_m, 'AMSL', now(), now(), jsonb_build_object('source','seed_equipment','simulated',true)
from equipment.asset where source_system='seed_equipment'
on conflict (asset_id) do update set
  connectivity_status=excluded.connectivity_status, dispatch_status=excluded.dispatch_status,
  last_heartbeat_at=excluded.last_heartbeat_at, observed_at=excluded.observed_at,
  payload=excluded.payload;

insert into equipment.capability(code, name, capability_type, description) values
  ('communication_6g','6G 通信','communication','提供模拟 6G 通信覆盖。'),
  ('video_observation','视频观测','observation','提供可见光或热成像视频观测。'),
  ('environment_sensing','环境感知','observation','采集气象和环境指标。'),
  ('uas_detection','无人机探测','detection','探测低空无人机目标。'),
  ('uas_identification','无人机识别','identification','辅助识别低空无人机目标。'),
  ('uas_tracking','无人机跟踪','tracking','持续跟踪低空无人机目标。'),
  ('mobile_transport','移动运输','transport','运输应急物资或设备。')
on conflict (code) do update set name=excluded.name, capability_type=excluded.capability_type, description=excluded.description;

insert into equipment.asset_capability(asset_id, capability_code, access_level, enabled, parameters)
select a.id, v.capability_code, v.access_level, true, v.parameters
from (values
  ('6G-001','communication_6g','observable','{"radius_m":3000}'::jsonb),
  ('CUAS-001','uas_detection','recommendable','{"radius_m":2500}'::jsonb),
  ('CUAS-001','uas_identification','recommendable','{}'::jsonb),
  ('CUAS-001','uas_tracking','recommendable','{}'::jsonb),
  ('VIDEO-001','video_observation','linkable','{"radius_m":1200}'::jsonb),
  ('UAV-011','video_observation','linkable','{"mobile":true}'::jsonb),
  ('UGV-001','mobile_transport','linkable','{"payload_kg":80}'::jsonb),
  ('VEHVIDEO-001','video_observation','linkable','{"mobile":true}'::jsonb),
  ('SENSOR-001','environment_sensing','observable','{}'::jsonb)
) v(source_asset_id, capability_code, access_level, parameters)
join equipment.asset a on a.source_system='seed_equipment' and a.source_asset_id=v.source_asset_id
on conflict (asset_id, capability_code) do update set access_level=excluded.access_level, enabled=excluded.enabled, parameters=excluded.parameters;

insert into equipment.asset_coverage(asset_capability_id, coverage_geom, min_height_amsl_m, max_height_amsl_m, height_datum, metadata)
select ac.id,
  ST_Multi(ST_Buffer(a.geom::geography, case ac.capability_code when 'communication_6g' then 3000 else 1200 end)::geometry),
  a.elevation_amsl_m, a.elevation_amsl_m + 500, 'AMSL', '{"simulated":true}'::jsonb
from equipment.asset_capability ac join equipment.asset a on a.id=ac.asset_id
where a.source_system='seed_equipment' and ac.capability_code in ('communication_6g','uas_detection','video_observation')
  and not exists (select 1 from equipment.asset_coverage c where c.asset_capability_id=ac.id and c.metadata @> '{"simulated":true}'::jsonb);

insert into equipment.raw_observation(asset_id, source_system, source_observation_id, observation_type, observed_at, received_at, geom, height_amsl_m, height_datum, confidence, processing_status, raw_payload, is_simulated)
select id, 'seed_equipment', source_asset_id || '-OBS-001',
  case category_code when 'sensor' then 'weather_sample' when 'counter_uas' then 'target_detection' else 'heartbeat' end,
  now(), now(), geom, elevation_amsl_m, 'AMSL', 0.92, 'received',
  jsonb_build_object('source_asset_id',source_asset_id,'sample',true), true
from equipment.asset where source_system='seed_equipment'
on conflict (source_system, source_observation_id) do nothing;

insert into emergency_resource.equipment_resource(asset_id, resource_role, active, metadata)
select id,
  case category_code when 'uav' then 'aerial_inspection' when 'unmanned_vehicle' then 'ground_transport' else 'video_observation' end,
  true, '{"simulated":true}'::jsonb
from equipment.asset
where source_system='seed_equipment' and category_code in ('uav','unmanned_vehicle','vehicle_surveillance','video_surveillance')
on conflict (asset_id) do update set resource_role=excluded.resource_role, active=excluded.active, metadata=excluded.metadata;

commit;
