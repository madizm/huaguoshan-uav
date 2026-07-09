(function (global) {
  'use strict';

  function $(selector) { return document.querySelector(selector); }

  function initLayer(options) {
    if (!global.FlightObstacleSituationLayer) {
      options.log('飞行障碍态势模块未加载，飞行障碍图层不可用。');
      return null;
    }

    var layer = global.FlightObstacleSituationLayer.create({
      getViewer: options.getViewer,
      getCesium: function () { return global.Cesium; },
      huaguoshan: options.huaguoshan,
      log: options.log,
      renderError: options.renderError,
      showPanel: options.showPanel,
      getLimit: function () {
        var input = $('#flightObstacleLimit');
        return input ? Number(input.value) : 200;
      },
      getTerrainLodMode: function () {
        var select = $('#terrainLodMode');
        return select ? select.value : 'auto';
      },
      requestSource: function (sourceKind, limit) {
        return options.rpc('list_flight_obstacles_gger', {
          p_source_kind: sourceKind,
          p_limit: limit,
          p_include_boxes: true
        }).then(function (data) {
          return Array.isArray(data) ? data : [];
        });
      },
      requestTerrainLod: function (payload) {
        return options.rpc('list_flight_obstacles_gger_lod', payload).then(function (data) {
          return Array.isArray(data) ? data : [];
        });
      },
      helpers: options.helpers
    });

    layer.syncSourceButtons();
    return layer;
  }

  function bindControls(options) {
    var limitInput = $('#flightObstacleLimit');
    var terrainMode = $('#terrainLodMode');
    var layer = options.layer;
    if (layer()) layer().syncSourceButtons();
    if (limitInput) {
      limitInput.addEventListener('change', function () {
        if (layer() && layer().isEnabled()) layer().refresh(true);
      });
    }
    if (terrainMode) {
      terrainMode.addEventListener('change', function () {
        if (layer()) layer().setTerrainLodMode(terrainMode.value);
      });
    }
  }

  global.HuaguoshanFlightObstacles = {
    initLayer: initLayer,
    bindControls: bindControls
  };
})(window);
