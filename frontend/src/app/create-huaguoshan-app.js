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
      var tiandituWhitemodelTilesetUrl = tilesetConfig.tiandituWhitemodel || '../exports/tianditu-bld-3dtiles/tileset.json';
      var demTilesetUrl = tilesetConfig.huaguoshanDem || '../exports/terrain/huaguoshan_dem_3dtiles/tileset.json';
      var lianyungangDemTilesetUrl = tilesetConfig.lianyungangDem || '../exports/terrain/lianyungang_dem_3dtiles/tileset.json';
      var airspaceWgTilesetUrls = tilesetConfig.airspaceWg || {};
      var airspaceProfile = postgrestConfig.airspaceProfile || 'api';
      var suitableFootprintResource = postgrestConfig.suitableFootprintResource || 'suitable_fly_zone_footprints';
      var postgrestJwtStorageKey = postgrestConfig.jwtStorageKey || 'postgrest.jwt';
      var airspaceTableByKind = postgrestConfig.airspaceTableByKind || {
        no_fly_zone: 'no_fly_zone',
        temp_control: 'temp_control_zone'
      };
      var postgrestClient = window.HuaguoshanPostgrest.createPostgrestClient({
        baseUrl: postgrestConfig.baseUrl || '../postgrest',
        storageKey: postgrestJwtStorageKey
      });
      var authClient = window.HuaguoshanPostgrest.createAuthClient({
        loginUrl: authConfig.loginUrl || '../auth/login',
        meUrl: authConfig.meUrl || '../auth/me',
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
        tiandituWhitemodelTileset: null,
        tiandituWhitemodelReady: false,
        tiandituWhitemodelLoadPromise: null,
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
        airspaceTilesLayer: null,
        suitableFootprintLayer: null,
        sourceSituation: null,
        airspaceEnabled: false,
        featurePropertyCache: {},
        featureGridCache: {},
        selectedGridPrimitive: null,
        selectedGridBounds: null,
        selectedGridCells: [],
        flightObstacleLayer: null,
        airspaceConstraintEditor: null,
        flightPathWorkbench: null,
        convexHullAnalysis: null
      };

      var $ = function (selector) { return document.querySelector(selector); };
      var authSelectors = {
        loginButton: '#authLoginBtn',
        logoutButton: '#authLogoutBtn',
        status: '#authStatus',
        username: '#authUsername',
        password: '#authPassword'
      };

      var statusCenter = window.HuaguoshanHud.createStatusCenter({
        currentSelector: '#status',
        historySelector: '#statusHistory',
        maxItems: 5
      });
      var log = statusCenter.log;
      var panelRouter = window.HuaguoshanPanelRouter.createPanelRouter({
        panelSelector: '.feature-panel',
        contentSelector: '#featureProperties',
        ownerSelector: '#featurePanelOwner',
        backSelector: '#featurePanelBack'
      });

      var gridHelpers = window.HuaguoshanGridGeometry.createGridHelpers(gridLayerColors);

      function hideFeaturePanel() {
        panelRouter.close();
      }

      function panelShow(ownerId, label) {
        return function (html) {
          panelRouter.show(ownerId, label, html);
        };
      }

      function panelError(ownerId, label) {
        return function (message) {
          window.HuaguoshanCitydbInspector.renderFeatureError({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, message);
          panelRouter.capture(ownerId, label);
        };
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

      function showSelectedGridHighlight(gridData) {
        var highlight;
        clearSelectedGridHighlight();
        highlight = window.HuaguoshanGridGeometry.createGridHighlight(window.Cesium, state.viewer, gridData, gridLayerColors);
        if (!highlight) return;
        state.selectedGridPrimitive = highlight.primitive;
        state.selectedGridBounds = highlight.bounds;
        state.selectedGridCells = highlight.cells;
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
        panelRouter.capture('citydb', '建筑属性');
      }

      function renderFeatureLoading(identifier, metadata) {
        window.HuaguoshanCitydbInspector.renderFeatureLoading({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, identifier, metadata);
        panelRouter.capture('citydb', '建筑属性');
      }

      function renderFeatureError(message) {
        window.HuaguoshanCitydbInspector.renderFeatureError({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, message);
        panelRouter.capture('citydb', '建筑属性');
      }

      function renderFeatureProperties(data, sourceIdentifier, gridData) {
        window.HuaguoshanCitydbInspector.renderFeatureProperties({ panelSelector: '.feature-panel', contentSelector: '#featureProperties' }, data, sourceIdentifier, gridData, gridHelpers.extractGridCells);
        panelRouter.capture('citydb', '建筑属性');
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
          airspaceTilesLayer: state.airspaceTilesLayer,
          convexHullAnalysis: state.convexHullAnalysis,
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


      function initAirspaceGrid(viewer) {
        state.airspaceGrid = window.HuaguoshanAirspaceGridUi.initGrid({
          viewer: viewer,
          log: log
        });
      }
      function initAirspaceTilesLayer() {
        state.airspaceTilesLayer = window.HuaguoshanAirspaceTiles.initLayer({
          getViewer: function () { return state.viewer; },
          CesiumRuntime: Cesium,
          urls: airspaceWgTilesetUrls,
          defaultLevel: 20,
          log: log,
          showPanel: panelShow('airspace-tiles', 'W/G 空域体素')
        });
      }
      function initSuitableFootprintLayer() {
        state.suitableFootprintLayer = window.HuaguoshanSuitableFootprint.initLayer({
          getViewer: function () { return state.viewer; },
          CesiumRuntime: Cesium,
          request: postgrestClient.request,
          profile: airspaceProfile,
          resourceName: suitableFootprintResource,
          log: log
        });
      }

      function featureCatalogUrl(tilesetUrl) {
        return new URL('analysis/feature-catalog.json', new URL(tilesetUrl, document.baseURI)).href;
      }

      function initSourceSituation() {
        if (!window.HuaguoshanSourceSituation) {
          log('源数据校验模块未加载。', 'error');
          return;
        }
        state.sourceSituation = window.HuaguoshanSourceSituation.createModule({
          CesiumRuntime: Cesium,
          viewer: state.viewer,
          rpc: postgrestRpc,
          log: log
        });
      }

      function initConvexHullAnalysis() {
        state.convexHullAnalysis = window.HuaguoshanConvexHull.createModule({
          CesiumRuntime: Cesium,
          viewer: state.viewer,
          sources: function () {
            return [
              {
                name: '花果山建筑',
                tileset: state.buildingsTileset,
                tilesetUrl: localTilesetUrl,
                catalogUrl: featureCatalogUrl(localTilesetUrl)
              },
              {
                name: '连云港全市建筑',
                tileset: state.lianyungangBuildingsTileset,
                tilesetUrl: lianyungangBuildingsTilesetUrl,
                catalogUrl: featureCatalogUrl(lianyungangBuildingsTilesetUrl)
              }
            ].filter(function (source) { return Boolean(source.tileset); });
          },
          readPickedMetadata: window.HuaguoshanCitydbInspector.readPickedMetadata,
          getPickedIdentifiers: window.HuaguoshanCitydbInspector.getPickedIdentifiers,
          toGeographicPosition: function (x, y, z) {
            var cartographic = Cesium.Cartographic.fromCartesian(new Cesium.Cartesian3(x, y, z));
            return [
              Cesium.Math.toDegrees(cartographic.longitude),
              Cesium.Math.toDegrees(cartographic.latitude),
              cartographic.height
            ];
          },
          requestGrid: function (payload) {
            return postgrestRpc('grid_convex_hull_3d', payload);
          },
          renderGrid: function (grid) {
            showSelectedGridHighlight({ grid: grid });
          },
          clearGrid: clearSelectedGridHighlight,
          setStatus: function (message, status) {
            if (status === 'error') log(message);
          }
        });
      }

      function initFlightObstacleLayer() {
        state.flightObstacleLayer = window.HuaguoshanFlightObstacles.initLayer({
          getViewer: function () { return state.viewer; },
          huaguoshan: huaguoshan,
          log: log,
          renderError: panelError('flight-obstacles', '飞行障碍'),
          showPanel: panelShow('flight-obstacles', '飞行障碍'),
          rpc: postgrestRpc,
          helpers: gridHelpers
        });
      }

      function bindAirspaceControls() {
        window.HuaguoshanAirspaceGridUi.bindControls({
          airspaceGrid: function () { return state.airspaceGrid; }
        });
      }
      function bindAirspaceTilesControls() {
        window.HuaguoshanAirspaceTiles.bindControls({
          layer: function () { return state.airspaceTilesLayer; }
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
          renderError: panelError('airspace-constraints', '空域约束'),
          zoomToPoints: function (points, message) {
            if (!state.flightObstacleLayer) return;
            state.flightObstacleLayer.zoomToBounds(gridHelpers.cellsBounds(points.map(function (point) {
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
          renderError: panelError('flight-path', '航迹规划'),
          getCesium: function () { return window.Cesium; },
          getViewer: function () { return state.viewer; },
          helpers: Object.assign({}, gridHelpers, {
            formatMeters: window.HuaguoshanAirspaceGridUi.formatMeters
          })
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
      function loadTiandituWhitemodel() {
        var button = $('#loadTiandituWhitemodelBtn');
        if (state.tiandituWhitemodelReady) {
          window.HuaguoshanTilesets.flyToTiandituWhitemodel(Cesium, state, log);
          return Promise.resolve(state.tiandituWhitemodelTileset);
        }
        if (state.tiandituWhitemodelLoadPromise) return state.tiandituWhitemodelLoadPromise;

        if (button) {
          button.disabled = true;
          button.textContent = '正在加载建筑白膜…';
        }
        state.tiandituWhitemodelLoadPromise = window.HuaguoshanTilesets.addTiandituWhitemodel(
          Cesium, state.viewer, state, tiandituWhitemodelTilesetUrl, log
        ).then(function (tileset) {
          if (tileset) {
            if (button) button.textContent = '查看天地图建筑白膜';
            window.HuaguoshanTilesets.flyToTiandituWhitemodel(Cesium, state, log);
          } else if (button) {
            button.textContent = '重试加载建筑白膜';
          }
          return tileset;
        }).finally(function () {
          state.tiandituWhitemodelLoadPromise = null;
          if (button) button.disabled = false;
        });
        return state.tiandituWhitemodelLoadPromise;
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

      var layerControlsDestroy = null;

      function bindControls() {
        layerControlsDestroy = window.HuaguoshanLayerActions.bindControls({
          state: state,
          CesiumRuntime: Cesium,
          huaguoshan: huaguoshan,
          log: log,
          hideFeaturePanel: hideFeaturePanel,
          clearSelectedGridHighlight: clearSelectedGridHighlight,
          flyToHuaguoshan: flyToHuaguoshan,
          flyToTileset: flyToTileset,
          loadLianyungangBuildings: loadLianyungangBuildings,
          loadTiandituWhitemodel: loadTiandituWhitemodel,
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
        // 调试与自动化测试钩子挂在 init 末尾统一暴露（见 window.HuaguoshanApp）。

        configureScene(state.viewer);
        addImagery(state.viewer);
        addTerrain(state.viewer);
        addPlaceNames(state.viewer);
        addHuaguoshanMarker(state.viewer);
        initAirspaceGrid(state.viewer);
        initAirspaceTilesLayer();
        initSuitableFootprintLayer();
        initSourceSituation();
        initFlightObstacleLayer();
        initConvexHullAnalysis();
        addLocalTileset(state.viewer);
        addDemTileset(state.viewer);
        addLianyungangDemTileset(state.viewer);
        bindControls();
        bindAirspaceControls();
        bindAirspaceTilesControls();
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
          selectors: authSelectors,
          onAuthChanged: function (loggedIn) {
            appEvents.emit('auth:changed', { loggedIn: loggedIn });
          }
        });
      }

      // ── Teardown ────────────────────────────────────────────────

      var disposers = [];

      function destroyApp() {
        disposers.splice(0).forEach(function (dispose) {
          try {
            dispose();
          } catch (error) {
            console.warn('[Tianditu3D] disposer failed:', error);
          }
        });
        appEvents.clear();
        panelRouter.destroy();
        statusCenter.destroy();
        if (state.sourceSituation) state.sourceSituation.destroy();
        if (state.viewer && !state.viewer.isDestroyed()) state.viewer.destroy();
      }

      // 天地图 GeoTerrainProvider 在部分浏览器会先探测 GetCapabilities，
      // 探测失败后仍会继续请求地形瓦片；只有这类可恢复的内部 Promise
      // 噪声才被吞掉，其余未处理 rejection 仍然抛出以便发现真实 bug。
      function isTiandituTerrainProbeRejection(reason) {
        if (!reason) return false;
        var text = String((reason && (reason.message || reason.reason || reason)) || '');
        return /GetCapabilities|tilemapresource|GeoTerrainProvider/i.test(text);
      }

      function handleWindowError(event) {
        log('运行异常：' + event.message, 'error');
      }

      function handleUnhandledRejection(event) {
        if (isTiandituTerrainProbeRejection(event.reason)) {
          console.warn('[Tianditu3D] Cesium provider promise rejected:', event.reason);
          event.preventDefault();
          return;
        }
        console.error('[Tianditu3D] unhandled rejection:', event.reason);
        log('未处理的异步异常：' + ((event.reason && event.reason.message) || event.reason || '未知错误'), 'error');
      }

      var appEvents = window.HuaguoshanAppEvents.createEventBus();
      appEvents.on('auth:changed', function (event) {
        window.HuaguoshanHud.setAuthRequiredLocked(!(event && event.loggedIn));
      });

      disposers.push(window.HuaguoshanHud.initHudSections({ storageKey: 'hud.sections.open' }));

      window.addEventListener('error', handleWindowError);
      window.addEventListener('unhandledrejection', handleUnhandledRejection);
      disposers.push(function () {
        window.removeEventListener('error', handleWindowError);
        window.removeEventListener('unhandledrejection', handleUnhandledRejection);
      });

      init();

      if (state.viewer) {
        disposers.push(function () {
          state.viewer.camera.moveEnd.removeEventListener(scheduleTerrainLodRefresh);
          state.viewer.scene.postRender.removeEventListener(updateCameraReadout);
        });
        if (typeof layerControlsDestroy === 'function') disposers.push(layerControlsDestroy);
      }

      // Call auth init after the main init.
      initAuth();

      window.HuaguoshanApp = { state: state, destroy: destroyApp, get viewer() { return state.viewer; } };
    })();
