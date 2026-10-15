(function (global, factory) {
  'use strict';
  var timeline = typeof module !== 'undefined' && module.exports ? require('./prediction-timeline') : global.HuaguoshanPredictionTimeline;
  var api = factory(timeline);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanTrajectoryPrediction = api;
})(typeof window !== 'undefined' ? window : globalThis, function (timeline) {
  'use strict';
  var SUBJECT_STYLE = {
    airspace_target: { color: '#e879f9', label: '空域目标' },
    aircraft_asset: { color: '#38bdf8', label: '无人机资产' }
  };
  var MODEL_LABEL = { cv: '恒速', ct: '转向', hover: '悬停' };
  var STATUS_LABEL = { valid: '有效', expired: '预测已结束', stale: '预测未更新', observation_stale: '基准观测已陈旧', insufficient_data: '无法生成预测', unknown: '暂无预测（原因未知）', invalid: '预测时间无效', future: '预测时间尚未到达' };
  var REASONS = { not_enough_points: '有效观测点不足', window_span_too_short: '观测时间跨度不足', unrealistic_speed: '速度异常，已拒绝预测' };
  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }
  function subjectStyle(kind) { return SUBJECT_STYLE[kind] || { color: '#94a3b8', label: kind || '未知' }; }
  function formatPredictionSummary(prediction) {
    return subjectStyle(prediction.subject_kind).label + ' #' + prediction.subject_id + ' · ' + (MODEL_LABEL[prediction.model_code] || prediction.model_code) + ' · ' +
      (prediction.speed_mps == null ? '--' : Number(prediction.speed_mps).toFixed(1)) + ' m/s · 观测后 +' + Number(prediction.horizon_seconds || 0) + 's';
  }
  function createModule(options) {
    var CesiumRuntime = options.CesiumRuntime, viewer = options.viewer;
    var rpc = options.rpc, log = options.log || function () {};
    var statusElement = options.statusElement;
    var now = options.now || Date.now;
    var sources = {}, records = {}, statuses = {}, selectedKey = null;
    var enabled = false, authenticated = true, destroyed = false, refreshTimer = null, tickTimer = null;
    var generation = 0, pending = null, readError = false, clockOffset = 0, synchronized = false;
    function clock() { return now() + clockOffset; }
    function sourceFor(kind) {
      if (!sources[kind]) {
        sources[kind] = new CesiumRuntime.CustomDataSource('trajectory-prediction-' + kind);
        sources[kind].show = enabled;
        viewer.dataSources.add(sources[kind]);
      }
      return sources[kind];
    }
    function clearEntities() { Object.keys(sources).forEach(function (k) { sources[k].entities.removeAll(); }); }
    function upsert(collection, desired, definition) {
      desired[definition.id] = true;
      var entity = collection.getById(definition.id);
      if (!entity) return collection.add(definition);
      Object.keys(definition).forEach(function (key) { if (key !== 'id') entity[key] = definition[key]; });
      return entity;
    }
    function position(point) { return CesiumRuntime.Cartesian3.fromDegrees(Number(point.longitude), Number(point.latitude), timeline.pointHeight(point)); }
    function renderPrediction(prediction, clipped, desired) {
      var kind = prediction.subject_kind, key = timeline.subjectKey(kind, prediction.subject_id);
      var collection = sourceFor(kind).entities;
      var color = CesiumRuntime.Color.fromCssColorString(subjectStyle(kind).color);
      var prefix = 'trajectory-prediction-' + kind + '-' + prediction.subject_id;
      var properties = { subject_kind: kind, subject_id: prediction.subject_id };
      var selected = key === selectedKey;
      var description = '关联对象：' + escapeHtml(key) + '；基准观测：' + escapeHtml(prediction.base_observed_at) +
        '；观测年龄：' + Math.floor(clipped.observationAgeSeconds) + ' 秒；剩余未来：' + Math.ceil(clipped.remainingSeconds) + ' 秒' +
        '；模型：' + escapeHtml(MODEL_LABEL[prediction.model_code] || prediction.model_code) +
        '；窗口点数：' + escapeHtml(prediction.window_point_count) + '；拟合残差：' + escapeHtml(prediction.fit_residual_m == null ? '--' : prediction.fit_residual_m + ' m');
      if (clipped.points.length >= 2) upsert(collection, desired, {
        id: prefix + '-line', name: formatPredictionSummary(prediction), properties: properties, description: description,
        polyline: { positions: clipped.points.map(position), width: selected ? 5 : 3,
          material: new CesiumRuntime.PolylineDashMaterialProperty({ color: color.withAlpha(selected ? 1 : 0.8), dashLength: 12 }), clampToGround: false }
      });
      clipped.points.forEach(function (point, index) {
        if ((index + 1) % 3 !== 0 && index !== clipped.points.length - 1) return;
        var uncertainty = Number(point.uncertainty_m);
        if (!Number.isFinite(uncertainty) || uncertainty <= 0) return;
        upsert(collection, desired, { id: prefix + '-uncertainty-' + point.eta_seconds, properties: properties,
          position: position(point), name: formatPredictionSummary(prediction), description: description,
          ellipse: { semiMajorAxis: uncertainty, semiMinorAxis: uncertainty, material: color.withAlpha(selected ? 0.14 : 0.05), outline: true,
            outlineColor: color.withAlpha(selected ? 0.65 : 0.3), height: timeline.pointHeight(point) }
        });
      });
      var last = clipped.points[clipped.points.length - 1];
      if (!last) return;
      upsert(collection, desired, { id: prefix + '-endpoint', properties: properties,
        position: position(last), name: formatPredictionSummary(prediction), description: description,
        point: { pixelSize: selected ? 10 : 7, color: color, outlineColor: CesiumRuntime.Color.fromCssColorString('#0b1120'), outlineWidth: 2, disableDepthTestDistance: Number.POSITIVE_INFINITY },
        label: { text: '距现在约 ' + Math.ceil(clipped.remainingSeconds) + 's', font: '600 11px sans-serif', fillColor: color, showBackground: true,
          backgroundColor: CesiumRuntime.Color.fromCssColorString('#0b1120').withAlpha(0.75), pixelOffset: new CesiumRuntime.Cartesian2(0, -16), disableDepthTestDistance: Number.POSITIVE_INFINITY }
      });
    }
    function writeStatus() {
      if (!statusElement) return;
      if (!enabled) { statusElement.textContent = '预测图层已关闭'; return; }
      var message;
      if (selectedKey) {
        var status = statuses[selectedKey] || { state: 'unknown' };
        var record = records[selectedKey];
        message = selectedKey + ' · ' + STATUS_LABEL[status.state];
        if (record && record.reason) message += ' · ' + (REASONS[record.reason] || record.reason);
        if (Number.isFinite(status.observationAgeSeconds)) message += ' · 观测已过 ' + Math.floor(status.observationAgeSeconds) + 's';
        if (status.state === 'valid') message += ' · 剩余 ' + Math.ceil(status.remainingSeconds) + 's';
      } else {
        var counts = {};
        Object.keys(statuses).forEach(function (key) { var s = statuses[key].state; counts[s] = (counts[s] || 0) + 1; });
        message = Object.keys(counts).map(function (s) { return STATUS_LABEL[s] + ' ' + counts[s]; }).join(' · ') || '暂无预测（原因未知）';
      }
      statusElement.textContent = (readError ? '读取异常，保留未过期数据 · ' : '') + message;
    }
    function redraw() {
      if (destroyed || !enabled) return;
      var desiredByKind = {};
      statuses = {};
      Object.keys(records).forEach(function (key) {
        var prediction = records[key], clipped = timeline.clipPrediction(prediction, clock());
        statuses[key] = clipped;
        if (clipped.state !== 'valid') return;
        var desired = desiredByKind[prediction.subject_kind] || (desiredByKind[prediction.subject_kind] = {});
        renderPrediction(prediction, clipped, desired);
      });
      Object.keys(sources).forEach(function (kind) {
        var collection = sources[kind].entities, desired = desiredByKind[kind] || {};
        collection.values.slice().forEach(function (entity) { if (!desired[entity.id]) collection.removeById(entity.id); });
      });
      writeStatus();
    }
    function refresh() {
      if (!enabled || destroyed) return Promise.resolve();
      if (pending) return pending;
      var requestGeneration = generation, requestStarted = now();
      var request = rpc('get_trajectory_predictions', { p_subject_kinds: null, p_max_subjects: 200, p_max_prediction_age_seconds: 30 }).then(function (payload) {
        if (destroyed || !enabled || requestGeneration !== generation) return payload;
        var serverTime = Date.parse(payload && payload.generated_at);
        if (Number.isFinite(serverTime)) {
          // generated_at lies after request send and before response receipt.
          // Use the conservative upper clock bound, not receipt-time skew:
          // delayed responses must never turn elapsed trajectory back into future.
          var upperOffset = serverTime - requestStarted;
          clockOffset = synchronized ? Math.max(clockOffset, upperOffset) : upperOffset;
          synchronized = true;
        }
        var next = {};
        (payload && payload.predictions || []).forEach(function (p) { next[timeline.subjectKey(p.subject_kind, p.subject_id)] = p; });
        (payload && payload.states || []).forEach(function (s) {
          var key = timeline.subjectKey(s.subject_kind, s.subject_id), p = next[key];
          // Never display an older valid line over a newer failed computation.
          if (!p || s.quality !== 'ok' || (s.id != null && p.id != null && String(s.id) !== String(p.id)) || s.predicted_at !== p.predicted_at) next[key] = s;
        });
        records = next;
        readError = false;
        redraw();
        return payload;
      }).catch(function (error) {
        if (destroyed || !enabled || requestGeneration !== generation) return;
        if (!readError) log('轨迹预测加载失败：' + error.message, 'error');
        readError = true;
        redraw();
      }).finally(function () { if (pending === request) pending = null; });
      pending = request;
      return request;
    }
    function stop() {
      if (refreshTimer) clearInterval(refreshTimer);
      if (tickTimer) clearInterval(tickTimer);
      refreshTimer = tickTimer = null;
    }
    function setEnabled(value) {
      var next = Boolean(value) && authenticated;
      if (next === enabled) return enabled ? refresh() : Promise.resolve();
      enabled = next;
      generation += 1;
      pending = null;
      Object.keys(sources).forEach(function (k) { sources[k].show = enabled; });
      if (!enabled) { stop(); records = {}; statuses = {}; clearEntities(); writeStatus(); return Promise.resolve(); }
      refreshTimer = setInterval(refresh, 2000);
      tickTimer = setInterval(redraw, 1000);
      return refresh();
    }
    return {
      setEnabled: setEnabled, refresh: refresh, isEnabled: function () { return enabled; },
      tick: redraw,
      selectSubject: function (kind, id) { selectedKey = kind != null && id != null ? timeline.subjectKey(kind, id) : null; redraw(); },
      getSubjectState: function (kind, id) { return statuses[timeline.subjectKey(kind, id)] || { state: 'unknown', points: [] }; },
      setAuthenticated: function (value) { authenticated = Boolean(value); return authenticated ? Promise.resolve() : setEnabled(false); },
      destroy: function () { destroyed = true; enabled = false; generation += 1; stop(); Object.keys(sources).forEach(function (k) { viewer.dataSources.remove(sources[k], true); }); sources = {}; records = {}; statuses = {}; }
    };
  }
  return { createModule: createModule, formatPredictionSummary: formatPredictionSummary, subjectStyle: subjectStyle };
});
