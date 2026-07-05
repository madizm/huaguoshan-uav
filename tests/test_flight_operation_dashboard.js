const assert = require('assert');

const FlightOperationDashboard = require('../js/FlightOperationDashboard');

const line = FlightOperationDashboard._private.normalizeRoutePreviewGeometry({
  type: 'LineString',
  coordinates: [[119.1, 34.6, 120], [119.2, 34.7, 130]],
});
assert.strictEqual(line.ok, true);
assert.deepStrictEqual(line.items.map((item) => item.kind), ['line']);
assert.deepStrictEqual(line.items[0].coordinates[0], [119.1, 34.6, 120]);

const polygon = FlightOperationDashboard._private.normalizeRoutePreviewGeometry({
  type: 'MultiPolygon',
  coordinates: [[[
    [119, 34], [119.1, 34], [119.1, 34.1], [119, 34.1], [119, 34],
  ]]],
});
assert.strictEqual(polygon.ok, true);
assert.deepStrictEqual(polygon.items.map((item) => item.kind), ['polygon']);

const points = FlightOperationDashboard._private.normalizeRoutePreviewGeometry({
  type: 'MultiPoint',
  coordinates: [[119, 34, 80], [119.2, 34.2]],
});
assert.strictEqual(points.ok, true);
assert.deepStrictEqual(points.items.map((item) => item.kind), ['point', 'point']);
assert.strictEqual(points.items[1].coordinate[2], 120);

const invalid = FlightOperationDashboard._private.normalizeRoutePreviewGeometry({ type: 'GeometryCollection', geometries: [] });
assert.strictEqual(invalid.ok, false);
assert.match(invalid.message, /unsupported/i);

let rendered = null;
const dashboard = FlightOperationDashboard.create({
  rpc: () => Promise.resolve({
    summary: { planned_sortie_count: 1, execution_rate: null },
    approval_reported_flights: [{
      id: 7,
      plan_type: 'approval_reported',
      pilot: '张三',
      reporting_unit: '第三方单位',
      approval_status: 'approved',
      route_preview_source: 'third_party',
      route_preview_geometry: { type: 'Point', coordinates: [119, 34, 90] },
    }],
    patrol_tasks: [],
  }),
  renderRoutePreview: (plan, normalized) => { rendered = { plan, normalized }; },
  log: () => {},
});

dashboard.setDashboardData({
  summary: { planned_sortie_count: 1, execution_rate: null },
  approval_reported_flights: [{
    id: 7,
    plan_type: 'approval_reported',
    pilot: '张三',
    reporting_unit: '第三方单位',
    approval_status: 'approved',
    route_preview_source: 'third_party',
    route_preview_geometry: { type: 'Point', coordinates: [119, 34, 90] },
  }],
  patrol_tasks: [],
});

const selected = dashboard.selectPlan(7);
assert.strictEqual(selected.id, 7);
assert.strictEqual(dashboard.selectedPlan().id, 7);
assert.strictEqual(rendered.normalized.ok, true);
assert.strictEqual(rendered.normalized.items[0].kind, 'point');
assert.match(FlightOperationDashboard._private.routePreviewSourceLabel(selected), /第三方航线预览/);

const routeFirstPlan = {
  route_preview_source: 'platform',
  route_preview_geometry: { type: 'LineString', coordinates: [[0, 0], [1, 1]] },
  active_execution_route: {
    source: 'third_party',
    route_grid_codes: ['GGER-001', 'GGER-002'],
    route_geometry: { type: 'Point', coordinates: [119, 34, 100] },
    external_source: 'forest-platform',
    external_id: 'route-9',
    platform_validated: false,
    platform_validation_label: '平台未复核可飞',
  },
};
assert.match(FlightOperationDashboard._private.routePreviewSourceLabel(routeFirstPlan), /第三方执行用航线/);
assert.deepStrictEqual(
  FlightOperationDashboard._private.routeGeometryForPreview(routeFirstPlan),
  routeFirstPlan.active_execution_route.route_geometry,
);
assert.strictEqual(
  FlightOperationDashboard._private.formatExecutionRouteGridCodes(routeFirstPlan),
  'GGER-001、GGER-002',
);
assert.match(FlightOperationDashboard._private.renderExecutionRouteDetail(routeFirstPlan), /GGER-001、GGER-002/);
assert.match(FlightOperationDashboard._private.renderExecutionRouteDetail(routeFirstPlan), /平台未复核可飞/);
assert.match(FlightOperationDashboard._private.renderExecutionRouteDetail(routeFirstPlan), /forest-platform \/ route-9/);
const gridCells = FlightOperationDashboard._private.executionRouteGridCells({
  active_execution_route: {
    route_grid_with_box: {
      cells: [
        { code: 'GZ001', bbox: '(119 34 10,119.1 34.1 20)' },
        { code: 'bad', bbox: null },
      ],
    },
  },
});
assert.strictEqual(gridCells.length, 1);
assert.strictEqual(gridCells[0].code, 'GZ001');
assert.strictEqual(gridCells[0].maxHeight, 20);


const fallback = FlightOperationDashboard._private.fallbackDashboardData(new Date('2026-07-05T08:00:00+08:00'));
assert.ok(fallback.summary.planned_sortie_count > 0);
assert.ok(fallback.approval_reported_flights.length > 0);
assert.ok(fallback.patrol_tasks.length > 0);

console.log('flight operation dashboard tests passed');
