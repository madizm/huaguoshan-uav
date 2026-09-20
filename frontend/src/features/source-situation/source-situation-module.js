(function (global, factory) {
  'use strict';
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanSourceSituation = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  var SOURCE_STYLE = {
    uav_hf: { color: '#5eead4', height: 100, label: '华飞无人机', labelOffsetX: -48 },
    uav_yh: { color: '#80b7ff', height: 130, label: '亿航无人机', labelOffsetX: 48 },
    passive_radar: { color: '#f6c85f', height: 80, label: '无源雷达目标' }
  };

  function $(selector) { return typeof document === 'undefined' ? null : document.querySelector(selector); }

  function addDays(dateText, days) {
    var parts = String(dateText || '').split('-').map(Number);
    if (parts.length !== 3 || parts.some(function (value) { return !Number.isFinite(value); })) return null;
    var date = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2] + days));
    return date.toISOString().slice(0, 10);
  }

  function buildPayload(startDate, inclusiveEndDate) {
    var exclusiveEnd = addDays(inclusiveEndDate, 1);
    if (!startDate || !exclusiveEnd || startDate > inclusiveEndDate) throw new Error('结束日期不能早于开始日期。');
    return {
      p_start_at: startDate + 'T00:00:00',
      p_end_at: exclusiveEnd + 'T00:00:00',
      p_drone_sample_seconds: 60
    };
  }

  function anomalyCount(source) {
    return Number(source.coordinate_anomaly_rows || 0) + Number(source.altitude_anomaly_rows || 0) + Number(source.speed_anomaly_rows || 0);
  }

  function qualityState(source) {
    var anomalies = anomalyCount(source);
    if (!Number(source.total_rows || 0)) return { code: 'empty', label: '无数据', count: 0 };
    if (anomalies) return { code: 'warning', label: '需核验 ' + anomalies.toLocaleString('zh-CN') + ' 条', count: anomalies };
    return { code: 'ok', label: '基础校验正常', count: 0 };
  }

  function formatCount(value) {
    return Number(value || 0).toLocaleString('zh-CN');
  }

  function formatTime(value) {
    return value ? String(value).replace('T', ' ').slice(0, 19) : '--';
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  function inferredGroundSpeed(a, b) {
    var elapsedSeconds = (Date.parse(b.observed_at + 'Z') - Date.parse(a.observed_at + 'Z')) / 1000;
    if (!(elapsedSeconds > 0)) return 0;
    var meanLatitude = (Number(a.lat) + Number(b.lat)) * Math.PI / 360;
    var eastMetres = (Number(b.lon) - Number(a.lon)) * 111320 * Math.cos(meanLatitude);
    var northMetres = (Number(b.lat) - Number(a.lat)) * 110540;
    return Math.sqrt(eastMetres * eastMetres + northMetres * northMetres) / elapsedSeconds;
  }

  function splitTrack(points, maximumSpeedMps) {
    var segments = [];
    var current = [];
    var jumpCount = 0;
    (points || []).forEach(function (point, index) {
      if (index && inferredGroundSpeed(points[index - 1], point) > maximumSpeedMps) {
        if (current.length > 1) segments.push(current);
        current = [];
        jumpCount += 1;
      }
      current.push(point);
    });
    if (current.length > 1) segments.push(current);
    return { segments: segments, jumpCount: jumpCount };
  }

  function sourceJumpCount(tracks, sourceCode) {
    return (tracks || []).filter(function (track) { return track.source_code === sourceCode && track.object_kind === 'aircraft_asset'; })
      .reduce(function (total, track) { return total + splitTrack(track.points, 100).jumpCount; }, 0);
  }

  function sourceSummaryHtml(sources, tracks) {
    if (!sources || !sources.length) return '<p class="source-situation-empty">所选时间区间无数据。</p>';
    return sources.map(function (source) {
      var quality = qualityState(source);
      var style = SOURCE_STYLE[source.source_code] || { color: '#f4ecd8' };
      var jumpCount = sourceJumpCount(tracks, source.source_code);
      return '<article class="source-quality-card" data-quality="' + quality.code + '">' +
        '<header><i style="--source-color:' + style.color + '"></i><strong>' + escapeHtml(source.source_name) + '</strong>' +
        '<span>' + quality.label + '</span></header>' +
        '<dl><div><dt>原始记录</dt><dd>' + formatCount(source.total_rows) + '</dd></div>' +
        '<div><dt>地图可用</dt><dd>' + formatCount(source.displayable_rows) + '</dd></div>' +
        '<div><dt>坐标异常</dt><dd>' + formatCount(source.coordinate_anomaly_rows) + '</dd></div>' +
        '<div><dt>速度异常</dt><dd>' + formatCount(source.speed_anomaly_rows) + '</dd></div>' +
        '<div><dt>轨迹跳变</dt><dd>' + formatCount(jumpCount) + '</dd></div></dl>' +
        '<p>' + formatTime(source.first_at) + ' — ' + formatTime(source.last_at) + '</p></article>';
    }).join('');
  }

  function sourceTracks(payload, sourceCode) {
    return (payload && payload.tracks || []).filter(function (track) { return track.source_code === sourceCode; });
  }

  function createModule(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var viewer = options.viewer;
    var rpc = options.rpc;
    var log = options.log || function () {};
    var dataSources = {};
    var payload = null;
    var destroyed = false;
    var loadButton = $('#sourceSituationLoad');
    var locateButton = $('#sourceSituationLocate');
    var clearButton = $('#sourceSituationClear');
    var summary = $('#sourceSituationSummary');
    var hint = $('#sourceSituationHint');
    var startInput = $('#sourceSituationStart');
    var endInput = $('#sourceSituationEnd');
    var sourceButtons = typeof document === 'undefined' ? [] : Array.prototype.slice.call(document.querySelectorAll('[data-source-situation]'));
    var disposers = [];

    function removeLayers() {
      Object.keys(dataSources).forEach(function (key) {
        viewer.dataSources.remove(dataSources[key], true);
      });
      dataSources = {};
      payload = null;
      if (locateButton) locateButton.disabled = true;
      if (clearButton) clearButton.disabled = true;
      if (summary) summary.innerHTML = '<p class="source-situation-empty">尚未加载源数据。</p>';
      if (hint) hint.textContent = '未加载';
    }

    function addDataSource(sourceCode) {
      var dataSource = new CesiumRuntime.CustomDataSource('raw-source-' + sourceCode);
      var button = sourceButtons.find(function (item) { return item.dataset.sourceSituation === sourceCode; });
      dataSource.show = !button || button.getAttribute('aria-pressed') !== 'false';
      viewer.dataSources.add(dataSource);
      dataSources[sourceCode] = dataSource;
      return dataSource;
    }

    function pointPosition(point, style) {
      // 首次校验仅验证水平轨迹；固定视觉抬升，避免把未确认的高度基准表达为真实三维高度。
      return CesiumRuntime.Cartesian3.fromDegrees(Number(point.lon), Number(point.lat), style.height);
    }

    function renderDroneTrack(track, dataSource, style) {
      var points = track.points || [];
      if (!points.length) return;
      var split = splitTrack(points, 100);
      split.segments.forEach(function (segment, segmentIndex) {
        dataSource.entities.add({
          id: 'raw-track-' + track.source_code + '-' + segmentIndex,
          name: style.label + '历史轨迹',
          polyline: {
            positions: segment.map(function (point) { return pointPosition(point, style); }),
            width: 3,
            material: CesiumRuntime.Color.fromCssColorString(style.color).withAlpha(0.82),
            clampToGround: false
          }
        });
      });
      var last = points[points.length - 1];
      dataSource.entities.add({
        id: 'raw-current-' + track.source_code,
        name: style.label + '区间末次位置',
        position: pointPosition(last, style),
        point: {
          pixelSize: 13,
          color: CesiumRuntime.Color.fromCssColorString(style.color),
          outlineColor: CesiumRuntime.Color.fromCssColorString('#071713'),
          outlineWidth: 3,
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        },
        label: {
          text: style.label,
          font: '600 13px sans-serif',
          fillColor: CesiumRuntime.Color.fromCssColorString('#fff7df'),
          showBackground: true,
          backgroundColor: CesiumRuntime.Color.fromCssColorString('#071713').withAlpha(0.78),
          pixelOffset: new CesiumRuntime.Cartesian2(style.labelOffsetX || 0, -24),
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        },
        description: '来源时间：' + formatTime(last.observed_at) + '；速度：' + (last.speed_mps == null ? '未知' : last.speed_mps + ' m/s') + '；原始高度基准未确认。'
      });
    }

    function renderRadarTrack(track, dataSource, style) {
      var points = track.points || [];
      if (!points.length) return;
      var point = points[points.length - 1];
      var disappeared = Number(point.status) === 8;
      dataSource.entities.add({
        id: 'raw-radar-' + track.track_id,
        name: '无源雷达目标 ' + track.track_id,
        position: pointPosition(point, style),
        point: {
          pixelSize: disappeared ? 5 : 7,
          color: CesiumRuntime.Color.fromCssColorString(disappeared ? '#8f9b95' : style.color).withAlpha(disappeared ? 0.45 : 0.82),
          outlineColor: CesiumRuntime.Color.fromCssColorString('#071713'),
          outlineWidth: 1,
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        },
        description: '航迹标识：' + track.track_id + '；来源时间：' + formatTime(point.observed_at) + '；状态：' + (disappeared ? '目标消失' : '跟踪中') + '；高度未知。'
      });
    }

    function render(nextPayload) {
      removeLayers();
      payload = nextPayload;
      Object.keys(SOURCE_STYLE).forEach(function (sourceCode) {
        var style = SOURCE_STYLE[sourceCode];
        var dataSource = addDataSource(sourceCode);
        sourceTracks(payload, sourceCode).forEach(function (track) {
          if (sourceCode === 'passive_radar') renderRadarTrack(track, dataSource, style);
          else renderDroneTrack(track, dataSource, style);
        });
      });
      if (summary) summary.innerHTML = sourceSummaryHtml(payload.sources || [], payload.tracks || []);
      if (hint) hint.textContent = formatCount((payload.tracks || []).length) + ' 条航迹';
      if (locateButton) locateButton.disabled = !payload.bounds;
      if (clearButton) clearButton.disabled = false;
    }

    function locate() {
      var bounds = payload && payload.bounds;
      if (!bounds) return;
      viewer.camera.flyTo({
        destination: CesiumRuntime.Rectangle.fromDegrees(
          Number(bounds.west), Number(bounds.south), Number(bounds.east), Number(bounds.north)
        ),
        duration: 1.4
      });
      log('已定位到源数据 1%—99% 稳健范围；当前为平面轨迹校验模式。', 'success');
    }

    function load() {
      var requestPayload;
      try {
        requestPayload = buildPayload(startInput && startInput.value, endInput && endInput.value);
      } catch (error) {
        log(error.message, 'error');
        return Promise.reject(error);
      }
      if (loadButton) {
        loadButton.disabled = true;
        loadButton.textContent = '正在校验…';
      }
      if (hint) hint.textContent = '查询中';
      log('正在读取 2025-12-26 至 2025-12-31 的源数据并执行基础质量校验。');
      return rpc('get_raw_source_situation', requestPayload).then(function (result) {
        if (destroyed) return result;
        render(result || { sources: [], tracks: [] });
        locate();
        log('源数据已加载：无人机按 60 秒抽样，雷达显示每条航迹在区间内的末次位置。', 'success');
        return result;
      }).catch(function (error) {
        if (hint) hint.textContent = '加载失败';
        log('源数据校验加载失败：' + error.message, 'error');
        throw error;
      }).finally(function () {
        if (loadButton) {
          loadButton.disabled = false;
          loadButton.textContent = '加载并定位';
        }
      });
    }

    function bind(element, eventName, handler) {
      if (!element) return;
      element.addEventListener(eventName, handler);
      disposers.push(function () { element.removeEventListener(eventName, handler); });
    }

    bind(loadButton, 'click', function () { load().catch(function () {}); });
    bind(locateButton, 'click', locate);
    bind(clearButton, 'click', function () {
      removeLayers();
      log('已清除源数据校验图层。');
    });
    sourceButtons.forEach(function (button) {
      bind(button, 'click', function () {
        var active = button.getAttribute('aria-pressed') !== 'true';
        button.setAttribute('aria-pressed', String(active));
        if (dataSources[button.dataset.sourceSituation]) dataSources[button.dataset.sourceSituation].show = active;
      });
    });

    return {
      load: load,
      locate: locate,
      clear: removeLayers,
      destroy: function () {
        destroyed = true;
        disposers.splice(0).forEach(function (dispose) { dispose(); });
        removeLayers();
      }
    };
  }

  return {
    createModule: createModule,
    buildPayload: buildPayload,
    qualityState: qualityState,
    sourceSummaryHtml: sourceSummaryHtml,
    sourceTracks: sourceTracks,
    _private: {
      addDays: addDays,
      anomalyCount: anomalyCount,
      escapeHtml: escapeHtml,
      inferredGroundSpeed: inferredGroundSpeed,
      splitTrack: splitTrack,
      sourceJumpCount: sourceJumpCount
    }
  };
});
