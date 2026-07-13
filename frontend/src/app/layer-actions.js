(function (global) {
  'use strict';

  function setGgerBaseLayerActive(state) {
    var button;
    if (!state.airspaceEnabled) {
      state.airspaceEnabled = true;
      button = document.querySelector('[data-layer="gger"]');
      if (button) button.setAttribute('aria-pressed', 'true');
      if (state.airspaceGrid) state.airspaceGrid.setEnabled(true);
    }
  }

  function handleAction(actionButton, options) {
    var action = actionButton.dataset.action;
    var state = options.state;
    var log = options.log;

    if (action === 'huaguoshan') options.flyToHuaguoshan();
    if (action === 'tileset') options.flyToTileset();
    if (action === 'dem') options.flyToDem();
    if (action === 'lianyungangDem') options.flyToLianyungangDem();
    if (action === 'lianyungangBuildings') options.loadLianyungangBuildings();
    if (action === 'china') global.HuaguoshanCamera.flyToChina(options.CesiumRuntime, state.viewer);
    if (action === 'tilt') global.HuaguoshanCamera.flyToTilt(options.CesiumRuntime, state.viewer, options.huaguoshan);
    if (action === 'zoomSelectedGrid') options.flyToSelectedGridHighlight();
    if (action === 'clearGridHighlight') {
      options.clearSelectedGridHighlight();
      log('已清除当前要素的 GGER 包围网格高亮。');
    }
    if (action === 'refreshFlightObstacles') {
      var flightButton = document.querySelector('[data-layer="flightObstacles"]');
      if (flightButton) flightButton.setAttribute('aria-pressed', 'true');
      if (state.flightObstacleLayer) {
        state.flightObstacleLayer.invalidate();
        state.flightObstacleLayer.setEnabled(true);
      }
    }
    if (action === 'zoomFlightObstacles' && state.flightObstacleLayer) {
      state.flightObstacleLayer.zoomToBounds(null, '已定位到当前飞行障碍总范围。');
    }
    if (action === 'clearFlightObstacles') {
      var clearButton = document.querySelector('[data-layer="flightObstacles"]');
      if (clearButton) clearButton.setAttribute('aria-pressed', 'false');
      if (state.flightObstacleLayer) state.flightObstacleLayer.setEnabled(false);
      log('飞行障碍图层已清除。');
    }
    if (action === 'zoomFlightObstacle' && state.flightObstacleLayer) {
      var obstacle = state.flightObstacleLayer.obstacleByIndex(actionButton.dataset.obstacleIndex);
      state.flightObstacleLayer.zoomToBounds(obstacle && obstacle.bounds, obstacle ? '已定位到飞行障碍：' + (obstacle.source_name || obstacle.source_id) : null);
    }
  }

  function handleSourceToggle(sourceButton, state) {
    var sourceKind = sourceButton.dataset.obstacleSource;
    var sourceActive = sourceButton.getAttribute('aria-pressed') !== 'true';
    sourceButton.setAttribute('aria-pressed', String(sourceActive));
    if (state.flightObstacleLayer) state.flightObstacleLayer.setSourceEnabled(sourceKind, sourceActive);
  }

  function handleLayerToggle(layerButton, options) {
    var state = options.state;
    var CesiumRuntime = options.CesiumRuntime;
    var log = options.log;
    var layer = layerButton.dataset.layer;
    var active = layerButton.getAttribute('aria-pressed') !== 'true';
    layerButton.setAttribute('aria-pressed', String(active));

    if (layer === 'image' && state.imageLayer) state.imageLayer.show = active;
    if (layer === 'boundary' && state.boundaryLayer) state.boundaryLayer.show = active;
    if (layer === 'terrain') {
      state.viewer.terrainProvider = active ? state.terrainProvider : new CesiumRuntime.EllipsoidTerrainProvider();
    }
    if (layer === 'tileset' && state.buildingsTileset) {
      state.buildingsTileset.show = active;
      log(active ? '本工程导出的 3D Tiles 模型已显示。' : '本工程导出的 3D Tiles 模型已隐藏。');
    }
    if (layer === 'dem') {
      state.demVisible = active;
      if (state.demTileset) state.demTileset.show = active;
      log(active ? 'DEM 网格已显示：用于检查本工程 GeoTIFF 高程面。' : 'DEM 网格已隐藏。');
    }
    if (layer === 'lianyungangDem') {
      state.lianyungangDemVisible = active;
      if (state.lianyungangDemTileset) state.lianyungangDemTileset.show = active;
      log(active ? '连云港 DEM 已显示：用于检查连云港市 GeoTIFF 高程面。' : '连云港 DEM 已隐藏。');
    }
    if (layer === 'place' && state.wtfs) {
      state.wtfsVisible = active;
      if (typeof state.wtfs.show === 'boolean') state.wtfs.show = active;
      if (state.wtfs.labels) state.wtfs.labels.show = active;
      log(active ? '三维地名服务已开启。' : '三维地名开关已切换；如插件版本不支持 show 属性，刷新瓦片后生效。');
    }
    if (layer === 'gger' && state.airspaceGrid) {
      state.airspaceEnabled = active;
      state.airspaceGrid.setEnabled(active);
      log(active ? 'GGER 网格已开启：按当前视域自动选择 GGER 层级。' : 'GGER 网格已关闭。');
    }
    if (layer === 'airspace' && state.airspaceGrid) {
      setGgerBaseLayerActive(state);
      state.airspaceGrid.setVerticalEnabled(active);
      log(active ? '空域柱网已开启：按 GGER 高度层向上堆叠显示三维线框。' : '空域柱网已关闭。');
    }
    if (layer === 'slice' && state.airspaceGrid) {
      setGgerBaseLayerActive(state);
      state.airspaceGrid.setSliceEnabled(active);
      log(active ? '高度切片已开启：显示当前高度所在 GGER 高度层。' : '高度切片已关闭。');
    }
    if (layer === 'ggerLabels' && state.airspaceGrid) {
      setGgerBaseLayerActive(state);
      state.airspaceGrid.setLabelsEnabled(active);
      log(active ? 'GGER 网格编码标签已开启。' : 'GGER 网格编码标签已关闭。');
    }
    if (layer === 'flightObstacles' && state.flightObstacleLayer) {
      state.flightObstacleLayer.setEnabled(active);
    }
  }

  function bindControls(options) {
    var closeFeaturePanel = document.querySelector('#closeFeaturePanel');
    if (closeFeaturePanel) {
      closeFeaturePanel.addEventListener('click', function (event) {
        event.stopPropagation();
        options.hideFeaturePanel();
        options.clearSelectedGridHighlight();
        options.log('CityDB 属性面板已关闭；再次点击建筑模型可重新打开。');
      });
    }

    document.addEventListener('click', function (event) {
      var actionButton = event.target.closest('[data-action]');
      var layerButton = event.target.closest('[data-layer]');
      var sourceButton = event.target.closest('[data-obstacle-source]');
      if (actionButton) handleAction(actionButton, options);
      if (sourceButton) handleSourceToggle(sourceButton, options.state);
      if (layerButton) handleLayerToggle(layerButton, options);
    });
  }

  global.HuaguoshanLayerActions = {
    bindControls: bindControls,
    handleAction: handleAction,
    handleSourceToggle: handleSourceToggle,
    handleLayerToggle: handleLayerToggle
  };
})(window);
