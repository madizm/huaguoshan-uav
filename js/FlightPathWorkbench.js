/*
 * Flight path planning and playback workbench.
 *
 * Owns 目标航迹 planning DOM/state, route rendering, route-grid display, and
 * playback camera behavior. The shell supplies RPC, map picking, Cesium, and
 * shared grid helpers.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.FlightPathWorkbench = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    function formatDateTimeLocal(date) {
        var pad = function(value) { return String(value).padStart(2, '0'); };
        return [date.getFullYear(), '-', pad(date.getMonth() + 1), '-', pad(date.getDate()), 'T', pad(date.getHours()), ':', pad(date.getMinutes())].join('');
    }

    function isoFromDateTimeLocal(value) {
        var date;
        if (!value) return null;
        date = new Date(value);
        if (!Number.isFinite(date.getTime())) return null;
        return date.toISOString();
    }

    function numberOrNull(value) {
        var num = Number(value);
        return Number.isFinite(num) ? num : null;
    }

    function escapeHtml(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function create(options) {
        var rpc = options.rpc;
        var map = options.map || {};
        var log = options.log || function() {};
        var renderError = options.renderError || function() {};
        var helpers = options.helpers;
        var rootEl = null;
        var state = {
            viewer: null,
            flightPath: {
                plans: [],
                currentPlanId: null,
                drawMode: null,
                points: [],
                pointEntities: [],
                rawLineEntity: null,
                routeEntity: null,
                routeGlowEntity: null,
                routeGridPrimitive: null,
                routeGridCells: [],
                routeGridVisible: true,
                latestResult: null,
                playback: {
                    entity: null, glowEntity: null, clockStart: null, clockStop: null, sampledPosition: null,
                    playing: false, followEnabled: false, mode: 'chase', speedMultiplier: 1, progress: 0, currentIndex: 0,
                    routePositions: [], cumulativeDistances: [], totalDistance: 0, duration: 0, baseSpeed: 0, gridCells: [],
                    currentGridPrimitive: null, currentGridIndex: null, cameraListener: null, cameraPosition: null, cameraDirection: null, cameraUp: null
                },
                loading: false
            }
        };

        function $(selector) { return rootEl ? rootEl.querySelector(selector) : null; }
        function $all(selector) { return rootEl ? Array.prototype.slice.call(rootEl.querySelectorAll(selector)) : []; }
        function getCesium() { return (options.getCesium && options.getCesium()) || (typeof Cesium !== 'undefined' ? Cesium : null); }
        function pickLonLatFromScreen(position) { return map.pickLonLat ? map.pickLonLat(position) : null; }
        function parseBboxText(value) { return helpers.parseBboxText(value); }
        function extractGridCells(value) { return helpers.extractGridCells(value); }
        function cellsBounds(value) { return helpers.cellsBounds(value); }
        function addBoxEdges(edges, cell, layerIndex) { return helpers.addBoxEdges(edges, cell, layerIndex); }
        function sortedGridLayers(cells) { return helpers.sortedGridLayers(cells); }
        function gridLayerIndex(cell, layers) { return helpers.gridLayerIndex(cell, layers); }
        function gridLayerMaterial(CesiumRuntime, cache, layerIndex, alpha) { return helpers.gridLayerMaterial(CesiumRuntime, cache, layerIndex, alpha); }
        function formatMeters(value, digits) { return helpers.formatMeters(value, digits); }
        var Cesium;

function setupFlightPathDefaults() {
  var planningTime = $('#flightPathPlanningTime');
  if (planningTime && !planningTime.value) planningTime.value = formatDateTimeLocal(new Date());
}

function flightPathHeight() {
  var value = numberOrNull($('#flightPathHeight') && $('#flightPathHeight').value);
  return value == null ? 120 : value;
}

function flightPathDetailLevel() {
  var value = numberOrNull($('#flightPathDetailLevel') && $('#flightPathDetailLevel').value);
  return Math.max(1, Math.min(32, value == null ? 19 : Math.round(value)));
}

function flightPathSpeed() {
  var value = numberOrNull($('#flightPathSpeed') && $('#flightPathSpeed').value);
  return Math.max(0.1, value == null ? 10 : value);
}

function flightPathRoleLabel(role) {
  if (role === 'start') return '起点';
  if (role === 'end') return '终点';
  return '途径点';
}

function flightPathDisplayHeight(point) {
  if (!point) return flightPathHeight();
  if (Number.isFinite(point.effective_height_m)) return point.effective_height_m;
  if ((point.height_datum || 'AMSL') === 'AGL') {
    return (Number.isFinite(point.terrain_height_m) ? point.terrain_height_m : 0) + (Number.isFinite(point.height_m) ? point.height_m : flightPathHeight());
  }
  return Number.isFinite(point.height_m) ? point.height_m : flightPathHeight();
}

function flightPathPointSummary(point) {
  var datum = point.height_datum || 'AMSL';
  var inputHeight = Number.isFinite(point.height_m) ? point.height_m : flightPathHeight();
  var displayHeight = flightPathDisplayHeight(point);
  if (datum === 'AGL') {
    return inputHeight.toFixed(1) + 'm AGL · calc ≈ ' + displayHeight.toFixed(1) + 'm AMSL';
  }
  return inputHeight.toFixed(1) + 'm ' + datum;
}

function normalizedFlightPathPoints(points) {
  var start = points.find(function (point) { return point.role === 'start'; });
  var end = points.find(function (point) { return point.role === 'end'; });
  var waypoints = points.filter(function (point) { return point.role === 'waypoint'; });
  return (start ? [start] : []).concat(waypoints, end ? [end] : []).map(function (point, index) {
    return Object.assign({}, point, { seq: index });
  });
}

function clearFlightPathPointEntities() {
  if (!state.viewer) return;
  state.flightPath.pointEntities.forEach(function (entity) { state.viewer.entities.remove(entity); });
  state.flightPath.pointEntities = [];
  if (state.flightPath.rawLineEntity) state.viewer.entities.remove(state.flightPath.rawLineEntity);
  state.flightPath.rawLineEntity = null;
}

function clearFlightPathGrid() {
  if (state.flightPath.routeGridPrimitive && state.viewer) {
    try {
      state.viewer.scene.primitives.remove(state.flightPath.routeGridPrimitive);
    } catch (error) {
      console.warn('[Tianditu3D] Failed to remove flight path grid primitive:', error);
    }
  }
  state.flightPath.routeGridPrimitive = null;
  state.flightPath.routeGridCells = [];
}

function clearFlightPathRoute() {
  if (!state.viewer) return;
  clearFlightPathPlayback();
  if (state.flightPath.routeEntity) state.viewer.entities.remove(state.flightPath.routeEntity);
  if (state.flightPath.routeGlowEntity) state.viewer.entities.remove(state.flightPath.routeGlowEntity);
  state.flightPath.routeEntity = null;
  state.flightPath.routeGlowEntity = null;
  clearFlightPathGrid();
  state.flightPath.latestResult = null;
}

function flightPathGridCellsFromResult(result) {
  var withBox = result && result.route_grid_with_box;
  var cells = withBox && Array.isArray(withBox.cells) ? withBox.cells : [];
  return cells.map(function (cell, index) {
    var bbox = parseBboxText(cell && cell.bbox);
    return bbox ? Object.assign({ code: cell.code || '', index: index }, bbox) : null;
  }).filter(Boolean);
}

function showFlightPathGrid(result) {
  var CesiumRuntime = window.Cesium;
  var cells = flightPathGridCellsFromResult(result || state.flightPath.latestResult);
  var edges = {};
  var materialCache = {};
  var layers;
  var primitive;
  clearFlightPathGrid();
  if (!state.viewer || !CesiumRuntime || !cells.length) return;
  layers = sortedGridLayers(cells);
  cells.forEach(function (cell) {
    addBoxEdges(edges, cell, gridLayerIndex(cell, layers));
  });
  primitive = new CesiumRuntime.PolylineCollection();
  Object.keys(edges).forEach(function (key) {
    var edge = edges[key];
    primitive.add({
      positions: [
        CesiumRuntime.Cartesian3.fromDegrees(edge.lon1, edge.lat1, edge.h1),
        CesiumRuntime.Cartesian3.fromDegrees(edge.lon2, edge.lat2, edge.h2)
      ],
      width: 2.8,
      material: gridLayerMaterial(CesiumRuntime, materialCache, edge.layerIndex, 0.96)
    });
  });
  state.flightPath.routeGridPrimitive = state.viewer.scene.primitives.add(primitive);
  state.flightPath.routeGridCells = cells;
}

function syncFlightPathGridButton() {
  var button = $('[data-action="toggleFlightPathGrid"]');
  if (button) button.setAttribute('aria-pressed', String(Boolean(state.flightPath.routeGridVisible)));
}

function toggleFlightPathGrid() {
  state.flightPath.routeGridVisible = !state.flightPath.routeGridVisible;
  syncFlightPathGridButton();
  if (state.flightPath.routeGridVisible) {
    showFlightPathGrid(state.flightPath.latestResult);
    log(state.flightPath.routeGridCells.length ? '飞行路径网格已显示：' + state.flightPath.routeGridCells.length + ' cells。' : '当前路径结果没有可展示的网格。');
  } else {
    clearFlightPathGrid();
    removeFlightPathCurrentGridPrimitive();
    log('飞行路径网格已隐藏。');
  }
}

function resetFlightPathPlaybackUi() {
  var slider = $('#flightPlaybackProgress');
  if (slider) slider.value = '0';
  if ($('#flightReplayProgress')) $('#flightReplayProgress').textContent = '--';
  if ($('#flightReplayAltitude')) $('#flightReplayAltitude').textContent = '--';
  if ($('#flightReplaySpeed')) $('#flightReplaySpeed').textContent = '--';
  if ($('#flightReplayDistance')) $('#flightReplayDistance').textContent = '--';
  if ($('#flightReplayMode')) $('#flightReplayMode').textContent = 'Idle';
  if ($('#flightReplayGrid')) $('#flightReplayGrid').textContent = '--';
}

function syncFlightPathPlaybackButtons() {
  var followButton = $('[data-action="toggleFlightPathFollow"]');
  if (followButton) followButton.setAttribute('aria-pressed', String(Boolean(state.flightPath.playback.followEnabled)));
  $all('[data-action="setFlightPathPlaybackSpeed"]').forEach(function (button) {
    button.setAttribute('aria-pressed', String(Number(button.dataset.speed) === Number(state.flightPath.playback.speedMultiplier)));
  });
  $all('[data-action="setFlightPathPlaybackMode"]').forEach(function (button) {
    button.setAttribute('aria-pressed', String(button.dataset.mode === state.flightPath.playback.mode));
  });
}

function removeFlightPathCurrentGridPrimitive() {
  var playback = state.flightPath.playback;
  if (playback.currentGridPrimitive && state.viewer) {
    try {
      state.viewer.scene.primitives.remove(playback.currentGridPrimitive);
    } catch (error) {
      console.warn('[Tianditu3D] Failed to remove flight playback grid primitive:', error);
    }
  }
  playback.currentGridPrimitive = null;
  playback.currentGridIndex = null;
}

function clearFlightPathPlayback() {
  var playback = state.flightPath.playback;
  if (!state.viewer) return;
  if (playback.cameraListener) {
    state.viewer.scene.preRender.removeEventListener(playback.cameraListener);
    playback.cameraListener = null;
  }
  if (state.viewer.trackedEntity === playback.entity) state.viewer.trackedEntity = undefined;
  if (playback.entity) state.viewer.entities.remove(playback.entity);
  if (playback.glowEntity) state.viewer.entities.remove(playback.glowEntity);
  removeFlightPathCurrentGridPrimitive();
  playback.entity = null;
  playback.glowEntity = null;
  playback.clockStart = null;
  playback.clockStop = null;
  playback.sampledPosition = null;
  playback.playing = false;
  playback.followEnabled = false;
  playback.progress = 0;
  playback.currentIndex = 0;
  playback.routePositions = [];
  playback.cumulativeDistances = [];
  playback.totalDistance = 0;
  playback.duration = 0;
  playback.baseSpeed = 0;
  playback.gridCells = [];
  playback.cameraPosition = null;
  playback.cameraDirection = null;
  playback.cameraUp = null;
  state.viewer.clock.shouldAnimate = false;
  resetFlightPathPlaybackUi();
  syncFlightPathPlaybackButtons();
}

function flightPathPlaybackCoords(result) {
  var smooth = result && result.smooth_route_geojson && result.smooth_route_geojson.coordinates;
  var raw = result && result.route_geojson && result.route_geojson.coordinates;
  var coords = Array.isArray(smooth) && smooth.length >= 2 ? smooth : raw;
  if (!Array.isArray(coords)) return [];
  return coords.map(function (coord) {
    var lon = Number(coord && coord[0]);
    var lat = Number(coord && coord[1]);
    var height = Number(coord && coord[2]);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
    return [lon, lat, Number.isFinite(height) ? height : flightPathHeight()];
  }).filter(Boolean);
}

function buildFlightPathPlaybackSamples(result) {
  var CesiumRuntime = window.Cesium;
  var coords = flightPathPlaybackCoords(result);
  var positions;
  var cumulative = [0];
  var totalDistance = 0;
  var routeDuration;
  var start;
  var stop;
  var sampled;
  var i;
  if (!CesiumRuntime || coords.length < 2) return null;
  positions = coords.map(function (coord) {
    return CesiumRuntime.Cartesian3.fromDegrees(coord[0], coord[1], coord[2]);
  });
  for (i = 1; i < positions.length; i += 1) {
    totalDistance += CesiumRuntime.Cartesian3.distance(positions[i - 1], positions[i]);
    cumulative.push(totalDistance);
  }
  if (!Number.isFinite(totalDistance) || totalDistance <= 0) return null;
  routeDuration = Number(result && result.duration_s);
  if (!Number.isFinite(routeDuration) || routeDuration <= 0) {
    routeDuration = totalDistance / Math.max(flightPathSpeed(), 0.1);
  }
  start = CesiumRuntime.JulianDate.now();
  stop = CesiumRuntime.JulianDate.addSeconds(start, routeDuration, new CesiumRuntime.JulianDate());
  sampled = new CesiumRuntime.SampledPositionProperty();
  positions.forEach(function (position, index) {
    var ratio = totalDistance > 0 ? cumulative[index] / totalDistance : index / Math.max(positions.length - 1, 1);
    var time = CesiumRuntime.JulianDate.addSeconds(start, routeDuration * ratio, new CesiumRuntime.JulianDate());
    sampled.addSample(time, position);
  });
  if (CesiumRuntime.LinearApproximation && typeof sampled.setInterpolationOptions === 'function') {
    sampled.setInterpolationOptions({
      interpolationDegree: 1,
      interpolationAlgorithm: CesiumRuntime.LinearApproximation
    });
  }
  return {
    start: start,
    stop: stop,
    sampled: sampled,
    positions: positions,
    cumulative: cumulative,
    totalDistance: totalDistance,
    duration: routeDuration,
    baseSpeed: totalDistance / routeDuration
  };
}

function playbackElapsedSeconds() {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var elapsed;
  if (!CesiumRuntime || !state.viewer || !playback.clockStart) return 0;
  elapsed = CesiumRuntime.JulianDate.secondsDifference(state.viewer.clock.currentTime, playback.clockStart);
  return Math.min(Math.max(elapsed, 0), playback.duration || 0);
}

function currentFlightPathPlaybackIndex(distance) {
  var cumulative = state.flightPath.playback.cumulativeDistances;
  var i;
  for (i = 1; i < cumulative.length; i += 1) {
    if (distance <= cumulative[i]) return i - 1;
  }
  return Math.max(cumulative.length - 2, 0);
}

function formatFlightDistance(current, total) {
  if (!Number.isFinite(current) || !Number.isFinite(total) || total <= 0) return '--';
  if (total >= 1000) return (current / 1000).toFixed(2) + ' / ' + (total / 1000).toFixed(2) + 'km';
  return current.toFixed(0) + ' / ' + total.toFixed(0) + 'm';
}

function findNearestFlightPathGridCell(position) {
  var CesiumRuntime = window.Cesium;
  var cells = state.flightPath.playback.gridCells;
  var cartographic;
  var lon;
  var lat;
  var height;
  var best = null;
  var bestScore = Number.POSITIVE_INFINITY;
  if (!CesiumRuntime || !position || !cells.length) return null;
  cartographic = CesiumRuntime.Ellipsoid.WGS84.cartesianToCartographic(position);
  if (!cartographic) return null;
  lon = CesiumRuntime.Math.toDegrees(cartographic.longitude);
  lat = CesiumRuntime.Math.toDegrees(cartographic.latitude);
  height = cartographic.height;
  cells.forEach(function (cell) {
    var insideLon = lon >= cell.minLon && lon <= cell.maxLon;
    var insideLat = lat >= cell.minLat && lat <= cell.maxLat;
    var insideHeight = height >= cell.minHeight && height <= cell.maxHeight;
    var center = CesiumRuntime.Cartesian3.fromDegrees(
      (cell.minLon + cell.maxLon) / 2,
      (cell.minLat + cell.maxLat) / 2,
      (cell.minHeight + cell.maxHeight) / 2
    );
    var score = CesiumRuntime.Cartesian3.distance(position, center);
    if (insideLon && insideLat) score *= insideHeight ? 0.01 : 0.12;
    if (score < bestScore) {
      bestScore = score;
      best = cell;
    }
  });
  return best;
}

function showFlightPathCurrentGridCell(cell) {
  var CesiumRuntime = window.Cesium;
  var edges = {};
  var primitive;
  if (!state.viewer || !CesiumRuntime) return;
  if (!cell || !state.flightPath.routeGridVisible) {
    removeFlightPathCurrentGridPrimitive();
    return;
  }
  if (state.flightPath.playback.currentGridIndex === cell.index) return;
  removeFlightPathCurrentGridPrimitive();
  addBoxEdges(edges, cell, 0);
  primitive = new CesiumRuntime.PolylineCollection();
  Object.keys(edges).forEach(function (key) {
    var edge = edges[key];
    primitive.add({
      positions: [
        CesiumRuntime.Cartesian3.fromDegrees(edge.lon1, edge.lat1, edge.h1),
        CesiumRuntime.Cartesian3.fromDegrees(edge.lon2, edge.lat2, edge.h2)
      ],
      width: 5.5,
      material: CesiumRuntime.Material.fromType(CesiumRuntime.Material.ColorType || 'Color', {
        color: CesiumRuntime.Color.fromCssColorString('#fff176').withAlpha(0.98)
      })
    });
  });
  state.flightPath.playback.currentGridPrimitive = state.viewer.scene.primitives.add(primitive);
  state.flightPath.playback.currentGridIndex = cell.index;
}

function flightPathPlaybackModeLabel(mode) {
  if (mode === 'fpv') return 'FPV Camera';
  if (mode === 'cinematic') return 'Cinematic';
  return 'Chase Camera';
}

function scaledCartesian(CesiumRuntime, vector, scale) {
  return CesiumRuntime.Cartesian3.multiplyByScalar(vector, scale, new CesiumRuntime.Cartesian3());
}

function addCartesianTerms(CesiumRuntime, origin, terms) {
  var result = CesiumRuntime.Cartesian3.clone(origin, new CesiumRuntime.Cartesian3());
  terms.forEach(function (term) {
    CesiumRuntime.Cartesian3.add(result, term, result);
  });
  return result;
}

function smoothedPlaybackVector(name, target, blend) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var previous = playback[name];
  var next;
  if (!CesiumRuntime || !target) return target;
  next = previous
    ? CesiumRuntime.Cartesian3.lerp(previous, target, blend, new CesiumRuntime.Cartesian3())
    : CesiumRuntime.Cartesian3.clone(target, new CesiumRuntime.Cartesian3());
  CesiumRuntime.Cartesian3.normalize(next, next);
  playback[name] = CesiumRuntime.Cartesian3.clone(next, previous || new CesiumRuntime.Cartesian3());
  return next;
}

function currentFlightPathForward(position, lookAheadSeconds) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var lookAheadTime;
  var nextPosition;
  var direction;
  var distance;
  var up;
  if (!CesiumRuntime || !state.viewer || !position || !playback.sampledPosition) return null;
  lookAheadTime = CesiumRuntime.JulianDate.addSeconds(state.viewer.clock.currentTime, lookAheadSeconds, new CesiumRuntime.JulianDate());
  nextPosition = playback.sampledPosition.getValue(lookAheadTime) || playback.routePositions[Math.min(playback.currentIndex + 1, playback.routePositions.length - 1)];
  if (!nextPosition) return null;
  direction = CesiumRuntime.Cartesian3.subtract(nextPosition, position, new CesiumRuntime.Cartesian3());
  distance = CesiumRuntime.Cartesian3.magnitude(direction);
  if (!Number.isFinite(distance) || distance < 0.1) return null;
  CesiumRuntime.Cartesian3.normalize(direction, direction);
  up = CesiumRuntime.Ellipsoid.WGS84.geodeticSurfaceNormal(position, new CesiumRuntime.Cartesian3());
  return { direction: direction, up: up };
}

function setFlightPathCamera(destination, target, up, blend) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var smoothedDestination;
  var direction;
  var smoothedDirection;
  var smoothedUp;
  if (!CesiumRuntime || !state.viewer || !destination || !target || !up) return;
  smoothedDestination = playback.cameraPosition
    ? CesiumRuntime.Cartesian3.lerp(playback.cameraPosition, destination, blend, new CesiumRuntime.Cartesian3())
    : CesiumRuntime.Cartesian3.clone(destination, new CesiumRuntime.Cartesian3());
  playback.cameraPosition = CesiumRuntime.Cartesian3.clone(smoothedDestination, playback.cameraPosition || new CesiumRuntime.Cartesian3());
  direction = CesiumRuntime.Cartesian3.subtract(target, smoothedDestination, new CesiumRuntime.Cartesian3());
  CesiumRuntime.Cartesian3.normalize(direction, direction);
  smoothedDirection = smoothedPlaybackVector('cameraDirection', direction, Math.min(Math.max(blend * 1.35, 0.08), 0.5));
  smoothedUp = smoothedPlaybackVector('cameraUp', up, Math.min(Math.max(blend, 0.06), 0.35));
  state.viewer.camera.setView({
    destination: smoothedDestination,
    orientation: {
      direction: smoothedDirection,
      up: smoothedUp
    }
  });
}

function updateFlightPathPlaybackCamera(position) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var forward;
  var direction;
  var up;
  var behind;
  var lift;
  var side;
  var destination;
  var target;
  var progress;
  var phase;
  var orbit;
  if (!CesiumRuntime || !state.viewer || !position || !playback.followEnabled || !playback.sampledPosition) return;
  forward = currentFlightPathForward(position, playback.mode === 'fpv' ? 2.2 : Math.min(4.5, Math.max(playback.duration * 0.035, 1.4)));
  if (!forward) return;
  direction = forward.direction;
  up = forward.up;
  side = CesiumRuntime.Cartesian3.cross(direction, up, new CesiumRuntime.Cartesian3());
  if (CesiumRuntime.Cartesian3.magnitude(side) < 0.001) side = CesiumRuntime.Cartesian3.clone(CesiumRuntime.Cartesian3.UNIT_X, side);
  CesiumRuntime.Cartesian3.normalize(side, side);

  if (playback.mode === 'fpv') {
    destination = addCartesianTerms(CesiumRuntime, position, [
      scaledCartesian(CesiumRuntime, up, 10),
      scaledCartesian(CesiumRuntime, direction, 3)
    ]);
    target = addCartesianTerms(CesiumRuntime, destination, [
      scaledCartesian(CesiumRuntime, direction, 1200),
      scaledCartesian(CesiumRuntime, up, -18)
    ]);
    setFlightPathCamera(destination, target, up, 0.28);
    return;
  }

  if (playback.mode === 'cinematic') {
    progress = playback.progress || 0;
    if (progress < 0.18) {
      phase = progress / 0.18;
      destination = addCartesianTerms(CesiumRuntime, position, [
        scaledCartesian(CesiumRuntime, direction, -760 + 500 * phase),
        scaledCartesian(CesiumRuntime, up, 520 - 380 * phase),
        scaledCartesian(CesiumRuntime, side, 120)
      ]);
      target = addCartesianTerms(CesiumRuntime, position, [scaledCartesian(CesiumRuntime, direction, 70)]);
      setFlightPathCamera(destination, target, up, 0.055);
      return;
    }
    if (progress < 0.72) {
      phase = (progress - 0.18) / 0.54;
      destination = addCartesianTerms(CesiumRuntime, position, [
        scaledCartesian(CesiumRuntime, direction, -240),
        scaledCartesian(CesiumRuntime, up, 112),
        scaledCartesian(CesiumRuntime, side, 165 * Math.sin(phase * Math.PI))
      ]);
      target = addCartesianTerms(CesiumRuntime, position, [scaledCartesian(CesiumRuntime, direction, 120)]);
      setFlightPathCamera(destination, target, up, 0.075);
      return;
    }
    if (progress < 0.90) {
      phase = (progress - 0.72) / 0.18;
      orbit = Math.PI * phase;
      destination = addCartesianTerms(CesiumRuntime, position, [
        scaledCartesian(CesiumRuntime, direction, -260 * Math.cos(orbit)),
        scaledCartesian(CesiumRuntime, side, 260 * Math.sin(orbit)),
        scaledCartesian(CesiumRuntime, up, 128)
      ]);
      target = addCartesianTerms(CesiumRuntime, position, [scaledCartesian(CesiumRuntime, direction, 95)]);
      setFlightPathCamera(destination, target, up, 0.06);
      return;
    }
    phase = (progress - 0.90) / 0.10;
    destination = addCartesianTerms(CesiumRuntime, position, [
      scaledCartesian(CesiumRuntime, direction, -300 - 920 * phase),
      scaledCartesian(CesiumRuntime, up, 160 + 620 * phase),
      scaledCartesian(CesiumRuntime, side, 170)
    ]);
    target = addCartesianTerms(CesiumRuntime, position, [scaledCartesian(CesiumRuntime, direction, 50)]);
    setFlightPathCamera(destination, target, up, 0.045);
    return;
  }

  behind = CesiumRuntime.Cartesian3.multiplyByScalar(direction, -170, new CesiumRuntime.Cartesian3());
  lift = CesiumRuntime.Cartesian3.multiplyByScalar(up, 72, new CesiumRuntime.Cartesian3());
  destination = addCartesianTerms(CesiumRuntime, position, [behind, lift]);
  target = addCartesianTerms(CesiumRuntime, position, [scaledCartesian(CesiumRuntime, direction, 35)]);
  setFlightPathCamera(destination, target, up, 0.14);
}

function updateFlightPathPlaybackFrame() {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var elapsed;
  var progress;
  var distance;
  var position;
  var cartographic;
  var cell;
  var slider = $('#flightPlaybackProgress');
  if (!CesiumRuntime || !state.viewer || !playback.sampledPosition || !playback.clockStart) return;
  elapsed = playbackElapsedSeconds();
  progress = playback.duration > 0 ? Math.min(Math.max(elapsed / playback.duration, 0), 1) : 0;
  distance = playback.totalDistance * progress;
  position = playback.sampledPosition.getValue(state.viewer.clock.currentTime) || playback.routePositions[playback.routePositions.length - 1];
  playback.progress = progress;
  playback.currentIndex = currentFlightPathPlaybackIndex(distance);
  if (slider && document.activeElement !== slider) slider.value = String(Math.round(progress * 1000));
  cartographic = position && CesiumRuntime.Ellipsoid.WGS84.cartesianToCartographic(position);
  cell = findNearestFlightPathGridCell(position);
  showFlightPathCurrentGridCell(cell);
  if ($('#flightReplayProgress')) $('#flightReplayProgress').textContent = Math.round(progress * 100) + '%';
  if ($('#flightReplayAltitude')) $('#flightReplayAltitude').textContent = cartographic ? cartographic.height.toFixed(1) + 'm' : '--';
  if ($('#flightReplaySpeed')) $('#flightReplaySpeed').textContent = playback.baseSpeed.toFixed(1) + 'm/s ×' + playback.speedMultiplier;
  if ($('#flightReplayDistance')) $('#flightReplayDistance').textContent = formatFlightDistance(distance, playback.totalDistance);
  if ($('#flightReplayMode')) $('#flightReplayMode').textContent = playback.followEnabled ? flightPathPlaybackModeLabel(playback.mode) : (playback.playing ? 'Free Camera' : 'Paused');
  if ($('#flightReplayGrid')) $('#flightReplayGrid').textContent = cell && cell.code ? cell.code : '--';
  updateFlightPathPlaybackCamera(position);
  if (progress >= 1 && playback.playing) {
    state.viewer.clock.shouldAnimate = false;
    playback.playing = false;
    if ($('#flightReplayMode')) $('#flightReplayMode').textContent = 'Complete';
  }
}

function setupFlightPathPlayback(autoplay) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var samples;
  if (!state.viewer || !CesiumRuntime) return false;
  if (!state.flightPath.latestResult || state.flightPath.latestResult.result_status !== 'success') {
    log('请先计算或载入一条成功的飞行路径结果。');
    return false;
  }
  if (playback.entity && playback.sampledPosition) return true;
  samples = buildFlightPathPlaybackSamples(state.flightPath.latestResult);
  if (!samples) {
    log('当前路径结果没有足够的 GeoJSON 坐标用于回放。');
    return false;
  }
  playback.clockStart = samples.start;
  playback.clockStop = samples.stop;
  playback.sampledPosition = samples.sampled;
  playback.routePositions = samples.positions;
  playback.cumulativeDistances = samples.cumulative;
  playback.totalDistance = samples.totalDistance;
  playback.duration = samples.duration;
  playback.baseSpeed = samples.baseSpeed;
  playback.gridCells = flightPathGridCellsFromResult(state.flightPath.latestResult);
  playback.entity = state.viewer.entities.add({
    name: 'Flight path replay aircraft',
    availability: new CesiumRuntime.TimeIntervalCollection([new CesiumRuntime.TimeInterval({ start: samples.start, stop: samples.stop })]),
    position: samples.sampled,
    orientation: CesiumRuntime.VelocityOrientationProperty ? new CesiumRuntime.VelocityOrientationProperty(samples.sampled) : undefined,
    point: {
      pixelSize: 15,
      color: CesiumRuntime.Color.fromCssColorString('#fff7df'),
      outlineColor: CesiumRuntime.Color.fromCssColorString('#00f5d4'),
      outlineWidth: 4,
      disableDepthTestDistance: Number.POSITIVE_INFINITY
    },
    label: {
      text: 'UAV',
      font: '700 12px Microsoft YaHei',
      fillColor: CesiumRuntime.Color.WHITE,
      outlineColor: CesiumRuntime.Color.BLACK,
      outlineWidth: 2,
      style: CesiumRuntime.LabelStyle.FILL_AND_OUTLINE,
      pixelOffset: new CesiumRuntime.Cartesian2(15, -20),
      disableDepthTestDistance: Number.POSITIVE_INFINITY
    },
    path: {
      resolution: 1,
      leadTime: 0,
      trailTime: Math.max(samples.duration, 1),
      width: 5,
      material: CesiumRuntime.Color.fromCssColorString('#00f5d4').withAlpha(0.78)
    }
  });
  playback.glowEntity = state.viewer.entities.add({
    name: 'Flight path replay current marker glow',
    position: samples.sampled,
    point: {
      pixelSize: 34,
      color: CesiumRuntime.Color.fromCssColorString('#00f5d4').withAlpha(0.22),
      outlineColor: CesiumRuntime.Color.fromCssColorString('#fff176').withAlpha(0.65),
      outlineWidth: 2,
      disableDepthTestDistance: Number.POSITIVE_INFINITY
    }
  });
  state.viewer.clock.startTime = CesiumRuntime.JulianDate.clone(samples.start);
  state.viewer.clock.stopTime = CesiumRuntime.JulianDate.clone(samples.stop);
  state.viewer.clock.currentTime = CesiumRuntime.JulianDate.clone(samples.start);
  state.viewer.clock.clockRange = CesiumRuntime.ClockRange.CLAMPED;
  state.viewer.clock.multiplier = playback.speedMultiplier;
  playback.cameraListener = updateFlightPathPlaybackFrame;
  state.viewer.scene.preRender.addEventListener(playback.cameraListener);
  playback.followEnabled = autoplay ? true : playback.followEnabled;
  playback.playing = Boolean(autoplay);
  state.viewer.clock.shouldAnimate = Boolean(autoplay);
  syncFlightPathPlaybackButtons();
  updateFlightPathPlaybackFrame();
  return true;
}

function playFlightPathPlayback() {
  if (!setupFlightPathPlayback(true)) return;
  if (state.flightPath.playback.progress >= 0.999 && state.flightPath.playback.clockStart) {
    state.viewer.clock.currentTime = Cesium.JulianDate.clone(state.flightPath.playback.clockStart);
    state.flightPath.playback.cameraPosition = null;
  }
  state.flightPath.playback.playing = true;
  state.flightPath.playback.followEnabled = true;
  state.viewer.clock.shouldAnimate = true;
  state.viewer.clock.multiplier = state.flightPath.playback.speedMultiplier;
  syncFlightPathPlaybackButtons();
  log('航迹回放已开始：' + flightPathPlaybackModeLabel(state.flightPath.playback.mode) + ' 正在跟随飞行器。');
}

function pauseFlightPathPlayback() {
  if (!state.viewer || !state.flightPath.playback.sampledPosition) return;
  state.viewer.clock.shouldAnimate = false;
  state.flightPath.playback.playing = false;
  updateFlightPathPlaybackFrame();
  log('航迹回放已暂停。');
}

function stopFlightPathPlayback() {
  clearFlightPathPlayback();
  log('航迹回放已停止并重置。');
}

function toggleFlightPathFollow() {
  var playback = state.flightPath.playback;
  if (!playback.sampledPosition && !setupFlightPathPlayback(false)) return;
  playback.followEnabled = !playback.followEnabled;
  playback.cameraPosition = null;
  playback.cameraDirection = null;
  playback.cameraUp = null;
  syncFlightPathPlaybackButtons();
  log(playback.followEnabled ? flightPathPlaybackModeLabel(playback.mode) + ' 已开启。' : '跟随镜头已关闭，可自由操作相机。');
}

function setFlightPathPlaybackSpeed(speed) {
  var playback = state.flightPath.playback;
  var nextSpeed = Number(speed);
  if (!Number.isFinite(nextSpeed) || nextSpeed <= 0) nextSpeed = 1;
  playback.speedMultiplier = nextSpeed;
  if (state.viewer) state.viewer.clock.multiplier = nextSpeed;
  syncFlightPathPlaybackButtons();
  updateFlightPathPlaybackFrame();
  log('航迹回放倍速：' + nextSpeed + 'x。');
}

function setFlightPathPlaybackMode(mode) {
  var playback = state.flightPath.playback;
  var nextMode = ['chase', 'fpv', 'cinematic'].indexOf(mode) >= 0 ? mode : 'chase';
  playback.mode = nextMode;
  playback.cameraPosition = null;
  playback.cameraDirection = null;
  playback.cameraUp = null;
  if (playback.sampledPosition) {
    playback.followEnabled = true;
    updateFlightPathPlaybackFrame();
  }
  syncFlightPathPlaybackButtons();
  log('航迹镜头模式：' + flightPathPlaybackModeLabel(nextMode) + '。');
}

function seekFlightPathPlayback(value) {
  var CesiumRuntime = window.Cesium;
  var playback = state.flightPath.playback;
  var ratio = Number(value) / 1000;
  if (!Number.isFinite(ratio)) ratio = 0;
  ratio = Math.min(Math.max(ratio, 0), 1);
  if (!playback.sampledPosition && !setupFlightPathPlayback(false)) return;
  state.viewer.clock.currentTime = CesiumRuntime.JulianDate.addSeconds(playback.clockStart, playback.duration * ratio, new CesiumRuntime.JulianDate());
  updateFlightPathPlaybackFrame();
}

function renderFlightPathDraft() {
  var CesiumRuntime = window.Cesium;
  var points = normalizedFlightPathPoints(state.flightPath.points);
  var list = $('#flightPathPointList');
  var positions;
  state.flightPath.points = points;
  clearFlightPathPointEntities();
  if (list) {
    list.innerHTML = points.length ? points.map(function (point) {
      return '<div class="flight-path-point-item">' +
        '<strong>' + escapeHtml(point.seq + 1) + '. ' + escapeHtml(flightPathRoleLabel(point.role)) + ' · ' + escapeHtml(point.name || '') + '</strong>' +
        '<span>' + escapeHtml(point.lon.toFixed(6)) + ', ' + escapeHtml(point.lat.toFixed(6)) + ' · ' + escapeHtml(flightPathPointSummary(point)) + '</span>' +
      '</div>';
    }).join('') : '<div class="feature-empty">尚未设置起点和终点。</div>';
  }
  if (!state.viewer || !CesiumRuntime) return;
  positions = points.map(function (point) {
    return CesiumRuntime.Cartesian3.fromDegrees(point.lon, point.lat, flightPathDisplayHeight(point));
  });
  points.forEach(function (point, index) {
    var color = point.role === 'start' ? '#2ef29f' : (point.role === 'end' ? '#ff4d3d' : '#4cc9f0');
    state.flightPath.pointEntities.push(state.viewer.entities.add({
      name: 'Flight path ' + flightPathRoleLabel(point.role),
      position: CesiumRuntime.Cartesian3.fromDegrees(point.lon, point.lat, flightPathDisplayHeight(point)),
      point: {
        pixelSize: point.role === 'waypoint' ? 10 : 13,
        color: CesiumRuntime.Color.fromCssColorString(color),
        outlineColor: CesiumRuntime.Color.WHITE,
        outlineWidth: 2,
        disableDepthTestDistance: Number.POSITIVE_INFINITY
      },
      label: {
        text: point.role === 'waypoint' ? String(index) : flightPathRoleLabel(point.role),
        font: '13px sans-serif',
        fillColor: CesiumRuntime.Color.WHITE,
        outlineColor: CesiumRuntime.Color.BLACK,
        outlineWidth: 2,
        style: CesiumRuntime.LabelStyle.FILL_AND_OUTLINE,
        pixelOffset: new CesiumRuntime.Cartesian2(12, -14),
        disableDepthTestDistance: Number.POSITIVE_INFINITY
      }
    }));
  });
  if (positions.length >= 2) {
    state.flightPath.rawLineEntity = state.viewer.entities.add({
      name: 'Flight path control polyline',
      polyline: {
        positions: positions,
        width: 2,
        material: CesiumRuntime.Color.fromCssColorString('#fff7df').withAlpha(0.55),
        depthFailMaterial: CesiumRuntime.Color.fromCssColorString('#fff7df').withAlpha(0.55)
      }
    });
  }
}

function setFlightPathDrawMode(role) {
  state.flightPath.drawMode = role;
  log('路径取点模式：请在地图上点击设置' + flightPathRoleLabel(role) + '。');
}

function addFlightPathPoint(position) {
  var point = pickLonLatFromScreen(position);
  var role = state.flightPath.drawMode || 'waypoint';
  var height = flightPathHeight();
  var datum = ($('#flightPathHeightDatum') && $('#flightPathHeightDatum').value) || 'AMSL';
  var terrainHeight = Number.isFinite(point && point.height) ? point.height : null;
  var nextPoint;
  if (!point) {
    log('无法从当前点击位置读取经纬度，请点击地球表面。');
    return;
  }
  nextPoint = {
    role: role,
    name: flightPathRoleLabel(role),
    lon: point.lon,
    lat: point.lat,
    height_m: height,
    height_datum: datum,
    terrain_height_m: terrainHeight,
    effective_height_m: datum === 'AGL' ? (Number.isFinite(terrainHeight) ? terrainHeight + height : height) : height
  };
  if (role === 'start') {
    state.flightPath.points = [nextPoint].concat(state.flightPath.points.filter(function (item) { return item.role !== 'start'; }));
  } else if (role === 'end') {
    state.flightPath.points = state.flightPath.points.filter(function (item) { return item.role !== 'end'; }).concat([nextPoint]);
  } else {
    state.flightPath.points = state.flightPath.points.filter(function (item) { return item.role !== 'end'; }).concat([nextPoint], state.flightPath.points.filter(function (item) { return item.role === 'end'; }));
  }
  state.flightPath.points = normalizedFlightPathPoints(state.flightPath.points);
  clearFlightPathRoute();
  renderFlightPathDraft();
  log('已添加' + flightPathRoleLabel(role) + '：' + point.lon.toFixed(6) + ', ' + point.lat.toFixed(6) + ' @ ' + flightPathPointSummary(nextPoint) + '。');
}

function undoFlightPathPoint() {
  var points = state.flightPath.points.slice();
  var waypointIndex = -1;
  points.forEach(function (point, index) { if (point.role === 'waypoint') waypointIndex = index; });
  if (waypointIndex >= 0) points.splice(waypointIndex, 1);
  else if (points.length) points.pop();
  state.flightPath.points = normalizedFlightPathPoints(points);
  clearFlightPathRoute();
  renderFlightPathDraft();
  log('已撤销一个路径控制点。');
}

function clearFlightPathDraft() {
  state.flightPath.currentPlanId = null;
  state.flightPath.drawMode = null;
  state.flightPath.points = [];
  clearFlightPathRoute();
  renderFlightPathDraft();
  log('已清空当前路径草稿。');
}

function flightPathPayload() {
  var points = normalizedFlightPathPoints(state.flightPath.points);
  var name = ($('#flightPathName') && $('#flightPathName').value || '').trim();
  var planningTime = isoFromDateTimeLocal($('#flightPathPlanningTime') && $('#flightPathPlanningTime').value) || new Date().toISOString();
  if (!name) throw new Error('请填写路径方案名称。');
  if (points.length < 2 || points[0].role !== 'start' || points[points.length - 1].role !== 'end') {
    throw new Error('请至少设置起点和终点；途径点必须位于两者之间。');
  }
  return {
    p_name: name,
    p_description: 'created from tianditu-3d.html',
    p_detail_level: flightPathDetailLevel(),
    p_cruise_height_m: flightPathHeight(),
    p_height_datum: ($('#flightPathHeightDatum') && $('#flightPathHeightDatum').value) || 'AMSL',
    p_planning_time: planningTime,
    p_points: points.map(function (point) {
      return {
        role: point.role,
        name: point.name || flightPathRoleLabel(point.role),
        lon: point.lon,
        lat: point.lat,
        height_m: point.height_m,
        height_datum: point.height_datum || 'AMSL',
        metadata: {
          terrain_height_m: Number.isFinite(point.terrain_height_m) ? point.terrain_height_m : null,
          effective_height_m: flightPathDisplayHeight(point)
        }
      };
    }),
    p_has_below: false,
    p_safety_buffer_m: 0,
    p_metadata: { cruise_speed_mps: flightPathSpeed() }
  };
}

function saveFlightPathPlan() {
  var payload;
  try {
    payload = flightPathPayload();
  } catch (error) {
    log(error.message);
    return Promise.reject(error);
  }
  state.flightPath.loading = true;
  if (state.flightPath.currentPlanId != null) {
    payload.p_plan_id = state.flightPath.currentPlanId;
    log('正在更新飞行路径方案 #' + state.flightPath.currentPlanId + '。');
    return rpc('update_flight_path_plan', payload).then(function () {
      log('飞行路径方案已更新：#' + state.flightPath.currentPlanId + '。');
      return loadFlightPathPlans();
    }).finally(function () { state.flightPath.loading = false; });
  }
  log('正在保存新的飞行路径方案。');
  return rpc('create_flight_path_plan', payload).then(function (planId) {
    state.flightPath.currentPlanId = planId;
    log('飞行路径方案已保存：#' + planId + '。');
    return loadFlightPathPlans();
  }).finally(function () { state.flightPath.loading = false; });
}

function renderFlightPathPlanList() {
  var list = $('#flightPathPlanList');
  var rows = state.flightPath.plans;
  if (!list) return;
  if (!rows.length) {
    list.innerHTML = '<div class="feature-empty">暂无飞行路径方案。</div>';
    return;
  }
  list.innerHTML = rows.map(function (plan) {
    return '<div class="flight-path-plan-item" data-plan-id="' + escapeHtml(plan.id) + '">' +
      '<strong>#' + escapeHtml(plan.id) + ' · ' + escapeHtml(plan.name || '(unnamed)') + '</strong>' +
      '<span>' + escapeHtml(plan.status) + ' · points ' + escapeHtml(plan.point_count || 0) + ' · waypoints ' + escapeHtml(plan.waypoint_count || 0) + ' · ' + escapeHtml(plan.cruise_height_m == null ? '--' : plan.cruise_height_m) + 'm ' + escapeHtml(plan.height_datum || 'AMSL') + '</span>' +
      '<div class="admin-actions">' +
        '<button type="button" data-action="loadFlightPathPlan" data-plan-id="' + escapeHtml(plan.id) + '">载入</button>' +
        '<button type="button" data-action="computeListedFlightPathPlan" data-plan-id="' + escapeHtml(plan.id) + '">计算</button>' +
        '<button type="button" data-action="archiveFlightPathPlan" data-plan-id="' + escapeHtml(plan.id) + '">归档</button>' +
      '</div>' +
    '</div>';
  }).join('');
}

function loadFlightPathPlans() {
  state.flightPath.loading = true;
  return rpc('list_flight_path_plans', { p_limit: 20, p_offset: 0 }).then(function (data) {
    state.flightPath.plans = data && Array.isArray(data.items) ? data.items : [];
    renderFlightPathPlanList();
    log('已加载飞行路径方案：' + state.flightPath.plans.length + ' 条。');
  }).catch(function (error) {
    console.error('[Tianditu3D] Flight path list failed:', error);
    if ($('#flightPathPlanList')) $('#flightPathPlanList').innerHTML = '<div class="feature-error">飞行路径方案加载失败：' + escapeHtml(error.message) + '</div>';
    log('飞行路径方案加载失败：' + error.message);
  }).finally(function () { state.flightPath.loading = false; });
}

function loadFlightPathPlan(planId) {
  return rpc('get_flight_path_plan', { p_plan_id: Number(planId) }).then(function (data) {
    var plan = data && data.plan;
    var points = data && Array.isArray(data.points) ? data.points : [];
    if (!plan) throw new Error('未找到飞行路径方案 #' + planId);
    state.flightPath.currentPlanId = plan.id;
    $('#flightPathName').value = plan.name || '';
    $('#flightPathHeight').value = plan.cruise_height_m == null ? '120' : plan.cruise_height_m;
    $('#flightPathDetailLevel').value = plan.detail_level || 19;
    $('#flightPathHeightDatum').value = plan.height_datum || 'AMSL';
    $('#flightPathPlanningTime').value = plan.planning_time ? formatDateTimeLocal(new Date(plan.planning_time)) : formatDateTimeLocal(new Date());
    $('#flightPathSpeed').value = plan.metadata && plan.metadata.cruise_speed_mps ? plan.metadata.cruise_speed_mps : 10;
    state.flightPath.points = normalizedFlightPathPoints(points.map(function (point) {
      return {
        role: point.point_role,
        name: point.name,
        lon: Number(point.lon),
        lat: Number(point.lat),
        height_m: Number(point.height_m == null ? plan.cruise_height_m || 120 : point.height_m),
        height_datum: point.height_datum || plan.height_datum || 'AMSL',
        terrain_height_m: point.metadata && Number.isFinite(Number(point.metadata.terrain_height_m)) ? Number(point.metadata.terrain_height_m) : null,
        effective_height_m: point.metadata && Number.isFinite(Number(point.metadata.effective_height_m)) ? Number(point.metadata.effective_height_m) : null
      };
    }));
    clearFlightPathRoute();
    renderFlightPathDraft();
    log('已载入飞行路径方案 #' + plan.id + '。');
    return loadLatestFlightPathResult(plan.id, false);
  }).catch(function (error) {
    console.error('[Tianditu3D] Flight path load failed:', error);
    log('飞行路径方案载入失败：' + error.message);
  });
}

function renderFlightPathResult(result) {
  var CesiumRuntime = window.Cesium;
  var coords = result && result.route_geojson && result.route_geojson.coordinates;
  var positions;
  clearFlightPathRoute();
  state.flightPath.latestResult = result || null;
  if (!result) return;
  if (result.result_status !== 'success') {
    log('路径计算失败：' + (result.error_message || '未知错误'));
    return;
  }
  if (!state.viewer || !CesiumRuntime || !Array.isArray(coords) || coords.length < 2) return;
  positions = coords.map(function (coord) {
    return CesiumRuntime.Cartesian3.fromDegrees(Number(coord[0]), Number(coord[1]), Number(coord[2] || flightPathHeight()));
  });
  state.flightPath.routeGlowEntity = state.viewer.entities.add({
    name: 'Flight path planned route glow',
    polyline: {
      positions: positions,
      width: 9,
      material: CesiumRuntime.Color.fromCssColorString('#00f5d4').withAlpha(0.22),
      depthFailMaterial: CesiumRuntime.Color.fromCssColorString('#00f5d4').withAlpha(0.22)
    }
  });
  state.flightPath.routeEntity = state.viewer.entities.add({
    name: 'Flight path planned route',
    polyline: {
      positions: positions,
      width: 4,
      material: CesiumRuntime.Color.fromCssColorString('#5eead4'),
      depthFailMaterial: CesiumRuntime.Color.fromCssColorString('#5eead4')
    }
  });
  if (state.flightPath.routeGridVisible) showFlightPathGrid(result);
  log('路径计算成功：' + (result.distance_m || 0).toFixed(1) + 'm，' + (result.grid_cell_count || 0) + ' cells，' + (result.traj_point_count || 0) + ' trajectory points。');
}

function loadLatestFlightPathResult(planId, shouldZoom) {
  return rpc('get_latest_flight_path_result', { p_plan_id: Number(planId) }).then(function (result) {
    renderFlightPathResult(result);
    if (shouldZoom) zoomFlightPathRoute();
    return result;
  }).catch(function (error) {
    console.error('[Tianditu3D] Flight path result failed:', error);
    log('飞行路径结果加载失败：' + error.message);
  });
}

function computeFlightPathPlan(planId) {
  var id = planId || state.flightPath.currentPlanId;
  var afterSave;
  if (!id) {
    afterSave = saveFlightPathPlan().then(function () { return state.flightPath.currentPlanId; });
  } else if (String(id) === String(state.flightPath.currentPlanId)) {
    afterSave = saveFlightPathPlan().then(function () { return state.flightPath.currentPlanId; });
  } else {
    afterSave = Promise.resolve(Number(id));
  }
  return afterSave.then(function (savedId) {
    log('正在计算飞行路径方案 #' + savedId + '；将自动避开 flight_obstacles。');
    return rpc('compute_flight_path_plan', { p_plan_id: Number(savedId) }).then(function (resultId) {
      log('路径计算已完成，结果 #' + resultId + '，正在加载 GeoJSON。');
      state.flightPath.currentPlanId = Number(savedId);
      return loadLatestFlightPathResult(savedId, true);
    });
  }).catch(function (error) {
    console.error('[Tianditu3D] Flight path compute failed:', error);
    log('飞行路径计算失败：' + error.message);
  });
}

function archiveFlightPathPlan(planId) {
  if (!window.confirm('确认归档飞行路径方案 #' + planId + '？')) return Promise.resolve();
  return rpc('archive_flight_path_plan', { p_plan_id: Number(planId) }).then(function () {
    if (String(state.flightPath.currentPlanId) === String(planId)) clearFlightPathDraft();
    log('飞行路径方案已归档：#' + planId + '。');
    return loadFlightPathPlans();
  }).catch(function (error) {
    console.error('[Tianditu3D] Flight path archive failed:', error);
    log('飞行路径方案归档失败：' + error.message);
  });
}

function zoomFlightPathRoute() {
  var entities = [];
  if (state.flightPath.routeEntity) entities.push(state.flightPath.routeEntity);
  if (!entities.length && state.flightPath.rawLineEntity) entities.push(state.flightPath.rawLineEntity);
  if (!entities.length) entities = state.flightPath.pointEntities.slice();
  if (!state.viewer || !entities.length) {
    log('当前没有可定位的飞行路径。');
    return;
  }
  state.viewer.flyTo(entities, { duration: 1.5 });
  log('已定位到当前飞行路径。');
}


        function html() {
            return '    <div class="flight-path-controls" aria-label="飞行路径规划">\n      <h2>Flight Path Planner</h2>\n      <div class="control-grid">\n        <label class="field">方案名称\n          <input id="flightPathName" type="text" value="花果山低空路径" />\n        </label>\n        <label class="field">巡航高度 m\n          <input id="flightPathHeight" type="number" step="1" value="120" />\n        </label>\n        <label class="field">网格层级\n          <input id="flightPathDetailLevel" type="number" min="1" max="32" step="1" value="19" />\n        </label>\n        <label class="field">巡航速度 m/s\n          <input id="flightPathSpeed" type="number" min="0.1" step="0.1" value="10" />\n        </label>\n        <label class="field">规划时间\n          <input id="flightPathPlanningTime" type="datetime-local" />\n        </label>\n        <label class="field">高度基准\n          <select id="flightPathHeightDatum">\n            <option value="AMSL" selected>海拔高度 AMSL</option>\n            <option value="AGL">离地高度 AGL</option>\n            <option value="ELLIPSOID">椭球高 ELLIPSOID</option>\n          </select>\n        </label>\n      </div>\n      <div class="draw-actions" aria-label="路径控制点编辑">\n        <button type="button" data-action="setFlightPathStart">点选起点</button>\n        <button type="button" data-action="addFlightPathWaypoint">点选途径点</button>\n        <button type="button" data-action="setFlightPathEnd">点选终点</button>\n        <button type="button" data-action="undoFlightPathPoint">撤销点</button>\n        <button type="button" data-action="clearFlightPathDraft">清空</button>\n      </div>\n      <div class="admin-actions">\n        <button class="primary" type="button" data-action="saveFlightPathPlan">保存路径</button>\n        <button type="button" data-action="computeFlightPathPlan">计算路径</button>\n        <button type="button" data-action="reloadFlightPathPlans">刷新方案</button>\n        <button type="button" data-action="zoomFlightPathRoute">定位路径</button>\n        <button type="button" data-action="toggleFlightPathGrid" aria-pressed="true">路径网格</button>\n      </div>\n      <div class="playback-actions" aria-label="航迹回放控制">\n        <button class="primary" type="button" data-action="playFlightPathPlayback">播放航迹</button>\n        <button type="button" data-action="pauseFlightPathPlayback">暂停</button>\n        <button type="button" data-action="stopFlightPathPlayback">停止</button>\n        <button type="button" data-action="toggleFlightPathFollow" aria-pressed="false">跟随镜头</button>\n        <div class="speed-actions" aria-label="航迹回放倍速">\n          <button type="button" data-action="setFlightPathPlaybackSpeed" data-speed="1" aria-pressed="true">1x</button>\n          <button type="button" data-action="setFlightPathPlaybackSpeed" data-speed="2" aria-pressed="false">2x</button>\n          <button type="button" data-action="setFlightPathPlaybackSpeed" data-speed="4" aria-pressed="false">4x</button>\n        </div>\n        <div class="mode-actions" aria-label="航迹回放镜头模式">\n          <button type="button" data-action="setFlightPathPlaybackMode" data-mode="chase" aria-pressed="true">追尾</button>\n          <button type="button" data-action="setFlightPathPlaybackMode" data-mode="fpv" aria-pressed="false">FPV</button>\n          <button type="button" data-action="setFlightPathPlaybackMode" data-mode="cinematic" aria-pressed="false">电影</button>\n        </div>\n        <label class="field flight-playback-slider">回放进度\n          <input id="flightPlaybackProgress" type="range" min="0" max="1000" step="1" value="0" />\n        </label>\n      </div>\n      <p class="admin-hint">点击“点选起点 / 途径点 / 终点”后在地图上取点；计算结果会写入 <code>flight_path.plan_result</code>，并生成 iBEST-DB <code>trajectory</code>。</p>\n      <div class="flight-path-point-list" id="flightPathPointList">\n        <div class="feature-empty">尚未设置起点和终点。</div>\n      </div>\n      <div class="flight-path-plan-list" id="flightPathPlanList">\n        <div class="feature-empty">尚未加载飞行路径方案。</div>\n      </div>\n    </div>\n';
        }

        function handleClick(event) {
            var button = event.target && event.target.closest('[data-action]');
            var action;
            if (!button || !rootEl || !rootEl.contains(button)) return;
            action = button.dataset.action;
            if (action === 'setFlightPathStart') setFlightPathDrawMode('start');
            if (action === 'addFlightPathWaypoint') setFlightPathDrawMode('waypoint');
            if (action === 'setFlightPathEnd') setFlightPathDrawMode('end');
            if (action === 'undoFlightPathPoint') undoFlightPathPoint();
            if (action === 'clearFlightPathDraft') clearFlightPathDraft();
            if (action === 'saveFlightPathPlan') saveFlightPathPlan().catch(function(error) { console.error('[FlightPathWorkbench] save failed:', error); renderError('飞行路径方案保存失败：' + error.message); log('飞行路径方案保存失败：' + error.message); });
            if (action === 'computeFlightPathPlan') computeFlightPathPlan();
            if (action === 'reloadFlightPathPlans') loadFlightPathPlans();
            if (action === 'zoomFlightPathRoute') zoomFlightPathRoute();
            if (action === 'toggleFlightPathGrid') toggleFlightPathGrid();
            if (action === 'playFlightPathPlayback') playFlightPathPlayback();
            if (action === 'pauseFlightPathPlayback') pauseFlightPathPlayback();
            if (action === 'stopFlightPathPlayback') stopFlightPathPlayback();
            if (action === 'toggleFlightPathFollow') toggleFlightPathFollow();
            if (action === 'setFlightPathPlaybackSpeed') setFlightPathPlaybackSpeed(button.dataset.speed);
            if (action === 'setFlightPathPlaybackMode') setFlightPathPlaybackMode(button.dataset.mode);
            if (action === 'loadFlightPathPlan') loadFlightPathPlan(button.dataset.planId);
            if (action === 'computeListedFlightPathPlan') computeFlightPathPlan(button.dataset.planId);
            if (action === 'archiveFlightPathPlan') archiveFlightPathPlan(button.dataset.planId);
        }

        function mount(container) {
            rootEl = container;
            rootEl.innerHTML = html();
            rootEl.addEventListener('click', handleClick);
            Cesium = getCesium();
            setupFlightPathDefaults();
            renderFlightPathDraft();
            resetFlightPathPlaybackUi();
            syncFlightPathPlaybackButtons();
            if ($('#flightPlaybackProgress')) {
                $('#flightPlaybackProgress').addEventListener('input', function() { seekFlightPathPlayback($('#flightPlaybackProgress').value); });
            }
            loadFlightPathPlans();
            return api;
        }

        function setViewer(viewer) {
            state.viewer = viewer;
            Cesium = getCesium();
        }

        function handleMapClick(position) {
            if (!state.flightPath.drawMode) return false;
            addFlightPathPoint(position);
            return true;
        }

        function destroy() {
            clearFlightPathDraft();
            if (rootEl) rootEl.removeEventListener('click', handleClick);
            rootEl = null;
        }

        var api = {
            mount: mount, setViewer: setViewer, loadPlans: loadFlightPathPlans, setDrawMode: setFlightPathDrawMode,
            handleMapClick: handleMapClick, isDrawing: function() { return Boolean(state.flightPath.drawMode); },
            savePlan: saveFlightPathPlan, computePlan: computeFlightPathPlan, destroy: destroy,
            _private: { normalizedFlightPathPoints: normalizedFlightPathPoints, flightPathGridCellsFromResult: flightPathGridCellsFromResult }
        };
        return api;
    }

    return { create: create };
}));
