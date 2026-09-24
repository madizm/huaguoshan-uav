const assert = require('assert');
const fs = require('fs');
const path = require('path');

function read(relativePath) {
  return fs.readFileSync(path.join(__dirname, '..', relativePath), 'utf8');
}

const router = read('frontend/admin/src/router.ts');
const layout = read('frontend/admin/src/layouts/AdminLayout.vue');
const view = read('frontend/admin/src/views/DefenseRingView.vue');
const api = read('frontend/admin/src/api/defenseRings.ts');
const map = read('frontend/admin/src/components/DefenseRingMap.vue');
const workbench = read('frontend/tianditu-3d.html');

assert(router.includes("path: 'defense-rings'"));
assert(layout.includes('index=\"/defense-rings\"'));
assert(view.includes('const DEFAULT_RADII = [5000, 4000, 3000, 2000, 1000]'));
assert(view.includes('半径须由外向内严格递减，优先级须严格递增'));
assert(view.includes('反制圈、硬打击圈仅表示空间层级'));
assert(api.includes("'/rpc/get_defense_ring_config'"));
assert(api.includes("'/rpc/save_defense_ring_config'"));
assert(api.includes("'/rpc/save_defense_risk_scores'"));
assert(map.includes("map.on('singleclick'"));
assert(!workbench.includes('sectionDefenseRings'));
assert(!workbench.includes('defense-ring-admin.js'));
console.log('defense ring admin route, API, map, and workbench separation OK');
