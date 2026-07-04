const assert = require('assert');

const FlightPathWorkbench = require('../js/FlightPathWorkbench');

const workbench = FlightPathWorkbench.create({
  rpc: () => Promise.resolve(null),
  log: () => {},
  renderError: () => {},
  getCesium: () => null,
  map: { pickLonLat: () => null },
  helpers: {
    parseBboxText: () => null,
    extractGridCells: () => [],
    cellsBounds: () => null,
    sortedGridLayers: () => [],
    addBoxEdges: () => {},
    gridLayerIndex: () => 0,
    gridLayerMaterial: () => null,
    formatMeters: (value, digits) => Number(value).toFixed(digits == null ? 1 : digits) + 'm',
  },
});

assert.strictEqual(typeof workbench.handleMapClick, 'function');
assert.strictEqual(workbench.isDrawing(), false);
workbench.setDrawMode('start');
assert.strictEqual(workbench.isDrawing(), true);

const normalized = workbench._private.normalizedFlightPathPoints([
  { role: 'end', lon: 3 },
  { role: 'waypoint', lon: 2 },
  { role: 'start', lon: 1 },
]);
assert.deepStrictEqual(normalized.map((point) => point.role), ['start', 'waypoint', 'end']);
assert.deepStrictEqual(normalized.map((point) => point.seq), [0, 1, 2]);

const cells = workbench._private.flightPathGridCellsFromResult({
  route_grid_with_box: {
    cells: [
      { code: 'G1', bbox: '(119 34 10,119.1 34.1 20)' },
      { code: 'bad', bbox: null },
    ],
  },
});
assert.deepStrictEqual(cells, []);

console.log('flight path workbench tests passed');
