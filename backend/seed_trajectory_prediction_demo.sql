-- 轨迹预测演示/验证数据：一个北飞雷达目标 + 一架直线飞行的无人机资产。
-- 空域目标走真实 ingest 通道（rawPayload 标记 simulated），无人机资产观测 is_simulated=true。
begin;

-- 空域目标：sourceTargetId=SIM-PRED-001，向正北 20 m/s，最近 60 秒每 5 秒一点。
select situation.ingest_target_observation(jsonb_build_object(
  'schemaVersion', '1',
  'sourceSystem', 'radar_cloud',
  'stationId', '90',
  'sourceObservationId', 'sim-pred-001-' || i || '-' || extract(epoch from now())::bigint,
  'sourceTargetId', 'SIM-PRED-001',
  'sourceSessionId', 'sim-pred-session-' || extract(epoch from now())::bigint,
  'sourceTypeCode', 10,
  'detectionMethodCode', 'radar',
  'eventType', 'snapshot',
  'observedAt', (now() - make_interval(secs => 60 - i * 5))::text,
  'receivedAt', now()::text,
  'longitude', 119.2683,
  'latitude', 34.6469 + 0.000898 * i,
  'altitudeAmslM', 150 + 1.5 * i,
  'speedMps', 20,
  'model', 'SIM-VTOL',
  'qualityFlags', array[]::text[],
  'rawPayload', jsonb_build_object('simulated', true, 'purpose', 'trajectory_prediction_validation')
)) from generate_series(0, 12) i;

-- 无人机资产：HGS-UAV-001 (id=2)，向东 12 m/s，最近 60 秒每 5 秒一点。
insert into equipment.raw_observation(
  asset_id, source_system, source_observation_id, observation_type,
  observed_at, received_at, geom, height_amsl_m, height_datum,
  confidence, processing_status, raw_payload, is_simulated
)
select
  2, 'prediction_selftest', 'sim-uav-001-' || i || '-' || extract(epoch from now())::bigint,
  'position_report',
  now() - make_interval(secs => 60 - i * 5), now(),
  ST_SetSRID(ST_MakePoint(119.2683 + 0.000547 * i, 34.6469), 4326),
  120 + 0.5 * i, 'AMSL', 1, 'received',
  jsonb_build_object('simulated', true, 'purpose', 'trajectory_prediction_validation'),
  true
from generate_series(0, 12) i;

commit;
