(function (global) {
  'use strict';

  function subtract(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function cross(a, b) {
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  }
  function lengthSquared(a) { return dot(a, a); }

  function face(points, a, b, c, interior) {
    var normal = cross(subtract(points[b], points[a]), subtract(points[c], points[a]));
    var length = Math.sqrt(lengthSquared(normal));
    if (!length) return null;
    normal = [normal[0] / length, normal[1] / length, normal[2] / length];
    var result = { a: a, b: b, c: c, normal: normal, offset: dot(normal, points[a]) };
    if (distance(result, interior) > 0) {
      result.b = c;
      result.c = b;
      result.normal = [-normal[0], -normal[1], -normal[2]];
      result.offset = dot(result.normal, points[a]);
    }
    return result;
  }

  function distance(currentFace, point) {
    return dot(currentFace.normal, point) - currentFace.offset;
  }

  function uniquePoints(flatPositions) {
    if (!flatPositions || flatPositions.length % 3 !== 0) throw new TypeError('Positions must contain xyz triples');
    var points = [];
    var seen = Object.create(null);
    var i;
    var min = [Infinity, Infinity, Infinity];
    var max = [-Infinity, -Infinity, -Infinity];
    for (i = 0; i < flatPositions.length; i += 3) {
      min[0] = Math.min(min[0], flatPositions[i]); min[1] = Math.min(min[1], flatPositions[i + 1]); min[2] = Math.min(min[2], flatPositions[i + 2]);
      max[0] = Math.max(max[0], flatPositions[i]); max[1] = Math.max(max[1], flatPositions[i + 1]); max[2] = Math.max(max[2], flatPositions[i + 2]);
    }
    var scale = Math.max(max[0] - min[0], max[1] - min[1], max[2] - min[2], 1);
    var tolerance = scale * 1e-10;
    for (i = 0; i < flatPositions.length; i += 3) {
      var point = [flatPositions[i], flatPositions[i + 1], flatPositions[i + 2]];
      var key = point.map(function (value) { return Math.round(value / tolerance); }).join(':');
      if (!seen[key]) { seen[key] = true; points.push(point); }
    }
    return { points: points, tolerance: scale * 1e-9 };
  }

  function farthestFromPoint(points, index) {
    var best = -1;
    var bestDistance = -1;
    points.forEach(function (point, candidate) {
      var value = lengthSquared(subtract(point, points[index]));
      if (value > bestDistance) { best = candidate; bestDistance = value; }
    });
    return { index: best, distance: Math.sqrt(bestDistance) };
  }

  function initialTetrahedron(points, tolerance) {
    var p0 = 0;
    points.forEach(function (point, index) { if (point[0] < points[p0][0]) p0 = index; });
    var line = farthestFromPoint(points, p0);
    if (line.distance <= tolerance) throw new Error('Convex hull points are coincident');
    var p1 = line.index;
    var direction = subtract(points[p1], points[p0]);
    var directionLength2 = lengthSquared(direction);
    var p2 = -1;
    var lineDistance2 = -1;
    points.forEach(function (point, index) {
      var relative = subtract(point, points[p0]);
      var projected = dot(relative, direction) / directionLength2;
      var rejection = subtract(relative, [direction[0] * projected, direction[1] * projected, direction[2] * projected]);
      var value = lengthSquared(rejection);
      if (value > lineDistance2) { p2 = index; lineDistance2 = value; }
    });
    if (Math.sqrt(lineDistance2) <= tolerance) throw new Error('Convex hull points are collinear');
    var planeNormal = cross(subtract(points[p1], points[p0]), subtract(points[p2], points[p0]));
    var planeLength = Math.sqrt(lengthSquared(planeNormal));
    planeNormal = [planeNormal[0] / planeLength, planeNormal[1] / planeLength, planeNormal[2] / planeLength];
    var p3 = -1;
    var planeDistance = -1;
    points.forEach(function (point, index) {
      var value = Math.abs(dot(planeNormal, subtract(point, points[p0])));
      if (value > planeDistance) { p3 = index; planeDistance = value; }
    });
    if (planeDistance <= tolerance) throw new Error('Convex hull points are coplanar');
    return [p0, p1, p2, p3];
  }

  function addHorizonEdge(edges, a, b) {
    var reverse = b + ':' + a;
    var key = a + ':' + b;
    if (edges[reverse]) delete edges[reverse];
    else edges[key] = [a, b];
  }

  function compute(flatPositions) {
    var unique = uniquePoints(flatPositions);
    var originalPoints = unique.points;
    if (originalPoints.length < 4) throw new Error('Convex hull requires at least four unique points');
    var center = originalPoints.reduce(function (sum, point) {
      return [sum[0] + point[0], sum[1] + point[1], sum[2] + point[2]];
    }, [0, 0, 0]).map(function (value) { return value / originalPoints.length; });
    var points = originalPoints.map(function (point) { return subtract(point, center); });
    var tetra = initialTetrahedron(points, unique.tolerance);
    var interior = tetra.reduce(function (sum, index) {
      return [sum[0] + points[index][0] / 4, sum[1] + points[index][1] / 4, sum[2] + points[index][2] / 4];
    }, [0, 0, 0]);
    var faces = [
      face(points, tetra[0], tetra[1], tetra[2], interior),
      face(points, tetra[0], tetra[3], tetra[1], interior),
      face(points, tetra[0], tetra[2], tetra[3], interior),
      face(points, tetra[1], tetra[3], tetra[2], interior)
    ];
    var initial = Object.create(null);
    tetra.forEach(function (index) { initial[index] = true; });

    points.forEach(function (point, pointIndex) {
      if (initial[pointIndex]) return;
      var visible = faces.filter(function (currentFace) { return distance(currentFace, point) > unique.tolerance; });
      if (!visible.length) return;
      var visibleSet = new Set(visible);
      var horizon = Object.create(null);
      visible.forEach(function (currentFace) {
        addHorizonEdge(horizon, currentFace.a, currentFace.b);
        addHorizonEdge(horizon, currentFace.b, currentFace.c);
        addHorizonEdge(horizon, currentFace.c, currentFace.a);
      });
      faces = faces.filter(function (currentFace) { return !visibleSet.has(currentFace); });
      Object.keys(horizon).forEach(function (key) {
        var edge = horizon[key];
        var next = face(points, edge[0], edge[1], pointIndex, interior);
        if (next) faces.push(next);
      });
    });

    var used = Object.create(null);
    faces.forEach(function (currentFace) { used[currentFace.a] = true; used[currentFace.b] = true; used[currentFace.c] = true; });
    var oldIndices = Object.keys(used).map(Number).sort(function (a, b) { return a - b; });
    var remap = Object.create(null);
    var positions = [];
    oldIndices.forEach(function (oldIndex, newIndex) {
      remap[oldIndex] = newIndex;
      positions.push(points[oldIndex][0] + center[0], points[oldIndex][1] + center[1], points[oldIndex][2] + center[2]);
    });
    var indices = [];
    faces.forEach(function (currentFace) { indices.push(remap[currentFace.a], remap[currentFace.b], remap[currentFace.c]); });
    return { positions: positions, indices: indices };
  }

  global.HuaguoshanConvexHullKernel = { compute: compute };
})(typeof window !== 'undefined' ? window : globalThis);
