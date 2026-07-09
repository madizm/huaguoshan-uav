(function (global) {
  'use strict';

  function $(selector) { return document.querySelector(selector); }

  var defaultSelectors = {
    levelMode: '#ggerLevelMode',
    maxCells: '#ggerMaxCells',
    anchorHeight: '#ggerAnchorHeight',
    stackCount: '#ggerStackCount',
    currentHeight: '#ggerCurrentHeight',
    currentHeightValue: '#ggerCurrentHeightValue',
    levelReadout: '#ggerLevel',
    cellsReadout: '#ggerCells',
    heightLayerReadout: '#ggerHeightLayer',
    selected2DReadout: '#ggerSelected2D',
    selected3DReadout: '#ggerSelected3D'
  };

  function selectors(overrides) {
    return Object.assign({}, defaultSelectors, overrides || {});
  }

  function formatMeters(value, digits) {
    return Number.isFinite(value) ? value.toFixed(digits == null ? 2 : digits) + 'm' : '--';
  }

  function updateCurrentHeightRange(info, selectorOverrides) {
    var s = selectors(selectorOverrides);
    var current = $(s.currentHeight);
    if (!current || !info || !Number.isFinite(info.stackMinHeight) || !Number.isFinite(info.stackMaxHeight)) return;
    current.min = String(info.stackMinHeight);
    current.max = String(info.stackMaxHeight);
    current.step = info.unitHeightMeters < 1 ? String(Math.max(info.unitHeightMeters / 4, 0.001)) : (info.unitHeightMeters < 10 ? '0.1' : '1');
    current.value = String(Math.min(Math.max(Number(current.value), Number(current.min)), Number(current.max)));
    if ($(s.currentHeightValue)) $(s.currentHeightValue).textContent = formatMeters(Number(current.value));
  }

  function updateStatus(info, options) {
    var s = selectors(options && options.selectors);
    var log = options && options.log;
    if (!info) return;
    if ($(s.levelReadout)) $(s.levelReadout).textContent = info.enabled ? 'L' + info.level : '--';
    if ($(s.cellsReadout)) $(s.cellsReadout).textContent = info.enabled ? String(info.cells || 0) : '--';
    if ($(s.heightLayerReadout)) {
      if (Number.isFinite(info.currentHeight) && info.currentLayer) {
        $(s.heightLayerReadout).textContent =
          '单层 ' + formatMeters(info.unitHeightMeters) +
          ' · 堆叠 ' + info.stackCount + ' 层 ' + formatMeters(info.stackMinHeight) + ' - ' + formatMeters(info.stackMaxHeight) +
          ' · 当前层 ' + formatMeters(info.currentLayer.minHeight) + ' - ' + formatMeters(info.currentLayer.maxHeight);
        updateCurrentHeightRange(info, s);
      } else {
        $(s.heightLayerReadout).textContent = '--';
      }
    }
    if (info.message && log) log(info.message);
  }

  function updateSelection(selection, selectorOverrides) {
    var s = selectors(selectorOverrides);
    if (!selection) {
      if ($(s.selected2DReadout)) $(s.selected2DReadout).textContent = '--';
      if ($(s.selected3DReadout)) $(s.selected3DReadout).textContent = '--';
      return;
    }

    if ($(s.selected2DReadout)) $(s.selected2DReadout).textContent = selection.code2D;
    if ($(s.selected3DReadout)) $(s.selected3DReadout).textContent = selection.code3D;
    if ($(s.heightLayerReadout)) {
      $(s.heightLayerReadout).textContent =
        '选中层 ' + formatMeters(selection.heightBounds.minHeight) + ' - ' + formatMeters(selection.heightBounds.maxHeight) +
        ' · 单层 ' + formatMeters(selection.unitHeightMeters) +
        ' · 堆叠 ' + selection.stackCount + ' 层';
    }
  }

  function syncCurrentHeightInput(selectorOverrides) {
    var s = selectors(selectorOverrides);
    var current = $(s.currentHeight);
    if (current && $(s.currentHeightValue)) $(s.currentHeightValue).textContent = formatMeters(Number(current.value));
  }

  function initGrid(options) {
    var s = selectors(options && options.selectors);
    var log = options.log;
    if (!global.GGERAirspaceGrid || !global.GGERGridCode || !global.GGERGridBounds) {
      log('GGER 网格模块未加载，空域分割图层不可用。');
      return null;
    }

    syncCurrentHeightInput(s);
    return global.GGERAirspaceGrid.create(options.viewer, {
      enabled: false,
      verticalEnabled: false,
      sliceEnabled: false,
      labelsEnabled: false,
      anchorHeight: Number($(s.anchorHeight).value),
      stackCount: Number($(s.stackCount).value),
      currentHeight: Number($(s.currentHeight).value),
      maxCells: Number($(s.maxCells).value),
      maxAutoLevel: 23,
      targetCellPixels: 120,
      onStatus: function (info) { updateStatus(info, { selectors: s, log: log }); },
      onSelection: function (selection) { updateSelection(selection, s); }
    });
  }

  function bindControls(options) {
    var s = selectors(options && options.selectors);
    var airspaceGrid = options.airspaceGrid;
    var levelMode = $(s.levelMode);
    var anchorHeight = $(s.anchorHeight);
    var stackCount = $(s.stackCount);
    var currentHeight = $(s.currentHeight);
    var maxCells = $(s.maxCells);

    if (levelMode) {
      levelMode.addEventListener('change', function () {
        if (!airspaceGrid()) return;
        if (levelMode.value === 'auto') {
          airspaceGrid().setAutoLevel(true);
        } else {
          airspaceGrid().setLevel(Number(levelMode.value));
        }
      });
    }

    if (anchorHeight) {
      anchorHeight.addEventListener('change', function () {
        if (airspaceGrid()) airspaceGrid().setAnchorHeight(Number(anchorHeight.value));
      });
    }

    if (stackCount) {
      stackCount.addEventListener('change', function () {
        if (airspaceGrid()) airspaceGrid().setStackCount(Number(stackCount.value));
      });
    }

    if (currentHeight) {
      currentHeight.addEventListener('input', function () {
        syncCurrentHeightInput(s);
        if (airspaceGrid()) airspaceGrid().setCurrentHeight(Number(currentHeight.value));
      });
    }

    if (maxCells) {
      maxCells.addEventListener('change', function () {
        if (airspaceGrid()) airspaceGrid().setMaxCells(Number(maxCells.value));
      });
    }
  }

  global.HuaguoshanAirspaceGridUi = {
    formatMeters: formatMeters,
    updateCurrentHeightRange: updateCurrentHeightRange,
    updateStatus: updateStatus,
    updateSelection: updateSelection,
    syncCurrentHeightInput: syncCurrentHeightInput,
    initGrid: initGrid,
    bindControls: bindControls
  };
})(window);
