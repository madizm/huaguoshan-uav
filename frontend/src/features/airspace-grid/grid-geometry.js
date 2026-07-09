(function (global) {
  'use strict';

  function parseJsonText(value) {
    if (!value) return null;
    if (typeof value === 'object') return value;
    try {
      return JSON.parse(String(value).trim());
    } catch (error) {
      console.warn('[Tianditu3D] Failed to parse GGER JSON text:', error, value);
      return null;
    }
  }

  function parseBboxText(bboxText) {
    var parts;
    var minParts;
    var maxParts;
    if (!bboxText) return null;
    parts = String(bboxText).replace(/[()]/g, '').split(',');
    if (parts.length !== 2) return null;
    minParts = parts[0].trim().split(/\s+/).map(Number);
    maxParts = parts[1].trim().split(/\s+/).map(Number);
    if (minParts.length < 3 || maxParts.length < 3) return null;
    if (minParts.concat(maxParts).some(function (value) { return !Number.isFinite(value); })) return null;
    return {
      minLon: minParts[0],
      minLat: minParts[1],
      minHeight: minParts[2],
      maxLon: maxParts[0],
      maxLat: maxParts[1],
      maxHeight: maxParts[2]
    };
  }

  function extractGridCells(gridData) {
    var grid = gridData && gridData.grid;
    var withBox = parseJsonText(grid && grid.gger_grids_with_box);
    var cells = withBox && Array.isArray(withBox.cells) ? withBox.cells : [];
    return cells.map(function (cell) {
      var bbox = parseBboxText(cell && cell.bbox);
      return bbox ? Object.assign({ code: cell.code || '' }, bbox) : null;
    }).filter(Boolean);
  }

  function gridLayerColor(colors, layerIndex) {
    var palette = colors && colors.length ? colors : ['#5eead4'];
    var index = Math.abs(parseInt(layerIndex, 10) || 0) % palette.length;
    return palette[index];
  }

  function gridLayerKey(cell) {
    return cell.minHeight.toFixed(3) + ':' + cell.maxHeight.toFixed(3);
  }

  function sortedGridLayers(cells) {
    var byKey = {};
    var layers = [];
    cells.forEach(function (cell) {
      var key = gridLayerKey(cell);
      if (!byKey[key]) {
        byKey[key] = {
          key: key,
          minHeight: cell.minHeight,
          maxHeight: cell.maxHeight
        };
        layers.push(byKey[key]);
      }
    });
    return layers.sort(function (a, b) {
      return (a.minHeight - b.minHeight) || (a.maxHeight - b.maxHeight);
    });
  }

  function gridLayerIndex(cell, layers) {
    var key = gridLayerKey(cell);
    var i;
    for (i = 0; i < layers.length; i += 1) {
      if (layers[i].key === key) return i;
    }
    return 0;
  }

  function gridLayerMaterial(CesiumRuntime, cache, layerIndex, alpha, colors) {
    var color = gridLayerColor(colors, layerIndex);
    var key = color + ':' + alpha;
    if (!cache[key]) {
      cache[key] = CesiumRuntime.Material.fromType(CesiumRuntime.Material.ColorType || 'Color', {
        color: CesiumRuntime.Color.fromCssColorString(color).withAlpha(alpha)
      });
    }
    return cache[key];
  }

  function makeEdgeKey(a, b) {
    var first = a.join(',');
    var second = b.join(',');
    return first < second ? first + '|' + second : second + '|' + first;
  }

  function addBoxEdge(edges, lon1, lat1, h1, lon2, lat2, h2, layerIndex) {
    var a = [lon1.toFixed(9), lat1.toFixed(9), h1.toFixed(3)];
    var b = [lon2.toFixed(9), lat2.toFixed(9), h2.toFixed(3)];
    var key = makeEdgeKey(a, b);
    if (!edges[key]) {
      edges[key] = {
        lon1: lon1,
        lat1: lat1,
        h1: h1,
        lon2: lon2,
        lat2: lat2,
        h2: h2,
        layerIndex: layerIndex
      };
    }
  }

  function addBoxEdges(edges, cell, layerIndex) {
    var west = cell.minLon;
    var south = cell.minLat;
    var east = cell.maxLon;
    var north = cell.maxLat;
    var bottom = cell.minHeight;
    var top = cell.maxHeight;

    addBoxEdge(edges, west, south, bottom, east, south, bottom, layerIndex);
    addBoxEdge(edges, east, south, bottom, east, north, bottom, layerIndex);
    addBoxEdge(edges, east, north, bottom, west, north, bottom, layerIndex);
    addBoxEdge(edges, west, north, bottom, west, south, bottom, layerIndex);
    addBoxEdge(edges, west, south, top, east, south, top, layerIndex);
    addBoxEdge(edges, east, south, top, east, north, top, layerIndex);
    addBoxEdge(edges, east, north, top, west, north, top, layerIndex);
    addBoxEdge(edges, west, north, top, west, south, top, layerIndex);
    addBoxEdge(edges, west, south, bottom, west, south, top, layerIndex);
    addBoxEdge(edges, east, south, bottom, east, south, top, layerIndex);
    addBoxEdge(edges, east, north, bottom, east, north, top, layerIndex);
    addBoxEdge(edges, west, north, bottom, west, north, top, layerIndex);
  }

  function cellsBounds(cells) {
    if (!cells.length) return null;
    return cells.reduce(function (acc, cell) {
      return {
        west: Math.min(acc.west, cell.minLon),
        south: Math.min(acc.south, cell.minLat),
        east: Math.max(acc.east, cell.maxLon),
        north: Math.max(acc.north, cell.maxLat),
        minHeight: Math.min(acc.minHeight, cell.minHeight),
        maxHeight: Math.max(acc.maxHeight, cell.maxHeight)
      };
    }, {
      west: Number.POSITIVE_INFINITY,
      south: Number.POSITIVE_INFINITY,
      east: Number.NEGATIVE_INFINITY,
      north: Number.NEGATIVE_INFINITY,
      minHeight: Number.POSITIVE_INFINITY,
      maxHeight: Number.NEGATIVE_INFINITY
    });
  }

  function mergeBounds(boundsList) {
    var valid = boundsList.filter(Boolean);
    if (!valid.length) return null;
    return valid.reduce(function (acc, bounds) {
      return {
        west: Math.min(acc.west, bounds.west),
        south: Math.min(acc.south, bounds.south),
        east: Math.max(acc.east, bounds.east),
        north: Math.max(acc.north, bounds.north),
        minHeight: Math.min(acc.minHeight, bounds.minHeight),
        maxHeight: Math.max(acc.maxHeight, bounds.maxHeight)
      };
    });
  }

  function createGridHighlight(CesiumRuntime, viewer, gridData, colors) {
    var cells = extractGridCells(gridData);
    var edges = {};
    var materialCache = {};
    var layers;
    var primitive;

    if (!viewer || !CesiumRuntime || !cells.length) return null;

    layers = sortedGridLayers(cells);
    cells.forEach(function (cell) {
      addBoxEdges(edges, cell, gridLayerIndex(cell, layers));
    });

    primitive = new CesiumRuntime.PolylineCollection();
    Object.keys(edges).forEach(function (key) {
      var edge = edges[key];
      primitive.add({
        positions: [
          CesiumRuntime.Cartesian3.fromDegrees(edge.lon1, edge.lat1, edge.h1),
          CesiumRuntime.Cartesian3.fromDegrees(edge.lon2, edge.lat2, edge.h2)
        ],
        width: layers.length > 1 ? 2.4 : 2.2,
        material: gridLayerMaterial(CesiumRuntime, materialCache, edge.layerIndex, 0.9, colors)
      });
    });

    return {
      primitive: viewer.scene.primitives.add(primitive),
      bounds: cellsBounds(cells),
      cells: cells
    };
  }

  global.HuaguoshanGridGeometry = {
    parseJsonText: parseJsonText,
    parseBboxText: parseBboxText,
    extractGridCells: extractGridCells,
    gridLayerColor: gridLayerColor,
    sortedGridLayers: sortedGridLayers,
    gridLayerIndex: gridLayerIndex,
    gridLayerMaterial: gridLayerMaterial,
    makeEdgeKey: makeEdgeKey,
    addBoxEdge: addBoxEdge,
    addBoxEdges: addBoxEdges,
    cellsBounds: cellsBounds,
    mergeBounds: mergeBounds,
    createGridHighlight: createGridHighlight
  };
})(window);
