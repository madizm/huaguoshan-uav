(function (global) {
  'use strict';

  var RING_STYLES = {
    sensing: { color: '#67e8f9', label: '感知圈' },
    tracking: { color: '#60a5fa', label: '跟踪圈' },
    countermeasure: { color: '#facc15', label: '反制圈' },
    hard_strike: { color: '#fb923c', label: '硬打击圈' },
    core: { color: '#fb7185', label: '核心圈' }
  };

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  function createModule(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var viewer = options.viewer;
    var rpc = options.rpc;
    var log = options.log || function () {};
    var dataSource = new CesiumRuntime.CustomDataSource('defense-rings');
    var enabled = false;
    var authenticated = false;
    var loading = null;
    var destroyed = false;
    viewer.dataSources.add(dataSource);
    dataSource.show = false;

    function clear() {
      dataSource.entities.removeAll();
    }

    function addRing(object, ring) {
      var style = RING_STYLES[ring.code] || { color: '#cbd5e1', label: ring.name || ring.code };
      var center = CesiumRuntime.Cartesian3.fromDegrees(Number(object.longitude), Number(object.latitude), 8);
      var color = CesiumRuntime.Color.fromCssColorString(style.color);
      var description = '保护对象：' + escapeHtml(object.name) +
        '；防御圈：' + escapeHtml(ring.name || style.label) +
        '；编码：' + escapeHtml(ring.code) +
        '；半径：' + Number(ring.radius_m).toLocaleString('zh-CN') + ' m' +
        '；圈版本：' + escapeHtml(ring.version) +
        '；保护对象版本：' + escapeHtml(object.version);
      dataSource.entities.add({
        id: 'defense-ring-' + object.id + '-' + ring.id,
        name: object.name + ' · ' + (ring.name || style.label),
        position: center,
        ellipse: {
          semiMajorAxis: Number(ring.radius_m),
          semiMinorAxis: Number(ring.radius_m),
          height: 12,
          heightReference: CesiumRuntime.HeightReference.CLAMP_TO_GROUND,
          material: color.withAlpha(0.045),
          outline: true,
          outlineColor: color.withAlpha(0.9),
          outlineWidth: 2
        },
        point: {
          pixelSize: 5,
          color: color,
          outlineColor: CesiumRuntime.Color.WHITE.withAlpha(0.8),
          outlineWidth: 1,
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        },
        label: {
          text: style.label + ' · ' + object.name,
          font: '600 12px sans-serif',
          fillColor: color,
          showBackground: true,
          backgroundColor: CesiumRuntime.Color.fromCssColorString('#071713').withAlpha(0.78),
          pixelOffset: new CesiumRuntime.Cartesian2(0, -16),
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
          show: false
        },
        description: description
      });
    }

    function render(config) {
      clear();
      (config && config.objects || []).forEach(function (object) {
        if (!object.enabled || !Number.isFinite(Number(object.longitude)) || !Number.isFinite(Number(object.latitude))) return;
        (object.rings || []).forEach(function (ring) {
          if (ring.enabled === false || !(Number(ring.radius_m) > 0)) return;
          addRing(object, ring);
        });
      });
      dataSource.show = enabled && authenticated;
    }

    function load() {
      if (destroyed || !authenticated || loading) return loading || Promise.resolve();
      loading = rpc('get_defense_ring_config', {}).then(function (config) {
        if (!destroyed) {
          render(config || {});
          log('已加载 ' + dataSource.entities.values.length + ' 个防御圈实体。', 'success');
        }
        return config;
      }).catch(function (error) {
        dataSource.show = false;
        log('防御圈加载失败：' + error.message, 'error');
        throw error;
      }).finally(function () { loading = null; });
      return loading;
    }

    return {
      setAuthenticated: function (value) {
        authenticated = Boolean(value);
        dataSource.show = enabled && authenticated;
        if (authenticated) return load();
        clear();
        return Promise.resolve();
      },
      setEnabled: function (value) {
        enabled = Boolean(value);
        dataSource.show = enabled && authenticated;
        if (enabled && authenticated) return load();
        return Promise.resolve();
      },
      refresh: load,
      isEnabled: function () { return enabled; },
      destroy: function () {
        destroyed = true;
        clear();
        viewer.dataSources.remove(dataSource, true);
      }
    };
  }

  global.HuaguoshanDefenseRings = {
    createModule: createModule,
    ringStyles: RING_STYLES
  };
})(window);
