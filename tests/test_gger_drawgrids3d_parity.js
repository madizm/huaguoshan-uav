'use strict';

const assert = require('assert');
const GGERGridBounds = require('../js/GGERGridBounds');
const {
  assertClose,
  integrationEnabled,
  queryJsonRows,
  sqlNumber
} = require('./helpers/gger_db_parity');

if (!integrationEnabled()) {
  console.log('SKIP GGER level 3-20 parity: set RUN_GGER_DB_INTEGRATION=1 to query iBEST-DB');
  process.exit(0);
}

const probes = [
  { name: 'huaguoshan-positive-height', lon: 119.2602, lat: 34.6402, height: 20 },
  { name: 'near-dms-carry', lon: 119.9999, lat: 34.9999, height: 115000 },
  { name: 'exact-grid-boundary', lon: 120, lat: 35, height: 0 },
  { name: 'western-southern-underground', lon: -73.9857, lat: -33.9999, height: -100 }
];
const rows = [];

for (let level = 3; level <= 20; level += 1) {
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
    'draw', ST_DrawGrids3D(lon, lat, height, lon, lat, height, level)::jsonb
  )::text
  from (values ${rows.join(',\n')}) as probes(name, lon, lat, height, level)
  order by level, name;
`);

assert.strictEqual(databaseRows.length, 18 * probes.length);

for (const row of databaseRows) {
  const horizontal = GGERGridBounds.getCellBounds(row.lon, row.lat, row.level);
  const vertical = GGERGridBounds.getHeightBounds(row.height, row.level);
  const context = `${row.name} L${row.level}`;

  assert.strictEqual(row.draw.lngs.length, 2, `${context} longitude planes`);
  assert.strictEqual(row.draw.lats.length, 2, `${context} latitude planes`);
  assert.strictEqual(row.draw.heights.length, 2, `${context} height planes`);

  assertClose(assert, horizontal.west, row.draw.lngs[0], 1e-10, `${context} west`);
  assertClose(assert, horizontal.east, row.draw.lngs[1], 1e-10, `${context} east`);
  assertClose(assert, horizontal.south, row.draw.lats[0], 1e-10, `${context} south`);
  assertClose(assert, horizontal.north, row.draw.lats[1], 1e-10, `${context} north`);
  assertClose(assert, vertical.minHeight, row.draw.heights[0], 0.05, `${context} minimum height`);
  assertClose(assert, vertical.maxHeight, row.draw.heights[1], 0.05, `${context} maximum height`);
}

console.log(`PASS GGER level 3-20 parity: ${databaseRows.length} point-cell comparisons against ST_DrawGrids3D`);
