(function (global, factory) {
  'use strict';
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.HuaguoshanPredictionSelection = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  function subjectOf(entity, time) {
    var properties = entity && entity.properties;
    if (!properties) return null;
    var values = typeof properties.getValue === 'function' ? properties.getValue(time) : properties;
    function value(v) { return v && typeof v.getValue === 'function' ? v.getValue(time) : v; }
    var kind = value(values.subject_kind), id = value(values.subject_id);
    return (kind === 'airspace_target' || kind === 'aircraft_asset') && id != null ? { kind: kind, id: String(id) } : null;
  }
  function createModule(options) {
    var viewer = options.viewer, selected = null, destroyed = false;
    var source = options.sourceSituation, prediction = options.trajectoryPrediction;
    var button = options.locateButton;
    var log = options.log || function () {};
    function select(kind, id, showDetail) {
      if (destroyed) return;
      var next = kind && id != null ? { kind: kind, id: String(id) } : null;
      var changed = !selected !== !next || (next && selected && (selected.kind !== next.kind || selected.id !== next.id));
      selected = next;
      if (source) source.selectSubject(next && next.kind, next && next.id);
      if (prediction) prediction.selectSubject(next && next.kind, next && next.id);
      if (button) button.disabled = !next;
      if (changed && next && showDetail && source) source.showSubjectDetail(next.kind, next.id);
    }
    function onSelected(entity) {
      var subject = subjectOf(entity, viewer.clock && viewer.clock.currentTime);
      select(subject && subject.kind, subject && subject.id, true);
    }
    function locate() {
      if (!selected || !source) return;
      var entity = source.getSubjectEntity(selected.kind, selected.id);
      if (!entity) { log('对应实时目标未显示；请开启实时态势图层或等待新观测。', 'info'); return; }
      if (source.isSubjectVisible && !source.isSubjectVisible(selected.kind, selected.id)) {
        log('对应实时目标图层已隐藏；已定位其位置，可开启对应侦测图层查看。', 'info');
      }
      return Promise.resolve(viewer.flyTo(entity)).catch(function () { log('关联目标定位失败。', 'warning'); });
    }
    var removeListener = viewer.selectedEntityChanged.addEventListener(onSelected);
    if (button) { button.disabled = true; button.addEventListener('click', locate); }
    return {
      selectSubject: function (kind, id) { select(kind, id, false); },
      destroy: function () { destroyed = true; if (removeListener) removeListener(); if (button) button.removeEventListener('click', locate); }
    };
  }
  return { createModule: createModule, subjectOf: subjectOf };
});
