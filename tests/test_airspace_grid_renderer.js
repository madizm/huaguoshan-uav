const assert = require('assert');

const AirspaceGridRenderer = require('../js/AirspaceGridRenderer');
const BeidouAirspaceGrid = require('../js/BeidouAirspaceGrid');
const GGERAirspaceGrid = require('../js/GGERAirspaceGrid');

function options(overrides) {
  return Object.assign({
    minLatitude: -89.999999,
    maxLatitude: 89.999999,
    rectanglePaddingCells: 0,
    maxAutoLevel: 23,
    targetCellPixels: 120,
  }, overrides || {});
}

assert.strictEqual(typeof AirspaceGridRenderer.createGridModule, 'function');

assert.strictEqual(typeof BeidouAirspaceGrid.create, 'function');
assert.strictEqual(typeof GGERAirspaceGrid.create, 'function');
assert.strictEqual(typeof BeidouAirspaceGrid._private.enumerateCells, 'function');
assert.strictEqual(typeof GGERAirspaceGrid._private.enumerateCells, 'function');

assert.strictEqual(BeidouAirspaceGrid._private.levelFromHeight(100000, 10), 4);
assert.strictEqual(BeidouAirspaceGrid._private.levelFromHeight(0, 10), 1);
assert.strictEqual(GGERAirspaceGrid._private.levelFromHeight(100000, 32), 18);
assert.strictEqual(GGERAirspaceGrid._private.levelFromHeight(0, 32), 8);

const beidouCells = BeidouAirspaceGrid._private.enumerateCells(
  { west: 119.26, south: 34.64, east: 119.27, north: 34.65 },
  5,
  1000,
  options({ minLatitude: -87.999999, maxLatitude: 87.999999 })
);
assert.strictEqual(beidouCells.exceeded, false);
assert.strictEqual(beidouCells.cells.length, 81);
assert.strictEqual(beidouCells.cells[0].code2D, 'N50IA510896');

const ggerCells = GGERAirspaceGrid._private.enumerateCells(
  { west: 119.26, south: 34.64, east: 119.27, north: 34.65 },
  19,
  1000,
  options()
);
assert.strictEqual(ggerCells.exceeded, false);
assert.strictEqual(ggerCells.cells.length, 81);
assert.strictEqual(ggerCells.cells[0].code2D, 'G0013101312013311221');

console.log('airspace grid renderer tests passed');
