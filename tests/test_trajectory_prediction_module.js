const fs = require('fs');
const assert = require('assert');

const pageHtml = fs.readFileSync(require.resolve('../frontend/tianditu-3d.html'), 'utf8');
assert(pageHtml.includes('data-layer="trajectoryPrediction"'), '页面缺少轨迹预测图层开关');
assert(pageHtml.includes('trajectory-prediction-module.js'), '页面未加载轨迹预测模块脚本');

const modulePath = require.resolve('../frontend/src/features/trajectory-prediction/trajectory-prediction-module');
const moduleText = fs.readFileSync(modulePath, 'utf8');
assert(moduleText.includes("rpc('get_trajectory_predictions'"), '模块应调用 get_trajectory_predictions RPC');
assert(moduleText.includes('PolylineDashMaterialProperty'), '预测线应为虚线样式');
assert(moduleText.includes('trajectory-prediction-'), '实体 ID 应有 trajectory-prediction- 前缀');
assert(moduleText.includes('semiMajorAxis'), '应绘制不确定范围圆环');

const layerActionsText = fs.readFileSync(require.resolve('../frontend/src/app/layer-actions.js'), 'utf8');
assert(layerActionsText.includes("layer === 'trajectoryPrediction'"), '图层开关应接线到轨迹预测模块');

const appText = fs.readFileSync(require.resolve('../frontend/src/app/create-huaguoshan-app.js'), 'utf8');
assert(appText.includes('initTrajectoryPrediction'), '应用初始化应挂载轨迹预测模块');
assert(appText.includes('state.trajectoryPrediction.setAuthenticated'), '认证变化应通知轨迹预测模块');

const TrajectoryPrediction = require(modulePath);

assert.strictEqual(TrajectoryPrediction.subjectStyle('airspace_target').label, '空域目标');
assert.strictEqual(TrajectoryPrediction.subjectStyle('aircraft_asset').label, '无人机资产');
assert.strictEqual(TrajectoryPrediction.subjectStyle('other').label, 'other');

const summary = TrajectoryPrediction.formatPredictionSummary({
  subject_kind: 'airspace_target', subject_id: 42, model_code: 'ct',
  speed_mps: 18.234, horizon_seconds: 120
});
assert(summary.includes('#42'), summary);
assert(summary.includes('转向'), summary);
assert(summary.includes('18.2 m/s'), summary);
assert(summary.includes('+120s'), summary);

// ── mock Cesium 功能测试 ─────────────────────────────────────────
function mockColor() {
  return { withAlpha() { return this; } };
}

function createMockCesium() {
  const sources = [];
  function CustomDataSource(name) {
    const entities = [];
    return {
      name,
      show: true,
      entities: {
        add(entity) { entities.push(entity); return entity; },
        removeAll() { entities.length = 0; },
        get values() { return entities.slice(); }
      }
    };
  }
  return {
    sources,
    CustomDataSource,
    Color: { fromCssColorString: mockColor },
    Cartesian3: { fromDegrees: (lon, lat, h) => ({ lon, lat, h }) },
    Cartesian2: function (x, y) { return { x, y }; },
    PolylineDashMaterialProperty: function (opts) { return opts; },
    viewer: {
      dataSources: {
        add(source) { sources.push(source); return source; },
        remove(source) { const i = sources.indexOf(source); if (i >= 0) sources.splice(i, 1); return i >= 0; }
      }
    }
  };
}

const Cesium = createMockCesium();
const prediction = {
  subject_kind: 'airspace_target', subject_id: 42, base_observed_at: '2026-01-01T00:00:20Z',
  predicted_at: '2026-01-01T00:00:21Z', model_code: 'cv', model_version: 1,
  horizon_seconds: 30, step_seconds: 5, speed_mps: 18.2, heading_deg: 90,
  window_point_count: 5, fit_residual_m: 1.5,
  points: [5, 10, 15, 20, 25, 30].map((eta) => ({
    eta_seconds: eta,
    longitude: 119.25 + eta * 0.0001, latitude: 34.65, height_amsl_m: 150,
    uncertainty_m: 10 + eta
  }))
};

const moduleInstance = TrajectoryPrediction.createModule({
  CesiumRuntime: Cesium,
  viewer: Cesium.viewer,
  rpc: () => Promise.resolve({ generated_at: '2026-01-01T00:00:21Z', predictions: [prediction] }),
  log: () => {}
});

moduleInstance.setEnabled(true).then(() => {
  assert.strictEqual(Cesium.sources.length, 1, '应创建一个数据源');
  const entities = Cesium.sources[0].entities.values;
  const ids = entities.map((entity) => entity.id);
  assert(ids.includes('trajectory-prediction-airspace_target-42-line'), ids.join(','));
  assert(ids.includes('trajectory-prediction-airspace_target-42-endpoint'), ids.join(','));
  assert(ids.filter((id) => id.includes('-uncertainty-')).length >= 2, '应绘制多个不确定圆环');
  const line = entities.find((entity) => entity.id.endsWith('-line'));
  assert.strictEqual(line.polyline.positions.length, 6, '预测线应含全部预测点');
  assert.strictEqual(line.polyline.positions[0].h, 150, '预测点应使用 AMSL 高度');

  return moduleInstance.setEnabled(false).then(() => {
    assert.strictEqual(Cesium.sources[0].entities.values.length, 0, '关闭图层应清空实体');
    moduleInstance.destroy();
    assert.strictEqual(Cesium.sources.length, 0, '销毁应移除数据源');
    console.log('trajectory-prediction module tests passed');
  });
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
