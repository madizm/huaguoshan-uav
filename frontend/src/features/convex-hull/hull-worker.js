'use strict';

importScripts('./convex-hull-kernel.js');

self.addEventListener('message', function (event) {
  var id = event.data.id;
  try {
    var positions = new Float64Array(event.data.positions);
    var hull = self.HuaguoshanConvexHullKernel.compute(positions);
    var hullPositions = new Float64Array(hull.positions);
    var hullIndices = new Uint32Array(hull.indices);
    self.postMessage({ id: id, positions: hullPositions.buffer, indices: hullIndices.buffer }, [hullPositions.buffer, hullIndices.buffer]);
  } catch (error) {
    self.postMessage({ id: id, error: error.message || String(error) });
  }
});
