const assert = require('assert');
const fs = require('fs');
const path = require('path');

require('../frontend/src/features/convex-hull/glb-feature-geometry.js');
require('../frontend/src/features/convex-hull/convex-hull-kernel.js');

const geometry = globalThis.HuaguoshanGlbFeatureGeometry;
const hullKernel = globalThis.HuaguoshanConvexHullKernel;
require('../frontend/src/features/convex-hull/convex-hull-module.js');
const hullModule = globalThis.HuaguoshanConvexHull;

const glbPath = path.join(
  __dirname,
  '../exports/citydb-3dtiler/huaguoshan_3dtiles/content/0_0_0.glb'
);
const tilesetPath = path.join(
  __dirname,
  '../exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json'
);
const glbBytes = fs.readFileSync(glbPath);
const glb = glbBytes.buffer.slice(glbBytes.byteOffset, glbBytes.byteOffset + glbBytes.byteLength);
const tileset = JSON.parse(fs.readFileSync(tilesetPath, 'utf8'));

const selected = geometry.readFeatureVertices({
  arrayBuffer: glb,
  identifiers: ['osm:way:1002427134'],
  tileTransform: tileset.root.transform,
  gltfUpAxis: tileset.asset.gltfUpAxis || 'Y'
});

assert.strictEqual(selected.identifier, 'osm:way:1002427134');
assert.strictEqual(selected.featureId, 0);
assert.strictEqual(selected.vertexCount, 248);
assert.strictEqual(selected.positions.length, 248 * 3);
assert.ok(Math.abs(selected.positions[0] - -2564702.90234375) < 0.001);
assert.ok(Math.abs(selected.positions[1] - 4583147.164611816) < 0.001);
assert.ok(Math.abs(selected.positions[2] - 3606943.989746094) < 0.001);

const selectedMesh = geometry.readFeatureMesh({
  arrayBuffer: glb,
  identifiers: ['osm:way:1002427134'],
  tileTransform: tileset.root.transform,
  gltfUpAxis: 'Y'
});
assert.strictEqual(selectedMesh.vertexCount, 248);
assert.strictEqual(selectedMesh.triangleCount, 84);
assert.strictEqual(selectedMesh.indices.length, 84 * 3);
assert.ok(Math.abs(selectedMesh.positions[2] - 3606943.989746094) < 0.001);

assert.throws(() => geometry.readFeatureVertices({
  arrayBuffer: glb,
  identifiers: ['missing-feature'],
  tileTransform: tileset.root.transform
}), /not found/i);

const cube = [
  [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
  [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
  [0.5, 0.5, 0.5], [0.25, 0.25, 0.25]
];
const cubeHull = hullKernel.compute(cube.flat());
assert.strictEqual(cubeHull.positions.length / 3, 8);
assert.strictEqual(cubeHull.indices.length / 3, 12);
assert.ok(cubeHull.indices.every((index) => index >= 0 && index < 8));

assert.throws(() => hullKernel.compute([
  0, 0, 0,
  1, 0, 0,
  0, 1, 0,
  1, 1, 0
]), /coplanar/i);

assert.strictEqual(
  hullModule.toPolyhedralSurfaceWkt({
    positions: [1, 2, 3, 4, 5, 6, 7, 8, 9],
    indices: [0, 1, 2]
  }, 2),
  'POLYHEDRALSURFACE Z (((1.00 2.00 3.00, 4.00 5.00 6.00, 7.00 8.00 9.00, 1.00 2.00 3.00)))'
);

assert.strictEqual(
  hullModule.toGeographicPolyhedralSurfaceWkt({
    positions: [1, 2, 3, 4, 5, 6, 7, 8, 9],
    indices: [0, 1, 2]
  }, (x, y, z) => [x + 100, y + 20, z + 30], 2),
  'POLYHEDRALSURFACE Z (((101.00 22.00 33.00, 104.00 25.00 36.00, 107.00 28.00 39.00, 101.00 22.00 33.00)))'
);

let rendered = null;
let gridPayload = null;
let renderedGrid = null;
const analysis = hullModule.createModule({
  sources: [{
    name: '花果山建筑',
    tileset: {},
    tilesetUrl: '../exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json',
    catalogUrl: '../exports/citydb-3dtiler/huaguoshan_3dtiles/analysis/feature-catalog.json'
  }],
  loadCatalog: () => Promise.resolve({
    tileTransform: tileset.root.transform,
    gltfUpAxis: 'Y',
    features: { 'osm:way:1002427134': ['content/0_0_0.glb'] }
  }),
  fetchArrayBuffer: () => Promise.resolve(glb),
  envelopeMode: 'shell',
  computeHull: () => { throw new Error('shell mode must not compute a convex hull'); },
  renderHull: (hull) => { rendered = hull; },
  setStatus: () => {},
  toGeographicPosition: (x, y, z) => [x / 100000, y / 100000, z / 100000],
  requestGrid: (payload) => {
    gridPayload = payload;
    return Promise.resolve({ detail_level: payload.p_detail_level, cell_count: 3, gger_grids_with_box: { cells: [] } });
  },
  renderGrid: (grid) => { renderedGrid = grid; },
});

analysis.activate();
assert.strictEqual(analysis.isActive(), true);

analysis.analyzeFeature(['osm:way:1002427134'], analysis.sources()[0]).then((result) => {
  assert.strictEqual(result.identifier, 'osm:way:1002427134');
  assert.strictEqual(result.inputVertexCount, 248);
  assert.strictEqual(result.mode, 'shell');
  assert.strictEqual(result.inputTriangleCount, 84);
  assert.strictEqual(result.geometry.indices.length / 3, 84);
  assert.strictEqual(result.geometry.positions.length / 3, 44);
  assert.strictEqual(rendered, result.geometry);
  assert.ok(Number.isFinite(result.heightRange.min));
  assert.ok(result.heightRange.max > result.heightRange.min);
  return analysis.generateGrid(19, true);
}).then((grid) => {
  assert.strictEqual(grid.cell_count, 3);
  assert.strictEqual(gridPayload.p_detail_level, 19);
  assert.strictEqual(gridPayload.p_is_agg, true);
  assert.match(gridPayload.p_wkt, /^POLYHEDRALSURFACE Z/);
  assert.strictEqual(renderedGrid, grid);
  analysis.clear();
  analysis.deactivate();
  assert.strictEqual(analysis.isActive(), false);
  console.log('convex hull module tests passed');
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
