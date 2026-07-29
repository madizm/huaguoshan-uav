(function (global) {
  'use strict';

  function formatCoordinate(value, precision) {
    var rounded = Number(value).toFixed(precision);
    return Number(rounded) === 0 ? (0).toFixed(precision) : rounded;
  }

  function toPolyhedralSurfaceWkt(hull, precision) {
    var digits = precision == null ? 3 : precision;
    if (!hull || !hull.positions || !hull.indices || hull.indices.length % 3 !== 0) {
      throw new TypeError('A triangular convex hull is required');
    }
    var faces = [];
    function coordinate(index) {
      var offset = index * 3;
      return [
        formatCoordinate(hull.positions[offset], digits),
        formatCoordinate(hull.positions[offset + 1], digits),
        formatCoordinate(hull.positions[offset + 2], digits)
      ].join(' ');
    }
    for (var i = 0; i < hull.indices.length; i += 3) {
      var first = coordinate(hull.indices[i]);
      faces.push('((' + [first, coordinate(hull.indices[i + 1]), coordinate(hull.indices[i + 2]), first].join(', ') + '))');
    }
    return 'POLYHEDRALSURFACE Z (' + faces.join(', ') + ')';
  }

  function toGeographicPolyhedralSurfaceWkt(hull, converter, precision) {
    if (typeof converter !== 'function') throw new TypeError('A Cartesian-to-geographic converter is required');
    var geographicPositions = [];
    for (var i = 0; i < hull.positions.length; i += 3) {
      var position = converter(hull.positions[i], hull.positions[i + 1], hull.positions[i + 2]);
      geographicPositions.push(position[0], position[1], position[2]);
    }
    return toPolyhedralSurfaceWkt({ positions: geographicPositions, indices: hull.indices }, precision == null ? 9 : precision);
  }

  function geographicHeightRange(hull, converter) {
    if (typeof converter !== 'function') return null;
    var min = Number.POSITIVE_INFINITY;
    var max = Number.NEGATIVE_INFINITY;
    for (var i = 0; i < hull.positions.length; i += 3) {
      var position = converter(hull.positions[i], hull.positions[i + 1], hull.positions[i + 2]);
      min = Math.min(min, position[2]);
      max = Math.max(max, position[2]);
    }
    return { min: min, max: max };
  }

  function createModule(options) {
    var active = false;
    var requestVersion = 0;
    var catalogPromises = Object.create(null);
    var currentPrimitive = null;
    var currentEdges = null;
    var destroyed = false;
    var selectedFeature = null;
    var selectedFeatureColor = null;
    var currentHull = null;
    var worker = null;
    var workerSequence = 0;
    var workerRequests = Object.create(null);
    var button = options.button || (typeof document !== 'undefined' && document.querySelector(options.buttonSelector || '#convexHullFeatureBtn'));
    var clearButton = options.clearButton || (typeof document !== 'undefined' && document.querySelector(options.clearButtonSelector || '#convexHullClearBtn'));
    var statusElement = options.statusElement || (typeof document !== 'undefined' && document.querySelector(options.statusSelector || '#convexHullStatus'));
    var wktDetails = options.wktDetails || (typeof document !== 'undefined' && document.querySelector(options.wktDetailsSelector || '#convexHullWktDetails'));
    var wktOutput = options.wktOutput || (typeof document !== 'undefined' && document.querySelector(options.wktOutputSelector || '#convexHullWkt'));
    var copyWktButton = options.copyWktButton || (typeof document !== 'undefined' && document.querySelector(options.copyWktSelector || '#convexHullCopyWktBtn'));
    var gridButton = options.gridButton || (typeof document !== 'undefined' && document.querySelector(options.gridButtonSelector || '#convexHullGridBtn'));
    var gridLevelInput = options.gridLevelInput || (typeof document !== 'undefined' && document.querySelector(options.gridLevelSelector || '#convexHullGridLevel'));
    var gridAggInput = options.gridAggInput || (typeof document !== 'undefined' && document.querySelector(options.gridAggSelector || '#convexHullGridAgg'));
    var gridStatusElement = options.gridStatusElement || (typeof document !== 'undefined' && document.querySelector(options.gridStatusSelector || '#convexHullGridStatus'));
    var envelopeModeInput = options.envelopeModeInput || (typeof document !== 'undefined' && document.querySelector(options.envelopeModeSelector || '#convexHullEnvelopeMode'));

    function sources() {
      return typeof options.sources === 'function' ? options.sources() : (options.sources || []);
    }
    function envelopeMode(explicitMode) {
      var mode = explicitMode || options.envelopeMode || (envelopeModeInput && envelopeModeInput.value) || 'shell';
      return mode === 'convex' ? 'convex' : 'shell';
    }

    function mergeMeshes(meshes) {
      var positions = [];
      var indices = [];
      var vertexByPosition = Object.create(null);
      var triangleKeys = Object.create(null);
      meshes.forEach(function (mesh) {
        var remap = [];
        for (var i = 0; i < mesh.positions.length; i += 3) {
          var key = [
            Math.round(mesh.positions[i] * 1000),
            Math.round(mesh.positions[i + 1] * 1000),
            Math.round(mesh.positions[i + 2] * 1000)
          ].join(':');
          if (!Object.prototype.hasOwnProperty.call(vertexByPosition, key)) {
            vertexByPosition[key] = positions.length / 3;
            positions.push(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2]);
          }
          remap[i / 3] = vertexByPosition[key];
        }
        for (var j = 0; j < mesh.indices.length; j += 3) {
          var triangle = [remap[mesh.indices[j]], remap[mesh.indices[j + 1]], remap[mesh.indices[j + 2]]];
          var triangleKey = triangle.slice().sort(function (a, b) { return a - b; }).join(':');
          if (triangleKeys[triangleKey]) continue;
          triangleKeys[triangleKey] = true;
          indices.push(triangle[0], triangle[1], triangle[2]);
        }
      });
      return { positions: positions, indices: indices };
    }

    function setStatus(message, state) {
      if (options.setStatus) options.setStatus(message, state);
      if (statusElement) {
        statusElement.textContent = message;
        statusElement.setAttribute('data-state', state || 'idle');
      }
    }
    function setGridStatus(message, state) {
      if (!gridStatusElement) return;
      gridStatusElement.textContent = message;
      gridStatusElement.setAttribute('data-state', state || 'idle');
    }

    function updateButton() {
      if (button) button.setAttribute('aria-pressed', active ? 'true' : 'false');
    }

    function activate() {
      if (destroyed) return;
      active = true;
      updateButton();
      setStatus('点击一个建筑模型生成三维包络。', 'ready');
    }

    function deactivate() {
      active = false;
      requestVersion += 1;
      updateButton();
      setStatus('单体包络分析未开启。', 'idle');
    }

    function isActive() { return active; }

    function restoreSelectedFeature() {
      if (selectedFeature && selectedFeatureColor) {
        try { selectedFeature.color = selectedFeatureColor; } catch (error) { /* feature may have unloaded */ }
      }
      selectedFeature = null;
      selectedFeatureColor = null;
    }

    function dimSelectedFeature(feature) {
      restoreSelectedFeature();
      if (!options.CesiumRuntime || !feature || !feature.color) return;
      selectedFeature = feature;
      selectedFeatureColor = options.CesiumRuntime.Color.clone(feature.color);
      feature.color = new options.CesiumRuntime.Color(
        selectedFeatureColor.red,
        selectedFeatureColor.green,
        selectedFeatureColor.blue,
        0.24
      );
    }

    function removeRender(preserveSelection) {
      if (options.clearHull) options.clearHull();
      if (currentPrimitive && options.viewer) options.viewer.scene.primitives.remove(currentPrimitive);
      if (currentEdges && options.viewer) options.viewer.scene.primitives.remove(currentEdges);
      currentPrimitive = null;
      currentEdges = null;
      if (!preserveSelection) restoreSelectedFeature();
    }

    function clearWkt() {
      if (wktOutput) wktOutput.value = '';
      if (wktDetails) {
        wktDetails.hidden = true;
        wktDetails.open = false;
      }
    }

    function showWkt(hull) {
      if (wktOutput) wktOutput.value = toPolyhedralSurfaceWkt(hull, 3);
      if (wktDetails) wktDetails.hidden = false;
      if (gridButton) gridButton.disabled = false;
    }

    function copyWkt() {
      if (!wktOutput || !wktOutput.value || typeof navigator === 'undefined' || !navigator.clipboard) return;
      navigator.clipboard.writeText(wktOutput.value).then(function () {
        setStatus('包络 WKT 已复制到剪贴板（EPSG:4978）。', 'success');
      }).catch(function (error) {
        setStatus('WKT 复制失败：' + error.message, 'error');
      });
    }

    function clear() {
      requestVersion += 1;
      removeRender();
      clearWkt();
      currentHull = null;
      if (gridButton) gridButton.disabled = true;
      if (options.clearGrid) options.clearGrid();
      setGridStatus('等待凸包计算。', 'idle');
      setStatus(active ? '已清除。点击建筑模型重新生成包络。' : '单体包络分析未开启。', active ? 'ready' : 'idle');
    }

    function defaultLoadCatalog(source) {
      return fetch(source.catalogUrl, { cache: 'force-cache' }).then(function (response) {
        if (!response.ok) throw new Error('凸包索引加载失败 HTTP ' + response.status);
        return response.json();
      });
    }

    function loadCatalog(source) {
      var key = source.catalogUrl;
      if (!catalogPromises[key]) {
        catalogPromises[key] = (options.loadCatalog ? options.loadCatalog(source) : defaultLoadCatalog(source)).catch(function (error) {
          delete catalogPromises[key];
          throw error;
        });
      }
      return catalogPromises[key];
    }

    function defaultFetchArrayBuffer(url) {
      return fetch(url, { cache: 'force-cache' }).then(function (response) {
        if (!response.ok) throw new Error('GLB 加载失败 HTTP ' + response.status + ': ' + url);
        return response.arrayBuffer();
      });
    }

    function resolveContentUrl(source, uri) {
      if (options.resolveContentUrl) return options.resolveContentUrl(source, uri);
      var pageUrl = typeof document !== 'undefined' ? document.baseURI : 'http://localhost/';
      return new URL(uri, new URL(source.tilesetUrl, pageUrl)).href;
    }

    function computeHull(positions) {
      if (options.computeHull) return Promise.resolve(options.computeHull(positions));
      if (typeof Worker === 'undefined') return Promise.resolve(global.HuaguoshanConvexHullKernel.compute(positions));
      if (!worker) {
        worker = new Worker(options.workerUrl || './src/features/convex-hull/hull-worker.js');
        worker.addEventListener('message', function (event) {
          var request = workerRequests[event.data.id];
          if (!request) return;
          delete workerRequests[event.data.id];
          if (event.data.error) request.reject(new Error(event.data.error));
          else request.resolve({
            positions: Array.from(new Float64Array(event.data.positions)),
            indices: Array.from(new Uint32Array(event.data.indices))
          });
        });
        worker.addEventListener('error', function (event) {
          Object.keys(workerRequests).forEach(function (id) {
            workerRequests[id].reject(new Error(event.message || '凸包 Worker 执行失败'));
            delete workerRequests[id];
          });
        });
      }
      return new Promise(function (resolve, reject) {
        var id = ++workerSequence;
        var values = new Float64Array(positions);
        workerRequests[id] = { resolve: resolve, reject: reject };
        worker.postMessage({ id: id, positions: values.buffer }, [values.buffer]);
      });
    }

    function displayShellPositions(hullPositions) {
      var center = [0, 0, 0];
      var count = hullPositions.length / 3;
      var i;
      for (i = 0; i < hullPositions.length; i += 3) {
        center[0] += hullPositions[i] / count;
        center[1] += hullPositions[i + 1] / count;
        center[2] += hullPositions[i + 2] / count;
      }
      var radius = 0;
      for (i = 0; i < hullPositions.length; i += 3) {
        var dx = hullPositions[i] - center[0];
        var dy = hullPositions[i + 1] - center[1];
        var dz = hullPositions[i + 2] - center[2];
        radius = Math.max(radius, Math.sqrt(dx * dx + dy * dy + dz * dz));
      }
      var offset = options.shellOffsetMeters == null ? 0.35 : options.shellOffsetMeters;
      var scale = radius > 0 ? 1 + offset / radius : 1;
      return hullPositions.map(function (value, index) {
        var axis = index % 3;
        return center[axis] + (value - center[axis]) * scale;
      });
    }

    function defaultRenderHull(hull) {
      var CesiumRuntime = options.CesiumRuntime;
      var viewer = options.viewer;
      var shellPositions = displayShellPositions(hull.positions);
      var positions = new Float64Array(shellPositions);
      var indexArray = hull.positions.length / 3 > 65535 ? new Uint32Array(hull.indices) : new Uint16Array(hull.indices);
      removeRender(true);
      currentPrimitive = viewer.scene.primitives.add(new CesiumRuntime.Primitive({
        geometryInstances: new CesiumRuntime.GeometryInstance({
          id: { type: 'convexHull' },
          geometry: new CesiumRuntime.Geometry({
            attributes: {
              position: new CesiumRuntime.GeometryAttribute({
                componentDatatype: CesiumRuntime.ComponentDatatype.DOUBLE,
                componentsPerAttribute: 3,
                values: positions
              })
            },
            indices: indexArray,
            primitiveType: CesiumRuntime.PrimitiveType.TRIANGLES,
            boundingSphere: CesiumRuntime.BoundingSphere.fromVertices(positions)
          }),
          attributes: {
            color: CesiumRuntime.ColorGeometryInstanceAttribute.fromColor(
              CesiumRuntime.Color.fromCssColorString('#f6c85f').withAlpha(0.28)
            )
          }
        }),
        appearance: new CesiumRuntime.PerInstanceColorAppearance({ translucent: true, closed: true, flat: true }),
        asynchronous: false
      }));
      var edges = Object.create(null);
      currentEdges = viewer.scene.primitives.add(new CesiumRuntime.PolylineCollection());
      function addEdge(a, b) {
        var low = Math.min(a, b); var high = Math.max(a, b); var key = low + ':' + high;
        if (edges[key]) return;
        edges[key] = true;
        currentEdges.add({
          positions: [
            CesiumRuntime.Cartesian3.fromArray(shellPositions, a * 3),
            CesiumRuntime.Cartesian3.fromArray(shellPositions, b * 3)
          ],
          width: 1.5,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
          material: CesiumRuntime.Material.fromType('Color', { color: CesiumRuntime.Color.fromCssColorString('#ffe9a8').withAlpha(0.92) })
        });
      }
      for (var i = 0; i < hull.indices.length; i += 3) {
        addEdge(hull.indices[i], hull.indices[i + 1]);
        addEdge(hull.indices[i + 1], hull.indices[i + 2]);
        addEdge(hull.indices[i + 2], hull.indices[i]);
      }
    }

    function analyzeFeature(identifiers, source, requestedMode) {
      var mode = envelopeMode(requestedMode);
      var version = ++requestVersion;
      var started = Date.now();
      currentHull = null;
      if (gridButton) gridButton.disabled = true;
      if (options.clearGrid) options.clearGrid();
      setGridStatus('正在准备' + (mode === 'convex' ? '凸包' : '模型外壳') + '，网格结果已清除。', 'busy');
      setStatus('正在读取浏览器缓存中的模型几何…', 'busy');
      return loadCatalog(source).then(function (catalog) {
        var uris = [];
        identifiers.some(function (identifier) {
          if (catalog.features[String(identifier)]) {
            uris = catalog.features[String(identifier)];
            return true;
          }
          return false;
        });
        if (!uris.length) throw new Error('模型索引中没有找到该要素');
        return Promise.all(uris.map(function (uri) {
          var url = resolveContentUrl(source, uri);
          var fetchBuffer = options.fetchArrayBuffer || defaultFetchArrayBuffer;
          return fetchBuffer(url, source).then(function (arrayBuffer) {
            return global.HuaguoshanGlbFeatureGeometry.readFeatureMesh({
              arrayBuffer: arrayBuffer,
              identifiers: identifiers,
              tileTransform: catalog.tileTransform,
              gltfUpAxis: catalog.gltfUpAxis || 'Y'
            });
          });
        }));
      }).then(function (fragments) {
        if (version !== requestVersion) throw new Error('Convex hull request superseded');
        var mesh = mergeMeshes(fragments);
        var inputVertexCount = fragments.reduce(function (sum, fragment) { return sum + fragment.vertexCount; }, 0);
        var inputTriangleCount = fragments.reduce(function (sum, fragment) { return sum + fragment.triangleCount; }, 0);
        setStatus(
          '已读取 ' + inputVertexCount + ' 个顶点 / ' + inputTriangleCount + ' 个模型面，正在生成' +
          (mode === 'convex' ? '凸包' : '模型外壳') + '…',
          'busy'
        );
        var geometryPromise = mode === 'convex' ? computeHull(mesh.positions) : Promise.resolve(mesh);
        return geometryPromise.then(function (geometry) {
          if (version !== requestVersion) throw new Error('Convex hull request superseded');
          if (options.renderHull) options.renderHull(geometry);
          else defaultRenderHull(geometry);
          showWkt(geometry);
          currentHull = geometry;
          setGridStatus((mode === 'convex' ? '凸包' : '模型外壳') + '已就绪，可调用 iBEST-DB 生成网格。', 'ready');
          var heightRange = geographicHeightRange(geometry, options.toGeographicPosition);
          var result = {
            identifier: fragments[0].identifier,
            mode: mode,
            inputVertexCount: inputVertexCount,
            inputTriangleCount: inputTriangleCount,
            geometry: geometry,
            hull: mode === 'convex' ? geometry : null,
            heightRange: heightRange,
            elapsedMs: Date.now() - started
          };
          setStatus(
            '完成：' + (mode === 'convex' ? '凸包' : '模型外壳') + '，' + geometry.positions.length / 3 +
            ' 个顶点 / ' + geometry.indices.length / 3 + ' 个面' +
            (heightRange ? '，高程 ' + heightRange.min.toFixed(2) + '–' + heightRange.max.toFixed(2) + ' m' : '') +
            '，耗时 ' + result.elapsedMs + ' ms。',
            'success'
          );
          return result;
        });
      }).catch(function (error) {
        if (/superseded/.test(error.message)) return Promise.reject(error);
        setStatus('计算失败：' + error.message, 'error');
        throw error;
      });
    }

    function generateGrid(detailLevel, isAgg) {
      if (!currentHull) return Promise.reject(new Error('请先计算凸包'));
      if (!options.requestGrid) return Promise.reject(new Error('未配置凸包网格 RPC'));
      var level = Number(detailLevel == null && gridLevelInput ? gridLevelInput.value : detailLevel);
      var aggregate = isAgg == null && gridAggInput ? gridAggInput.checked : Boolean(isAgg);
      if (!Number.isInteger(level) || level < 6 || level > 32) return Promise.reject(new Error('网格层级必须在 6 到 32 之间'));
      var geographicWkt = toGeographicPolyhedralSurfaceWkt(currentHull, options.toGeographicPosition, 9);
      setGridStatus('正在调用 iBEST-DB ST_AsGrids3D…', 'busy');
      if (gridButton) gridButton.disabled = true;
      return options.requestGrid({
        p_wkt: geographicWkt,
        p_detail_level: level,
        p_is_agg: aggregate,
        p_max_cells: 5000
      }).then(function (grid) {
        if (options.renderGrid) options.renderGrid(grid);
        setGridStatus('已显示 ' + grid.cell_count + ' 个 GGER 三维网格（L' + grid.detail_level + '）。', 'success');
        return grid;
      }).catch(function (error) {
        setGridStatus('网格生成失败：' + error.message, 'error');
        throw error;
      }).finally(function () {
        if (gridButton && currentHull) gridButton.disabled = false;
      });
    }

    function handleGenerateGrid() {
      generateGrid().catch(function (error) {
        console.error('[ConvexHull] GGER generation failed:', error);
      });
    }
    function handleEnvelopeModeChange() {
      clear();
      if (active) setStatus('包络模式已切换，请重新点击建筑模型。', 'ready');
    }

    function sourceForPicked(picked) {
      var pickedTileset = picked && (picked.tileset || (picked.content && picked.content.tileset));
      return sources().find(function (source) { return source.tileset && source.tileset === pickedTileset; });
    }

    function selectPicked(picked) {
      var source = sourceForPicked(picked);
      if (!source || !picked || typeof picked.getProperty !== 'function') {
        setStatus('请选择已加载的建筑 3D Tiles 模型。', 'error');
        return false;
      }
      var metadata = options.readPickedMetadata(picked);
      var identifiers = options.getPickedIdentifiers(metadata);
      if (!identifiers.length) {
        setStatus('所选模型缺少可识别的 metadata ID。', 'error');
        return true;
      }
      dimSelectedFeature(picked);
      analyzeFeature(identifiers, source).catch(function (error) {
        if (!/superseded/.test(error.message)) {
          restoreSelectedFeature();
          console.error('[ConvexHull] Analysis failed:', error);
        }
      });
      return true;
    }

    function toggle() { if (active) deactivate(); else activate(); }
    function destroy() {
      clear();
      destroyed = true;
      active = false;
      if (button) button.removeEventListener('click', toggle);
      if (clearButton) clearButton.removeEventListener('click', clear);
      if (copyWktButton) copyWktButton.removeEventListener('click', copyWkt);
      if (gridButton) gridButton.removeEventListener('click', handleGenerateGrid);
      if (envelopeModeInput) envelopeModeInput.removeEventListener('change', handleEnvelopeModeChange);
      if (worker) worker.terminate();
      worker = null;
      Object.keys(workerRequests).forEach(function (id) {
        workerRequests[id].reject(new Error('Convex hull module destroyed'));
        delete workerRequests[id];
      });
    }

    if (button) button.addEventListener('click', toggle);
    if (clearButton) clearButton.addEventListener('click', clear);
    if (copyWktButton) copyWktButton.addEventListener('click', copyWkt);
    if (gridButton) gridButton.addEventListener('click', handleGenerateGrid);
    if (envelopeModeInput) envelopeModeInput.addEventListener('change', handleEnvelopeModeChange);
    if (gridButton) gridButton.disabled = true;
    updateButton();

    return {
      activate: activate,
      deactivate: deactivate,
      isActive: isActive,
      selectPicked: selectPicked,
      analyzeFeature: analyzeFeature,
      generateGrid: generateGrid,
      clear: clear,
      destroy: destroy,
      sources: sources
    };
  }

  global.HuaguoshanConvexHull = {
    createModule: createModule,
    toPolyhedralSurfaceWkt: toPolyhedralSurfaceWkt,
    toGeographicPolyhedralSurfaceWkt: toGeographicPolyhedralSurfaceWkt
  };
})(typeof window !== 'undefined' ? window : globalThis);
