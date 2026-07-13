const assert = require('assert');

require('../frontend/src/features/suitable-footprint/suitable-footprint-module.js');

let observedPath = null;
let observedOptions = null;

const result = globalThis.HuaguoshanSuitableFootprint.requestFootprints((path, options) => {
  observedPath = path;
  observedOptions = options;
  return Promise.resolve({ type: 'FeatureCollection', features: [] });
}, 'api', 'suitable_fly_zone_footprints');

result.then((geojson) => {
  assert.deepStrictEqual(geojson, { type: 'FeatureCollection', features: [] });
  assert.strictEqual(observedPath, '/suitable_fly_zone_footprints?select=id,name,geom');
  assert.strictEqual(observedOptions.profile, 'api');
  assert.strictEqual(observedOptions.headers.Accept, 'application/geo+json');
  assert.match(observedOptions.errorLabel, /GeoJSON/);
  assert.deepStrictEqual(globalThis.HuaguoshanSuitableFootprint.airspaceBand('wAirspace'), { aglMin: 0, aglMax: 120 });
  assert.deepStrictEqual(globalThis.HuaguoshanSuitableFootprint.airspaceBand('gAirspace'), { aglMin: 120, aglMax: 300 });
  assert.strictEqual(globalThis.HuaguoshanSuitableFootprint.airspaceBand('footprint'), null);
  console.log('suitable footprint module tests passed');
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
