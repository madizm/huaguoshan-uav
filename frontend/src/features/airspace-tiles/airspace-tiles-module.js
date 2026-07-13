(function (global) {
  'use strict';

  var MODE_CONFIG = {
    candidateW: { kind: 'candidate', classCode: 'W', label: 'W 候选空域' },
    candidateG: { kind: 'candidate', classCode: 'G', label: 'G 候选空域' },
    suitableW: { kind: 'suitable', classCode: 'W', label: 'W 适飞空域' },
    suitableG: { kind: 'suitable', classCode: 'G', label: 'G 适飞空域' }
  };

  function escapeHtml(value) {
    if (global.HuaguoshanCitydbInspector && global.HuaguoshanCitydbInspector.escapeHtml) {
      return global.HuaguoshanCitydbInspector.escapeHtml(value);
    }
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (char) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' })[char];
    });
  }

  function property(picked, name) {
    if (!picked || typeof picked.getProperty !== 'function') return null;
    try {
      return picked.getProperty(name);
    } catch (error) {
      return null;
    }
  }

  function normalizeMode(mode) {
    return MODE_CONFIG[mode] ? mode : 'candidateW';
  }

  function defaultUrlFor(kind, level) {
    return '../exports/airspace/wg_gger/' + kind + '/level-' + level + '/tileset.json';
  }

  function urlFor(options, kind, level) {
    var configured = options.urls && options.urls[kind] && options.urls[kind][String(level)];
    return configured || defaultUrlFor(kind, level);
  }

  function styleFor(CesiumRuntime, classCode, includeMixed) {
    var showExpression = "${candidate_class} === '" + classCode + "'";
    if (includeMixed) showExpression = "(" + showExpression + ") || (${candidate_class} === 'MIXED')";
    return new CesiumRuntime.Cesium3DTileStyle({
      show: showExpression,
      color: {
        conditions: [
          ["${candidate_class} === 'MIXED'", "color('#a855f7', 0.78)"],
          ["${candidate_class} === 'W'", "color('#22d3ee', 0.82)"],
          ["${candidate_class} === 'G'", "color('#3b82f6', 0.72)"],
          ['true', "color('#94a3b8', 0.5)"]
        ]
      }
    });
  }

  function formatNumber(value, digits) {
    var number = Number(value);
    if (!isFinite(number)) return '--';
    return number.toFixed(digits == null ? 2 : digits);
  }

  function renderPickedHtml(metadata) {
    var title = metadata.tileset_kind === 'suitable' ? '适飞空域 GGER 网格' : '候选空域 GGER 网格';
    var rows = [
      ['GGER 3D 编码', metadata.gger_3d_code],
      ['GGER 2D 编码', metadata.gger_2d_code],
      ['层级', metadata.level ? 'Level ' + metadata.level : null],
      ['图层类型', metadata.tileset_kind],
      ['候选类别', metadata.candidate_class],
      ['适飞状态', metadata.suitability_status === 'SUITABLE' ? '适飞' : '无'],
      ['高度基准', metadata.height_datum || 'AGL'],
      ['AGL 高度范围', formatNumber(metadata.agl_min, 1) + 'm - ' + formatNumber(metadata.agl_max, 1) + 'm'],
      ['绝对高度范围', formatNumber(metadata.bbox_min_h, 2) + 'm - ' + formatNumber(metadata.bbox_max_h, 2) + 'm'],
      ['DEM 高程范围', formatNumber(metadata.dem_min, 2) + 'm - ' + formatNumber(metadata.dem_max, 2) + 'm']
    ];
    return '<div class="feature-card airspace-tile-card">' +
      '<div class="feature-title"><span>' + escapeHtml(title) + '</span><strong>' + escapeHtml(metadata.candidate_class || '--') + '</strong></div>' +
      '<div class="feature-meta">' + rows.map(function (row) {
        return '<div class="feature-meta-row"><span>' + escapeHtml(row[0]) + '</span><code>' + escapeHtml(row[1] == null ? '--' : row[1]) + '</code></div>';
      }).join('') + '</div>' +
      '</div>';
  }

  function readMetadata(picked) {
    var names = [
      'gger_3d_code', 'gger_2d_code', 'level', 'tileset_kind', 'candidate_class',
      'suitability_status', 'height_datum', 'agl_min', 'agl_max', 'bbox_min_h',
      'bbox_max_h', 'dem_min', 'dem_max', 'is_mixed'
    ];
    return names.reduce(function (metadata, name) {
      metadata[name] = property(picked, name);
      return metadata;
    }, {});
  }

  function initLayer(options) {
    var getViewer = options.getViewer;
    var CesiumRuntime = options.CesiumRuntime;
    var log = options.log || function () {};
    var state = {
      enabled: false,
      level: options.defaultLevel || 20,
      mode: 'candidateW',
      includeMixed: true,
      tilesets: {},
      loadPromises: {}
    };

    function cacheKey(kind, level) {
      return kind + ':' + level;
    }

    function activeConfig() {
      return MODE_CONFIG[state.mode];
    }

    function applyVisibility() {
      var config = activeConfig();
      Object.keys(state.tilesets).forEach(function (key) {
        var tileset = state.tilesets[key];
        var parts = key.split(':');
        var visible = state.enabled && parts[0] === config.kind && String(parts[1]) === String(state.level);
        tileset.show = visible;
        if (visible && CesiumRuntime.Cesium3DTileStyle) {
          tileset.style = styleFor(CesiumRuntime, config.classCode, state.includeMixed);
        }
      });
    }

    function loadActiveTileset() {
      var viewer = getViewer();
      var config = activeConfig();
      var key = cacheKey(config.kind, state.level);
      var url;
      if (!state.enabled || !viewer) return Promise.resolve(null);
      if (state.tilesets[key]) {
        applyVisibility();
        return Promise.resolve(state.tilesets[key]);
      }
      if (state.loadPromises[key]) return state.loadPromises[key];
      if (!CesiumRuntime.Cesium3DTileset) {
        log('当前 Cesium 版本不支持 W/G 空域 3D Tiles。');
        return Promise.resolve(null);
      }
      url = urlFor(options, config.kind, state.level);
      log('正在加载 ' + config.label + '：' + url);
      state.loadPromises[key] = global.HuaguoshanTilesetLoader.add3DTileset(CesiumRuntime, viewer, url, {
        tilesetOptions: {
          maximumScreenSpaceError: 2,
          dynamicScreenSpaceError: false,
          show: true
        },
        onAdded: function (tileset) {
          state.tilesets[key] = tileset;
        }
      }).then(function (tileset) {
        if (tileset) {
          tileset._huaguoshanAirspaceTilesKind = config.kind;
          applyVisibility();
          log(config.label + ' 已加载。');
        }
        return tileset;
      }).catch(function (error) {
        console.error('[Tianditu3D] W/G airspace tileset load failed:', error);
        log(config.label + ' 加载失败。请先运行 scripts/export_wg_airspace_3dtiles.py 生成 3D Tiles。');
        return null;
      }).finally(function () {
        delete state.loadPromises[key];
      });
      return state.loadPromises[key];
    }

    function setEnabled(enabled) {
      state.enabled = Boolean(enabled);
      applyVisibility();
      if (state.enabled) loadActiveTileset();
    }

    function setMode(mode) {
      state.mode = normalizeMode(mode);
      applyVisibility();
      if (state.enabled) loadActiveTileset();
    }

    function setLevel(level) {
      var parsed = parseInt(level, 10);
      if (!isFinite(parsed) || parsed < 1 || parsed > 32) return;
      state.level = parsed;
      applyVisibility();
      if (state.enabled) loadActiveTileset();
    }

    function setIncludeMixed(includeMixed) {
      state.includeMixed = Boolean(includeMixed);
      applyVisibility();
    }

    function isPickedFeature(picked) {
      var pickedTileset = picked && (picked.tileset || (picked.content && picked.content.tileset));
      if (!picked || typeof picked.getProperty !== 'function') return false;
      if (property(picked, 'gger_3d_code') == null) return false;
      return Object.keys(state.tilesets).some(function (key) { return state.tilesets[key] === pickedTileset; }) || property(picked, 'tileset_kind') != null;
    }

    function selectPickedFeature(picked) {
      var metadata = readMetadata(picked);
      if (options.showPanel) options.showPanel(renderPickedHtml(metadata));
      log('已选中空域 GGER 网格：' + (metadata.gger_3d_code || '--'));
    }

    return {
      setEnabled: setEnabled,
      setMode: setMode,
      setLevel: setLevel,
      setIncludeMixed: setIncludeMixed,
      isPickedFeature: isPickedFeature,
      selectPickedFeature: selectPickedFeature,
      state: state
    };
  }

  function bindControls(options) {
    var layer = options.layer;
    var modeSelect = document.querySelector('#airspaceTilesMode');
    var levelSelect = document.querySelector('#airspaceTilesLevel');
    var mixedInput = document.querySelector('#airspaceTilesMixed');
    if (modeSelect) modeSelect.addEventListener('change', function () {
      if (layer()) layer().setMode(modeSelect.value);
    });
    if (levelSelect) levelSelect.addEventListener('change', function () {
      if (layer()) layer().setLevel(levelSelect.value);
    });
    if (mixedInput) mixedInput.addEventListener('change', function () {
      if (layer()) layer().setIncludeMixed(mixedInput.checked);
    });
  }

  global.HuaguoshanAirspaceTiles = {
    initLayer: initLayer,
    bindControls: bindControls,
    styleFor: styleFor,
    renderPickedHtml: renderPickedHtml
  };
})(window);
