(function (global) {
  'use strict';

  function radians(CesiumRuntime, degrees) {
    return CesiumRuntime.Math.toRadians(degrees);
  }

  function flyToLonLat(CesiumRuntime, viewer, options) {
    viewer.camera.flyTo({
      destination: CesiumRuntime.Cartesian3.fromDegrees(options.lon, options.lat, options.height),
      orientation: {
        heading: radians(CesiumRuntime, options.heading),
        pitch: radians(CesiumRuntime, options.pitch),
        roll: options.roll || 0
      },
      duration: options.duration
    });
  }

  function flyToTileset(CesiumRuntime, viewer, tileset, options) {
    viewer.flyTo(tileset, {
      duration: options.duration,
      offset: new CesiumRuntime.HeadingPitchRange(
        radians(CesiumRuntime, options.heading),
        radians(CesiumRuntime, options.pitch),
        options.range
      )
    });
  }

  function flyToHuaguoshan(CesiumRuntime, viewer, huaguoshan) {
    flyToLonLat(CesiumRuntime, viewer, {
      lon: huaguoshan.lon,
      lat: huaguoshan.lat,
      height: 18500,
      heading: 18,
      pitch: -48,
      duration: 2.4
    });
  }

  function flyToChina(CesiumRuntime, viewer) {
    flyToLonLat(CesiumRuntime, viewer, {
      lon: 103.84,
      lat: 31.15,
      height: 17850000,
      heading: 348.4202942851978,
      pitch: -89.74026687972041,
      duration: 2
    });
  }

  function flyToTilt(CesiumRuntime, viewer, huaguoshan) {
    flyToLonLat(CesiumRuntime, viewer, {
      lon: huaguoshan.lon - 0.018,
      lat: huaguoshan.lat - 0.028,
      height: 5400,
      heading: 30,
      pitch: -28,
      duration: 2
    });
  }

  global.HuaguoshanCamera = {
    flyToLonLat: flyToLonLat,
    flyToTileset: flyToTileset,
    flyToHuaguoshan: flyToHuaguoshan,
    flyToChina: flyToChina,
    flyToTilt: flyToTilt
  };
})(window);
