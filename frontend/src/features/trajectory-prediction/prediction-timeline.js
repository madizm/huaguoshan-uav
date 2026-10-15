(function (global, factory) {
  'use strict';
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanPredictionTimeline = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  function number(value) { return value !== null && value !== undefined && value !== '' && Number.isFinite(Number(value)); }
  function height(point) { return number(point && point.height_amsl_m) ? Number(point.height_amsl_m) : 100; }
  function subjectKey(kind, id) { return String(kind) + ':' + String(id); }
  function clipPrediction(prediction, timeMs, options) {
    options = options || {};
    if (!prediction || !Number.isFinite(timeMs)) return { state: 'unknown', points: [] };
    var base = Date.parse(prediction.base_observed_at);
    var computed = Date.parse(prediction.predicted_at);
    if (!Number.isFinite(base) || !Number.isFinite(computed)) return { state: 'invalid', points: [] };
    var result = { points: [], observationAgeSeconds: (timeMs - base) / 1000, remainingSeconds: 0 };
    function finish(state) { result.state = state; return result; }
    if (base > timeMs || computed > timeMs) return finish('future');
    var maxAge = options.maxPredictionAgeSeconds === undefined ? 30 : options.maxPredictionAgeSeconds;
    if (maxAge !== null && timeMs - computed > maxAge * 1000) return finish('stale');
    if (prediction.quality && prediction.quality !== 'ok') return finish('insufficient_data');
    var maxObservationAge = options.maxObservationAgeSeconds === undefined ? (maxAge === null ? null : 30) : options.maxObservationAgeSeconds;
    if (maxObservationAge !== null && timeMs - base > maxObservationAge * 1000) return finish('observation_stale');
    var points = (prediction.points || []).filter(function (p) {
      return number(p.longitude) && number(p.latitude) && number(p.eta_seconds) && Number(p.eta_seconds) >= 0;
    }).slice().sort(function (a, b) { return Number(a.eta_seconds) - Number(b.eta_seconds); });
    // A timestamp is a single point, even if a malformed payload repeats it.
    points = points.filter(function (p, i) { return !i || Number(p.eta_seconds) !== Number(points[i - 1].eta_seconds); });
    if (!points.length) return finish('unknown');
    var horizon = number(prediction.horizon_seconds) ? Number(prediction.horizon_seconds) : Number(points[points.length - 1].eta_seconds);
    var endEta = Math.min(horizon, Number(points[points.length - 1].eta_seconds));
    var age = (timeMs - base) / 1000;
    if (age >= endEta) return finish('expired');
    result.remainingSeconds = Math.max(0, endEta - age);
    points = points.filter(function (p) { return Number(p.eta_seconds) <= endEta; });
    var next = points.findIndex(function (p) { return Number(p.eta_seconds) >= age; });
    if (next < 0) return finish('expired');
    result.points = points.slice(next);
    if (next > 0 && Number(points[next].eta_seconds) > age) {
      var a = points[next - 1], b = points[next];
      var fraction = (age - Number(a.eta_seconds)) / (Number(b.eta_seconds) - Number(a.eta_seconds));
      var longitudeDelta = ((Number(b.longitude) - Number(a.longitude) + 540) % 360) - 180;
      result.points.unshift({ eta_seconds: age,
        longitude: ((Number(a.longitude) + fraction * longitudeDelta + 540) % 360) - 180,
        latitude: Number(a.latitude) + fraction * (Number(b.latitude) - Number(a.latitude)),
        height_amsl_m: number(a.height_amsl_m) && number(b.height_amsl_m) ? Number(a.height_amsl_m) + fraction * (Number(b.height_amsl_m) - Number(a.height_amsl_m)) : null,
        uncertainty_m: number(a.uncertainty_m) && number(b.uncertainty_m) ? Number(a.uncertainty_m) + fraction * (Number(b.uncertainty_m) - Number(a.uncertainty_m)) : null
      });
    }
    return finish('valid');
  }
  function pickReplayPrediction(predictions, timeMs) {
    var best = null;
    (predictions || []).forEach(function (p) {
      var base = Date.parse(p.base_observed_at), generated = Date.parse(p.predicted_at);
      if (!Number.isFinite(base) || !Number.isFinite(generated) || base > timeMs || generated > timeMs) return;
      if (!best || Date.parse(p.predicted_at) > Date.parse(best.predicted_at) ||
        (Date.parse(p.predicted_at) === Date.parse(best.predicted_at) && Number(p.id) > Number(best.id))) best = p;
    });
    return best && clipPrediction(best, timeMs, { maxPredictionAgeSeconds: null }).state === 'valid' ? best : null;
  }
  return { clipPrediction: clipPrediction, pickReplayPrediction: pickReplayPrediction, pointHeight: height, subjectKey: subjectKey };
});
