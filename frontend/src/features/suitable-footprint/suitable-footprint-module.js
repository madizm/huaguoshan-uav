(function (global) {
  'use strict';

  var LAYER_CONFIG = {
    footprint: {
      label: '适飞基底',
      clampToGround: true,
      color: '#facc15',
      alpha: 0.14,
      outlineAlpha: 0.9
    },
    wAirspace: {
      label: 'W 适飞空域',
      clampToGround: false,
      color: '#22d3ee',
      alpha: 0.22,
      outlineAlpha: 0.78,
      aglMin: 0,
      aglMax: 120
    },
    gAirspace: {
      label: 'G 适飞空域',
      clampToGround: false,
      color: '#3b82f6',
      alpha: 0.16,
      outlineAlpha: 0.64,
      aglMin: 120,
      aglMax: 300
    }
  };

  function requestFootprints(request, profile, resourceName) {
    return request('/' + (resourceName || 'suitable_fly_zone_footprints') + '?select=id,name,geom', {
      profile: profile || 'api',
      headers: { Accept: 'application/geo+json' },
      errorLabel: 'PostGREST suitable-footprint GeoJSON'
    });
  }

  function featureCount(geojson) {
    return geojson && Array.isArray(geojson.features) ? geojson.features.length : 0;
  }

  function airspaceBand(layerName) {
    var config = LAYER_CONFIG[layerName];
    if (!config || config.aglMin == null || config.aglMax == null) return null;
    return { aglMin: config.aglMin, aglMax: config.aglMax };
  }

  function applyEntityStyle(CesiumRuntime, dataSource, layerName) {
    var config = LAYER_CONFIG[layerName] || LAYER_CONFIG.footprint;
    var entities = dataSource && dataSource.entities && dataSource.entities.values || [];
    var relativeToGround = CesiumRuntime.HeightReference && CesiumRuntime.HeightReference.RELATIVE_TO_GROUND;
    entities.forEach(function (entity) {
      if (!entity.polygon) return;
      entity.polygon.material = CesiumRuntime.Color.fromCssColorString(config.color).withAlpha(config.alpha);
      entity.polygon.outline = true;
      entity.polygon.outlineColor = CesiumRuntime.Color.fromCssColorString(config.color).withAlpha(config.outlineAlpha);
      entity.polygon.outlineWidth = 2;
      if (config.aglMin != null && config.aglMax != null) {
        // Cesium polygon extrusion uses `height` as the upper surface and
        // `extrudedHeight` as the lower surface. With RELATIVE_TO_GROUND this
        // renders W/G bands directly from the frontend using the terrain/DEM
        // visible in the scene: W=[0,120)m AGL, G=[120,300]m AGL.
        entity.polygon.height = config.aglMax;
        entity.polygon.extrudedHeight = config.aglMin;
        if (relativeToGround) {
          entity.polygon.heightReference = relativeToGround;
          entity.polygon.extrudedHeightReference = relativeToGround;
        }
        entity.polygon.closeTop = true;
        entity.polygon.closeBottom = true;
      } else if (CesiumRuntime.ClassificationType) {
        entity.polygon.classificationType = CesiumRuntime.ClassificationType.TERRAIN;
      }
      if (entity.properties && entity.properties.name) {
        entity.name = entity.properties.name.getValue ? entity.properties.name.getValue() : entity.properties.name;
      }
    });
  }

  function initLayer(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var getViewer = options.getViewer;
    var request = options.request;
    var log = options.log || function () {};
    var state = {
      geojson: null,
      geojsonPromise: null,
      enabledByLayer: { footprint: false, wAirspace: false, gAirspace: false },
      dataSources: {},
      loadPromises: {}
    };

    function ensureGeojson() {
      if (state.geojson) return Promise.resolve(state.geojson);
      if (state.geojsonPromise) return state.geojsonPromise;
      log('正在请求适飞基底 GeoJSON（Accept: application/geo+json）。');
      state.geojsonPromise = requestFootprints(request, options.profile, options.resourceName).then(function (geojson) {
        state.geojson = geojson;
        log('适飞基底 GeoJSON 已返回：' + featureCount(geojson) + ' 个 MultiPolygon。');
        return geojson;
      }).finally(function () {
        state.geojsonPromise = null;
      });
      return state.geojsonPromise;
    }

    function setDataSourceVisible(layerName, visible) {
      if (state.dataSources[layerName]) state.dataSources[layerName].show = Boolean(visible);
    }

    function loadLayer(layerName) {
      var viewer = getViewer();
      var config = LAYER_CONFIG[layerName];
      if (!config || !viewer || !state.enabledByLayer[layerName]) return Promise.resolve(null);
      if (state.dataSources[layerName]) {
        setDataSourceVisible(layerName, true);
        return Promise.resolve(state.dataSources[layerName]);
      }
      if (state.loadPromises[layerName]) return state.loadPromises[layerName];

      state.loadPromises[layerName] = ensureGeojson().then(function (geojson) {
        return CesiumRuntime.GeoJsonDataSource.load(geojson, {
          clampToGround: config.clampToGround,
          stroke: CesiumRuntime.Color.fromCssColorString(config.color),
          fill: CesiumRuntime.Color.fromCssColorString(config.color).withAlpha(config.alpha),
          strokeWidth: 2
        });
      }).then(function (dataSource) {
        state.dataSources[layerName] = dataSource;
        applyEntityStyle(CesiumRuntime, dataSource, layerName);
        dataSource.show = state.enabledByLayer[layerName];
        viewer.dataSources.add(dataSource);
        log(config.label + '已加载。');
        return dataSource;
      }).catch(function (error) {
        console.error('[Tianditu3D] Suitable footprint layer load failed:', error);
        log(config.label + '加载失败。请确认 PostgREST api.suitable_fly_zone_footprints 可访问。');
        return null;
      }).finally(function () {
        delete state.loadPromises[layerName];
      });
      return state.loadPromises[layerName];
    }

    function setLayerEnabled(layerName, enabled) {
      if (!LAYER_CONFIG[layerName]) return;
      state.enabledByLayer[layerName] = Boolean(enabled);
      setDataSourceVisible(layerName, enabled);
      if (enabled) loadLayer(layerName);
    }

    function setEnabled(enabled) {
      setLayerEnabled('footprint', enabled);
    }

    return {
      setEnabled: setEnabled,
      setLayerEnabled: setLayerEnabled,
      load: function () { return loadLayer('footprint'); },
      airspaceBand: airspaceBand,
      state: state
    };
  }

  global.HuaguoshanSuitableFootprint = {
    requestFootprints: requestFootprints,
    initLayer: initLayer,
    airspaceBand: airspaceBand,
    _private: {
      LAYER_CONFIG: LAYER_CONFIG,
      applyEntityStyle: applyEntityStyle
    }
  };
})(typeof window !== 'undefined' ? window : globalThis);
