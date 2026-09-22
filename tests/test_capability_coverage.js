const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const ts = require('../frontend/admin/node_modules/typescript');

const source = fs.readFileSync(
  require.resolve('../frontend/admin/src/capabilityCoverage.ts'),
  'utf8',
);
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText;
const moduleBox = { exports: {} };
vm.runInNewContext(compiled, { module: moduleBox, exports: moduleBox.exports, require });
const coverage = moduleBox.exports;

const radial = coverage.generateCapabilityCoverage({
  longitude: 119.192932,
  latitude: 34.591952,
  radiusM: 5000,
  mode: 'radial',
  segments: 36,
});
assert.strictEqual(radial.type, 'Polygon');
assert.strictEqual(radial.coordinates[0].length, 37);
assert.deepStrictEqual(radial.coordinates[0][0], radial.coordinates[0][36]);

const sector = coverage.generateCapabilityCoverage({
  longitude: 119.192932,
  latitude: 34.591952,
  radiusM: 8000,
  mode: 'sector',
  azimuthStartDeg: 330,
  azimuthEndDeg: 30,
});
assert.strictEqual(sector.coordinates[0][0][0], 119.192932);
assert.strictEqual(sector.coordinates[0][0][1], 34.591952);
assert.deepStrictEqual(sector.coordinates[0][0], sector.coordinates[0].at(-1));

assert.strictEqual(coverage.validateCapabilityRangeParameters({
  min_range_m: 500,
  max_range_m: 100,
  range_basis: 'vendor_spec',
  frequency_min_mhz: null,
  frequency_max_mhz: null,
  positioning_mode: '',
}), '最小侦测距离不能大于最大侦测距离');
assert.throws(() => coverage.generateCapabilityCoverage({
  longitude: 119,
  latitude: 34,
  radiusM: 0,
  mode: 'radial',
}), /覆盖半径必须大于 0/);

console.log('capability coverage tests passed');
