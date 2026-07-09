(function (global) {
  'use strict';

  function createViewer(CesiumRuntime, containerId) {
    return new CesiumRuntime.Map(containerId, {
      shouldAnimate: true,
      selectionIndicator: false,
      baseLayerPicker: false,
      fullscreenButton: false,
      geocoder: false,
      homeButton: false,
      infoBox: false,
      sceneModePicker: false,
      timeline: false,
      navigationHelpButton: false,
      navigationInstructionsInitiallyVisible: false,
      showRenderLoopErrors: false,
      shadows: false
    });
  }

  function configureScene(CesiumRuntime, viewer) {
    viewer.scene.fxaa = true;
    viewer.scene.postProcessStages.fxaa.enabled = false;
    viewer.scene.globe.showGroundAtmosphere = true;
    viewer.scene.screenSpaceCameraController.constrainedPitch = CesiumRuntime.Math.toRadians(-20);
    viewer.scene.screenSpaceCameraController.autoResetHeadingPitch = false;
    viewer.scene.screenSpaceCameraController.inertiaZoom = 0.5;
    viewer.scene.screenSpaceCameraController.minimumZoomDistance = 50;
    viewer.scene.screenSpaceCameraController.maximumZoomDistance = 20000000;
    viewer.scene.screenSpaceCameraController.zoomEventTypes = [
      CesiumRuntime.CameraEventType.RIGHT_DRAG,
      CesiumRuntime.CameraEventType.WHEEL,
      CesiumRuntime.CameraEventType.PINCH
    ];
    viewer.scene.screenSpaceCameraController.tiltEventTypes = [
      CesiumRuntime.CameraEventType.MIDDLE_DRAG,
      CesiumRuntime.CameraEventType.PINCH,
      { eventType: CesiumRuntime.CameraEventType.LEFT_DRAG, modifier: CesiumRuntime.KeyboardEventModifier.CTRL },
      { eventType: CesiumRuntime.CameraEventType.RIGHT_DRAG, modifier: CesiumRuntime.KeyboardEventModifier.CTRL }
    ];
    viewer.cesiumWidget.screenSpaceEventHandler.removeInputAction(CesiumRuntime.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
  }

  function addImagery(CesiumRuntime, viewer, options) {
    var imgMap = new CesiumRuntime.UrlTemplateImageryProvider({
      url: options.tdtUrl + 'DataServer?T=img_w&x={x}&y={y}&l={z}&tk=' + options.token,
      subdomains: options.subdomains,
      tilingScheme: new CesiumRuntime.WebMercatorTilingScheme(),
      maximumLevel: 18,
      credit: '天地图影像底图'
    });
    var imageLayer = viewer.imageryLayers.addImageryProvider(imgMap);

    var iboMap = new CesiumRuntime.UrlTemplateImageryProvider({
      url: options.tdtUrl + 'DataServer?T=ibo_w&x={x}&y={y}&l={z}&tk=' + options.token,
      subdomains: options.subdomains,
      tilingScheme: new CesiumRuntime.WebMercatorTilingScheme(),
      maximumLevel: 10,
      credit: '天地图国界服务'
    });
    var boundaryLayer = viewer.imageryLayers.addImageryProvider(iboMap);

    return {
      imageLayer: imageLayer,
      boundaryLayer: boundaryLayer
    };
  }

  function addTerrain(CesiumRuntime, viewer, options) {
    var terrainUrls = options.subdomains.map(function (subdomain) {
      return options.tdtUrl.replace('{s}', subdomain) + 'mapservice/swdx?T=elv_c&tk=' + options.token;
    });
    var terrainProvider = new CesiumRuntime.GeoTerrainProvider({ urls: terrainUrls });
    viewer.terrainProvider = terrainProvider;
    return terrainProvider;
  }

  function addPlaceNames(CesiumRuntime, viewer, options) {
    var wtfs = new CesiumRuntime.GeoWTFS({
      viewer: viewer,
      subdomains: options.subdomains,
      metadata: {
        boundBox: { minX: -180, minY: -90, maxX: 180, maxY: 90 },
        minLevel: 1,
        maxLevel: 20
      },
      depthTestOptimization: true,
      dTOElevation: 15000,
      dTOPitch: CesiumRuntime.Math.toRadians(-70),
      aotuCollide: true,
      collisionPadding: [5, 10, 8, 5],
      serverFirstStyle: true,
      labelGraphics: {
        font: '28px sans-serif',
        fontSize: 28,
        fillColor: CesiumRuntime.Color.WHITE,
        scale: 0.5,
        outlineColor: CesiumRuntime.Color.BLACK,
        outlineWidth: 2,
        style: CesiumRuntime.LabelStyle.FILL_AND_OUTLINE,
        showBackground: false,
        horizontalOrigin: CesiumRuntime.HorizontalOrigin.LEFT,
        verticalOrigin: CesiumRuntime.VerticalOrigin.TOP,
        pixelOffset: new CesiumRuntime.Cartesian2(5, 5)
      },
      billboardGraphics: {
        horizontalOrigin: CesiumRuntime.HorizontalOrigin.CENTER,
        verticalOrigin: CesiumRuntime.VerticalOrigin.CENTER,
        color: CesiumRuntime.Color.WHITE,
        rotation: 0,
        scale: 1,
        width: 18,
        height: 18
      }
    });

    wtfs.getTileUrl = function () {
      return options.tdtUrl + 'mapservice/GetTiles?lxys={z},{x},{y}&VERSION=1.0.0&tk=' + options.token;
    };
    wtfs.getIcoUrl = function () {
      return options.tdtUrl + 'mapservice/GetIcon?id={id}&tk=' + options.token;
    };
    wtfs.initTDT([
      {"x":6,"y":1,"level":2,"boundBox":{"minX":90,"minY":0,"maxX":135,"maxY":45}},
      {"x":7,"y":1,"level":2,"boundBox":{"minX":135,"minY":0,"maxX":180,"maxY":45}},
      {"x":6,"y":0,"level":2,"boundBox":{"minX":90,"minY":45,"maxX":135,"maxY":90}},
      {"x":7,"y":0,"level":2,"boundBox":{"minX":135,"minY":45,"maxX":180,"maxY":90}},
      {"x":5,"y":1,"level":2,"boundBox":{"minX":45,"minY":0,"maxX":90,"maxY":45}},
      {"x":4,"y":1,"level":2,"boundBox":{"minX":0,"minY":0,"maxX":45,"maxY":45}},
      {"x":5,"y":0,"level":2,"boundBox":{"minX":45,"minY":45,"maxX":90,"maxY":90}},
      {"x":4,"y":0,"level":2,"boundBox":{"minX":0,"minY":45,"maxX":45,"maxY":90}},
      {"x":6,"y":2,"level":2,"boundBox":{"minX":90,"minY":-45,"maxX":135,"maxY":0}},
      {"x":6,"y":3,"level":2,"boundBox":{"minX":90,"minY":-90,"maxX":135,"maxY":-45}},
      {"x":7,"y":2,"level":2,"boundBox":{"minX":135,"minY":-45,"maxX":180,"maxY":0}},
      {"x":5,"y":2,"level":2,"boundBox":{"minX":45,"minY":-45,"maxX":90,"maxY":0}},
      {"x":4,"y":2,"level":2,"boundBox":{"minX":0,"minY":-45,"maxX":45,"maxY":0}},
      {"x":3,"y":1,"level":2,"boundBox":{"minX":-45,"minY":0,"maxX":0,"maxY":45}},
      {"x":3,"y":0,"level":2,"boundBox":{"minX":-45,"minY":45,"maxX":0,"maxY":90}},
      {"x":2,"y":0,"level":2,"boundBox":{"minX":-90,"minY":45,"maxX":-45,"maxY":90}},
      {"x":0,"y":1,"level":2,"boundBox":{"minX":-180,"minY":0,"maxX":-135,"maxY":45}},
      {"x":1,"y":0,"level":2,"boundBox":{"minX":-135,"minY":45,"maxX":-90,"maxY":90}},
      {"x":0,"y":0,"level":2,"boundBox":{"minX":-180,"minY":45,"maxX":-135,"maxY":90}}
    ]);

    return wtfs;
  }

  function addHuaguoshanMarker(CesiumRuntime, viewer, huaguoshan) {
    return viewer.entities.add({
      name: '连云港花果山景区',
      position: CesiumRuntime.Cartesian3.fromDegrees(huaguoshan.lon, huaguoshan.lat, 650),
      point: {
        pixelSize: 12,
        color: CesiumRuntime.Color.fromCssColorString('#d85a35'),
        outlineColor: CesiumRuntime.Color.WHITE,
        outlineWidth: 2,
        disableDepthTestDistance: Number.POSITIVE_INFINITY
      },
      label: {
        text: '花果山景区',
        font: '600 16px Microsoft YaHei',
        fillColor: CesiumRuntime.Color.WHITE,
        outlineColor: CesiumRuntime.Color.BLACK,
        outlineWidth: 3,
        style: CesiumRuntime.LabelStyle.FILL_AND_OUTLINE,
        pixelOffset: new CesiumRuntime.Cartesian2(14, -18),
        horizontalOrigin: CesiumRuntime.HorizontalOrigin.LEFT,
        disableDepthTestDistance: Number.POSITIVE_INFINITY
      }
    });
  }

  global.HuaguoshanCesiumMap = {
    createViewer: createViewer,
    configureScene: configureScene,
    addImagery: addImagery,
    addTerrain: addTerrain,
    addPlaceNames: addPlaceNames,
    addHuaguoshanMarker: addHuaguoshanMarker
  };
})(window);
