const fs = require('fs');
const assert = require('assert');
const SourceSituation = require('../frontend/src/features/source-situation/source-situation-module');
const PredictionTimeline = require('../frontend/src/features/trajectory-prediction/prediction-timeline');

const pageHtml = fs.readFileSync(require.resolve('../frontend/tianditu-3d.html'), 'utf8');
assert(pageHtml.includes('data-situation-layer="remote-pilot"'));
const defenseRingLayerText = fs.readFileSync(
  require.resolve('../frontend/src/features/defense-rings/defense-ring-layer'),
  'utf8',
);
assert(pageHtml.includes('data-layer="defenseRings"'));
assert(defenseRingLayerText.includes("rpc('get_defense_ring_config'"));
assert(defenseRingLayerText.includes('semiMajorAxis'));
assert(defenseRingLayerText.includes('sensing'));
assert(defenseRingLayerText.includes('hard_strike'));
assert(defenseRingLayerText.includes('core'));

const sourceModuleText = fs.readFileSync(
  require.resolve('../frontend/src/features/source-situation/source-situation-module'),
  'utf8',
);
assert(sourceModuleText.includes("rpc('get_detection_live_tracks_v3'"));
assert(!sourceModuleText.includes("rpc('list_target_risk_assessments'"));
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
    p_require_spatial: false,
  },
);
assert.strictEqual(
  SourceSituation.buildHistoryPayload('2026-09-21', '2026-09-21', [20], true).p_require_spatial,
  true,
  '开启空间过滤时必须传递 p_require_spatial',
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

const riskSplit = SourceSituation.splitTrackByRisk([
  { observed_at: '2026-09-21T10:00:00+08:00', position: { coordinates: [119.19, 34.59] }, riskAssessment: { status: 'assessed', riskLevel: 'low' } },
  { observed_at: '2026-09-21T10:01:00+08:00', position: { coordinates: [119.191, 34.59] }, riskAssessment: { status: 'assessed', riskLevel: 'high' } },
  { observed_at: '2026-09-21T10:02:00+08:00', position: { coordinates: [119.192, 34.59] }, riskAssessment: { status: 'assessed', riskLevel: 'high' } },
], 100);
assert.deepStrictEqual(riskSplit.segments.map((segment) => segment.riskAssessment.riskLevel), ['low', 'high']);
assert.deepStrictEqual(riskSplit.segments.map((segment) => segment.points.length), [2, 2]);

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
assert.deepStrictEqual(
  SourceSituation.sourceState({
    enabled: true,
    connector_state: 'connected',
    last_message_at: '2026-09-21T10:00:00+08:00',
    lost_timeout_seconds: 60,
    skew_abs_max_seconds: 24.3,
    skew_sample_count: 40,
  }, '2026-09-21T10:01:00+08:00'),
  { code: 'warning', label: '源时钟偏差严重' },
);
assert.deepStrictEqual(
  SourceSituation.sourceState({
    enabled: true,
    connector_state: 'connected',
    last_message_at: '2026-09-21T10:00:00+08:00',
    lost_timeout_seconds: 60,
    skew_abs_max_seconds: 8.2,
    skew_sample_count: 40,
  }, '2026-09-21T10:01:00+08:00'),
  { code: 'warning', label: '源时钟偏差' },
);
assert.strictEqual(
  SourceSituation.sourceState({
    enabled: true,
    connector_state: 'connected',
    last_message_at: '2026-09-21T10:00:00+08:00',
    lost_timeout_seconds: 60,
    skew_abs_max_seconds: 2.1,
    skew_sample_count: 40,
  }, '2026-09-21T10:01:00+08:00').code,
  'ok',
);

const replayPredictions = [
  { id: 1, base_observed_at: '2026-10-14T10:00:00+08:00' },
  { id: 2, base_observed_at: '2026-10-14T10:00:30+08:00' },
  { id: 3, base_observed_at: '2026-10-14T10:01:00+08:00' },
].map((prediction) => Object.assign(prediction, {
  predicted_at: prediction.base_observed_at,
  points: [
    { eta_seconds: 0, longitude: 119, latitude: 34, height_amsl_m: 0 },
    { eta_seconds: 120, longitude: 119.01, latitude: 34, height_amsl_m: 200, uncertainty_m: 50 },
  ],
}));
const futureGeneratedPrediction = Object.assign({}, replayPredictions[1], {
  id: 4, predicted_at: '2026-10-14T10:00:50+08:00',
});
assert.strictEqual(SourceSituation.pickReplayPrediction(
  replayPredictions.concat(futureGeneratedPrediction), Date.parse('2026-10-14T10:00:45+08:00'),
).id, 2, '未来生成的预测不能进入回放');
const longPrediction = Object.assign({}, replayPredictions[0], {
  points: [replayPredictions[0].points[0], Object.assign({}, replayPredictions[0].points[1], { eta_seconds: 300 })],
});
assert.strictEqual(SourceSituation.pickReplayPrediction([longPrediction], Date.parse('2026-10-14T10:03:00+08:00')), longPrediction);
assert.strictEqual(SourceSituation.pickReplayPrediction([longPrediction], Date.parse('2026-10-14T10:03:00+08:00')),
  PredictionTimeline.pickReplayPrediction([longPrediction], Date.parse('2026-10-14T10:03:00+08:00')));
assert.strictEqual(
  SourceSituation.pickReplayPrediction(replayPredictions, Date.parse('2026-10-14T10:00:45+08:00')).id,
  2,
);
assert.strictEqual(
  SourceSituation.pickReplayPrediction(replayPredictions, Date.parse('2026-10-14T10:00:10+08:00')).id,
  1,
);
assert.strictEqual(
  SourceSituation.pickReplayPrediction(replayPredictions, Date.parse('2026-10-14T09:59:00+08:00')),
  null,
);
assert.strictEqual(
  SourceSituation.pickReplayPrediction(replayPredictions, Date.parse('2026-10-14T10:05:00+08:00')),
  null,
);
assert.strictEqual(SourceSituation.pickReplayPrediction([], Date.parse('2026-10-14T10:00:45+08:00')), null);

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
  riskAssessment: { status: 'assessed', riskLevel: 'high', riskScore: 75 },
  observations: [{
    observation_id: 1,
    observed_at: '2026-09-21T10:00:00+08:00',
    target_location: { position: { coordinates: [119.19, 34.59] }, altitude_amsl_m: 100 },
    remote_pilot_location: { position: { coordinates: [119.18, 34.58] }, source: 'vendor_reported' },
  }],
}]);
SourceSituation.applyLiveChanges(liveTracks, [{
  type: 'risk_changed',
  aggregate_id: 7,
  riskAssessment: { status: 'assessed', riskLevel: 'critical', riskScore: 90 },
  payload: { track_id: 7 },
}], '2026-09-21T10:01:00+08:00', 300, 60, ['radio_detection']);
assert.strictEqual(liveTracks['7'].riskAssessment.riskLevel, 'critical', '风险增量只替换 current 风险属性');
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
  riskAssessment: { status: 'assessed', riskLevel: 'high', riskScore: 75 },
  spatial_point_count: 12,
  flagged_observation_count: 2,
  first_observed_at: '2026-09-21T10:00:00+08:00',
  last_observed_at: '2026-09-21T10:01:00+08:00',
}]);
assert(html.includes('&lt;DJI&gt;'));
assert(html.includes('12'));
assert(html.includes('高 75分'));
assert(html.includes('高 75分'));

const riskHistoryHtml = SourceSituation.riskHistoryHtml({ assessments: [
  { observedAt: '2026-09-21T10:00:00+08:00', status: 'assessed', riskLevel: 'low', riskScore: 25, ringCode: 'sensing', ruleVersion: 1 },
  { observedAt: '2026-09-21T10:01:00+08:00', status: 'assessed', riskLevel: 'high', riskScore: 75, ringCode: 'hard_strike', ruleVersion: 2 },
] });
assert(riskHistoryHtml.includes('风险评估历史'));
assert(riskHistoryHtml.includes('变化'));
assert(riskHistoryHtml.includes('硬打击圈'));
assert(riskHistoryHtml.includes('risk-history-list'));
const riskDetailHtml = SourceSituation.riskTrackDetailHtml({
  track: { id: 7, track_code: 'TRK-7', riskAssessment: { status: 'assessed', riskLevel: 'high', riskScore: 75 } },
  observations: [
    { observation_id: 105, observed_at: '2026-09-21T10:00:00+08:00', riskAssessment: { status: 'assessed', riskLevel: 'low', riskScore: 25 } },
    { observation_id: 106, observed_at: '2026-09-21T10:01:00+08:00', riskAssessment: { status: 'assessed', riskLevel: 'high', riskScore: 75 } },
  ],
}, { assessments: [
  { observedAt: '2026-09-21T10:00:00+08:00', status: 'assessed', riskLevel: 'low', riskScore: 25 },
  { observedAt: '2026-09-21T10:01:00+08:00', status: 'assessed', riskLevel: 'high', riskScore: 75 },
] });
assert(riskDetailHtml.includes('TRK-7'));
assert(riskDetailHtml.includes('区间末风险'));
assert(riskDetailHtml.includes('风险变化'));
assert.deepStrictEqual(SourceSituation.riskAssessmentsFromObservations([{
  observation_id: 106,
  observed_at: '2026-09-21T10:01:00+08:00',
  riskAssessment: { status: 'assessed', riskLevel: 'high', riskScore: 75, ringCode: 'hard_strike' },
}])[0], {
  observationId: 106,
  observedAt: '2026-09-21T10:01:00+08:00',
  status: 'assessed',
  riskLevel: 'high',
  riskScore: 75,
  ringCode: 'hard_strike',
});
assert(!html.includes('<DJI>'));

async function testModuleIntegration() {
  const originalDocument = global.document;
  const originalSetInterval = global.setInterval;
  const originalClearInterval = global.clearInterval;
  const elements = {};
  function element(key) {
    if (!elements[key]) elements[key] = {
      value: '2026-10-14', dataset: {}, handlers: {}, attributes: {},
      addEventListener(name, handler) { this.handlers[name] = handler; },
      removeEventListener(name) { delete this.handlers[name]; },
      getAttribute(name) { return this.attributes[name]; },
      setAttribute(name, value) { this.attributes[name] = value; },
    };
    return elements[key];
  }
  const historyButton = element('history');
  historyButton.dataset.situationMode = 'history';
  const realtimeButton = element('realtime');
  realtimeButton.dataset.situationMode = 'realtime';
  global.document = {
    querySelector: element,
    querySelectorAll: (selector) => selector === '[data-situation-mode]' ? [historyButton, realtimeButton] : [],
  };
  let timerId = 0;
  const timers = new Map();
  global.setInterval = (callback) => { timers.set(++timerId, callback); return timerId; };
  global.clearInterval = (id) => timers.delete(id);
  const sources = [];
  const color = { withAlpha() { return this; } };
  const CesiumRuntime = {
    CustomDataSource: function (name) {
      this.name = name;
      this.entities = {
        values: [],
        getById(id) { return this.values.find((entity) => entity.id === id); },
        removeById(id) {
          const entity = this.getById(id);
          if (!entity) return false;
          this.values.splice(this.values.indexOf(entity), 1);
          return true;
        },
        add(entity) {
          assert(!this.getById(entity.id), 'entity IDs must be unique within a collection');
          this.values.push(entity);
          return entity;
        },
      };
    },
    Color: { fromCssColorString: () => color },
    Cartesian3: { fromDegrees: (longitude, latitude, height) => ({ longitude, latitude, height }) },
    Cartesian2: function () {},
    Rectangle: { fromDegrees: (...values) => values },
    PolylineOutlineMaterialProperty: function () {},
    PolylineDashMaterialProperty: function () {},
  };
  const selectedEntity = { id: 'unrelated' };
  const viewer = {
    selectedEntity,
    dataSources: {
      add(source) { sources.push(source); },
      remove(source) { sources.splice(sources.indexOf(source), 1); },
    },
    camera: { flyTo() { throw new Error('detail-only must not move camera'); } },
  };
  const observations = [0, 60, 90].map((seconds, index) => ({
    observation_id: index + 1,
    observed_at: new Date(Date.parse('2026-10-14T02:00:00Z') + seconds * 1000).toISOString(),
    target_location: { position: { coordinates: [119 + index * 0.0001, 34] }, altitude_amsl_m: 0 },
    detection_method_code: 'radar',
  }));
  const detail = { track: { id: 7, track_code: 'TRK-7' }, observations };
  const deferred = [];
  const callbacks = [];
  const detailHtml = [];
  const logs = [];
  let liveIds = [7, 8];
  let liveObservations = observations;
  let liveMethod = 'radar';
  let pendingDetail = null;
  let module;
  const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
  const entities = () => sources.flatMap((source) => source.entities.values);
  function clickTrack(id) {
    element('#sourceSituationSummary').handlers.click({ target: { closest: () => ({ dataset: { trackId: id } }) } });
  }
  function replay() {
    element('#featureProperties').handlers.click({ target: { closest: () => ({}) } });
  }
  try {
    module = SourceSituation.createModule({
      CesiumRuntime, viewer,
      showDetail: (html) => detailHtml.push(html),
      log: (...args) => logs.push(args),
      onSubjectSelected: (...args) => callbacks.push(args),
      rpc: (name, payload) => {
        if (name === 'get_detection_live_tracks_v3') return Promise.resolve({
          cursor: 1,
          tracks: liveIds.map((id) => ({ track_id: id, observations: liveObservations, latest_observation_method_code: id === 7 ? liveMethod : 'radio_detection' })),
        });
        if (name === 'get_target_track_detail') {
          if (pendingDetail) return new Promise((resolve, reject) => { pendingDetail.resolve = resolve; pendingDetail.reject = reject; });
          return Promise.resolve(Object.assign({}, detail, { track: { id: payload.p_track_id, track_code: 'TRK-' + payload.p_track_id } }));
        }
        if (name === 'get_track_prediction_history') return new Promise((resolve, reject) => deferred.push({ resolve, reject }));
        if (name === 'get_detection_situation_changes') return Promise.resolve({ changes: [], next_cursor: 1 });
        throw new Error('Unexpected RPC ' + name);
      },
    });
    await module.load();
    const target = module.getSubjectEntity('airspace_target', '7');
    assert(target);
    assert.deepStrictEqual(target.properties, { subject_kind: 'airspace_target', subject_id: 7 });
    const trail = entities().find((entity) => entity.id === 'detection-live-trail-7-0');
    assert.deepStrictEqual(trail.properties, target.properties);
    module.selectSubject('airspace_target', 7);
    assert.strictEqual(target.point.pixelSize, 16);
    assert.strictEqual(trail.polyline.width, 6);
    module.selectSubject('airspace_target', 8);
    assert.strictEqual(target.point.pixelSize, 11);
    assert.strictEqual(trail.polyline.width, 3);
    assert.strictEqual(module.getSubjectEntity('airspace_target', 8).point.pixelSize, 16);
    await module.load();
    assert.strictEqual(module.getSubjectEntity('airspace_target', 8).point.pixelSize, 16, '重绘后保留选择');
    assert.strictEqual(module.getSubjectEntity('airspace_target', 7), target, '连续刷新保留目标 Entity');
    assert.strictEqual(entities().find((entity) => entity.id === trail.id), trail, '连续刷新保留尾迹 Entity');
    viewer.selectedEntity = target;
    const radarSource = sources.find((source) => source.entities.getById(target.id));
    radarSource.show = false;
    for (let i = 0; i < 3; i++) await module.load();
    assert.strictEqual(viewer.selectedEntity, target);
    assert.strictEqual(radarSource.show, false, '实时刷新保留图层可见性');
    assert.strictEqual(module.isSubjectVisible('airspace_target', 7), false, '定位可区分已隐藏的实时目标');
    assert.strictEqual(sources.find((source) => source.entities.getById(target.id)), radarSource);
    assert.strictEqual(entities().length, 4, '连续刷新不累积实体');
    // Replacing graphics must still restore the current subject highlight.
    module.selectSubject('airspace_target', 7);
    await module.load();
    assert.strictEqual(target.point.pixelSize, 16);
    assert.strictEqual(trail.polyline.width, 6);
    module.selectSubject(null, null);
    assert.strictEqual(target.point.pixelSize, 11);
    assert.strictEqual(trail.polyline.width, 3);

    // Method migration also keeps the same entity, without duplicate IDs.
    liveMethod = 'radio_detection';
    await module.load();
    assert.strictEqual(module.getSubjectEntity('airspace_target', 7), target);
    assert.strictEqual(entities().find((entity) => entity.id === trail.id), trail);
    assert.strictEqual(radarSource.entities.values.length, 0);
    liveMethod = 'radar';

    // A realtime pass removes old history/replay graphics without replacing live entities.
    radarSource.entities.add({ id: 'detection-history-stale', polyline: {} });
    radarSource.entities.add({ id: 'replay-prediction-line-stale', polyline: {} });
    await module.load();
    assert(!entities().some((entity) => /stale/.test(entity.id)));
    assert.strictEqual(module.getSubjectEntity('airspace_target', 7), target);

    // Bounds are computed only from this render, not from a previous larger extent.
    liveObservations = observations.map((observation) => Object.assign({}, observation, {
      target_location: { position: { coordinates: [120, 35] }, altitude_amsl_m: 12 },
    }));
    await module.load();
    assert.deepStrictEqual(target.position, { longitude: 120, latitude: 35, height: 12 });
    let destination;
    viewer.camera.flyTo = (options) => { destination = options.destination; };
    element('#sourceSituationLocate').handlers.click();
    assert.deepStrictEqual(destination, [119.998, 34.998, 120.002, 35.002]);
    liveIds = [];
    await module.load();
    assert.strictEqual(element('#sourceSituationLocate').disabled, true);
    assert.strictEqual(entities().length, 0);
    destination = null;
    element('#sourceSituationLocate').handlers.click();
    assert.strictEqual(destination, null);
    liveIds = [7, 8];
    liveObservations = observations;

    // Pilot marker/link are reconciled when pilot observations expire.
    liveObservations = observations.map((observation) => Object.assign({}, observation, {
      remote_pilot_location: { position: { coordinates: [118.9, 34] } },
    }));
    await module.load();
    assert(entities().some((entity) => entity.id === 'detection-remote-pilot-7'));
    assert(entities().some((entity) => entity.id === 'detection-target-pilot-link-7'));
    liveObservations = observations;
    await module.load();
    assert(!entities().some((entity) => /pilot/.test(entity.id)));
    liveIds = [7];
    await module.load();
    assert.strictEqual(module.getSubjectEntity('airspace_target', 8), null);
    assert(!entities().some((entity) => entity.id === 'detection-live-trail-8-0'));
    liveIds = [7, 8];
    await module.load();

    for (const nextId of [null, 8]) {
      module.selectSubject('airspace_target', 7);
      pendingDetail = {};
      const request = module.showSubjectDetail('airspace_target', 7);
      const count = detailHtml.length;
      module.selectSubject(nextId == null ? null : 'airspace_target', nextId);
      pendingDetail.resolve(detail);
      assert.strictEqual(await request, null);
      assert.strictEqual(detailHtml.length, count, '清除或切换选择后不显示过期详情');
      pendingDetail = null;
    }
    viewer.selectedEntity = selectedEntity;
    const currentSources = sources.slice();
    await module.showSubjectDetail('airspace_target', 7);
    assert(detailHtml.at(-1).includes('TRK-7'));
    assert.deepStrictEqual(sources, currentSources, '详情不得替换实时图层');
    assert.strictEqual(viewer.selectedEntity, selectedEntity);
    assert.deepStrictEqual(callbacks, [], '详情不触发选择回调');
    await module.load();
    assert(module.getSubjectEntity('airspace_target', 7), '详情后仍处于实时模式');
    assert.strictEqual(await module.showSubjectDetail('unknown', 1), null);

    // History list selection loads detail and reports the same subject identity.
    viewer.camera.flyTo = () => {};
    historyButton.handlers.click();
    clickTrack(7);
    await flush();
    assert.deepStrictEqual(callbacks.at(-1), ['airspace_target', 7]);
    element('#featureProperties').handlers.change({ target: { closest: () => ({ checked: true }) } });
    replay();
    assert.strictEqual(deferred.length, 1);
    deferred[0].resolve({ predictions: [replayPredictions[0]] });
    await flush();
    replay(); // Cached history renders synchronously at the first observation.
    assert.strictEqual(entities().find((entity) => entity.id === 'replay-prediction-line-1').polyline.positions[0].height, 0);
    assert.strictEqual(entities().find((entity) => entity.id === 'replay-prediction-uncertainty-1').ellipse.height, 200);
    [...timers.values()][0](); // second observation is 60 seconds into prediction
    const line = entities().find((entity) => entity.id === 'replay-prediction-line-1');
    assert(line);
    assert(Math.abs(line.polyline.positions[0].longitude - 119.005) < 1e-8);
    assert.strictEqual(line.polyline.positions[0].height, 100, '插值 AMSL 不额外增加 100 米');
    assert.strictEqual(line.polyline.positions.at(-1).height, 200);

    // A later track request wins even if the old request resolves last.
    clickTrack(8);
    await flush();
    replay();
    clickTrack(9);
    await flush();
    replay();
    deferred[2].resolve({ predictions: [Object.assign({}, replayPredictions[0], { id: 9 })] });
    await flush();
    deferred[1].resolve({ predictions: [Object.assign({}, replayPredictions[0], { id: 8 })] });
    await flush();
    [...timers.values()][0]();
    assert(entities().some((entity) => entity.id === 'replay-prediction-line-9'));
    assert(!entities().some((entity) => entity.id === 'replay-prediction-line-8'));

    // Reset, mode changes, and destruction invalidate pending success/error handlers.
    for (const action of [() => module.clear(), () => realtimeButton.handlers.click(), () => module.destroy()]) {
      historyButton.handlers.click();
      clickTrack(10);
      await flush();
      replay();
      const pending = deferred.at(-1);
      action();
      const logCount = logs.length;
      if (deferred.length % 2) pending.reject(new Error('obsolete request'));
      else pending.resolve({ predictions: [] });
      await flush();
      assert.strictEqual(logs.length, logCount, '过期请求不得报告错误或污染缓存');
      assert.strictEqual(sources.length, 0);
    }
  } finally {
    if (module) module.destroy();
    global.document = originalDocument;
    global.setInterval = originalSetInterval;
    global.clearInterval = originalClearInterval;
  }
}

testModuleIntegration().then(() => console.log('source situation module tests passed')).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
