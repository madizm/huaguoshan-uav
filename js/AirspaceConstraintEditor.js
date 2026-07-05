/*
 * Airspace constraint editor for the Huaguoshan workbench.
 *
 * Owns 空域约束 editing DOM/state and talks to the shell through small adapters:
 * PostgREST request, Cesium-backed map operations, logging, and change events.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.AirspaceConstraintEditor = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    var AIRSPACE_HEIGHT_MARGIN_M = 10;

    function escapeHtml(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function formatDateTimeLocal(date) {
        var pad = function(value) { return String(value).padStart(2, '0'); };
        return [
            date.getFullYear(), '-', pad(date.getMonth() + 1), '-', pad(date.getDate()),
            'T', pad(date.getHours()), ':', pad(date.getMinutes())
        ].join('');
    }

    function isoFromDateTimeLocal(value) {
        var date;
        if (!value) return null;
        date = new Date(value);
        if (!Number.isFinite(date.getTime())) return null;
        return date.toISOString();
    }

    function numberOrNull(value) {
        var num = Number(value);
        return Number.isFinite(num) ? num : null;
    }

    function kindLabel(kind) {
        if (kind === 'no_fly_zone') return '长期禁飞区';
        if (kind === 'temp_control') return '临时禁飞/管制';
        return kind || '禁限飞区';
    }

    function parseGeometry(geom) {
        if (!geom) return null;
        if (typeof geom === 'string') {
            try { return JSON.parse(geom); } catch (error) { return null; }
        }
        return geom;
    }

    function sameLonLat(a, b) {
        return a && b && Math.abs(a[0] - b[0]) < 1e-12 && Math.abs(a[1] - b[1]) < 1e-12;
    }

    function geometryToDrawPoints(geom) {
        var geometry = parseGeometry(geom);
        var ring;
        if (!geometry) return [];
        if (geometry.type === 'MultiPolygon') ring = geometry.coordinates && geometry.coordinates[0] && geometry.coordinates[0][0];
        if (geometry.type === 'Polygon') ring = geometry.coordinates && geometry.coordinates[0];
        if (!Array.isArray(ring)) return [];
        if (ring.length > 1 && sameLonLat(ring[0], ring[ring.length - 1])) ring = ring.slice(0, -1);
        return ring.map(function(coord) {
            return { lon: Number(coord[0]), lat: Number(coord[1]) };
        }).filter(function(point) {
            return Number.isFinite(point.lon) && Number.isFinite(point.lat);
        });
    }

    function drawPointsToMultiPolygon(points) {
        var ring = points.map(function(point) { return [point.lon, point.lat]; });
        if (ring.length && !sameLonLat(ring[0], ring[ring.length - 1])) ring.push([ring[0][0], ring[0][1]]);
        return { type: 'MultiPolygon', coordinates: [[ring]] };
    }

    function terrainSamplePoints(points) {
        var result = [];
        var seen = {};
        var lonSum = 0;
        var latSum = 0;

        function add(lon, lat, height) {
            var key = lon.toFixed(7) + ':' + lat.toFixed(7);
            if (seen[key]) return;
            seen[key] = true;
            result.push({ lon: lon, lat: lat, height: Number.isFinite(height) ? height : null });
        }

        points.forEach(function(point, index) {
            add(point.lon, point.lat, point.height);
            lonSum += point.lon;
            latSum += point.lat;
            if (index > 0) add((points[index - 1].lon + point.lon) / 2, (points[index - 1].lat + point.lat) / 2, null);
        });
        if (points.length > 2) {
            add((points[points.length - 1].lon + points[0].lon) / 2, (points[points.length - 1].lat + points[0].lat) / 2, null);
            add(lonSum / points.length, latSum / points.length, null);
        }
        return result;
    }

    function summarizeHeights(samples, source) {
        var heights = samples.map(function(sample) { return Number(sample.height); }).filter(Number.isFinite);
        if (!heights.length) return { min: 0, max: 0, source: source || 'fallback' };
        return {
            min: Math.min.apply(Math, heights),
            max: Math.max.apply(Math, heights),
            source: source || 'terrain'
        };
    }

    function create(options) {
        var request = options.request;
        var map = options.map;
        var log = options.log || function() {};
        var onChanged = options.onChanged || function() {};
        var renderError = options.renderError || function() {};
        var confirmAction = options.confirm || function(message) { return Promise.resolve(window.confirm(message)); };
        var zoomToPoints = options.zoomToPoints || function() {};
        var root = null;
        var els = {};
        var state = {
            zones: [],
            editingKind: null,
            editingId: null,
            drawActive: false,
            drawPoints: [],
            existingGeometry: null,
            terrainSample: null,
            loading: false
        };

        function $(name) {
            return els[name];
        }

        function html() {
            return '' +
                '<div class="airspace-admin-controls" aria-label="禁限飞空域管理">' +
                  '<h2>Airspace Admin</h2>' +
                  '<div class="control-grid">' +
                    '<label class="field">类型<select data-field="kind"><option value="no_fly_zone">长期禁飞区</option><option value="temp_control">临时禁飞/管制</option></select></label>' +
                    '<label class="field">名称<input data-field="name" type="text" value="新建禁飞区" /></label>' +
                    '<label class="field">最低高度 m<input data-field="minHeight" type="number" step="1" value="0" /></label>' +
                    '<label class="field">最高高度 m<input data-field="maxHeight" type="number" step="1" value="300" /></label>' +
                    '<label class="field">安全缓冲 m<input data-field="safetyBuffer" type="number" min="0" step="1" value="20" /></label>' +
                    '<label class="field">高度基准<select data-field="heightDatum"><option value="AGL" selected>离地高度 AGL（推荐）</option><option value="AMSL">海拔高度 AMSL</option></select></label>' +
                    '<label class="field">地形采样<input data-field="terrainSummary" type="text" value="绘制后保存时自动采样" readonly /></label>' +
                    '<label class="field" data-temp-field>Status<select data-field="status"><option value="planned">planned</option><option value="active" selected>active</option><option value="cancelled">cancelled</option></select></label>' +
                    '<label class="field" data-temp-field>有效开始<input data-field="validFrom" type="datetime-local" /></label>' +
                    '<label class="field" data-temp-field>有效结束<input data-field="validTo" type="datetime-local" /></label>' +
                    '<label class="field" style="grid-column: 1 / -1;">当前面坐标<textarea data-field="geometryPreview" readonly placeholder="点击“开始绘制”后在地图上依次左键点选 polygon 顶点。"></textarea></label>' +
                  '</div>' +
                  '<div class="draw-actions">' +
                    '<button type="button" data-action="new">新建</button>' +
                    '<button type="button" data-action="startDraw">开始绘制</button>' +
                    '<button type="button" data-action="undoPoint">撤销点</button>' +
                    '<button type="button" data-action="finishDraw">完成面</button>' +
                    '<button type="button" data-action="cancelDraw">取消绘制</button>' +
                  '</div>' +
                  '<div class="admin-actions">' +
                    '<button class="primary" type="button" data-action="save">保存到 PostgREST</button>' +
                    '<button type="button" data-action="reload">刷新列表</button>' +
                  '</div>' +
                  '<p class="admin-hint">保存写入 airspace 业务表；飞行障碍物化视图仍需后台执行 <code>--source airspace --refresh-total</code> 后才会更新。</p>' +
                  '<div class="airspace-zone-list" data-field="zoneList"><div class="feature-empty">尚未加载禁限飞区列表。</div></div>' +
                '</div>';
        }

        function bindElements() {
            Array.prototype.forEach.call(root.querySelectorAll('[data-field]'), function(element) {
                els[element.getAttribute('data-field')] = element;
            });
        }

        function setTerrainSummary(text) {
            if ($('terrainSummary')) $('terrainSummary').value = text || '';
        }

        function setupDefaults() {
            var now = new Date();
            var later = new Date(now.getTime() + 2 * 60 * 60 * 1000);
            if ($('validFrom') && !$('validFrom').value) $('validFrom').value = formatDateTimeLocal(now);
            if ($('validTo') && !$('validTo').value) $('validTo').value = formatDateTimeLocal(later);
        }

        function updateTempFields() {
            var kind = $('kind') ? $('kind').value : 'no_fly_zone';
            Array.prototype.forEach.call(root.querySelectorAll('[data-temp-field]'), function(field) {
                field.style.display = kind === 'temp_control' ? '' : 'none';
            });
        }

        function updateGeometryPreview() {
            var preview = $('geometryPreview');
            var points = state.drawPoints;
            if (!preview) return;
            preview.value = points.length ? points.map(function(point, index) {
                return (index + 1) + '. ' + point.lon.toFixed(7) + ', ' + point.lat.toFixed(7);
            }).join('\n') : '';
        }

        function renderPreview() {
            updateGeometryPreview();
            if (map && typeof map.renderPreview === 'function') {
                map.renderPreview(state.drawPoints, $('kind') ? $('kind').value : 'no_fly_zone');
            }
        }

        function resetForm() {
            state.editingKind = null;
            state.editingId = null;
            state.existingGeometry = null;
            state.drawPoints = [];
            state.drawActive = false;
            $('name').value = '新建禁飞区';
            $('minHeight').value = '0';
            $('maxHeight').value = '300';
            $('safetyBuffer').value = '20';
            $('heightDatum').value = 'AGL';
            $('status').value = 'active';
            $('validFrom').value = '';
            $('validTo').value = '';
            state.terrainSample = null;
            setTerrainSummary('绘制后保存时自动采样');
            setupDefaults();
            updateTempFields();
            renderPreview();
            log('已进入新建禁限飞区模式。点击“开始绘制”后在地图上点选 polygon 顶点。');
        }

        function startDraw() {
            state.drawActive = true;
            state.drawPoints = [];
            state.existingGeometry = null;
            state.terrainSample = null;
            setTerrainSummary('绘制后保存时自动采样');
            renderPreview();
            log('禁限飞区绘制已开始：请在地图上依次左键点击 polygon 顶点，完成后点“完成面”。');
        }

        function finishDraw() {
            if (state.drawPoints.length < 3) {
                log('至少需要 3 个顶点才能完成禁限飞区 polygon。');
                return;
            }
            state.drawActive = false;
            renderPreview();
            log('禁限飞区 polygon 已完成，可继续修改属性并保存。');
        }

        function cancelDraw() {
            state.drawActive = false;
            state.drawPoints = [];
            state.existingGeometry = null;
            state.terrainSample = null;
            setTerrainSummary('绘制后保存时自动采样');
            renderPreview();
            log('已取消禁限飞区绘制。');
        }

        function undoPoint() {
            if (!state.drawPoints.length) return;
            state.drawPoints.pop();
            state.terrainSample = null;
            setTerrainSummary(state.drawPoints.length ? '保存时将重新采样' : '绘制后保存时自动采样');
            renderPreview();
            log('已撤销最后一个顶点。');
        }

        function addDrawPoint(position) {
            var point = map && typeof map.pickLonLat === 'function' ? map.pickLonLat(position) : null;
            if (!point) {
                log('无法从当前点击位置读取经纬度，请点击地球表面。');
                return;
            }
            state.drawPoints.push(point);
            state.terrainSample = null;
            setTerrainSummary('保存时将重新采样');
            renderPreview();
            log('已添加禁限飞区顶点 #' + state.drawPoints.length + '：' + point.lon.toFixed(6) + ', ' + point.lat.toFixed(6));
        }

        function sampleTerrain(points) {
            if (map && typeof map.sampleTerrain === 'function') return map.sampleTerrain(points, terrainSamplePoints, summarizeHeights);
            return Promise.resolve(summarizeHeights(terrainSamplePoints(points), 'fallback'));
        }

        function preparePayloadFromForm() {
            var kind = $('kind').value;
            var points = state.drawPoints;
            var geometry = points.length >= 3 ? drawPointsToMultiPolygon(points) : state.existingGeometry;
            var minInput = numberOrNull($('minHeight').value);
            var maxInput = numberOrNull($('maxHeight').value);
            var datum = $('heightDatum') ? $('heightDatum').value : 'AGL';
            var payload;

            if (!geometry) return Promise.reject(new Error('请先绘制或选择一个 polygon。'));
            if (points.length > 0 && points.length < 3) return Promise.reject(new Error('polygon 至少需要 3 个顶点。'));
            if (minInput == null) minInput = 0;
            if (maxInput == null) return Promise.reject(new Error('请填写最高高度；最高高度必须高于地形。'));
            if (minInput < 0) return Promise.reject(new Error('最低高度不能小于 0。'));
            if (maxInput <= minInput) return Promise.reject(new Error('最高高度必须大于最低高度。'));

            return sampleTerrain(points.length >= 3 ? points : geometryToDrawPoints(geometry)).then(function(terrain) {
                state.terrainSample = terrain;
                setTerrainSummary('terrain ' + terrain.min.toFixed(1) + '–' + terrain.max.toFixed(1) + 'm · ' + terrain.source);

                if (datum === 'AGL') {
                    if (maxInput <= AIRSPACE_HEIGHT_MARGIN_M) {
                        throw new Error('AGL 最高高度过低。请设置为至少 ' + AIRSPACE_HEIGHT_MARGIN_M + 'm 以上，避免禁飞区被地形完全遮挡。');
                    }
                } else if (maxInput <= terrain.max + AIRSPACE_HEIGHT_MARGIN_M) {
                    throw new Error('AMSL 最高高度低于当前地形最高高程。请至少设置为 ' + (terrain.max + AIRSPACE_HEIGHT_MARGIN_M).toFixed(1) + 'm，或切换为 AGL 离地高度。');
                }

                payload = {
                    name: ($('name').value || '').trim(),
                    geom: JSON.stringify(geometry),
                    height_datum: datum,
                    min_height: Number(minInput.toFixed(2)),
                    max_height: Number(maxInput.toFixed(2)),
                    safety_buffer_m: Math.max(0, numberOrNull($('safetyBuffer').value) || 0)
                };
                if (!payload.name) throw new Error('请填写禁限飞区名称。');
                if (kind === 'no_fly_zone') {
                    payload.enabled = true;
                } else {
                    payload.valid_from = isoFromDateTimeLocal($('validFrom').value);
                    payload.valid_to = isoFromDateTimeLocal($('validTo').value);
                    payload.status = $('status').value || 'planned';
                    if (!payload.valid_from || !payload.valid_to) throw new Error('临时禁飞/管制必须填写有效开始和结束时间。');
                    if (new Date(payload.valid_to) <= new Date(payload.valid_from)) throw new Error('有效结束时间必须晚于开始时间。');
                }
                return { kind: kind, payload: payload, datum: datum, terrain: terrain };
            });
        }

        function save() {
            var editing = state.editingId != null && state.editingKind === ($('kind') && $('kind').value);
            log('正在采样地形并校验禁限飞高度。');
            return preparePayloadFromForm().then(function(form) {
                var method = editing ? 'PATCH' : 'POST';
                var suffix = editing ? '?id=eq.' + encodeURIComponent(state.editingId) : '';
                log('正在通过 PostgREST 保存' + kindLabel(form.kind) + '（' + form.datum + ' ' + form.payload.min_height + '–' + form.payload.max_height + 'm；grids 刷新时按高度基准计算）。');
                return request(form.kind, suffix, {
                    method: method,
                    headers: { 'Content-Type': 'application/json', 'Prefer': 'return=representation' },
                    body: JSON.stringify(form.payload)
                });
            }).then(function() {
                state.drawActive = false;
                state.editingKind = null;
                state.editingId = null;
                onChanged();
                log('禁限飞区已保存到 airspace 业务表；后台 worker 将自动刷新 airspace grids。');
                return load();
            }).catch(function(error) {
                console.error('[AirspaceConstraintEditor] Airspace save failed:', error);
                renderError('禁限飞区保存失败：' + error.message);
                log('禁限飞区保存失败：' + error.message);
            });
        }

        function renderList() {
            var list = $('zoneList');
            if (!list) return;
            if (!state.zones.length) {
                list.innerHTML = '<div class="feature-empty">暂无禁限飞区业务表记录，或 PostgREST airspace 查询未返回数据。</div>';
                return;
            }
            list.innerHTML = state.zones.map(function(zone) {
                var activeText = zone.kind === 'no_fly_zone' ? (zone.enabled === false ? 'disabled' : 'enabled') : (zone.status || 'planned');
                var datumText = zone.height_datum || 'AMSL legacy';
                var timeText = zone.kind === 'temp_control' ? ' · ' + (zone.valid_from || '--') + ' → ' + (zone.valid_to || '--') : '';
                return '<div class="airspace-zone-item" data-zone-kind="' + escapeHtml(zone.kind) + '" data-zone-id="' + escapeHtml(zone.id) + '">' +
                    '<strong>#' + escapeHtml(zone.id) + ' · ' + escapeHtml(zone.name || '(unnamed)') + '</strong>' +
                    '<span>' + escapeHtml(kindLabel(zone.kind)) + ' · ' + escapeHtml(activeText) + ' · ' + escapeHtml(datumText) + ' ' + escapeHtml(zone.min_height == null ? 0 : zone.min_height) + '–' + escapeHtml(zone.max_height == null ? '∞' : zone.max_height) + 'm · buffer ' + escapeHtml(zone.safety_buffer_m || 0) + 'm' + escapeHtml(timeText) + '</span>' +
                    '<div class="admin-actions">' +
                      '<button type="button" data-action="edit" data-zone-kind="' + escapeHtml(zone.kind) + '" data-zone-id="' + escapeHtml(zone.id) + '">编辑</button>' +
                      '<button type="button" data-action="disable" data-zone-kind="' + escapeHtml(zone.kind) + '" data-zone-id="' + escapeHtml(zone.id) + '">禁用</button>' +
                      '<button type="button" data-action="delete" data-zone-kind="' + escapeHtml(zone.kind) + '" data-zone-id="' + escapeHtml(zone.id) + '">删除</button>' +
                    '</div>' +
                  '</div>';
            }).join('');
        }

        function load() {
            var selectNoFly = '?select=id,name,geom,height_datum,min_height,max_height,safety_buffer_m,enabled,created_at,updated_at&order=id.desc&limit=50';
            var selectTemp = '?select=id,name,geom,height_datum,min_height,max_height,safety_buffer_m,valid_from,valid_to,status,created_at,updated_at&order=id.desc&limit=50';
            state.loading = true;
            return Promise.all([
                request('no_fly_zone', selectNoFly, { method: 'GET' }),
                request('temp_control', selectTemp, { method: 'GET' })
            ]).then(function(groups) {
                state.zones = (groups[0] || []).map(function(row) { return Object.assign({ kind: 'no_fly_zone' }, row); })
                    .concat((groups[1] || []).map(function(row) { return Object.assign({ kind: 'temp_control' }, row); }));
                renderList();
                log('已加载禁限飞区管理列表：' + state.zones.length + ' 条。');
            }).catch(function(error) {
                console.error('[AirspaceConstraintEditor] Airspace list failed:', error);
                if ($('zoneList')) $('zoneList').innerHTML = '<div class="feature-error">禁限飞区列表加载失败：' + escapeHtml(error.message) + '</div>';
                log('禁限飞区列表加载失败；请确认 pgrest.conf 已暴露 airspace schema 且 admin 具备表权限。');
            }).finally(function() {
                state.loading = false;
            });
        }

        function edit(kind, id) {
            var zone = state.zones.find(function(item) { return item.kind === kind && String(item.id) === String(id); });
            var points;
            if (!zone) {
                log('未找到待编辑的禁限飞区记录：' + kind + '#' + id);
                return;
            }
            $('kind').value = kind;
            $('name').value = zone.name || '';
            $('minHeight').value = zone.min_height == null ? '0' : zone.min_height;
            $('maxHeight').value = zone.max_height == null ? '' : zone.max_height;
            $('safetyBuffer').value = zone.safety_buffer_m == null ? '0' : zone.safety_buffer_m;
            $('heightDatum').value = zone.height_datum || 'AMSL';
            setTerrainSummary((zone.height_datum === 'AGL' ? '已存储高度为离地高度；保存时会重新校验地形' : '已存储高度为海拔高度；保存时会重新校验地形'));
            $('status').value = zone.status || 'planned';
            $('validFrom').value = zone.valid_from ? formatDateTimeLocal(new Date(zone.valid_from)) : '';
            $('validTo').value = zone.valid_to ? formatDateTimeLocal(new Date(zone.valid_to)) : '';
            updateTempFields();
            state.editingKind = kind;
            state.editingId = zone.id;
            state.existingGeometry = parseGeometry(zone.geom);
            points = geometryToDrawPoints(zone.geom);
            state.drawPoints = points;
            state.drawActive = false;
            renderPreview();
            if (points.length >= 3) zoomToPoints(points, '已定位到禁限飞区业务面，可编辑顶点后保存。');
            log('已载入编辑：' + kindLabel(kind) + ' #' + zone.id + '。如需修改范围，请重新开始绘制。');
        }

        function disable(kind, id) {
            var payload = kind === 'no_fly_zone' ? { enabled: false } : { status: 'cancelled' };
            return confirmAction('确认禁用 ' + kindLabel(kind) + ' #' + id + '？').then(function(confirmed) {
                if (!confirmed) return null;
                return request(kind, '?id=eq.' + encodeURIComponent(id), {
                    method: 'PATCH',
                    headers: { 'Content-Type': 'application/json', 'Prefer': 'return=representation' },
                    body: JSON.stringify(payload)
                }).then(function() {
                    onChanged();
                    log('禁限飞区已禁用；后台 worker 将自动刷新 airspace grids。');
                    return load();
                });
            }).catch(function(error) {
                console.error('[AirspaceConstraintEditor] Airspace disable failed:', error);
                log('禁限飞区禁用失败：' + error.message);
            });
        }

        function remove(kind, id) {
            return confirmAction('确认永久删除 ' + kindLabel(kind) + ' #' + id + '？该操作不可恢复。').then(function(confirmed) {
                if (!confirmed) return null;
                return request(kind, '?id=eq.' + encodeURIComponent(id), {
                    method: 'DELETE',
                    headers: { 'Prefer': 'return=minimal' }
                }).then(function() {
                    onChanged();
                    log('禁限飞区已删除；后台 worker 将自动刷新 airspace grids。');
                    return load();
                });
            }).catch(function(error) {
                console.error('[AirspaceConstraintEditor] Airspace delete failed:', error);
                log('禁限飞区删除失败：' + error.message);
            });
        }

        function onClick(event) {
            var action = event.target && event.target.getAttribute('data-action');
            var kind = event.target && event.target.getAttribute('data-zone-kind');
            var id = event.target && event.target.getAttribute('data-zone-id');
            if (!action) return;
            if (action === 'new') resetForm();
            if (action === 'startDraw') startDraw();
            if (action === 'undoPoint') undoPoint();
            if (action === 'finishDraw') finishDraw();
            if (action === 'cancelDraw') cancelDraw();
            if (action === 'save') save();
            if (action === 'reload') load();
            if (action === 'edit') edit(kind, id);
            if (action === 'disable') disable(kind, id);
            if (action === 'delete') remove(kind, id);
        }

        function mount(container) {
            root = container;
            root.innerHTML = html();
            bindElements();
            root.addEventListener('click', onClick);
            $('kind').addEventListener('change', function() {
                updateTempFields();
                renderPreview();
            });
            $('heightDatum').addEventListener('change', function() {
                state.terrainSample = null;
                setTerrainSummary($('heightDatum').value === 'AGL' ? 'AGL 原样入库；刷新 grids 时结合地形计算' : 'AMSL 保存时校验高于地形');
            });
            setupDefaults();
            updateTempFields();
            load();
            return api;
        }

        function setViewer(viewer) {
            if (map && typeof map.setViewer === 'function') map.setViewer(viewer);
        }

        function destroy() {
            if (root) root.removeEventListener('click', onClick);
            if (map && typeof map.clearPreview === 'function') map.clearPreview();
            root = null;
            els = {};
        }

        function handleMapClick(position) {
            if (!state.drawActive) return false;
            addDrawPoint(position);
            return true;
        }

        var api = {
            mount: mount,
            setViewer: setViewer,
            load: load,
            destroy: destroy,
            isDrawing: function() { return state.drawActive; },
            handleMapClick: handleMapClick,
            _private: {
                geometryToDrawPoints: geometryToDrawPoints,
                drawPointsToMultiPolygon: drawPointsToMultiPolygon,
                terrainSamplePoints: terrainSamplePoints,
                summarizeHeights: summarizeHeights
            }
        };
        return api;
    }

    return {
        create: create,
        _private: {
            geometryToDrawPoints: geometryToDrawPoints,
            drawPointsToMultiPolygon: drawPointsToMultiPolygon,
            terrainSamplePoints: terrainSamplePoints,
            summarizeHeights: summarizeHeights
        }
    };
}));
