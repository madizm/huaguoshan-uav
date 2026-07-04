const assert = require('assert');

const FlightObstacleSituationLayer = require('../js/FlightObstacleSituationLayer');

const layer = FlightObstacleSituationLayer.create({
  getViewer: () => null,
  getCesium: () => null,
  log: () => {},
  renderError: () => {},
  showPanel: () => {},
  getLimit: () => 200,
  getTerrainLodMode: () => 'auto',
  requestSource: () => Promise.resolve([]),
  requestTerrainLod: () => Promise.resolve([]),
  helpers: {
    extractGridCells: () => [],
    cellsBounds: () => null,
    sortedGridLayers: () => [],
    addBoxEdges: () => {},
    gridLayerIndex: () => 0,
    gridLayerMaterial: () => null,
    mergeBounds: () => null,
  },
});

assert.deepStrictEqual(layer.getSourceFilters(), {
  building: true,
  terrain: false,
  no_fly_zone: true,
  temp_control: true,
});
assert.strictEqual(layer._private.sourceLabel('no_fly_zone'), '长期禁飞区');
assert.strictEqual(layer._private.terrainBboxCacheKey({ west: 119.261, south: 34.642, east: 119.279, north: 34.659 }), '11926:3464:11927:3465');
assert.strictEqual(layer._private.terrainPointCacheKey({ lon: 119.2683, lat: 34.6469 }), 'center:119268:34646');

layer.setSourceEnabled('terrain', true);
assert.strictEqual(layer.getSourceFilters().terrain, true);
layer.invalidate();
layer.destroy();

console.log('flight obstacle situation layer tests passed');
