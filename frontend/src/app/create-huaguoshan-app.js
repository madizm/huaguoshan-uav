    (function () {
      'use strict';

      var runtimeConfig = window.HuaguoshanRuntimeConfig || {};
      var tiandituConfig = runtimeConfig.tianditu || {};
      var tilesetConfig = runtimeConfig.tilesets || {};
      var postgrestConfig = runtimeConfig.postgrest || {};
      var authConfig = runtimeConfig.auth || {};
      var token = tiandituConfig.token || '2444f36b636d8eebf4c30ac7bc6c9347';
      var tdtUrl = tiandituConfig.url || 'https://t{s}.tianditu.gov.cn/';
      var subdomains = tiandituConfig.subdomains || ['0', '1', '2', '3', '4', '5', '6', '7'];
      var localTilesetUrl = tilesetConfig.citydb || '../exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json';
      var lianyungangBuildingsTilesetUrl = tilesetConfig.lianyungangBuildings || '../exports/citydb-3dtiler/lianyungang_buildings_3dtiles/tileset.json';
      var demTilesetUrl = tilesetConfig.huaguoshanDem || '../exports/terrain/huaguoshan_dem_3dtiles/tileset.json';
      var lianyungangDemTilesetUrl = tilesetConfig.lianyungangDem || '../exports/terrain/lianyungang_dem_3dtiles/tileset.json';
      var airspaceProfile = postgrestConfig.airspaceProfile || 'api';
      var postgrestJwtStorageKey = postgrestConfig.jwtStorageKey || 'postgrest.jwt';
      var airspaceTableByKind = postgrestConfig.airspaceTableByKind || {
        no_fly_zone: 'no_fly_zone',
        temp_control: 'temp_control_zone'
      };
      var postgrestClient = window.HuaguoshanPostgrest.createPostgrestClient({
        baseUrl: postgrestConfig.baseUrl || '/postgrest',
        storageKey: postgrestJwtStorageKey
      });
      var authClient = window.HuaguoshanPostgrest.createAuthClient({
        loginUrl: authConfig.loginUrl || '/auth/login',
        meUrl: authConfig.meUrl || '/auth/me',
        storageKey: postgrestJwtStorageKey
      });
      var gridLayerColors = runtimeConfig.gridLayerColors || ['#5eead4', '#f6c85f', '#ff8f5f', '#8bd17c', '#80b7ff', '#c084fc', '#f472b6', '#67e8f9', '#facc15', '#a3e635'];
      var huaguoshan = runtimeConfig.huaguoshan || { lon: 119.2683, lat: 34.6469 };
      var state = {
        viewer: null,
        imageLayer: null,
        boundaryLayer: null,
        terrainProvider: null,
        buildingsTileset: null,
        buildingsReady: false,
        lianyungangBuildingsTileset: null,
        lianyungangBuildingsReady: false,
        lianyungangBuildingsLoadPromise: null,
        demTileset: null,
        demReady: false,
        demVisible: false,
        lianyungangDemTileset: null,
        lianyungangDemReady: false,
        lianyungangDemVisible: false,
        wtfs: null,
        wtfsVisible: true,
        airspaceGrid: null,
        airspaceEnabled: false,
        featurePropertyCache: {},
        featureGridCache: {},
        selectedGridPrimitive: null,
        selectedGridBounds: null,
        selectedGridCells: [],
        flightObstacleLayer: null,
        airspaceConstraintEditor: null,
        flightPathWorkbench: null
      };

      var $ = function (selector) { return document.querySelector(selector); };
      var authSelectors = {
        loginButton: '#authLoginBtn',
        logoutButton: '#authLogoutBtn',
        status: '#authStatus',
        username: '#authUsername',
        password: '#authPassword'
      };

      var log = window.HuaguoshanHud.createStatusLogger('#status');

      function escapeHtml(value) {
        return window.HuaguoshanCitydbInspector.escapeHtml(value);
      }

      function featurePanel() {
        return window.HuaguoshanCitydbInspector.featurePanel('#featureProperties');
      }

      function showFeaturePanel() {
        window.HuaguoshanCitydbInspector.showPanel('.feature-panel');
      }

      function hideFeaturePanel() {
        window.HuaguoshanCitydbInspector.hidePanel('.feature-panel');
      }

      function formatPropertyValue(value, uom) {
        return window.HuaguoshanCitydbInspector.formatPropertyValue(value, uom);
      }

      function parseJsonText(value) {
        return window.HuaguoshanGridGeometry.parseJsonText(value);
      }

      function parseBboxText(bboxText) {
        return window.HuaguoshanGridGeometry.parseBboxText(bboxText);
      }

      function extractGridCells(gridData) {
        return window.HuaguoshanGridGeometry.extractGridCells(gridData);
      }

      function getGridLayerColor(layerIndex) {
        return window.HuaguoshanGridGeometry.gridLayerColor(gridLayerColors, layerIndex);
      }

      function gridLayerKey(cell) {
        return cell.minHeight.toFixed(3) + ':' + cell.maxHeight.toFixed(3);
      }

      function sortedGridLayers(cells) {
        return window.HuaguoshanGridGeometry.sortedGridLayers(cells);
      }

      function gridLayerIndex(cell, layers) {
        return window.HuaguoshanGridGeometry.gridLayerIndex(cell, layers);
      }

      function gridLayerMaterial(CesiumRuntime, cache, layerIndex, alpha) {
        return window.HuaguoshanGridGeometry.gridLayerMaterial(CesiumRuntime, cache, layerIndex, alpha, gridLayerColors);
      }

      function clearSelectedGridHighlight() {
        if (state.selectedGridPrimitive && state.viewer) {
          try {
            state.viewer.scene.primitives.remove(state.selectedGridPrimitive);
          } catch (error) {
            console.warn('[Tianditu3D] Failed to remove selected grid primitive:', error);
          }
        }
        state.selectedGridPrimitive = null;
        state.selectedGridBounds = null;
        state.selectedGridCells = [];
      }

      function makeEdgeKey(a, b) {
        return window.HuaguoshanGridGeometry.makeEdgeKey(a, b);
      }

      function addBoxEdge(edges, lon1, lat1, h1, lon2, lat2, h2, layerIndex) {
        return window.HuaguoshanGridGeometry.addBoxEdge(edges, lon1, lat1, h1, lon2, lat2, h2, layerIndex);
      }

      function addBoxEdges(edges, cell, layerIndex) {
        return window.HuaguoshanGridGeometry.addBoxEdges(edges, cell, layerIndex);
      }

      function showSelectedGridHighlight(gridData) {
        var highlight;
        clearSelectedGridHighlight();
        highlight = window.HuaguoshanGridGeometry.createGridHighlight(window.Cesium, state.viewer, gridData, gridLayerColors);
        if (!highlight) return;
        state.selectedGridPrimitive = highlight.primitive;
        state.selectedGridBounds = highlight.bounds;
        state.selectedGridCells = highlight.cells;
      }

      function cellsBounds(cells) {
        return window.HuaguoshanGridGeometry.cellsBounds(cells);
      }

      function mergeBounds(boundsList) {
        return window.HuaguoshanGridGeometry.mergeBounds(boundsList);
      }

      function airspaceTable(kind) {
        return airspaceTableByKind[kind] || airspaceTableByKind.no_fly_zone;
      }

      function airspaceRequest(kind, pathSuffix, options) {
        var table = airspaceTable(kind);
        var requestOptions = Object.assign({}, options || {});
        return postgrestClient.request('/' + table + (pathSuffix || ''), Object.assign(requestOptions, {
          profile: airspaceProfile,
          errorLabel: 'PostgREST airspace ' + (requestOptions.method || 'GET')
        }));
      }

      function postgrestRpc(name, payload) {
        return postgrestClient.rpc(name, payload);
      }

      function flyToSelectedGridHighlight() {
        window.HuaguoshanCitydbInspector.flyToSelectedGridHighlight(Cesium, state.viewer, state.selectedGridBounds, log);
      }

      function renderFeatureMessage(className, message) {
        window.HuaguoshanCitydbInspector.renderFeatureMessage({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, className, message);
      }

      function renderFeatureLoading(identifier, metadata) {
        window.HuaguoshanCitydbInspector.renderFeatureLoading({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, identifier, metadata);
      }

      function renderFeatureError(message) {
        window.HuaguoshanCitydbInspector.renderFeatureError({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, message);
      }

      function renderGridCard(gridData) {
        return window.HuaguoshanCitydbInspector.renderGridCard(gridData, extractGridCells);
      }

      function renderFeatureProperties(data, sourceIdentifier, gridData) {
        window.HuaguoshanCitydbInspector.renderFeatureProperties({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, data, sourceIdentifier, gridData, extractGridCells);
      }

      function getPickedPropertyIds(picked) {
        return window.HuaguoshanCitydbInspector.getPickedPropertyIds(picked);
      }

      function getPickedProperty(picked, name) {
        return window.HuaguoshanCitydbInspector.getPickedProperty(picked, name);
      }

      function readPickedMetadata(picked) {
        return window.HuaguoshanCitydbInspector.readPickedMetadata(picked);
      }

      function metadataValue(metadata, names) {
        return window.HuaguoshanCitydbInspector.metadataValue(metadata, names);
      }

      function getPickedIdentifiers(metadata) {
        return window.HuaguoshanCitydbInspector.getPickedIdentifiers(metadata);
      }

      function isPickedCitydbFeature(picked) {
        return window.HuaguoshanCitydbInspector.isPickedCitydbFeature(picked, state.buildingsTileset);
      }

      function requestCitydbFeature(identifiers, index) {
        var identifier = identifiers[index];
        if (!identifier) return Promise.resolve(null);
        if (state.featurePropertyCache[identifier]) return Promise.resolve(state.featurePropertyCache[identifier]);

        return postgrestRpc('get_citydb_feature_properties', {
          p_feature_identifier: identifier
        }).then(function (data) {
          if (data && data.feature) {
            state.featurePropertyCache[identifier] = data;
            return data;
          }
          if (index + 1 < identifiers.length) return requestCitydbFeature(identifiers, index + 1);
          return null;
        });
      }

      function requestCitydbGrid(identifiers, index) {
        var identifier = identifiers[index];
        if (!identifier) return Promise.resolve(null);
        if (state.featureGridCache[identifier]) return Promise.resolve(state.featureGridCache[identifier]);

        return postgrestRpc('get_citydb_feature_gger_grids', {
          p_feature_identifier: identifier
        }).then(function (data) {
          if (data && data.feature) {
            state.featureGridCache[identifier] = data;
            return data;
          }
          if (index + 1 < identifiers.length) return requestCitydbGrid(identifiers, index + 1);
          return null;
        });
      }

      function bindFeaturePicking(viewer) {
        window.HuaguoshanCitydbInspector.bindFeaturePicking({
          CesiumRuntime: Cesium,
          viewer: viewer,
          buildingsTileset: function () {
            return [state.buildingsTileset, state.lianyungangBuildingsTileset].filter(Boolean);
          },
          airspaceConstraintEditor: state.airspaceConstraintEditor,
          flightPathWorkbench: state.flightPathWorkbench,
          flightObstacleLayer: state.flightObstacleLayer,
          requestCitydbFeature: requestCitydbFeature,
          requestCitydbGrid: requestCitydbGrid,
          renderFeatureLoading: renderFeatureLoading,
          renderFeatureError: renderFeatureError,
          renderFeatureProperties: renderFeatureProperties,
          clearSelectedGridHighlight: clearSelectedGridHighlight,
          showSelectedGridHighlight: showSelectedGridHighlight,
          log: log
        });
      }

      function updateCameraReadout() {
        window.HuaguoshanHud.updateCameraReadout(Cesium, state.viewer, {
          lon: '#lon',
          lat: '#lat',
          alt: '#alt'
        });
      }

      function configureScene(viewer) {
        window.HuaguoshanCesiumMap.configureScene(Cesium, viewer);
      }

      function addImagery(viewer) {
        var layers = window.HuaguoshanCesiumMap.addImagery(Cesium, viewer, {
          tdtUrl: tdtUrl,
          token: token,
          subdomains: subdomains
        });
        state.imageLayer = layers.imageLayer;
        state.boundaryLayer = layers.boundaryLayer;
      }

      function addTerrain(viewer) {
        state.terrainProvider = window.HuaguoshanCesiumMap.addTerrain(Cesium, viewer, {
          tdtUrl: tdtUrl,
          token: token,
          subdomains: subdomains
        });
      }

      function addPlaceNames(viewer) {
        state.wtfs = window.HuaguoshanCesiumMap.addPlaceNames(Cesium, viewer, {
          tdtUrl: tdtUrl,
          token: token,
          subdomains: subdomains
        });
      }

      function addHuaguoshanMarker(viewer) {
        window.HuaguoshanCesiumMap.addHuaguoshanMarker(Cesium, viewer, huaguoshan);
      }

      function formatMeters(value, digits) {
        return window.HuaguoshanAirspaceGridUi.formatMeters(value, digits);
      }

      function initAirspaceGrid(viewer) {
        state.airspaceGrid = window.HuaguoshanAirspaceGridUi.initGrid({
          viewer: viewer,
          log: log
        });
      }

      function initFlightObstacleLayer() {
        state.flightObstacleLayer = window.HuaguoshanFlightObstacles.initLayer({
          getViewer: function () { return state.viewer; },
          huaguoshan: huaguoshan,
          log: log,
          renderError: renderFeatureError,
          showPanel: function (html) {
            showFeaturePanel();
            featurePanel().innerHTML = html;
          },
          rpc: postgrestRpc,
          helpers: {
            extractGridCells: extractGridCells,
            cellsBounds: cellsBounds,
            sortedGridLayers: sortedGridLayers,
            addBoxEdges: addBoxEdges,
            gridLayerIndex: gridLayerIndex,
            gridLayerMaterial: gridLayerMaterial,
            mergeBounds: mergeBounds
          }
        });
      }

      function bindAirspaceControls() {
        window.HuaguoshanAirspaceGridUi.bindControls({
          airspaceGrid: function () { return state.airspaceGrid; }
        });
      }

      function bindObstacleControls() {
        window.HuaguoshanFlightObstacles.bindControls({
          layer: function () { return state.flightObstacleLayer; }
        });
      }

      function bindAirspaceAdminControls() {
        state.airspaceConstraintEditor = window.HuaguoshanAirspaceConstraints.initEditor({
          containerSelector: '#airspaceConstraintEditor',
          request: airspaceRequest,
          getViewer: function () { return state.viewer; },
          getCesium: function () { return window.Cesium; },
          log: log,
          confirm: function (message) { return Promise.resolve(window.confirm(message)); },
          onChanged: function () {
            if (state.flightObstacleLayer) {
              state.flightObstacleLayer.invalidate();
              if (state.flightObstacleLayer.isEnabled()) state.flightObstacleLayer.refresh(true);
            }
          },
          renderError: renderFeatureError,
          zoomToPoints: function (points, message) {
            if (!state.flightObstacleLayer) return;
            state.flightObstacleLayer.zoomToBounds(cellsBounds(points.map(function (point) {
              return { minLon: point.lon, maxLon: point.lon, minLat: point.lat, maxLat: point.lat, minHeight: 0, maxHeight: 0 };
            })), message);
          }
        });
      }


      function bindFlightPathControls() {
        state.flightPathWorkbench = window.HuaguoshanFlightPath.initWorkbench({
          containerSelector: '#flightPathWorkbench',
          rpc: postgrestRpc,
          log: log,
          renderError: renderFeatureError,
          getCesium: function () { return window.Cesium; },
          getViewer: function () { return state.viewer; },
          helpers: {
            parseBboxText: parseBboxText,
            extractGridCells: extractGridCells,
            cellsBounds: cellsBounds,
            sortedGridLayers: sortedGridLayers,
            addBoxEdges: addBoxEdges,
            gridLayerIndex: gridLayerIndex,
            gridLayerMaterial: gridLayerMaterial,
            formatMeters: formatMeters
          }
        });
      }

      function scheduleTerrainLodRefresh() {
        if (state.flightObstacleLayer) state.flightObstacleLayer.scheduleTerrainLodRefresh();
      }

      function bindTerrainLodCameraRefresh(viewer) {
        if (!viewer || !viewer.camera || !viewer.camera.moveEnd) return;
        viewer.camera.moveEnd.addEventListener(scheduleTerrainLodRefresh);
      }

      function loadLianyungangBuildings() {
        var button = $('#loadLianyungangBuildingsBtn');
        if (state.lianyungangBuildingsReady) {
          window.HuaguoshanTilesets.flyToLianyungangBuildings(Cesium, state, log);
          return Promise.resolve(state.lianyungangBuildingsTileset);
        }
        if (state.lianyungangBuildingsLoadPromise) return state.lianyungangBuildingsLoadPromise;

        if (button) {
          button.disabled = true;
          button.textContent = '正在加载全市建筑…';
        }
        state.lianyungangBuildingsLoadPromise = window.HuaguoshanTilesets.addLianyungangBuildings(
          Cesium, state.viewer, state, lianyungangBuildingsTilesetUrl, log
        ).then(function (tileset) {
          if (tileset) {
            if (button) button.textContent = '查看连云港全市建筑';
            window.HuaguoshanTilesets.flyToLianyungangBuildings(Cesium, state, log);
          } else if (button) {
            button.textContent = '重试加载全市建筑';
          }
          return tileset;
        }).finally(function () {
          state.lianyungangBuildingsLoadPromise = null;
          if (button) button.disabled = false;
        });
        return state.lianyungangBuildingsLoadPromise;
      }

      function addLocalTileset(viewer) {
        return window.HuaguoshanTilesets.addCitydbBuildings(Cesium, viewer, state, localTilesetUrl, log);
      }

      function addDemTileset(viewer) {
        return window.HuaguoshanTilesets.addDem(Cesium, viewer, state, demTilesetUrl, log);
      }

      function addLianyungangDemTileset(viewer) {
        return window.HuaguoshanTilesets.addLianyungangDem(Cesium, viewer, state, lianyungangDemTilesetUrl, log);
      }

      function flyToTileset() {
        window.HuaguoshanTilesets.flyToTileset(Cesium, state, huaguoshan, log);
      }

      function flyToDem() {
        window.HuaguoshanTilesets.flyToDem(Cesium, state, huaguoshan, log);
      }

      function flyToLianyungangDem() {
        window.HuaguoshanTilesets.flyToLianyungangDem(Cesium, state, log);
      }

      function flyToHuaguoshan() {
        window.HuaguoshanCamera.flyToHuaguoshan(Cesium, state.viewer, huaguoshan);
      }

      function bindControls() {
        window.HuaguoshanLayerActions.bindControls({
          state: state,
          CesiumRuntime: Cesium,
          huaguoshan: huaguoshan,
          log: log,
          hideFeaturePanel: hideFeaturePanel,
          clearSelectedGridHighlight: clearSelectedGridHighlight,
          flyToHuaguoshan: flyToHuaguoshan,
          flyToTileset: flyToTileset,
          loadLianyungangBuildings: loadLianyungangBuildings,
          flyToDem: flyToDem,
          flyToLianyungangDem: flyToLianyungangDem,
          flyToSelectedGridHighlight: flyToSelectedGridHighlight
        });
      }

      function init() {
        if (!window.Cesium || typeof Cesium.Map !== 'function') {
          log('初始化失败：未加载 Cesium 或天地图 Cesium 扩展。请检查网络与 CDN 访问。');
          return;
        }

        state.viewer = window.HuaguoshanCesiumMap.createViewer(Cesium, 'cesiumContainer');

        configureScene(state.viewer);
        addImagery(state.viewer);
        addTerrain(state.viewer);
        addPlaceNames(state.viewer);
        addHuaguoshanMarker(state.viewer);
        initAirspaceGrid(state.viewer);
        initFlightObstacleLayer();
        addLocalTileset(state.viewer);
        addDemTileset(state.viewer);
        addLianyungangDemTileset(state.viewer);
        bindControls();
        bindAirspaceControls();
        bindAirspaceAdminControls();
        bindFlightPathControls();
        bindObstacleControls();
        bindTerrainLodCameraRefresh(state.viewer);
        bindFeaturePicking(state.viewer);

        state.viewer.scene.postRender.addEventListener(updateCameraReadout);
        flyToHuaguoshan();
        log('天地图影像、国界、三维地形、三维地名、本地 3D Tiles 与 DEM 网格正在初始化。右键/滚轮缩放，中键或 Ctrl+拖拽倾斜视角。');
      }

      // ── Auth init ───────────────────────────────────────────────

      function initAuth() {
        window.HuaguoshanHud.initAuth({
          authClient: authClient,
          log: log,
          selectors: authSelectors
        });
      }

      // Call auth init after the main init.
      initAuth();

      window.addEventListener('error', function (event) {
        log('运行异常：' + event.message);
      });

      window.addEventListener('unhandledrejection', function (event) {
        // 天地图 GeoTerrainProvider 在部分浏览器会先探测 GetCapabilities，
        // 探测失败后仍会继续请求地形瓦片；避免把可恢复的内部 Promise 噪声暴露给用户。
        console.warn('[Tianditu3D] Cesium provider promise rejected:', event.reason);
        event.preventDefault();
      });

      init();
    })();
