(function (global, factory) {
  'use strict';
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanTrajectoryPrediction = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  var SUBJECT_STYLE = {
    airspace_target: { color: '#e879f9', label: '空域目标' },
    aircraft_asset: { color: '#38bdf8', label: '无人机资产' }
  };
  var MODEL_LABEL = { cv: '恒速', ct: '转向', hover: '悬停' };
  var FALLBACK_HEIGHT_M = 100;
  var POLL_INTERVAL_MS = 2000;
  var UNCERTAINTY_EVERY = 3;

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/&gt;/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  function subjectStyle(kind) {
    return SUBJECT_STYLE[kind] || { color: '#94a3b8', label: kind || '未知' };
  }

  function formatPredictionSummary(prediction) {
    var style = subjectStyle(prediction.subject_kind);
    var speed = prediction.speed_mps == null ? '--' : Number(prediction.speed_mps).toFixed(1);
    var model = MODEL_LABEL[prediction.model_code] || prediction.model_code;
    return style.label + ' #' + prediction.subject_id + ' · ' + model + ' · ' + speed + ' m/s · +' +
      Number(prediction.horizon_seconds || 0) + 's';
  }

  function pointHeight(point) {
    var height = Number(point && point.height_amsl_m);
    return Number.isFinite(height) ? height : FALLBACK_HEIGHT_M;
  }

  function createModule(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var viewer = options.viewer;
    var rpc = options.rpc;
    var log = options.log || function () {};
    var dataSources = {};
    var enabled = false;
    var authenticated = true;
    var refreshTimer = null;
    var destroyed = false;
    var polling = false;
    var failedOnce = false;

    function ensureDataSource(kind) {
      var key = String(kind || 'unknown');
      if (dataSources[key]) return dataSources[key];
      var style = subjectStyle(kind);
      var dataSource = new CesiumRuntime.CustomDataSource('trajectory-prediction-' + key);
      dataSource.show = enabled;
      viewer.dataSources.add(dataSource);
      dataSources[key] = dataSource;
      return dataSource;
    }

    function clearEntities() {
      Object.keys(dataSources).forEach(function (key) {
        dataSources[key].entities.removeAll();
      });
    }

    function removeLayers() {
      Object.keys(dataSources).forEach(function (key) { viewer.dataSources.remove(dataSources[key], true); });
      dataSources = {};
    }

    function positionOf(point) {
      return CesiumRuntime.Cartesian3.fromDegrees(point.longitude, point.latitude, pointHeight(point));
    }

    function renderPrediction(prediction) {
      var points = (prediction && prediction.points || []).filter(function (point) {
        return Number.isFinite(Number(point.longitude)) && Number.isFinite(Number(point.latitude));
      });
      if (!points.length) return;
      var kind = prediction.subject_kind;
      var style = subjectStyle(kind);
      var color = CesiumRuntime.Color.fromCssColorString(style.color);
      var dataSource = ensureDataSource(kind);
      var idPrefix = 'trajectory-prediction-' + kind + '-' + prediction.subject_id;
      var positions = points.map(positionOf);
      dataSource.entities.add({
        id: idPrefix + '-line',
        name: formatPredictionSummary(prediction),
        polyline: {
          positions: positions,
          width: 3,
          material: new CesiumRuntime.PolylineDashMaterialProperty({
            color: color.withAlpha(0.95),
            dashLength: 12
          }),
          clampToGround: false
        },
        description: '模型：' + escapeHtml(MODEL_LABEL[prediction.model_code] || prediction.model_code) +
          '；窗口点数：' + escapeHtml(prediction.window_point_count) +
          '；拟合残差：' + escapeHtml(prediction.fit_residual_m == null ? '--' : prediction.fit_residual_m + ' m')
      });
      points.forEach(function (point, index) {
        if ((index + 1) % UNCERTAINTY_EVERY !== 0 && index !== points.length - 1) return;
        var uncertainty = Number(point.uncertainty_m);
        if (!Number.isFinite(uncertainty) || uncertainty <= 0) return;
        var fade = 1 - 0.6 * (index / Math.max(1, points.length - 1));
        dataSource.entities.add({
          id: idPrefix + '-uncertainty-' + index,
          position: positionOf(point),
          ellipse: {
            semiMajorAxis: uncertainty,
            semiMinorAxis: uncertainty,
            material: color.withAlpha(0.08 * fade),
            outline: true,
            outlineColor: color.withAlpha(0.35 * fade),
            height: pointHeight(point)
          }
        });
      });
      var last = points[points.length - 1];
      dataSource.entities.add({
        id: idPrefix + '-endpoint',
        position: positionOf(last),
        point: {
          pixelSize: 7,
          color: color.withAlpha(0.9),
          outlineColor: CesiumRuntime.Color.fromCssColorString('#0b1120').withAlpha(0.9),
          outlineWidth: 2,
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        },
        label: {
          text: '+' + Number(last.eta_seconds || 0) + 's',
          font: '600 11px sans-serif',
          fillColor: color,
          showBackground: true,
          backgroundColor: CesiumRuntime.Color.fromCssColorString('#0b1120').withAlpha(0.75),
          pixelOffset: new CesiumRuntime.Cartesian2(0, -16),
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        }
      });
    }

    function refresh() {
      if (!enabled || polling || destroyed) return Promise.resolve();
      polling = true;
      return rpc('get_trajectory_predictions', {
        p_subject_kinds: null,
        p_max_subjects: 200,
        p_max_prediction_age_seconds: 30
      }).then(function (payload) {
        if (destroyed || !enabled) return payload;
        clearEntities();
        (payload && payload.predictions || []).forEach(renderPrediction);
        failedOnce = false;
        return payload;
      }).catch(function (error) {
        if (!failedOnce) log('轨迹预测加载失败：' + error.message, 'error');
        failedOnce = true;
      }).finally(function () {
        polling = false;
      });
    }

    function stopRefresh() {
      if (refreshTimer) clearInterval(refreshTimer);
      refreshTimer = null;
    }

    function applyVisibility() {
      Object.keys(dataSources).forEach(function (key) {
        dataSources[key].show = enabled;
      });
    }

    function setEnabled(value) {
      var next = Boolean(value) && authenticated;
      if (next === enabled) {
        applyVisibility();
        return Promise.resolve();
      }
      enabled = next;
      if (!enabled) {
        stopRefresh();
        clearEntities();
        applyVisibility();
        return Promise.resolve();
      }
      var promise = refresh();
      refreshTimer = setInterval(refresh, POLL_INTERVAL_MS);
      return promise;
    }

    function setAuthenticated(value) {
      authenticated = Boolean(value);
      if (!authenticated) return setEnabled(false);
      applyVisibility();
      return Promise.resolve();
    }

    return {
      setEnabled: setEnabled,
      setAuthenticated: setAuthenticated,
      isEnabled: function () { return enabled; },
      refresh: refresh,
      destroy: function () {
        destroyed = true;
        stopRefresh();
        removeLayers();
      }
    };
  }

  return {
    createModule: createModule,
    formatPredictionSummary: formatPredictionSummary,
    subjectStyle: subjectStyle
  };
});
