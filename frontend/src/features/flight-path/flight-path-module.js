(function (global) {
  'use strict';

  function pickLonLat(getViewer, CesiumRuntime, position) {
    if (global.HuaguoshanAirspaceConstraints && global.HuaguoshanAirspaceConstraints.pickLonLat) {
      return global.HuaguoshanAirspaceConstraints.pickLonLat(getViewer, CesiumRuntime, position);
    }
    return null;
  }

  function initWorkbench(options) {
    var container = document.querySelector(options.containerSelector || '#flightPathWorkbench');
    var workbench;
    if (!container || !global.FlightPathWorkbench) {
      options.log('目标航迹工作台模块未加载，飞行路径规划不可用。');
      return null;
    }
    workbench = global.FlightPathWorkbench.create({
      rpc: options.rpc,
      log: options.log,
      renderError: options.renderError,
      getCesium: options.getCesium || function () { return global.Cesium; },
      map: {
        pickLonLat: function (position) {
          return pickLonLat(options.getViewer, (options.getCesium || function () { return global.Cesium; })(), position);
        }
      },
      helpers: options.helpers
    });
    workbench.setViewer(options.getViewer());
    workbench.mount(container);
    return workbench;
  }

  global.HuaguoshanFlightPath = {
    pickLonLat: pickLonLat,
    initWorkbench: initWorkbench
  };
})(window);
