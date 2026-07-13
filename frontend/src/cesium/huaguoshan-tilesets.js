(function (global) {
  'use strict';

  function unsupported(CesiumRuntime, message, log) {
    if (!CesiumRuntime.Cesium3DTileset) {
      log(message);
      return true;
    }
    return false;
  }

  function addCitydbBuildings(CesiumRuntime, viewer, state, url, log) {
    if (unsupported(CesiumRuntime, '当前 Cesium 版本不支持 Cesium3DTileset，无法挂载本地 3D Tiles。', log)) return Promise.resolve(null);
    log('正在挂载本工程 3D Tiles：' + url);
    return global.HuaguoshanTilesetLoader.add3DTileset(CesiumRuntime, viewer, url, {
      tilesetOptions: {
        maximumScreenSpaceError: 8,
        dynamicScreenSpaceError: true,
        skipLevelOfDetail: true,
        immediatelyLoadDesiredLevelOfDetail: false,
        cullRequestsWhileMoving: true,
        show: true
      },
      onAdded: function (tileset) { state.buildingsTileset = tileset; }
    }).then(function (tileset) {
      state.buildingsReady = true;
      log('3D Tiles 已挂载：exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json');
      return tileset;
    }).catch(function (error) {
      console.error('[Tianditu3D] 3D Tiles load failed:', error);
      log('3D Tiles 挂载失败。请从工程根目录启动服务：python3 -m http.server 4173，然后访问 /frontend/tianditu-3d.html');
      return null;
    });
  }

  function addLianyungangBuildings(CesiumRuntime, viewer, state, url, log) {
    if (unsupported(CesiumRuntime, '当前 Cesium 版本不支持 Cesium3DTileset，无法挂载连云港全市建筑。', log)) return Promise.resolve(null);
    log('正在加载连云港全市建筑 3D Tiles：' + url);
    return global.HuaguoshanTilesetLoader.add3DTileset(CesiumRuntime, viewer, url, {
      tilesetOptions: {
        maximumScreenSpaceError: 12,
        dynamicScreenSpaceError: true,
        skipLevelOfDetail: true,
        immediatelyLoadDesiredLevelOfDetail: false,
        cullRequestsWhileMoving: true,
        show: true
      },
      onAdded: function (tileset) { state.lianyungangBuildingsTileset = tileset; }
    }).then(function (tileset) {
      state.lianyungangBuildingsReady = true;
      log('连云港全市建筑已挂载：25,018 栋 OSM LoD1 建筑。');
      return tileset;
    }).catch(function (error) {
      console.error('[Tianditu3D] Lianyungang building tileset load failed:', error);
      log('连云港全市建筑加载失败。请确认 exports/citydb-3dtiler/lianyungang_buildings_3dtiles/tileset.json 存在，并从工程根目录启动服务。');
      return null;
    });
  }

  function flyToLianyungangBuildings(CesiumRuntime, state, log) {
    if (!state.lianyungangBuildingsTileset || !state.lianyungangBuildingsReady) return;
    global.HuaguoshanCamera.flyToTileset(CesiumRuntime, state.viewer, state.lianyungangBuildingsTileset, {
      duration: 2.2,
      heading: 18,
      pitch: -40,
      range: 72000
    });
    log('已定位到连云港全市建筑范围。');
  }

  function addDem(CesiumRuntime, viewer, state, url, log) {
    if (unsupported(CesiumRuntime, '当前 Cesium 版本不支持 Cesium3DTileset，无法挂载 DEM 网格。', log)) return Promise.resolve(null);
    return global.HuaguoshanTilesetLoader.add3DTileset(CesiumRuntime, viewer, url, {
      tilesetOptions: {
        maximumScreenSpaceError: 4,
        dynamicScreenSpaceError: true,
        skipLevelOfDetail: false,
        show: state.demVisible
      },
      onAdded: function (tileset) { state.demTileset = tileset; }
    }).then(function (tileset) {
      state.demReady = true;
      state.demTileset.show = state.demVisible;
      log('DEM 网格已挂载：exports/terrain/huaguoshan_dem_3dtiles/tileset.json');
      return tileset;
    }).catch(function (error) {
      console.error('[Tianditu3D] DEM tileset load failed:', error);
      log('DEM 网格挂载失败。请先运行 uv run scripts/export_dem_3dtiles.py --execute，并从工程根目录启动服务。');
      return null;
    });
  }

  function addLianyungangDem(CesiumRuntime, viewer, state, url, log) {
    if (unsupported(CesiumRuntime, '当前 Cesium 版本不支持 Cesium3DTileset，无法挂载连云港 DEM。', log)) return Promise.resolve(null);
    return global.HuaguoshanTilesetLoader.add3DTileset(CesiumRuntime, viewer, url, {
      tilesetOptions: {
        maximumScreenSpaceError: 4,
        dynamicScreenSpaceError: true,
        skipLevelOfDetail: false,
        show: state.lianyungangDemVisible
      },
      onAdded: function (tileset) { state.lianyungangDemTileset = tileset; }
    }).then(function (tileset) {
      state.lianyungangDemReady = true;
      state.lianyungangDemTileset.show = state.lianyungangDemVisible;
      log('连云港 DEM 已挂载：exports/terrain/lianyungang_dem_3dtiles/tileset.json');
      return tileset;
    }).catch(function (error) {
      console.error('[Tianditu3D] Lianyungang DEM tileset load failed:', error);
      log('连云港 DEM 挂载失败。请确认 exports/terrain/lianyungang_dem_3dtiles/tileset.json 存在，并从工程根目录启动服务。');
      return null;
    });
  }

  function flyToTileset(CesiumRuntime, state, huaguoshan, log) {
    if (state.buildingsTileset && state.buildingsReady) {
      global.HuaguoshanCamera.flyToTileset(CesiumRuntime, state.viewer, state.buildingsTileset, {
        duration: 1.8,
        heading: 24,
        pitch: -28,
        range: 5200
      });
      return;
    }
    log('3D Tiles 仍在加载，先切换到花果山低空视角。');
    global.HuaguoshanCamera.flyToLonLat(CesiumRuntime, state.viewer, {
      lon: huaguoshan.lon,
      lat: huaguoshan.lat,
      height: 5200,
      heading: 24,
      pitch: -28,
      duration: 1.6
    });
  }

  function flyToDem(CesiumRuntime, state, huaguoshan, log) {
    state.demVisible = true;
    var demButton = document.querySelector('[data-layer="dem"]');
    if (demButton) demButton.setAttribute('aria-pressed', 'true');
    if (state.demTileset) state.demTileset.show = true;

    if (state.demTileset && state.demReady) {
      global.HuaguoshanCamera.flyToTileset(CesiumRuntime, state.viewer, state.demTileset, {
        duration: 1.8,
        heading: 26,
        pitch: -32,
        range: 10500
      });
      log('DEM 网格已显示。该图层用于可视化验证，不替代 Cesium terrainProvider。');
      return;
    }

    log('DEM 网格仍在加载，先切换到 DEM 覆盖范围视角。');
    global.HuaguoshanCamera.flyToLonLat(CesiumRuntime, state.viewer, {
      lon: huaguoshan.lon,
      lat: huaguoshan.lat,
      height: 10500,
      heading: 26,
      pitch: -32,
      duration: 1.6
    });
  }

  function flyToLianyungangDem(CesiumRuntime, state, log) {
    state.lianyungangDemVisible = true;
    var demButton = document.querySelector('[data-layer="lianyungangDem"]');
    if (demButton) demButton.setAttribute('aria-pressed', 'true');
    if (state.lianyungangDemTileset) state.lianyungangDemTileset.show = true;

    if (state.lianyungangDemTileset && state.lianyungangDemReady) {
      global.HuaguoshanCamera.flyToTileset(CesiumRuntime, state.viewer, state.lianyungangDemTileset, {
        duration: 1.8,
        heading: 18,
        pitch: -42,
        range: 58000
      });
      log('连云港 DEM 已显示：exports/terrain/lianyungang_dem_3dtiles/tileset.json。');
      return;
    }

    log('连云港 DEM 仍在加载，先切换到连云港市视角。');
    global.HuaguoshanCamera.flyToLonLat(CesiumRuntime, state.viewer, {
      lon: 119.22,
      lat: 34.60,
      height: 58000,
      heading: 18,
      pitch: -42,
      duration: 1.6
    });
  }

  global.HuaguoshanTilesets = {
    addCitydbBuildings: addCitydbBuildings,
    addLianyungangBuildings: addLianyungangBuildings,
    addDem: addDem,
    addLianyungangDem: addLianyungangDem,
    flyToTileset: flyToTileset,
    flyToLianyungangBuildings: flyToLianyungangBuildings,
    flyToDem: flyToDem,
    flyToLianyungangDem: flyToLianyungangDem
  };
})(window);
