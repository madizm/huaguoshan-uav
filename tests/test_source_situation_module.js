const fs = require('fs');
const assert = require('assert');
const SourceSituation = require('../frontend/src/features/source-situation/source-situation-module');

const pageHtml = fs.readFileSync(require.resolve('../frontend/tianditu-3d.html'), 'utf8');
assert(pageHtml.includes('data-situation-layer="remote-pilot"'));

const sourceModuleText = fs.readFileSync(
  require.resolve('../frontend/src/features/source-situation/source-situation-module'),
  'utf8',
);
assert(sourceModuleText.includes("rpc('get_detection_live_tracks_v3'"));
assert(sourceModuleText.includes('p_detection_method_codes: detectionMethods'));
assert(!sourceModuleText.includes("rpc('get_detection_live_tracks',"));
assert(sourceModuleText.includes("data-situation-layer"));
assert(sourceModuleText.includes("detection-remote-pilot-"));
assert(sourceModuleText.includes("detection-target-pilot-link-"));

assert.deepStrictEqual(
  SourceSituation.buildHistoryPayload('2026-09-21', '2026-09-21', [20]),
  {
    p_start_at: '2026-09-21T00:00:00+08:00',
    p_end_at: '2026-09-22T00:00:00+08:00',
    p_station_ids: null,
    p_source_type_codes: [20],
    p_limit: 200,
  },
);
assert.throws(
  () => SourceSituation.buildHistoryPayload('2025-12-31', '2025-12-26'),
  /结束日期不能早于开始日期/,
);
assert.throws(
  () => SourceSituation.buildHistoryPayload('2026-09-01', '2026-09-08'),
  /最多支持 7 天/,
);
assert.deepStrictEqual(
  SourceSituation.buildHistoryPayload('2026-09-21', '2026-09-21', []).p_source_type_codes,
  [],
  '来源全部取消时必须查询空集，而不是退化为不过滤',
);

const split = SourceSituation.splitTrack([
  { observed_at: '2026-09-21T10:00:00+08:00', position: { coordinates: [119.19, 34.59] } },
  { observed_at: '2026-09-21T10:01:00+08:00', position: { coordinates: [119.191, 34.59] } },
  { observed_at: '2026-09-21T10:02:00+08:00', position: { coordinates: [122, 38] } },
], 100);
assert.strictEqual(split.jumpCount, 1);
assert.strictEqual(split.segments.length, 1);

const duplicatePoint = {
  observed_at: '2026-09-21T10:00:00+08:00',
  position: { coordinates: [119.19, 34.59] },
};
assert.strictEqual(SourceSituation._private.groundSpeed(duplicatePoint, duplicatePoint), 0);

assert.deepStrictEqual(
  SourceSituation.sourceState({
    enabled: true,
    connector_state: 'connected',
    last_message_at: '2026-09-21T10:00:00+08:00',
    lost_timeout_seconds: 60,
  }, '2026-09-21T10:01:00+08:00'),
  { code: 'ok', label: '接入正常' },
);
assert.strictEqual(
  SourceSituation.sourceState({
    enabled: true,
    connector_state: 'connected',
    last_message_at: '2026-09-21T09:00:00+08:00',
    lost_timeout_seconds: 60,
  }, '2026-09-21T10:01:00+08:00').code,
  'warning',
);

const sourceButtons = ['radar', 'radio_detection'].map((code) => ({
  dataset: { detectionMethod: code },
  getAttribute: () => 'true',
}));
assert.strictEqual(SourceSituation._private.detectionMethodFilter(sourceButtons), null);
sourceButtons[0].getAttribute = () => 'false';
assert.deepStrictEqual(SourceSituation._private.detectionMethodFilter(sourceButtons), ['radio_detection']);
assert.deepStrictEqual(SourceSituation._private.legacySourceTypeFilter(sourceButtons), [20]);

const liveTracks = SourceSituation.indexLiveTracks([{
  track_id: 7,
  status: 'tracking',
  source_type_code: 20,
  observations: [{
    observation_id: 1,
    observed_at: '2026-09-21T10:00:00+08:00',
    target_location: { position: { coordinates: [119.19, 34.59] }, altitude_amsl_m: 100 },
    remote_pilot_location: { position: { coordinates: [119.18, 34.58] }, source: 'vendor_reported' },
  }],
}]);
SourceSituation.applyLiveChanges(liveTracks, [{
  type: 'target_upsert',
  occurred_at: '2026-09-21T10:01:00+08:00',
  payload: {
    track_id: 7,
    observation: {
      observation_id: 2,
      observed_at: '2026-09-21T10:01:00+08:00',
      target_location: { position: { coordinates: [119.191, 34.59] }, altitude_amsl_m: 101 },
      remote_pilot_location: { position: { coordinates: [119.181, 34.581] }, source: 'vendor_reported' },
      detection_method_code: 'radio_detection',
    },
  },
}, {
  type: 'target_upsert',
  occurred_at: '2026-09-21T10:01:00+08:00',
  payload: {
    track_id: 7,
    observation: {
      observation_id: 2,
      observed_at: '2026-09-21T10:01:00+08:00',
      target_location: { position: { coordinates: [119.191, 34.59] } },
      remote_pilot_location: { position: { coordinates: [119.181, 34.581] } },
      detection_method_code: 'radio_detection',
    },
  },
}], '2026-09-21T10:01:00+08:00', 300, 60, ['radio_detection']);
assert.strictEqual(liveTracks['7'].points.length, 2, '增量观测按 observation_id 去重');
assert.strictEqual(liveTracks['7'].remotePilotPoints.length, 2, '飞手位置按同一 observation_id 合并');
assert.deepStrictEqual(liveTracks['7'].remotePilotPoints[1].position.coordinates, [119.181, 34.581]);

SourceSituation.applyLiveChanges(liveTracks, [{
  type: 'target_remove',
  occurred_at: '2026-09-21T10:01:30+08:00',
  payload: { track_id: 7 },
}], '2026-09-21T10:01:30+08:00', 300, 60, ['radio_detection']);
assert.strictEqual(liveTracks['7'].status, 'lost');
SourceSituation.applyLiveChanges(liveTracks, [], '2026-09-21T10:02:31+08:00', 300, 60, ['radio_detection']);
assert.strictEqual(liveTracks['7'], undefined, '丢失航迹超过保留时间后移除');

const html = SourceSituation.historySummaryHtml([{
  track_id: 1,
  track_code: 'TRK-1',
  source_target_id: '<target>',
  source_type_code: 20,
  model: '<DJI>',
  spatial_point_count: 12,
  flagged_observation_count: 2,
  first_observed_at: '2026-09-21T10:00:00+08:00',
  last_observed_at: '2026-09-21T10:01:00+08:00',
}]);
assert(html.includes('&lt;DJI&gt;'));
assert(html.includes('12'));
assert(!html.includes('<DJI>'));

console.log('source situation module tests passed');
