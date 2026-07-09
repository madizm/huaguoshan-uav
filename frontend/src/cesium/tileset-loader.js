(function (global) {
  'use strict';

  function add3DTileset(CesiumRuntime, viewer, url, options) {
    var tilesetOptions = Object.assign({}, options && options.tilesetOptions || {});
    var onAdded = options && options.onAdded;
    var createTileset = CesiumRuntime.Cesium3DTileset.fromUrl
      ? CesiumRuntime.Cesium3DTileset.fromUrl(url, tilesetOptions)
      : Promise.resolve(new CesiumRuntime.Cesium3DTileset(Object.assign({ url: url }, tilesetOptions)));

    return createTileset.then(function (tileset) {
      if (Object.prototype.hasOwnProperty.call(tilesetOptions, 'show')) {
        tileset.show = tilesetOptions.show;
      }
      viewer.scene.primitives.add(tileset);
      if (onAdded) onAdded(tileset);

      var ready = tileset.readyPromise || Promise.resolve(tileset);
      return ready.then(function () {
        return tileset;
      });
    });
  }

  global.HuaguoshanTilesetLoader = {
    add3DTileset: add3DTileset
  };
})(window);
