'use strict';

const assert = require('assert');
const GGERGridBounds = require('../js/GGERGridBounds');
const GGERGridCode = require('../js/GGERGridCode');
const {
  assertClose,
  integrationEnabled,
  parseBbox,
  queryJsonRows,
  sqlNumber
} = require('./helpers/gger_db_parity');

if (!integrationEnabled()) {
  console.log('SKIP GGER level 21-32 parity: set RUN_GGER_DB_INTEGRATION=1 to query iBEST-DB');
  process.exit(0);
}

const probes = [
  { name: 'huaguoshan-positive-height', lon: 119.2602, lat: 34.6402, height: 20 },
  { name: 'near-dms-carry', lon: 119.999999, lat: 34.999999, height: 115000 },
  { name: 'exact-grid-boundary', lon: 120, lat: 35, height: 0 },
  { name: 'western-southern-underground', lon: -73.9857, lat: -33.9999, height: -100 },
  { name: 'high-altitude', lon: 118.54321, lat: 35.01234, height: 150000 }
];
const rows = [];

for (let level = 21; level <= 32; level += 1) {
  for (const probe of probes) {
    rows.push(`('${probe.name}', ${sqlNumber(probe.lon)}::double precision, ${sqlNumber(probe.lat)}::double precision, ${sqlNumber(probe.height)}::double precision, ${level}::integer)`);
  }
}

const databaseRows = queryJsonRows(`
  select jsonb_build_object(
    'name', name,
    'lon', lon,
    'lat', lat,
    'height', height,
    'level', level,
    'code', ST_AsText(cell, 'GGER'),
    'withBox', ST_WithBox(ST_AsGrids(cell), 'GGER')::jsonb
  )::text
  from (values ${rows.join(',\n')}) as probes(name, lon, lat, height, level)
  cross join lateral (
    select ST_AsGridcell3D(lon, lat, height, level) as cell
  ) encoded
  order by level, name;
`);

assert.strictEqual(databaseRows.length, 12 * probes.length);

for (const row of databaseRows) {
  const expectedCode = GGERGridCode.encode3D(row.lon, row.lat, row.height, row.level);
  const horizontal = GGERGridBounds.getCellBounds(row.lon, row.lat, row.level);
  const vertical = GGERGridBounds.getHeightBounds(row.height, row.level);
  const cells = row.withBox && row.withBox.cells;
  const context = `${row.name} L${row.level}`;

  assert.strictEqual(row.code, expectedCode, `${context} GGER 3D code`);
  assert.ok(Array.isArray(cells), `${context} ST_WithBox cells`);
  assert.strictEqual(cells.length, 1, `${context} ST_WithBox cell count`);
  assert.strictEqual(cells[0].code, expectedCode, `${context} ST_WithBox code`);

  const bbox = parseBbox(cells[0].bbox);
  assertClose(assert, horizontal.west, bbox.west, 1e-8, `${context} west`);
  assertClose(assert, horizontal.east, bbox.east, 1e-8, `${context} east`);
  assertClose(assert, horizontal.south, bbox.south, 1e-8, `${context} south`);
  assertClose(assert, horizontal.north, bbox.north, 1e-8, `${context} north`);
  assertClose(assert, vertical.minHeight, bbox.minHeight, 0.001, `${context} minimum height`);
  assertClose(assert, vertical.maxHeight, bbox.maxHeight, 0.001, `${context} maximum height`);
}

console.log(`PASS GGER level 21-32 parity: ${databaseRows.length} code and bbox comparisons against ST_AsGridcell3D/ST_WithBox`);
