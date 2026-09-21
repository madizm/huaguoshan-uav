const assert = require('assert');
const SourceSituation = require('../frontend/src/features/source-situation/source-situation-module');

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

const sourceButtons = [10, 20].map((code) => ({
  dataset: { sourceSituation: String(code) },
  getAttribute: () => 'true',
}));
assert.strictEqual(SourceSituation._private.sourceTypeFilter(sourceButtons), null);
sourceButtons[0].getAttribute = () => 'false';
assert.deepStrictEqual(SourceSituation._private.sourceTypeFilter(sourceButtons), [20]);

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
