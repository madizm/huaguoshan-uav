(function (global, factory) {
  'use strict';
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanSourceSituation = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  var SOURCE_STYLE = {
    radar: { color: '#f6c85f', label: '雷达' },
    radio_detection: { color: '#5eead4', label: '电侦' },
    10: { color: '#f6c85f', label: '雷达' },
    20: { color: '#5eead4', label: '电侦' }
  };
  var LEGACY_SOURCE_TYPE = { radar: 10, radio_detection: 20 };
  var MAX_TRACK_SPEED_MPS = 100;

  function $(selector) { return typeof document === 'undefined' ? null : document.querySelector(selector); }

  function addDays(dateText, days) {
    var parts = String(dateText || '').split('-').map(Number);
    if (parts.length !== 3 || parts.some(function (value) { return !Number.isFinite(value); })) return null;
    var date = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2] + days));
    return date.toISOString().slice(0, 10);
  }

  function buildHistoryPayload(startDate, inclusiveEndDate, sourceTypeCodes) {
    var exclusiveEnd = addDays(inclusiveEndDate, 1);
    if (!startDate || !exclusiveEnd || startDate > inclusiveEndDate) throw new Error('结束日期不能早于开始日期。');
    if ((Date.parse(exclusiveEnd) - Date.parse(startDate)) / 86400000 > 7) throw new Error('历史查询最多支持 7 天。');
    return {
      p_start_at: startDate + 'T00:00:00+08:00',
      p_end_at: exclusiveEnd + 'T00:00:00+08:00',
      p_station_ids: null,
      p_source_type_codes: sourceTypeCodes == null ? null : sourceTypeCodes,
      p_limit: 200
    };
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  function formatCount(value) { return Number(value || 0).toLocaleString('zh-CN'); }

  function formatTime(value) {
    if (!value) return '--';
    var date = new Date(value);
    if (!Number.isFinite(date.getTime())) return String(value).replace('T', ' ').slice(0, 19);
    return date.toLocaleString('zh-CN', { hour12: false });
  }

  function coordinates(point) {
    var values = point && point.position && point.position.coordinates;
    if (!Array.isArray(values) || values.length < 2) return null;
    var lon = Number(values[0]);
    var lat = Number(values[1]);
    return Number.isFinite(lon) && Number.isFinite(lat) ? [lon, lat] : null;
  }

  function groundSpeed(a, b) {
    var first = coordinates(a);
    var second = coordinates(b);
    if (!first || !second) return Number.POSITIVE_INFINITY;
    var meanLatitude = (first[1] + second[1]) * Math.PI / 360;
    var eastMetres = (second[0] - first[0]) * 111320 * Math.cos(meanLatitude);
    var northMetres = (second[1] - first[1]) * 110540;
    var distanceMetres = Math.sqrt(eastMetres * eastMetres + northMetres * northMetres);
    var elapsedSeconds = (Date.parse(b.observed_at) - Date.parse(a.observed_at)) / 1000;
    if (!(elapsedSeconds > 0)) return distanceMetres <= 1 ? 0 : Number.POSITIVE_INFINITY;
    return distanceMetres / elapsedSeconds;
  }

  function splitTrack(points, maximumSpeedMps) {
    var segments = [];
    var current = [];
    var jumpCount = 0;
    (points || []).filter(coordinates).forEach(function (point) {
      if (current.length && groundSpeed(current[current.length - 1], point) > maximumSpeedMps) {
        if (current.length > 1) segments.push(current);
        current = [];
        jumpCount += 1;
      }
      current.push(point);
    });
    if (current.length > 1) segments.push(current);
    return { segments: segments, jumpCount: jumpCount };
  }

  function selectedDetectionMethods(buttons) {
    return (buttons || []).filter(function (button) {
      return button.getAttribute('aria-pressed') === 'true';
    }).map(function (button) { return button.dataset.detectionMethod; });
  }
  function detectionMethodFilter(buttons) {
    var selected = selectedDetectionMethods(buttons);
    return selected.length === (buttons || []).length ? null : selected;
  }
  function legacySourceTypeFilter(buttons) {
    var supported = (buttons || []).filter(function (button) {
      return LEGACY_SOURCE_TYPE[button.dataset.detectionMethod] != null;
    });
    var selected = selectedDetectionMethods(supported);
    if (selected.length === supported.length) return null;
    return selected.map(function (code) { return LEGACY_SOURCE_TYPE[code]; });
  }

  function indexLiveTracks(tracks) {
    return (tracks || []).reduce(function (indexed, track) {
      indexed[String(track.track_id)] = Object.assign({}, track, { points: (track.points || []).slice() });
      return indexed;
    }, {});
  }

  function applyLiveChanges(trackMap, changes, referenceTime, trailSeconds, lostRetentionSeconds, acceptedSourceTypes) {
    var referenceMs = Date.parse(referenceTime);
    var cutoffMs = referenceMs - Number(trailSeconds || 300) * 1000;
    var lostCutoffMs = referenceMs - Number(lostRetentionSeconds || 60) * 1000;
    (changes || []).forEach(function (change) {
      var payload = change.payload || {};
      var trackId = payload.track_id;
      if (trackId == null) return;
      var key = String(trackId);
      var track = trackMap[key];
      if (change.type === 'target_remove') {
        if (track) {
          track.status = 'lost';
          track.lost_at = change.occurred_at;
        }
        return;
      }
      if (change.type !== 'target_upsert') return;
      if (acceptedSourceTypes && acceptedSourceTypes.indexOf(payload.detection_method_code) < 0) return;
      if (!track) {
        track = trackMap[key] = {
          track_id: Number(trackId),
          target_id: payload.target_id,
          track_code: payload.track_code,
          source_target_id: payload.source_target_id,
          source_type_code: payload.source_type_code,
          model: payload.model,
          latest_observation_method_code: payload.detection_method_code,
          points: []
        };
      }
      track.status = 'tracking';
      track.last_observed_at = payload.observed_at || change.occurred_at;
      ['track_code', 'source_target_id', 'source_type_code', 'model'].forEach(function (field) {
        if (payload[field] != null) track[field] = payload[field];
      });
      if (payload.detection_method_code != null) track.latest_observation_method_code = payload.detection_method_code;
      if (payload.position && payload.observation_id != null && !track.points.some(function (point) {
        return String(point.observation_id) === String(payload.observation_id);
      })) {
        track.points.push({
          observation_id: payload.observation_id,
          observed_at: payload.observed_at || change.occurred_at,
          position: payload.position,
          altitude_amsl_m: payload.altitude_amsl_m,
          source_type_code: payload.source_type_code,
          speed_mps: payload.speed_mps,
          detection_method_code: payload.detection_method_code,
          quality_flags: payload.quality_flags || []
        });
      }
    });
    Object.keys(trackMap).forEach(function (key) {
      var track = trackMap[key];
      track.points = (track.points || []).filter(function (point) {
        return Date.parse(point.observed_at) >= cutoffMs;
      }).sort(function (a, b) {
        return Date.parse(a.observed_at) - Date.parse(b.observed_at) || Number(a.observation_id) - Number(b.observation_id);
      });
      if (track.status === 'lost' && Date.parse(track.lost_at) < lostCutoffMs) delete trackMap[key];
    });
    return trackMap;
  }

  function sourceState(source, generatedAt) {
    if (!source || !source.enabled) return { code: 'disabled', label: '已停用' };
    if (source.connector_state !== 'connected') return { code: 'warning', label: '连接异常' };
    var ageSeconds = (Date.parse(generatedAt) - Date.parse(source.last_message_at)) / 1000;
    if (!Number.isFinite(ageSeconds) || ageSeconds > Math.max(120, Number(source.lost_timeout_seconds || 30) * 2)) {
      return { code: 'warning', label: '数据已延迟' };
    }
    return { code: 'ok', label: '接入正常' };
  }

  function realtimeSummaryHtml(payload) {
    var targets = payload && (payload.tracks || payload.targets) || [];
    var spatialCount = targets.filter(function (track) { return (track.points || []).length || track.position; }).length;
    var nonSpatialCount = targets.length - spatialCount;
    var sources = payload && payload.sources || [];
    var sourceCards = sources.map(function (source) {
      var state = sourceState(source, payload.generated_at);
      return '<article class="source-quality-card" data-quality="' + state.code + '">' +
        '<header><i style="--source-color:#5eead4"></i><strong>' + escapeHtml(source.name) + '</strong><span>' + state.label + '</span></header>' +
        '<dl><div><dt>空间目标</dt><dd>' + formatCount(spatialCount) + '</dd></div>' +
        '<div><dt>无坐标</dt><dd>' + formatCount(nonSpatialCount) + '</dd></div>' +
        '<div><dt>站点</dt><dd>' + escapeHtml(source.station_id) + '</dd></div></dl>' +
        '<p>最近消息 ' + formatTime(source.last_message_at) + '</p></article>';
    }).join('');
    if (!sourceCards) sourceCards = '<p class="source-situation-empty">没有可用侦测来源。</p>';
    if (!targets.length) sourceCards += '<p class="source-situation-empty">当前没有正在跟踪的目标。</p>';
    return sourceCards;
  }

  function historySummaryHtml(tracks) {
    if (!tracks || !tracks.length) return '<p class="source-situation-empty">所选时间区间没有航迹。</p>';
    return '<div class="detection-track-list">' + tracks.map(function (track) {
      var style = SOURCE_STYLE[track.source_type_code] || { color: '#9ba8a2', label: '来源待确认' };
      return '<button type="button" class="detection-track-row" data-track-id="' + Number(track.track_id) + '">' +
        '<span class="detection-track-main"><i style="--source-color:' + style.color + '"></i><strong>' +
        escapeHtml(track.model || track.source_target_id || track.track_code) + '</strong><small>' +
        escapeHtml(style.label + ' · ' + track.track_code) + '</small></span>' +
        '<span class="detection-track-count"><strong>' + formatCount(track.spatial_point_count) + '</strong><small>空间点</small></span>' +
        '<span class="detection-track-meta">' + formatTime(track.first_observed_at) + ' — ' + formatTime(track.last_observed_at) +
        (Number(track.flagged_observation_count) ? ' · ' + formatCount(track.flagged_observation_count) + ' 条待核验' : '') + '</span></button>';
    }).join('') + '</div>';
  }

  function createModule(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var viewer = options.viewer;
    var rpc = options.rpc;
    var log = options.log || function () {};
    var dataSources = {};
    var mode = 'realtime';
    var lastBounds = null;
    var refreshTimer = null;
    var destroyed = false;
    var requestSequence = 0;
    var liveTracks = {};
    var liveCursor = 0;
    var liveSources = [];
    var liveTrailSeconds = 300;
    var liveDetectionMethods = [];
    var livePolling = false;
    var loadButton = $('#sourceSituationLoad');
    var locateButton = $('#sourceSituationLocate');
    var clearButton = $('#sourceSituationClear');
    var summary = $('#sourceSituationSummary');
    var hint = $('#sourceSituationHint');
    var note = $('#sourceSituationNote');
    var startInput = $('#sourceSituationStart');
    var endInput = $('#sourceSituationEnd');
    var sourceToggleContainer = typeof document === 'undefined' ? null : document.querySelector('.source-situation-toggles');
    var sourceButtons = typeof document === 'undefined' ? [] : Array.prototype.slice.call(document.querySelectorAll('[data-detection-method]'));
    var modeButtons = typeof document === 'undefined' ? [] : Array.prototype.slice.call(document.querySelectorAll('[data-situation-mode]'));
    var disposers = [];

    function setDefaultDates() {
      var today = new Date();
      var localToday = new Date(today.getTime() - today.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
      if (startInput && !startInput.value) startInput.value = localToday;
      if (endInput && !endInput.value) endInput.value = localToday;
    }

    function stopRefresh() {
      if (refreshTimer) clearInterval(refreshTimer);
      refreshTimer = null;
    }

    function removeLayers() {
      Object.keys(dataSources).forEach(function (key) { viewer.dataSources.remove(dataSources[key], true); });
      dataSources = {};
      lastBounds = null;
      if (locateButton) locateButton.disabled = true;
      if (clearButton) clearButton.disabled = true;
    }

    function reset() {
      stopRefresh();
      requestSequence += 1;
      removeLayers();
      if (summary) summary.innerHTML = '<p class="source-situation-empty">尚未加载侦测态势。</p>';
      liveTracks = {};
      liveCursor = 0;
      liveSources = [];
      if (hint) hint.textContent = '未加载';
    }

    function addDataSource(sourceTypeCode, name) {
      var key = String(sourceTypeCode == null ? 'unknown' : sourceTypeCode);
      if (dataSources[key]) return dataSources[key];
      var dataSource = new CesiumRuntime.CustomDataSource(name || ('detection-' + key));
      var button = sourceButtons.find(function (item) { return item.dataset.detectionMethod === key; });
      dataSource.show = !button || button.getAttribute('aria-pressed') !== 'false';
      viewer.dataSources.add(dataSource);
      dataSources[key] = dataSource;
      return dataSource;
    }

    function pointPosition(point, fallbackHeight) {
      var values = coordinates(point);
      if (!values) return null;
      var hasHeight = point.altitude_amsl_m !== null && point.altitude_amsl_m !== undefined && point.altitude_amsl_m !== '';
      var height = Number(point.altitude_amsl_m);
      return CesiumRuntime.Cartesian3.fromDegrees(values[0], values[1], hasHeight && Number.isFinite(height) ? height : fallbackHeight);
    }

    function extendBounds(point) {
      var values = coordinates(point);
      if (!values) return;
      if (!lastBounds) lastBounds = { west: values[0], east: values[0], south: values[1], north: values[1] };
      lastBounds.west = Math.min(lastBounds.west, values[0]);
      lastBounds.east = Math.max(lastBounds.east, values[0]);
      lastBounds.south = Math.min(lastBounds.south, values[1]);
      lastBounds.north = Math.max(lastBounds.north, values[1]);
    }

    function renderRealtime(payload) {
      removeLayers();
      var tracks = payload.tracks || [];
      tracks.forEach(function (track) {
        var points = track.points || [];
        var methodCode = track.latest_observation_method_code ||
          (points.length && points[points.length - 1].detection_method_code) || 'unknown';
        var style = SOURCE_STYLE[methodCode] || { color: '#9ba8a2', label: '方式待确认' };
        var dataSource = addDataSource(methodCode, style.label);
        var split = splitTrack(points, MAX_TRACK_SPEED_MPS);
        var lost = track.status === 'lost';
        points.forEach(extendBounds);
        split.segments.forEach(function (segment, index) {
          dataSource.entities.add({
            id: 'detection-live-trail-' + track.track_id + '-' + index,
            name: (track.track_code || track.source_target_id) + ' 实时尾迹',
            polyline: {
              positions: segment.map(function (point) { return pointPosition(point, 100); }),
              width: lost ? 2 : 3,
              material: CesiumRuntime.Color.fromCssColorString(style.color).withAlpha(lost ? 0.28 : 0.78),
              clampToGround: false
            }
          });
        });
        if (!points.length) return;
        var target = points[points.length - 1];
        var position = pointPosition(target, 100);
        if (!position) return;
        dataSource.entities.add({
          id: 'detection-target-' + track.track_id,
          name: (track.model || style.label) + ' ' + track.source_target_id,
          position: position,
          point: {
            pixelSize: lost ? 8 : 11,
            color: CesiumRuntime.Color.fromCssColorString(style.color).withAlpha(lost ? 0.38 : 1),
            outlineColor: CesiumRuntime.Color.fromCssColorString('#071713'),
            outlineWidth: 2,
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          },
          label: {
            text: (lost ? '已丢失 · ' : '') + (track.model || style.label),
            font: '600 12px sans-serif',
            fillColor: CesiumRuntime.Color.fromCssColorString('#fff7df'),
            showBackground: true,
            backgroundColor: CesiumRuntime.Color.fromCssColorString('#071713').withAlpha(0.78),
            pixelOffset: new CesiumRuntime.Cartesian2(0, -22),
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          },
          description: '来源目标：' + escapeHtml(track.source_target_id) + '；观测时间：' + formatTime(target.observed_at) +
            '；高度：' + (target.altitude_amsl_m == null ? '未知' : target.altitude_amsl_m + ' m AMSL')
        });
      });
      if (summary) summary.innerHTML = realtimeSummaryHtml(payload);
      var activeCount = tracks.filter(function (track) { return track.status !== 'lost'; }).length;
      var pointCount = tracks.reduce(function (total, track) { return total + (track.points || []).length; }, 0);
      if (hint) hint.textContent = formatCount(activeCount) + ' 目标 · ' + formatCount(pointCount) + ' 尾迹点';
      if (locateButton) locateButton.disabled = !lastBounds;
      if (clearButton) clearButton.disabled = false;
    }

    function renderTrack(detail) {
      removeLayers();
      var points = detail.points || [];
      var split = splitTrack(points, MAX_TRACK_SPEED_MPS);
      var sourceTypeCode = points.length ? points[points.length - 1].source_type_code : null;
      var style = SOURCE_STYLE[sourceTypeCode] || { color: '#9ba8a2', label: '来源待确认' };
      var dataSource = addDataSource(sourceTypeCode, '历史航迹');
      points.forEach(extendBounds);
      split.segments.forEach(function (segment, index) {
        dataSource.entities.add({
          id: 'detection-history-' + detail.track.id + '-' + index,
          name: detail.track.track_code + ' 历史航迹',
          polyline: {
            positions: segment.map(function (point) { return pointPosition(point, 100); }),
            width: 3,
            material: CesiumRuntime.Color.fromCssColorString(style.color).withAlpha(0.86),
            clampToGround: false
          }
        });
      });
      if (points.length) {
        var last = points[points.length - 1];
        dataSource.entities.add({
          id: 'detection-history-last-' + detail.track.id,
          name: detail.track.track_code + ' 末次位置',
          position: pointPosition(last, 100),
          point: {
            pixelSize: 12,
            color: CesiumRuntime.Color.fromCssColorString(style.color),
            outlineColor: CesiumRuntime.Color.fromCssColorString('#071713'),
            outlineWidth: 3,
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          }
        });
      }
      if (locateButton) locateButton.disabled = !lastBounds;
      if (clearButton) clearButton.disabled = false;
      if (hint) hint.textContent = formatCount(points.length) + ' 点 · ' + formatCount(split.jumpCount) + ' 断点';
      locate();
      log('航迹 ' + detail.track.track_code + ' 已加载；' + split.jumpCount + ' 个异常跳变已断开。', split.jumpCount ? 'warning' : 'success');
    }

    function locate() {
      if (!lastBounds) return;
      var lonPadding = Math.max((lastBounds.east - lastBounds.west) * 0.12, 0.002);
      var latPadding = Math.max((lastBounds.north - lastBounds.south) * 0.12, 0.002);
      viewer.camera.flyTo({
        destination: CesiumRuntime.Rectangle.fromDegrees(
          lastBounds.west - lonPadding, lastBounds.south - latPadding,
          lastBounds.east + lonPadding, lastBounds.north + latPadding
        ),
        duration: 1.2
      });
    }

    function setLoading(active, label) {
      if (!loadButton) return;
      loadButton.disabled = active;
      loadButton.textContent = active ? '正在加载…' : label;
    }

    function currentLivePayload(generatedAt) {
      return {
        generated_at: generatedAt || new Date().toISOString(),
        tracks: Object.keys(liveTracks).map(function (key) { return liveTracks[key]; }),
        sources: liveSources,
        detection_methods: liveDetectionMethods
      };
    }

    function synchronizeDetectionMethods(methods) {
      var palette = ['#f6c85f', '#5eead4', '#7dd3fc', '#c4b5fd', '#fb7185', '#86efac'];
      liveDetectionMethods = methods || [];
      liveDetectionMethods.forEach(function (method, index) {
        var metadata = method.display_metadata || {};
        SOURCE_STYLE[method.code] = {
          color: metadata.color || (SOURCE_STYLE[method.code] && SOURCE_STYLE[method.code].color) || palette[index % palette.length],
          label: method.name || method.code
        };
        if (!sourceToggleContainer || sourceButtons.some(function (button) {
          return button.dataset.detectionMethod === method.code;
        })) return;
        var button = document.createElement('button');
        button.type = 'button';
        button.dataset.detectionMethod = method.code;
        button.setAttribute('aria-pressed', 'true');
        button.style.setProperty('--source-color', SOURCE_STYLE[method.code].color);
        button.textContent = SOURCE_STYLE[method.code].label;
        sourceToggleContainer.appendChild(button);
        sourceButtons.push(button);
        bindSourceButton(button);
      });
    }

    function loadRealtime(silent) {
      var sequence = ++requestSequence;
      var detectionMethods = detectionMethodFilter(sourceButtons);
      if (!silent) setLoading(true, '刷新实时态势');
      if (hint && !silent) hint.textContent = '查询中';
      return rpc('get_detection_live_tracks_v2', {
        p_observation_source_ids: null,
        p_producer_asset_ids: null,
        p_detection_method_codes: detectionMethods,
        p_active_within_seconds: 120,
        p_trail_seconds: 300,
        p_max_tracks: 1000,
        p_max_points_per_track: 300
      }).then(function (payload) {
        if (destroyed || sequence !== requestSequence || mode !== 'realtime') return payload;
        payload = payload || { tracks: [], sources: [], cursor: 0, trail_seconds: 300 };
        synchronizeDetectionMethods(payload.detection_methods || []);
        liveTracks = indexLiveTracks(payload.tracks);
        liveCursor = Number(payload.cursor || 0);
        liveSources = payload.sources || [];
        liveTrailSeconds = Number(payload.trail_seconds || 300);
        renderRealtime(currentLivePayload(payload.generated_at));
        if (!silent) log('实时目标及最近 5 分钟尾迹已加载。', 'success');
        return payload;
      }).catch(function (error) {
        if (hint) hint.textContent = '加载失败';
        if (!silent) log('实时侦测态势加载失败：' + error.message, 'error');
        throw error;
      }).finally(function () {
        if (!silent) setLoading(false, '刷新实时态势');
      });
    }

    function pollRealtimeChanges() {
      if (livePolling || destroyed || mode !== 'realtime' || !liveCursor) return Promise.resolve();
      livePolling = true;
      var acceptedTypes = detectionMethodFilter(sourceButtons);
      function readPage() {
        return rpc('get_detection_situation_changes', {
          p_after_cursor: liveCursor,
          p_station_ids: null,
          p_limit: 500
        }).then(function (page) {
          if (destroyed || mode !== 'realtime') return page;
          var generatedAt = new Date().toISOString();
          applyLiveChanges(liveTracks, page.changes || [], generatedAt, liveTrailSeconds, 60, acceptedTypes);
          liveCursor = Number(page.next_cursor || liveCursor);
          var targetChanges = (page.changes || []).filter(function (change) {
            return change.type === 'target_upsert' || change.type === 'target_remove';
          });
          if (targetChanges.length) {
            var newest = targetChanges.reduce(function (latest, change) {
              return Date.parse(change.occurred_at) > Date.parse(latest) ? change.occurred_at : latest;
            }, targetChanges[0].occurred_at);
            liveSources.forEach(function (source) {
              if (!source.last_message_at || Date.parse(newest) > Date.parse(source.last_message_at)) source.last_message_at = newest;
            });
          }
          renderRealtime(currentLivePayload(generatedAt));
          return page.has_more ? readPage() : page;
        });
      }
      return readPage().catch(function (error) {
        if (hint) hint.textContent = '增量中断';
        log('实时航迹增量读取失败：' + error.message, 'error');
      }).finally(function () { livePolling = false; });
    }

    function startRealtimeRefresh() {
      stopRefresh();
      refreshTimer = setInterval(pollRealtimeChanges, 2000);
    }

    function loadHistory() {
      var payload;
      try {
        payload = buildHistoryPayload(startInput && startInput.value, endInput && endInput.value, legacySourceTypeFilter(sourceButtons));
      } catch (error) {
        log(error.message, 'error');
        return Promise.reject(error);
      }
      stopRefresh();
      setLoading(true, '查询历史航迹');
      if (hint) hint.textContent = '查询中';
      return rpc('list_detection_target_tracks', payload).then(function (result) {
        if (destroyed || mode !== 'history') return result;
        removeLayers();
        var tracks = result && result.tracks || [];
        if (summary) summary.innerHTML = historySummaryHtml(tracks);
        if (hint) hint.textContent = formatCount(tracks.length) + ' 条航迹';
        if (clearButton) clearButton.disabled = false;
        log('历史航迹摘要已加载，选择航迹查看空间轨迹。', 'success');
        return result;
      }).catch(function (error) {
        if (hint) hint.textContent = '加载失败';
        log('历史航迹加载失败：' + error.message, 'error');
        throw error;
      }).finally(function () { setLoading(false, '查询历史航迹'); });
    }

    function loadTrack(trackId) {
      var payload;
      try {
        payload = buildHistoryPayload(startInput && startInput.value, endInput && endInput.value, null);
      } catch (error) {
        log(error.message, 'error');
        return Promise.reject(error);
      }
      if (hint) hint.textContent = '加载航迹';
      return rpc('get_target_track_detail', {
        p_track_id: Number(trackId),
        p_start_at: payload.p_start_at,
        p_end_at: payload.p_end_at,
        p_max_points: 5000
      }).then(renderTrack).catch(function (error) {
        if (hint) hint.textContent = '加载失败';
        log('航迹详情加载失败：' + error.message, 'error');
        throw error;
      });
    }

    function setMode(nextMode) {
      mode = nextMode;
      stopRefresh();
      removeLayers();
      modeButtons.forEach(function (button) {
        button.setAttribute('aria-pressed', String(button.dataset.situationMode === mode));
      });
      var historyMode = mode === 'history';
      sourceButtons.forEach(function (button) {
        button.hidden = historyMode && LEGACY_SOURCE_TYPE[button.dataset.detectionMethod] == null;
      });
      if (startInput) startInput.disabled = !historyMode;
      if (endInput) endInput.disabled = !historyMode;
      if (loadButton) loadButton.textContent = historyMode ? '查询历史航迹' : '刷新实时态势';
      if (note) note.textContent = historyMode
        ? '选择航迹查看详情；推算速度超过 100 m/s 的相邻点自动断开。'
        : '实时模式按游标每 2 秒补读，显示最近 5 分钟尾迹；异常跳变自动断开。';
      if (summary) summary.innerHTML = '<p class="source-situation-empty">' + (historyMode ? '请选择日期查询历史航迹。' : '点击刷新加载当前侦测态势。') + '</p>';
      if (hint) hint.textContent = '未加载';
    }

    function bind(element, eventName, handler) {
      if (!element) return;
      element.addEventListener(eventName, handler);
      disposers.push(function () { element.removeEventListener(eventName, handler); });
    }

    function bindSourceButton(button) {
      bind(button, 'click', function () {
        var active = button.getAttribute('aria-pressed') !== 'true';
        button.setAttribute('aria-pressed', String(active));
        if (mode === 'realtime' && liveCursor) {
          loadRealtime(true).then(startRealtimeRefresh).catch(function () {});
        } else if (dataSources[button.dataset.detectionMethod]) {
          dataSources[button.dataset.detectionMethod].show = active;
        }
      });
    }

    setDefaultDates();
    setMode('realtime');
    bind(loadButton, 'click', function () {
      var request = mode === 'history' ? loadHistory() : loadRealtime(false).then(startRealtimeRefresh);
      request.catch(function () {});
    });
    bind(locateButton, 'click', locate);
    bind(clearButton, 'click', reset);
    bind(summary, 'click', function (event) {
      var button = event.target.closest && event.target.closest('[data-track-id]');
      if (button) loadTrack(button.dataset.trackId).catch(function () {});
    });
    modeButtons.forEach(function (button) {
      bind(button, 'click', function () { setMode(button.dataset.situationMode); });
    });
    sourceButtons.forEach(bindSourceButton);

    return {
      load: function () { return mode === 'history' ? loadHistory() : loadRealtime(false); },
      locate: locate,
      clear: reset,
      destroy: function () {
        destroyed = true;
        stopRefresh();
        disposers.splice(0).forEach(function (dispose) { dispose(); });
        removeLayers();
      }
    };
  }

  return {
    createModule: createModule,
    buildHistoryPayload: buildHistoryPayload,
    splitTrack: splitTrack,
    sourceState: sourceState,
    realtimeSummaryHtml: realtimeSummaryHtml,
    historySummaryHtml: historySummaryHtml,
    indexLiveTracks: indexLiveTracks,
    applyLiveChanges: applyLiveChanges,
    _private: {
      addDays: addDays,
      coordinates: coordinates,
      groundSpeed: groundSpeed,
      escapeHtml: escapeHtml,
      selectedDetectionMethods: selectedDetectionMethods,
      detectionMethodFilter: detectionMethodFilter,
      legacySourceTypeFilter: legacySourceTypeFilter
    }
  };
});
