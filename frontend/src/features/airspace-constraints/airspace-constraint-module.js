(function (global) {
  'use strict';

  function pickLonLat(getViewer, CesiumRuntime, position) {
    var viewer = getViewer();
    var cartesian = null;
    var ray;
    var cartographic;
    if (!viewer || !CesiumRuntime || !position) return null;
    if (viewer.scene.globe && typeof viewer.camera.getPickRay === 'function') {
      ray = viewer.camera.getPickRay(position);
      if (ray) cartesian = viewer.scene.globe.pick(ray, viewer.scene);
    }
    if (!cartesian && typeof viewer.camera.pickEllipsoid === 'function') {
      cartesian = viewer.camera.pickEllipsoid(position, viewer.scene.globe.ellipsoid);
    }
    if (!cartesian) return null;
    cartographic = CesiumRuntime.Cartographic.fromCartesian(cartesian);
    return {
      lon: CesiumRuntime.Math.toDegrees(cartographic.longitude),
      lat: CesiumRuntime.Math.toDegrees(cartographic.latitude),
      height: Number.isFinite(cartographic.height) ? cartographic.height : null
    };
  }

  function createMapAdapter(options) {
    var previewEntities = [];
    var getViewer = options.getViewer;
    var getCesium = options.getCesium || function () { return global.Cesium; };

    function clearPreview() {
      var viewer = getViewer();
      if (viewer) {
        previewEntities.forEach(function (entity) {
          viewer.entities.remove(entity);
        });
      }
      previewEntities = [];
    }

    function renderPreview(points, kind) {
      var viewer = getViewer();
      var CesiumRuntime = getCesium();
      var positions;
      var color;
      var heightReference;
      clearPreview();
      if (!viewer || !CesiumRuntime || !points.length) return;
      color = CesiumRuntime.Color.fromCssColorString(kind === 'temp_control' ? '#ffb000' : '#ff3b30');
      heightReference = CesiumRuntime.HeightReference && CesiumRuntime.HeightReference.CLAMP_TO_GROUND;
      positions = points.map(function (point) { return CesiumRuntime.Cartesian3.fromDegrees(point.lon, point.lat); });
      points.forEach(function (point, index) {
        previewEntities.push(viewer.entities.add({
          name: 'Airspace draw vertex ' + (index + 1),
          position: CesiumRuntime.Cartesian3.fromDegrees(point.lon, point.lat),
          point: {
            pixelSize: 11,
            color: color,
            outlineColor: CesiumRuntime.Color.WHITE,
            outlineWidth: 2,
            heightReference: heightReference,
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          },
          label: {
            text: String(index + 1),
            font: '13px sans-serif',
            fillColor: CesiumRuntime.Color.WHITE,
            outlineColor: CesiumRuntime.Color.BLACK,
            outlineWidth: 2,
            style: CesiumRuntime.LabelStyle.FILL_AND_OUTLINE,
            pixelOffset: new CesiumRuntime.Cartesian2(12, -12),
            heightReference: heightReference,
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          }
        }));
      });
      if (positions.length >= 2) {
        previewEntities.push(viewer.entities.add({
          name: 'Airspace draw outline',
          polyline: {
            positions: positions.concat(positions.length >= 3 ? [positions[0]] : []),
            width: 3,
            material: color.withAlpha(0.95),
            depthFailMaterial: color.withAlpha(0.95),
            clampToGround: true
          }
        }));
      }
      if (positions.length >= 3) {
        previewEntities.push(viewer.entities.add({
          name: 'Airspace draw polygon',
          polygon: {
            hierarchy: positions,
            material: color.withAlpha(0.22),
            outline: true,
            outlineColor: color,
            heightReference: heightReference
          }
        }));
      }
    }

    function fallbackTerrainSample(points, terrainSamplePoints, summarizeHeights) {
      var viewer = getViewer();
      var CesiumRuntime = getCesium();
      var samples = terrainSamplePoints(points).map(function (point) {
        var height = point.height;
        var cartographic;
        if (!Number.isFinite(height) && viewer && viewer.scene && viewer.scene.globe && CesiumRuntime) {
          cartographic = CesiumRuntime.Cartographic.fromDegrees(point.lon, point.lat);
          height = viewer.scene.globe.getHeight(cartographic);
        }
        return Object.assign({}, point, { height: Number.isFinite(height) ? height : 0 });
      });
      return Promise.resolve(summarizeHeights(samples, 'loaded terrain'));
    }

    function sampleTerrain(points, terrainSamplePoints, summarizeHeights) {
      var viewer = getViewer();
      var CesiumRuntime = getCesium();
      var samples = terrainSamplePoints(points);
      var cartographics;
      if (!points.length || !CesiumRuntime || !viewer || !viewer.terrainProvider || typeof CesiumRuntime.sampleTerrainMostDetailed !== 'function') {
        return fallbackTerrainSample(points, terrainSamplePoints, summarizeHeights);
      }
      cartographics = samples.map(function (point) {
        return CesiumRuntime.Cartographic.fromDegrees(point.lon, point.lat);
      });
      return CesiumRuntime.sampleTerrainMostDetailed(viewer.terrainProvider, cartographics).then(function (updated) {
        return summarizeHeights(updated.map(function (cartographic, index) {
          return Object.assign({}, samples[index], { height: cartographic.height });
        }), 'terrain provider');
      }).catch(function (error) {
        console.warn('[Tianditu3D] Terrain sampling fell back to loaded globe heights:', error);
        return fallbackTerrainSample(points, terrainSamplePoints, summarizeHeights);
      });
    }

    return {
      pickLonLat: function (position) { return pickLonLat(getViewer, getCesium(), position); },
      renderPreview: renderPreview,
      clearPreview: clearPreview,
      sampleTerrain: sampleTerrain
    };
  }

  function initEditor(options) {
    var container = document.querySelector(options.containerSelector || '#airspaceConstraintEditor');
    var editor;
    if (!container || !global.AirspaceConstraintEditor) {
      options.log('空域约束编辑模块未加载，禁限飞区管理不可用。');
      return null;
    }
    editor = global.AirspaceConstraintEditor.create({
      request: options.request,
      map: createMapAdapter({ getViewer: options.getViewer, getCesium: options.getCesium }),
      log: options.log,
      confirm: options.confirm || function (message) { return Promise.resolve(global.confirm(message)); },
      onChanged: options.onChanged,
      renderError: options.renderError,
      zoomToPoints: options.zoomToPoints
    });
    editor.setViewer(options.getViewer());
    editor.mount(container);
    return editor;
  }

  global.HuaguoshanAirspaceConstraints = {
    pickLonLat: pickLonLat,
    createMapAdapter: createMapAdapter,
    initEditor: initEditor
  };
})(window);
