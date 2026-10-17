const fs = require('fs');
const assert = require('assert');
const pageHtml = fs.readFileSync(require.resolve('../frontend/tianditu-3d.html'), 'utf8');
assert(pageHtml.includes('data-layer="trajectoryPrediction"'));
assert(pageHtml.indexOf('prediction-timeline.js') < pageHtml.indexOf('source-situation-module.js'));
assert(pageHtml.includes('trajectoryPredictionStatus'));
assert(/class="toggle-group-note"[^>]*id="trajectoryPredictionStatus"/.test(pageHtml), '预测状态应复用图层说明样式');
const controlsCss = fs.readFileSync(require.resolve('../frontend/src/styles/controls.css'), 'utf8');
assert(/\.toggle-group-note\s*\{[^}]*padding: 0 14px;[^}]*font-size: 11px;[^}]*overflow-wrap: anywhere;/s.test(controlsCss), '预测状态的字号、对齐和长文本换行应保持一致');
const modulePath = require.resolve('../frontend/src/features/trajectory-prediction/trajectory-prediction-module');
const TrajectoryPrediction = require(modulePath);
assert.strictEqual(TrajectoryPrediction.subjectStyle('airspace_target').label, '空域目标');
assert.strictEqual(TrajectoryPrediction.subjectStyle('aircraft_asset').label, '无人机资产');
assert(TrajectoryPrediction.formatPredictionSummary({subject_kind:'airspace_target',subject_id:42,model_code:'ct',speed_mps:18.234,horizon_seconds:30}).includes('18.2 m/s'));
function createMockCesium() {
  const sources = [];
  function CustomDataSource(name) {
    const entities = new Map();
    return { name, show: true, entities: {
      add(e) { assert(!entities.has(e.id)); entities.set(e.id,e); return e; },
      getById(id) { return entities.get(id); },
      removeById(id) { return entities.delete(id); },
      removeAll() { entities.clear(); },
      get values() { return [...entities.values()]; }
    }};
  }
  return {sources, CustomDataSource, Color:{fromCssColorString: () => ({withAlpha(){return this;}})},
    Cartesian3:{fromDegrees:(lon,lat,h)=>({lon,lat,h})},Cartesian2:function(x,y){return{x,y};},PolylineDashMaterialProperty:function(o){return o;},
    viewer:{dataSources:{add(s){sources.push(s);return s;},remove(s){sources.splice(sources.indexOf(s),1);}}}};
}
const base = Date.parse('2026-01-01T00:00:20Z');
const prediction = {id:1,subject_kind:'airspace_target',subject_id:42,base_observed_at:new Date(base).toISOString(),predicted_at:new Date(base+1000).toISOString(),
  model_code:'cv',horizon_seconds:30,step_seconds:5,speed_mps:18.2,window_point_count:5,fit_residual_m:1.5,
  points:[5,10,15,20,25,30].map(eta=>({eta_seconds:eta,longitude:119.25+eta*.0001,latitude:34.65,height_amsl_m:150,uncertainty_m:10+eta}))};
async function run() {
  const Cesium = createMockCesium(), status = {textContent:''};
  let time=base+1000, error=false, payload={predictions:[prediction]}, deferred=null;
  const module = TrajectoryPrediction.createModule({CesiumRuntime:Cesium,viewer:Cesium.viewer,now:()=>time,statusElement:status,
    rpc:()=> deferred || (error ? Promise.reject(new Error('offline')) : Promise.resolve({...payload,generated_at:new Date(time).toISOString()}))});
  try {
    await module.setEnabled(true);
    const collection=Cesium.sources[0].entities;
    const line=collection.getById('trajectory-prediction-airspace_target-42-line');
    assert.strictEqual(line.polyline.positions.length,6);
    assert.strictEqual(line.polyline.positions[0].h,150);
    assert.strictEqual(line.properties.subject_id,42);
    module.selectSubject('airspace_target',42);
    assert.strictEqual(line.polyline.width,5);
    await module.refresh();
    assert.strictEqual(collection.getById(line.id),line,'preserve entity and selection identity');
    time=base+12000;
    module.tick();
    assert.strictEqual(line.polyline.positions.length,5);
    assert(status.textContent.includes('剩余 18s'));
    assert(collection.getById('trajectory-prediction-airspace_target-42-endpoint').label.text.includes('18s'));
    error=true;
    await module.refresh();
    assert.strictEqual(collection.getById(line.id),line,'retain valid cache on read failure');
    assert(status.textContent.includes('读取异常'));
    time=base+30000;
    module.tick();
    assert.strictEqual(collection.values.length,0,'expire without needing a successful network response');
    assert(status.textContent.includes('预测已结束'));
    error=false; time=base+15000;
    payload={predictions:[prediction],states:[{...prediction,id:2,points:undefined,quality:'insufficient_data',reason:'not_enough_points',predicted_at:new Date(time).toISOString()}]};
    await module.refresh();
    assert.strictEqual(collection.values.length,0,'new insufficiency hides older valid prediction');
    assert(status.textContent.includes('有效观测点不足'));
    payload={predictions:[]};
    await module.refresh();
    assert(status.textContent.includes('原因未知'),'legacy empty response does not prove insufficient data');
    // Ignore request responses after disable/re-enable or logout.
    let resolveOld;
    deferred=new Promise(resolve=>{resolveOld=resolve;});
    const old=module.refresh();
    await module.setEnabled(false);
    deferred=null; payload={predictions:[]};
    await module.setEnabled(true);
    resolveOld({predictions:[prediction]}); await old;
    assert.strictEqual(collection.values.length,0);
    // A delayed response must not be interpreted as a negative client clock offset.
    time=base+26000;
    let resolveDelayed;
    deferred=new Promise(resolve=>{resolveDelayed=resolve;});
    const delayed=module.refresh();
    time=base+31000;
    resolveDelayed({generated_at:new Date(base+26000).toISOString(),predictions:[prediction]});
    await delayed;
    assert.strictEqual(collection.values.length,0,'5s response delay cannot revive expired trajectory');
    deferred=null;
    await module.setAuthenticated(false);
    assert.strictEqual(module.isEnabled(),false);
  } finally {module.destroy();}
  assert.strictEqual(Cesium.sources.length,0);
  console.log('trajectory-prediction module tests passed');
}
run().catch(e=>{console.error(e);process.exit(1);});

assert(TrajectoryPrediction.formatPredictionSummary({
  subject_kind: 'airspace_target', subject_id: 42, model_code: 'cv', speed_mps: 20,
  horizon_seconds: 120, horizon_policy: { mode: 'adaptive', actual_horizon_seconds: 45 }
}).includes('观测后 +45s'));
