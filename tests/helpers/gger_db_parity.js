'use strict';

const { execFileSync } = require('child_process');

function integrationEnabled() {
  return process.env.RUN_GGER_DB_INTEGRATION === '1';
}

function databaseConfig() {
  return {
    host: process.env.GGER_DB_HOST || '10.1.109.151',
    port: process.env.GGER_DB_PORT || '5432',
    database: process.env.GGER_DB_NAME || 'huaguoshan_projd',
    user: process.env.GGER_DB_USER || 'postgres',
    password: process.env.GGER_DB_PASSWORD || process.env.PGPASSWORD || 'postgres'
  };
}

function queryJsonRows(sql) {
  const config = databaseConfig();
  const output = execFileSync(process.env.PSQL_BIN || 'psql', [
    '-h', config.host,
    '-p', config.port,
    '-U', config.user,
    '-d', config.database,
    '-X',
    '-v', 'ON_ERROR_STOP=1',
    '-A',
    '-t',
    '-q',
    '-c', sql
  ], {
    encoding: 'utf8',
    env: Object.assign({}, process.env, { PGPASSWORD: config.password }),
    stdio: ['ignore', 'pipe', 'pipe']
  });

  return output.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

function sqlNumber(value) {
  if (!Number.isFinite(value)) throw new TypeError('SQL test values must be finite numbers');
  return String(value);
}

function assertClose(assert, actual, expected, tolerance, label) {
  const difference = Math.abs(actual - expected);
  assert.ok(
    difference <= tolerance,
    `${label}: expected ${expected}, got ${actual}, difference ${difference}, tolerance ${tolerance}`
  );
}

function parseBbox(bbox) {
  const values = String(bbox).match(/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g).map(Number);
  if (values.length !== 6 || values.some((value) => !Number.isFinite(value))) {
    throw new Error(`Invalid iBEST-DB bbox: ${bbox}`);
  }
  return {
    west: values[0],
    south: values[1],
    minHeight: values[2],
    east: values[3],
    north: values[4],
    maxHeight: values[5]
  };
}

module.exports = {
  assertClose,
  integrationEnabled,
  parseBbox,
  queryJsonRows,
  sqlNumber
};
