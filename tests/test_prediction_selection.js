const assert = require('assert');
const Selection = require('../frontend/src/features/trajectory-prediction/prediction-selection');
assert.deepStrictEqual(Selection.subjectOf({properties:{getValue:()=>({subject_kind:'airspace_target',subject_id:42})}}),{kind:'airspace_target',id:'42'});
assert.strictEqual(Selection.subjectOf({id:'unrelated-42'}),null,'do not guess identity from coordinates or arbitrary IDs');
let listener, removed=false, clicked, detailCalls=0, focused=null;
const sourceSelections=[],predictionSelections=[],logs=[];
const entity={id:'target-42'};
const button={disabled:false,addEventListener(type,cb){clicked=cb;},removeEventListener(type,cb){assert.strictEqual(cb,clicked);clicked=null;}};
const bridge=Selection.createModule({
 viewer:{selectedEntityChanged:{addEventListener(cb){listener=cb;return()=>{removed=true;};}},flyTo(e){focused=e;return Promise.resolve();}},
 sourceSituation:{selectSubject:(...args)=>sourceSelections.push(args),getSubjectEntity:(kind,id)=>id==='42'?entity:null,showSubjectDetail(){detailCalls++;return Promise.resolve();}},
 trajectoryPrediction:{selectSubject:(...args)=>predictionSelections.push(args)},locateButton:button,log:msg=>logs.push(msg)
});
assert(button.disabled);
listener({properties:{subject_kind:'airspace_target',subject_id:42}});
assert.deepStrictEqual(sourceSelections.at(-1),['airspace_target','42']);
assert.deepStrictEqual(predictionSelections.at(-1),['airspace_target','42']);
assert.strictEqual(detailCalls,1);
listener({properties:{subject_kind:'airspace_target',subject_id:42}});
assert.strictEqual(detailCalls,1,'do not reload same object details when selecting another part');
clicked(); assert.strictEqual(focused,entity);
bridge.selectSubject('airspace_target',99); clicked(); assert(logs.at(-1).includes('未显示'));
listener(null); assert(button.disabled);
assert.deepStrictEqual(predictionSelections.at(-1),[null,null]);
bridge.destroy(); assert(removed && !clicked);
console.log('prediction selection tests passed');
