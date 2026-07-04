/*
 * Flight obstacle situation layer for the Huaguoshan workbench.
 *
 * Owns 飞行障碍 source filters, terrain LOD loading, Cesium primitive rendering,
 * bounds, cache, and panel rendering. The shell supplies map/RPC/DOM adapters.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.FlightObstacleSituationLayer = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    var DEFAULT_TERRAIN_LOD_RULES = [
        { minHeight: 8000, lod: 0, limit: 200, bboxBuffer: 0.50, label: 'Overview' },
        { minHeight: 2000, lod: 1, limit: 500, bboxBuffer: 0.25, label: 'Medium' },
        { minHeight: 0, lod: 2, limit: 800, bboxBuffer: 0.15, label: 'Fine' }
    ];

    var DEFAULT_SOURCES = {
        building: { label: '建筑', color: '#4cc9f0' },
        terrain: { label: '地形', color: '#8bc34a' },
        no_fly_zone: { label: '长期禁飞区', color: '#ff3b30' },
        temp_control: { label: '临时禁飞/管制', color: '#ffb000' }
    };

    function escapeHtml(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function create(options) {
        var getViewer = options.getViewer;
        var getCesium = options.getCesium || function() { return typeof Cesium === 'undefined' ? null : Cesium; };
        var huaguoshan = options.huaguoshan || { lon: 119.2683, lat: 34.6469 };
        var log = options.log || function() {};
        var renderError = options.renderError || function() {};
        var showPanel = options.showPanel || function() {};
        var getLimit = options.getLimit || function() { return state.maxItems; };
        var getTerrainLodMode = options.getTerrainLodMode || function() { return state.terrainLod.mode; };
        var requestSource = options.requestSource;
        var requestTerrainLod = options.requestTerrainLod;
        var helpers = options.helpers;
        var terrainLodRules = options.terrainLodRules || DEFAULT_TERRAIN_LOD_RULES;
        var sources = options.sources || DEFAULT_SOURCES;
        var state = {
            enabled: false,
            primitive: null,
            items: [],
            bounds: null,
            cache: {},
            sourceFilters: {
                building: true,
                terrain: false,
                no_fly_zone: true,
                temp_control: true
            },
            maxItems: 200,
            loading: false,
            requestToken: null,
            terrainLod: {
                mode: 'auto',
                currentLod: null,
                cache: {},
                loadedBbox: null,
                summary: null,
                loading: false,
                moveEndTimer: null
            }
        };

        function viewer() { return getViewer && getViewer(); }
        function CesiumRuntime() { return getCesium && getCesium(); }

        function sourceColor(sourceKind) {
            return (sources[sourceKind] && sources[sourceKind].color) || '#ffb000';
        }

        function sourceLabel(sourceKind) {
            return (sources[sourceKind] && sources[sourceKind].label) || sourceKind || '未知来源';
        }

        function lineWidth(sourceKind) {
            if (sourceKind === 'terrain') return 1.4;
            if (sourceKind === 'no_fly_zone' || sourceKind === 'temp_control') return 2.8;
            return 2.2;
        }

        function lineAlpha(sourceKind) {
            if (sourceKind === 'terrain') return 0.62;
            if (sourceKind === 'no_fly_zone' || sourceKind === 'temp_control') return 0.94;
            return 0.86;
        }

        function heightRange(bounds) {
            if (!bounds) return '--';
            return bounds.minHeight.toFixed(1) + '–' + bounds.maxHeight.toFixed(1) + 'm';
        }

        function selectedSources() {
            return Object.keys(state.sourceFilters).filter(function(sourceKind) {
                return state.sourceFilters[sourceKind];
            });
        }

        function emptyMessage() {
            var selected = selectedSources();
            if (!selected.length) return '请至少选择一个飞行障碍来源。';
            if (selected.length === 1 && selected[0] === 'terrain') return '当前视域没有返回地形障碍；可拉近镜头或调大 limit。';
            if (selected.length === 1 && selected[0] === 'building') return '当前没有建筑障碍 GGER 数据。请先导入 OSM 建筑并刷新障碍视图。';
            if (selected.length === 1 && selected[0] === 'no_fly_zone') return '当前没有启用的长期禁飞区。请先导入 airspace.no_fly_zone 并刷新障碍视图。';
            if (selected.length === 1 && selected[0] === 'temp_control') return '当前没有当前规划时间内有效的临时禁飞区。请检查 airspace.temp_control_zone 的 status、valid_from、valid_to，并刷新障碍视图。';
            return '当前没有返回飞行障碍 GGER 数据。请确认后台已刷新 citydb_grid.flight_obstacles。';
        }

        function cameraHeightMeters() {
            var v = viewer();
            if (!v || !v.camera || !v.camera.positionCartographic) return 0;
            return v.camera.positionCartographic.height || 0;
        }

        function terrainLodRuleForCamera() {
            var mode = getTerrainLodMode();
            var fixedLod = Number(mode);
            var height = cameraHeightMeters();
            var rule;
            if (Number.isFinite(fixedLod)) {
                rule = terrainLodRules.find(function(item) { return item.lod === fixedLod; }) || terrainLodRules[0];
                return Object.assign({}, rule, { manual: true });
            }
            return terrainLodRules.find(function(item) { return height >= item.minHeight; }) || terrainLodRules[terrainLodRules.length - 1];
        }

        function terrainViewBbox(bufferRatio) {
            var C = CesiumRuntime();
            var v = viewer();
            var rectangle;
            var west;
            var south;
            var east;
            var north;
            var lonPad;
            var latPad;
            if (!v || !C) return null;
            rectangle = v.camera.computeViewRectangle(v.scene.globe.ellipsoid);
            if (!rectangle) {
                west = huaguoshan.lon - 0.08;
                south = huaguoshan.lat - 0.08;
                east = huaguoshan.lon + 0.08;
                north = huaguoshan.lat + 0.08;
            } else {
                west = C.Math.toDegrees(rectangle.west);
                south = C.Math.toDegrees(rectangle.south);
                east = C.Math.toDegrees(rectangle.east);
                north = C.Math.toDegrees(rectangle.north);
            }
            lonPad = Math.max(0.01, Math.abs(east - west) * bufferRatio);
            latPad = Math.max(0.01, Math.abs(north - south) * bufferRatio);
            return { west: Math.max(-180, west - lonPad), south: Math.max(-90, south - latPad), east: Math.min(180, east + lonPad), north: Math.min(90, north + latPad) };
        }

        function terrainViewCenter(fallbackBbox) {
            var C = CesiumRuntime();
            var v = viewer();
            var canvas;
            var screenCenter;
            var cartesian = null;
            var ray;
            var cartographic;
            if (!v || !C) return null;
            canvas = v.scene.canvas;
            screenCenter = new C.Cartesian2(canvas.clientWidth / 2, canvas.clientHeight / 2);
            if (v.scene.globe && typeof v.camera.getPickRay === 'function') {
                ray = v.camera.getPickRay(screenCenter);
                if (ray) cartesian = v.scene.globe.pick(ray, v.scene);
            }
            if (!cartesian && typeof v.camera.pickEllipsoid === 'function') {
                cartesian = v.camera.pickEllipsoid(screenCenter, v.scene.globe.ellipsoid);
            }
            if (cartesian) {
                cartographic = C.Cartographic.fromCartesian(cartesian);
                return { lon: C.Math.toDegrees(cartographic.longitude), lat: C.Math.toDegrees(cartographic.latitude) };
            }
            if (fallbackBbox) return { lon: (fallbackBbox.west + fallbackBbox.east) / 2, lat: (fallbackBbox.south + fallbackBbox.north) / 2 };
            return { lon: huaguoshan.lon, lat: huaguoshan.lat };
        }

        function terrainBboxCacheKey(bbox) {
            if (!bbox) return 'all';
            return [bbox.west, bbox.south, bbox.east, bbox.north].map(function(value) { return Math.floor(value * 100); }).join(':');
        }

        function terrainPointCacheKey(point) {
            if (!point) return 'center:none';
            return 'center:' + Math.floor(point.lon * 1000) + ':' + Math.floor(point.lat * 1000);
        }

        function limit() {
            var value = Number(getLimit());
            if (!Number.isFinite(value)) value = state.maxItems;
            if (!Number.isFinite(value)) value = 200;
            state.maxItems = Math.max(1, Math.min(1000, Math.round(value)));
            return state.maxItems;
        }

        function clear() {
            var v = viewer();
            if (state.primitive && v) {
                try { v.scene.primitives.remove(state.primitive); } catch (error) { console.warn('[FlightObstacleSituationLayer] Failed to remove primitive:', error); }
            }
            state.primitive = null;
            state.items = [];
            state.bounds = null;
        }

        function fetchSource(sourceKind, sourceLimit) {
            var cacheKey = sourceKind + ':' + sourceLimit;
            if (state.cache[cacheKey]) return Promise.resolve(state.cache[cacheKey]);
            return requestSource(sourceKind, sourceLimit).then(function(data) {
                if (!Array.isArray(data)) data = [];
                state.cache[cacheKey] = data;
                return data;
            });
        }

        function fetchTerrainLod() {
            var rule = terrainLodRuleForCamera();
            var viewBbox = terrainViewBbox(rule.bboxBuffer);
            var bbox = rule.lod === 0 ? null : viewBbox;
            var center = terrainViewCenter(viewBbox);
            var terrainLimit = Math.min(rule.limit, limit());
            var cacheKey = 'terrain:' + rule.lod + ':' + terrainBboxCacheKey(bbox || viewBbox) + ':' + terrainPointCacheKey(center) + ':' + terrainLimit;
            var payload = { p_source_kind: 'terrain', p_lod_level: rule.lod, p_limit: terrainLimit, p_include_boxes: true };
            if (bbox) {
                payload.p_west = bbox.west; payload.p_south = bbox.south; payload.p_east = bbox.east; payload.p_north = bbox.north;
            }
            if (center) {
                payload.p_center_lon = center.lon; payload.p_center_lat = center.lat;
            }
            state.terrainLod.currentLod = rule.lod;
            state.terrainLod.loadedBbox = bbox;
            state.terrainLod.summary = { lod: rule.lod, limit: terrainLimit, bbox: bbox, label: rule.label, mode: getTerrainLodMode() };
            if (state.terrainLod.cache[cacheKey]) return Promise.resolve(state.terrainLod.cache[cacheKey]);
            state.terrainLod.loading = true;
            return requestTerrainLod(payload).then(function(data) {
                if (!Array.isArray(data)) data = [];
                state.terrainLod.cache[cacheKey] = data;
                return data;
            }).finally(function() { state.terrainLod.loading = false; });
        }

        function requestObstacles() {
            var activeSources = selectedSources();
            var sourceLimit = limit();
            if (!activeSources.length) return Promise.resolve([]);
            return Promise.all(activeSources.map(function(sourceKind) {
                if (sourceKind === 'terrain') return fetchTerrainLod();
                return fetchSource(sourceKind, sourceLimit);
            })).then(function(groups) { return groups.reduce(function(all, group) { return all.concat(group); }, []); });
        }

        function normalize(obstacle, index) {
            var cells = helpers.extractGridCells({ grid: obstacle });
            return Object.assign({}, obstacle, { index: index, cells: cells, bounds: helpers.cellsBounds(cells) });
        }

        function renderPrimitives(obstacles) {
            var C = CesiumRuntime();
            var v = viewer();
            var primitive;
            var materialCache = {};
            var layers;
            clear();
            if (!v || !C || !obstacles.length) return;
            layers = helpers.sortedGridLayers(obstacles.reduce(function(cells, obstacle) { return cells.concat(obstacle.cells || []); }, []));
            primitive = new C.PolylineCollection();
            obstacles.forEach(function(obstacle) {
                var edges = {};
                var sourceKind = obstacle.source_kind;
                obstacle.cells.forEach(function(cell) { helpers.addBoxEdges(edges, cell, helpers.gridLayerIndex(cell, layers)); });
                Object.keys(edges).forEach(function(key) {
                    var edge = edges[key];
                    primitive.add({
                        positions: [C.Cartesian3.fromDegrees(edge.lon1, edge.lat1, edge.h1), C.Cartesian3.fromDegrees(edge.lon2, edge.lat2, edge.h2)],
                        width: lineWidth(sourceKind),
                        material: helpers.gridLayerMaterial(C, materialCache, edge.layerIndex, lineAlpha(sourceKind)),
                        id: { type: 'flightObstacle', source_kind: obstacle.source_kind, source_id: obstacle.source_id, index: obstacle.index }
                    });
                });
            });
            state.primitive = v.scene.primitives.add(primitive);
            state.items = obstacles;
            state.bounds = helpers.mergeBounds(obstacles.map(function(obstacle) { return obstacle.bounds; }));
        }

        function terrainLodPanelRows() {
            var summary = state.terrainLod.summary;
            if (!summary || !state.sourceFilters.terrain) return '';
            return '<div class="feature-meta-row"><span>地形障碍 LOD</span><code>LOD' + escapeHtml(summary.lod) + ' · ' + escapeHtml(summary.label) + ' · limit ' + escapeHtml(summary.limit) + '</code></div>' +
                '<div class="feature-meta-row"><span>地形加载策略</span><code>' + escapeHtml(summary.mode === 'auto' ? 'Auto · moveEnd bbox' : 'Manual') + '</code></div>';
        }

        function terrainLodLogSuffix() {
            var summary = state.terrainLod.summary;
            if (!summary || !state.sourceFilters.terrain) return '';
            return '；地形 LOD' + summary.lod + '（' + summary.label + '，limit ' + summary.limit + '）';
        }

        function panelHtml(obstacles) {
            var summary;
            var cards;
            if (!obstacles.length) return '<div class="feature-empty">' + escapeHtml(emptyMessage()) + '</div>';
            summary = obstacles.reduce(function(acc, obstacle) { var key = obstacle.source_kind || 'unknown'; acc[key] = (acc[key] || 0) + 1; return acc; }, {});
            cards = obstacles.slice(0, 12).map(function(obstacle) {
                var color = sourceColor(obstacle.source_kind);
                var metaRows = [
                    ['Type', sourceLabel(obstacle.source_kind)],
                    ['Source ID', obstacle.source_id],
                    ['Height', heightRange(obstacle.bounds)],
                    ['Terrain LOD', obstacle.lod_level != null ? 'LOD' + obstacle.lod_level + (obstacle.block_size_px ? ' · ' + obstacle.block_size_px + 'px block' : '') : null],
                    ['Detail', obstacle.detail_level ? 'L' + obstacle.detail_level : null],
                    ['Cells', obstacle.cell_count || obstacle.cells.length || 0],
                    ['Priority', obstacle.priority],
                    ['Valid From', obstacle.valid_from],
                    ['Valid To', obstacle.valid_to]
                ].filter(function(row) { return row[1] != null && row[1] !== ''; });
                return '<div class="obstacle-card" style="--source-color:' + escapeHtml(color) + '">' +
                    '<span class="obstacle-pill">' + escapeHtml(sourceLabel(obstacle.source_kind)) + '</span>' +
                    '<h3>' + escapeHtml(obstacle.source_name || obstacle.source_id || 'flight obstacle') + '</h3>' +
                    '<div class="feature-meta">' + metaRows.map(function(row) { return '<div class="feature-meta-row"><span>' + escapeHtml(row[0]) + '</span><code>' + escapeHtml(row[1]) + '</code></div>'; }).join('') + '</div>' +
                    '<div class="feature-grid-actions"><button type="button" data-action="zoomFlightObstacle" data-obstacle-index="' + obstacle.index + '">定位该障碍</button></div>' +
                '</div>';
            }).join('');
            return '<div class="feature-card">' +
                '<div class="feature-title"><span>Flight Obstacles</span><strong>多源飞行障碍 · ' + obstacles.length + ' 条</strong></div>' +
                '<div class="feature-meta">' + Object.keys(summary).map(function(sourceKind) { return '<div class="feature-meta-row"><span>' + escapeHtml(sourceLabel(sourceKind)) + '</span><code>' + summary[sourceKind] + '</code></div>'; }).join('') + terrainLodPanelRows() + '</div>' +
                cards +
                (obstacles.length > 12 ? '<div class="feature-empty">面板仅展示前 12 / ' + obstacles.length + ' 条；地图已绘制全部返回障碍。</div>' : '') +
            '</div>';
        }

        function renderPanel(obstacles) {
            showPanel(panelHtml(obstacles));
        }

        function refresh(forceRefresh) {
            var token;
            if (!state.enabled) return Promise.resolve();
            if (forceRefresh) invalidate();
            state.loading = true;
            token = Date.now();
            state.requestToken = token;
            log('正在加载多源飞行障碍 GGER 线框。');
            return requestObstacles().then(function(obstacles) {
                var normalized;
                if (state.requestToken !== token) return;
                normalized = obstacles.map(normalize).filter(function(obstacle) { return obstacle.cells.length; });
                renderPrimitives(normalized);
                renderPanel(normalized);
                log('飞行障碍已加载：' + normalized.length + ' 条，来源：' + selectedSources().map(sourceLabel).join(' / ') + terrainLodLogSuffix() + '。');
            }).catch(function(error) {
                console.error('[FlightObstacleSituationLayer] RPC failed:', error);
                renderError('飞行障碍 RPC 查询失败：' + error.message + '。请确认 PostgREST 服务与 list_flight_obstacles_gger / list_flight_obstacles_gger_lod RPC 可访问。');
                log('飞行障碍 RPC 查询失败，请检查 PostgREST。');
            }).finally(function() { state.loading = false; });
        }

        function setEnabled(enabled) {
            state.enabled = Boolean(enabled);
            if (!state.enabled) {
                clear();
                log('飞行障碍图层已关闭。');
                return Promise.resolve();
            }
            return refresh(false);
        }

        function setSourceEnabled(sourceKind, enabled) {
            state.sourceFilters[sourceKind] = Boolean(enabled);
            if (state.enabled) return refresh(false);
            return Promise.resolve();
        }

        function setTerrainLodMode(mode) {
            state.terrainLod.mode = mode;
            state.terrainLod.cache = {};
            if (state.enabled && state.sourceFilters.terrain) return refresh(true);
            return Promise.resolve();
        }

        function invalidate() {
            state.cache = {};
            state.terrainLod.cache = {};
        }

        function scheduleTerrainLodRefresh() {
            if (!state.enabled || !state.sourceFilters.terrain) return;
            if (state.terrainLod.moveEndTimer) window.clearTimeout(state.terrainLod.moveEndTimer);
            state.terrainLod.moveEndTimer = window.setTimeout(function() { refresh(false); }, 350);
        }

        function zoomToBounds(bounds, message) {
            var C = CesiumRuntime();
            var v = viewer();
            var target = bounds || state.bounds;
            if (!v || !target) {
                log('当前没有可定位的飞行障碍。');
                return;
            }
            v.camera.flyTo({ destination: C.Rectangle.fromDegrees(target.west, target.south, target.east, target.north), duration: 1.2 });
            log(message || '已定位到飞行障碍范围。');
        }

        function obstacleByIndex(index) {
            return state.items.find(function(item) { return item.index === Number(index); });
        }

        function selectObstacle(obstacle) {
            if (!obstacle) return;
            renderPanel([obstacle]);
            log('已选中飞行障碍：' + sourceLabel(obstacle.source_kind) + ' · ' + (obstacle.source_name || obstacle.source_id));
        }

        function syncSourceButtons() {
            Object.keys(state.sourceFilters).forEach(function(sourceKind) {
                var button = document.querySelector('[data-obstacle-source="' + sourceKind + '"]');
                if (button) button.setAttribute('aria-pressed', String(Boolean(state.sourceFilters[sourceKind])));
            });
        }

        function destroy() {
            if (state.terrainLod.moveEndTimer) window.clearTimeout(state.terrainLod.moveEndTimer);
            clear();
        }

        return {
            setEnabled: setEnabled,
            isEnabled: function() { return state.enabled; },
            setSourceEnabled: setSourceEnabled,
            setTerrainLodMode: setTerrainLodMode,
            refresh: refresh,
            clear: clear,
            invalidate: invalidate,
            scheduleTerrainLodRefresh: scheduleTerrainLodRefresh,
            zoomToBounds: zoomToBounds,
            obstacleByIndex: obstacleByIndex,
            selectObstacle: selectObstacle,
            syncSourceButtons: syncSourceButtons,
            getSourceFilters: function() { return Object.assign({}, state.sourceFilters); },
            getBounds: function() { return state.bounds; },
            destroy: destroy,
            _private: { terrainBboxCacheKey: terrainBboxCacheKey, terrainPointCacheKey: terrainPointCacheKey, sourceLabel: sourceLabel }
        };
    }

    return { create: create, _private: { escapeHtml: escapeHtml } };
}));
