/*
 * 今日飞行运营看板.
 *
 * Owns the high-level flight operation view model, fallback data, selection
 * state, and route-preview rendering seam. The backend remains responsible for
 * summary semantics; this module only displays API data and safely normalizes
 * route preview GeoJSON for Cesium.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.FlightOperationDashboard = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    function escapeHtml(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function toFiniteNumber(value) {
        var num = Number(value);
        return Number.isFinite(num) ? num : null;
    }

    function normalizePosition(value) {
        var lon;
        var lat;
        var height;
        if (!Array.isArray(value) || value.length < 2) return null;
        lon = toFiniteNumber(value[0]);
        lat = toFiniteNumber(value[1]);
        height = toFiniteNumber(value[2]);
        if (lon == null || lat == null || lon < -180 || lon > 180 || lat < -90 || lat > 90) return null;
        return [lon, lat, height == null ? 120 : height];
    }

    function normalizeLine(coordinates) {
        var points = Array.isArray(coordinates) ? coordinates.map(normalizePosition).filter(Boolean) : [];
        return points.length >= 2 ? { kind: 'line', coordinates: points } : null;
    }

    function normalizeRing(coordinates) {
        var points = Array.isArray(coordinates) ? coordinates.map(normalizePosition).filter(Boolean) : [];
        return points.length >= 4 ? points : null;
    }

    function normalizePolygon(coordinates) {
        var rings = Array.isArray(coordinates) ? coordinates.map(normalizeRing).filter(Boolean) : [];
        return rings.length ? { kind: 'polygon', rings: rings } : null;
    }

    function geometryFromInput(input) {
        if (!input) return null;
        if (input.type === 'Feature') return input.geometry || null;
        if (input.type === 'FeatureCollection') {
            return input.features && input.features[0] && input.features[0].geometry ? input.features[0].geometry : null;
        }
        return input;
    }

    function normalizeRoutePreviewGeometry(input) {
        var geometry = geometryFromInput(input);
        var items = [];
        if (!geometry || !geometry.type) return { ok: false, items: [], message: 'missing route preview geometry' };
        if (geometry.type === 'Point') {
            var point = normalizePosition(geometry.coordinates);
            if (point) items.push({ kind: 'point', coordinate: point });
        } else if (geometry.type === 'MultiPoint') {
            (geometry.coordinates || []).forEach(function(coordinate) {
                var point = normalizePosition(coordinate);
                if (point) items.push({ kind: 'point', coordinate: point });
            });
        } else if (geometry.type === 'LineString') {
            var line = normalizeLine(geometry.coordinates);
            if (line) items.push(line);
        } else if (geometry.type === 'MultiLineString') {
            (geometry.coordinates || []).forEach(function(lineCoordinates) {
                var line = normalizeLine(lineCoordinates);
                if (line) items.push(line);
            });
        } else if (geometry.type === 'Polygon') {
            var polygon = normalizePolygon(geometry.coordinates);
            if (polygon) items.push(polygon);
        } else if (geometry.type === 'MultiPolygon') {
            (geometry.coordinates || []).forEach(function(polygonCoordinates) {
                var polygon = normalizePolygon(polygonCoordinates);
                if (polygon) items.push(polygon);
            });
        } else {
            return { ok: false, items: [], message: 'unsupported route preview geometry: ' + geometry.type };
        }
        if (!items.length) return { ok: false, items: [], message: 'invalid route preview geometry coordinates' };
        return { ok: true, geometryType: geometry.type, items: items, message: null };
    }

    function routePreviewSourceLabel(plan) {
        var source = plan && plan.route_preview_source;
        if (source === 'third_party') return '第三方航线预览（非平台规划结果）';
        if (source === 'platform') return '平台航线预览';
        if (source === 'manual') return '人工录入航线预览';
        return '无航线预览';
    }

    function formatDateTime(value) {
        var date = value ? new Date(value) : null;
        if (!date || !Number.isFinite(date.getTime())) return '--';
        return date.toLocaleString('zh-CN', { hour12: false, month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
    }

    function formatInterval(plan) {
        return formatDateTime(plan && plan.planned_start_at) + ' — ' + formatDateTime(plan && plan.planned_end_at);
    }

    function formatExecutionRate(value) {
        var num = Number(value);
        if (!Number.isFinite(num)) return '--';
        return Math.round(num * 100) + '%';
    }

    function chinaDayBounds(now) {
        var base = now ? new Date(now) : new Date();
        var local = new Date(base.toLocaleString('en-US', { timeZone: 'Asia/Shanghai' }));
        var start = new Date(local.getFullYear(), local.getMonth(), local.getDate(), 9, 0, 0);
        var mid = new Date(local.getFullYear(), local.getMonth(), local.getDate(), 13, 30, 0);
        var end = new Date(local.getFullYear(), local.getMonth(), local.getDate(), 18, 0, 0);
        return { start: start, mid: mid, end: end };
    }

    function fallbackDashboardData(now) {
        var bounds = chinaDayBounds(now);
        return {
            business_window: { time_zone: 'Asia/Shanghai' },
            summary: {
                planned_sortie_count: 5,
                completed_actual_sortie_count: 2,
                cumulative_actual_sortie_count: 3,
                pending_planned_sortie_count: 2,
                execution_rate: 0.4,
                patrol_count: 3,
                aircraft_on_mission_count: 1,
                idle_aircraft_count: 2,
            },
            approval_reported_flights: [{
                id: 'demo-approval-1',
                plan_type: 'approval_reported',
                status: 'pending',
                pilot: '张三',
                reporting_unit: '花果山通航服务队',
                approval_status: 'approved',
                external_source: 'demo-third-party',
                external_id: 'HGSD-20260705-001',
                planned_start_at: bounds.start.toISOString(),
                planned_end_at: new Date(bounds.start.getTime() + 90 * 60 * 1000).toISOString(),
                planned_sortie_count: 1,
                route_preview_source: 'third_party',
                route_preview_geometry: { type: 'LineString', coordinates: [[119.245, 34.642, 150], [119.268, 34.651, 150], [119.286, 34.646, 150]] },
            }],
            patrol_tasks: [{
                id: 'demo-patrol-1',
                plan_type: 'patrol_task',
                status: 'in_progress',
                name: '花果山北坡林火巡查',
                unit: '连云港低空巡查队',
                task_type: '林火巡查',
                planned_start_at: bounds.mid.toISOString(),
                planned_end_at: bounds.end.toISOString(),
                planned_sortie_count: 3,
                route_preview_source: 'platform',
                route_preview_geometry: { type: 'Polygon', coordinates: [[[119.255, 34.635, 120], [119.292, 34.637, 120], [119.296, 34.661, 120], [119.252, 34.662, 120], [119.255, 34.635, 120]]] },
            }],
        };
    }

    function normalizeDashboardData(data) {
        data = data || fallbackDashboardData();
        return {
            business_window: data.business_window || {},
            summary: data.summary || {},
            approval_reported_flights: Array.isArray(data.approval_reported_flights) ? data.approval_reported_flights : [],
            patrol_tasks: Array.isArray(data.patrol_tasks) ? data.patrol_tasks : [],
        };
    }

    function create(options) {
        options = options || {};
        var rpc = options.rpc || function() { return Promise.reject(new Error('RPC unavailable')); };
        var log = options.log || function() {};
        var getCesium = options.getCesium || function() { return typeof Cesium !== 'undefined' ? Cesium : null; };
        var rootEl = null;
        var viewer = options.viewer || null;
        var routeEntities = [];
        var state = {
            data: normalizeDashboardData(options.initialData || fallbackDashboardData()),
            selectedPlanId: null,
            previewMessage: '选择飞行计划后展示航线预览。',
            usingFallback: false,
        };

        function allPlans() {
            return state.data.approval_reported_flights.concat(state.data.patrol_tasks);
        }

        function selectedPlan() {
            return allPlans().find(function(plan) { return String(plan.id) === String(state.selectedPlanId); }) || null;
        }

        function clearRoutePreview() {
            if (options.clearRoutePreview) {
                options.clearRoutePreview();
                return;
            }
            if (!viewer || !viewer.entities) return;
            routeEntities.forEach(function(entity) { viewer.entities.remove(entity); });
            routeEntities = [];
        }

        function degreesToCartesian(CesiumRuntime, coordinates) {
            return CesiumRuntime.Cartesian3.fromDegrees(coordinates[0], coordinates[1], coordinates[2]);
        }

        function renderCesiumRoutePreview(plan, normalized) {
            var CesiumRuntime = getCesium();
            clearRoutePreview();
            if (!viewer || !viewer.entities || !CesiumRuntime || !normalized.ok) return;
            normalized.items.forEach(function(item, index) {
                var entity;
                if (item.kind === 'line') {
                    entity = viewer.entities.add({
                        name: 'flight-operation-route-' + plan.id + '-' + index,
                        polyline: {
                            positions: item.coordinates.map(function(coordinate) { return degreesToCartesian(CesiumRuntime, coordinate); }),
                            width: 4,
                            material: CesiumRuntime.Color.CYAN.withAlpha(0.92),
                            clampToGround: false,
                        },
                    });
                } else if (item.kind === 'polygon') {
                    entity = viewer.entities.add({
                        name: 'flight-operation-area-' + plan.id + '-' + index,
                        polygon: {
                            hierarchy: item.rings[0].map(function(coordinate) { return degreesToCartesian(CesiumRuntime, coordinate); }),
                            material: CesiumRuntime.Color.CYAN.withAlpha(0.18),
                            outline: true,
                            outlineColor: CesiumRuntime.Color.CYAN,
                        },
                    });
                } else if (item.kind === 'point') {
                    entity = viewer.entities.add({
                        name: 'flight-operation-point-' + plan.id + '-' + index,
                        position: degreesToCartesian(CesiumRuntime, item.coordinate),
                        point: { pixelSize: 12, color: CesiumRuntime.Color.ORANGE, outlineColor: CesiumRuntime.Color.WHITE, outlineWidth: 2 },
                    });
                }
                if (entity) routeEntities.push(entity);
            });
        }

        function renderRoutePreview(plan, normalized) {
            if (options.renderRoutePreview) {
                options.renderRoutePreview(plan, normalized);
            } else {
                renderCesiumRoutePreview(plan, normalized);
            }
        }

        function renderSummaryCards() {
            var summary = state.data.summary || {};
            var cards = [
                ['执行率', formatExecutionRate(summary.execution_rate)],
                ['计划架次', summary.planned_sortie_count == null ? '--' : summary.planned_sortie_count],
                ['累计实际', summary.cumulative_actual_sortie_count == null ? '--' : summary.cumulative_actual_sortie_count],
                ['待执行', summary.pending_planned_sortie_count == null ? '--' : summary.pending_planned_sortie_count],
                ['今日巡检', summary.patrol_count == null ? '--' : summary.patrol_count],
                ['任务中飞行器', summary.aircraft_on_mission_count == null ? '--' : summary.aircraft_on_mission_count],
                ['空闲飞行器', summary.idle_aircraft_count == null ? '--' : summary.idle_aircraft_count],
            ];
            return '<div class="flight-operation-summary">' + cards.map(function(card) {
                return '<div class="flight-operation-card"><span>' + escapeHtml(card[0]) + '</span><strong>' + escapeHtml(card[1]) + '</strong></div>';
            }).join('') + '</div>';
        }

        function renderApprovalItem(plan) {
            var selected = String(plan.id) === String(state.selectedPlanId);
            return '<button type="button" class="flight-operation-item' + (selected ? ' is-selected' : '') + '" data-flight-operation-plan-id="' + escapeHtml(plan.id) + '">' +
                '<strong>' + escapeHtml(plan.pilot || '未知飞手') + ' · ' + escapeHtml(plan.reporting_unit || '未知单位') + '</strong>' +
                '<span>' + escapeHtml(formatInterval(plan)) + '</span>' +
                '<span>审批/报备：' + escapeHtml(plan.approval_status || 'unknown') + ' · ' + escapeHtml(routePreviewSourceLabel(plan)) + '</span>' +
                '</button>';
        }

        function renderPatrolItem(plan) {
            var selected = String(plan.id) === String(state.selectedPlanId);
            return '<button type="button" class="flight-operation-item' + (selected ? ' is-selected' : '') + '" data-flight-operation-plan-id="' + escapeHtml(plan.id) + '">' +
                '<strong>' + escapeHtml(plan.name || '未命名巡查任务') + '</strong>' +
                '<span>' + escapeHtml(plan.unit || '未知单位') + ' · ' + escapeHtml(plan.task_type || '未知类型') + ' · ' + escapeHtml(plan.status || 'pending') + '</span>' +
                '<span>' + escapeHtml(formatInterval(plan)) + '</span>' +
                '</button>';
        }

        function renderDetail() {
            var plan = selectedPlan();
            if (!plan) return '<div class="flight-operation-detail">选择列表项查看来源与航线预览。</div>';
            return '<div class="flight-operation-detail">' +
                '<strong>' + escapeHtml(plan.plan_type === 'approval_reported' ? (plan.pilot || '审批报备飞行') : (plan.name || '巡查任务')) + '</strong>' +
                '<span>' + escapeHtml(routePreviewSourceLabel(plan)) + '</span>' +
                (plan.external_source ? '<span>来源：' + escapeHtml(plan.external_source) + ' / ' + escapeHtml(plan.external_id || '--') + '</span>' : '') +
                '<span>' + escapeHtml(state.previewMessage) + '</span>' +
                '</div>';
        }

        function html() {
            return '<section class="flight-operation-dashboard" aria-label="今日飞行运营看板">' +
                '<div class="flight-operation-heading"><h2>今日飞行运营看板</h2><button type="button" data-flight-operation-action="refresh">刷新</button></div>' +
                (state.usingFallback ? '<p class="flight-operation-hint">API 不可用，当前展示本地演示数据。</p>' : '') +
                renderSummaryCards() +
                '<div class="flight-operation-lists">' +
                '<section><h3>审批报备飞行</h3><div class="flight-operation-list">' + (state.data.approval_reported_flights.map(renderApprovalItem).join('') || '<div class="flight-operation-empty">今日无审批报备飞行。</div>') + '</div></section>' +
                '<section><h3>巡查任务</h3><div class="flight-operation-list">' + (state.data.patrol_tasks.map(renderPatrolItem).join('') || '<div class="flight-operation-empty">今日无巡查任务。</div>') + '</div></section>' +
                '</div>' + renderDetail() + '</section>';
        }

        function render() {
            if (!rootEl) return;
            rootEl.innerHTML = html();
        }

        function selectPlan(planId) {
            var plan;
            var normalized;
            state.selectedPlanId = planId;
            plan = selectedPlan();
            if (!plan) {
                clearRoutePreview();
                state.previewMessage = '未找到所选飞行计划。';
                render();
                return null;
            }
            normalized = normalizeRoutePreviewGeometry(plan.route_preview_geometry);
            state.previewMessage = normalized.ok ? '已在地图展示航线预览。' : normalized.message;
            renderRoutePreview(plan, normalized);
            render();
            return plan;
        }

        function setDashboardData(data) {
            state.data = normalizeDashboardData(data);
            if (!selectedPlan()) state.selectedPlanId = null;
            render();
        }

        function load() {
            return rpc('get_today_flight_operation_dashboard', {}).then(function(data) {
                state.usingFallback = false;
                setDashboardData(data);
                return state.data;
            }).catch(function(error) {
                state.usingFallback = true;
                setDashboardData(fallbackDashboardData());
                log('今日飞行运营 API 不可用，使用本地演示数据：' + error.message);
                return state.data;
            });
        }

        function handleClick(event) {
            var button = event.target.closest('[data-flight-operation-plan-id], [data-flight-operation-action]');
            if (!button) return;
            if (button.dataset.flightOperationAction === 'refresh') {
                load();
            } else if (button.dataset.flightOperationPlanId != null) {
                selectPlan(button.dataset.flightOperationPlanId);
            }
        }

        function mount(container) {
            rootEl = container;
            rootEl.addEventListener('click', handleClick);
            render();
            load();
            return api;
        }

        function destroy() {
            clearRoutePreview();
            if (rootEl) rootEl.removeEventListener('click', handleClick);
            rootEl = null;
        }

        var api = {
            mount: mount,
            load: load,
            destroy: destroy,
            setViewer: function(nextViewer) { viewer = nextViewer; },
            setDashboardData: setDashboardData,
            selectPlan: selectPlan,
            selectedPlan: selectedPlan,
            _private: {
                normalizeRoutePreviewGeometry: normalizeRoutePreviewGeometry,
                fallbackDashboardData: fallbackDashboardData,
                routePreviewSourceLabel: routePreviewSourceLabel,
            },
        };
        return api;
    }

    return {
        create: create,
        _private: {
            normalizeRoutePreviewGeometry: normalizeRoutePreviewGeometry,
            fallbackDashboardData: fallbackDashboardData,
            routePreviewSourceLabel: routePreviewSourceLabel,
        },
    };
}));
