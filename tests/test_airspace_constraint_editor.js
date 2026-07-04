const assert = require('assert');

const AirspaceConstraintEditor = require('../js/AirspaceConstraintEditor');

const points = [
  { lon: 119.1, lat: 34.1 },
  { lon: 119.2, lat: 34.1 },
  { lon: 119.2, lat: 34.2 },
];

const geometry = AirspaceConstraintEditor._private.drawPointsToMultiPolygon(points);
assert.deepStrictEqual(geometry, {
  type: 'MultiPolygon',
  coordinates: [[[
    [119.1, 34.1],
    [119.2, 34.1],
    [119.2, 34.2],
    [119.1, 34.1],
  ]]],
});

assert.deepStrictEqual(
  AirspaceConstraintEditor._private.geometryToDrawPoints(geometry),
  points
);

const samples = AirspaceConstraintEditor._private.terrainSamplePoints(points);
assert.strictEqual(samples.length, 7);
assert.deepStrictEqual(
  AirspaceConstraintEditor._private.summarizeHeights([
    { height: 12 },
    { height: 18 },
    { height: null },
  ], 'terrain provider'),
  { min: 0, max: 18, source: 'terrain provider' }
);

console.log('airspace constraint editor tests passed');
