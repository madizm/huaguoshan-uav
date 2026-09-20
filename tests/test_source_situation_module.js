const assert = require('assert');
const SourceSituation = require('../frontend/src/features/source-situation/source-situation-module');

assert.deepStrictEqual(
  SourceSituation.buildPayload('2025-12-26', '2025-12-31'),
  {
    p_start_at: '2025-12-26T00:00:00',
    p_end_at: '2026-01-01T00:00:00',
    p_drone_sample_seconds: 60,
  },
);
assert.throws(
  () => SourceSituation.buildPayload('2025-12-31', '2025-12-26'),
  /结束日期不能早于开始日期/,
);

assert.deepStrictEqual(
  SourceSituation.qualityState({ total_rows: 10, coordinate_anomaly_rows: 0 }),
  { code: 'ok', label: '基础校验正常', count: 0 },
);
assert.strictEqual(
  SourceSituation.qualityState({ total_rows: 10, coordinate_anomaly_rows: 2, speed_anomaly_rows: 1 }).count,
  3,
);
assert.strictEqual(SourceSituation.qualityState({ total_rows: 0 }).code, 'empty');

const payload = {
  tracks: [
    { source_code: 'uav_hf', track_id: 'a' },
    { source_code: 'passive_radar', track_id: '1' },
    { source_code: 'passive_radar', track_id: '2' },
  ],
};
assert.strictEqual(SourceSituation.sourceTracks(payload, 'passive_radar').length, 2);

const split = SourceSituation._private.splitTrack([
  { observed_at: '2025-12-26T10:00:00', lon: 110, lat: 20 },
  { observed_at: '2025-12-26T10:01:00', lon: 110.001, lat: 20 },
  { observed_at: '2025-12-26T10:02:00', lon: 113, lat: 23 },
], 100);
assert.strictEqual(split.jumpCount, 1);
assert.strictEqual(split.segments.length, 1);

const html = SourceSituation.sourceSummaryHtml([{
  source_code: 'uav_hf', source_name: '<华飞>', total_rows: 100, displayable_rows: 98,
  coordinate_anomaly_rows: 2, altitude_anomaly_rows: 0, speed_anomaly_rows: 0,
  first_at: '2025-12-30T10:00:00', last_at: '2025-12-31T10:00:00',
}]);
assert(html.includes('&lt;华飞&gt;'));
assert(html.includes('需核验 2 条'));
assert(!html.includes('<华飞>'));

console.log('source situation module tests passed');
