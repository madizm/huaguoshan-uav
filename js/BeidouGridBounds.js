/*
 * BeiDou Grid Code (BGC) bounds helper for GB/T 39409-2020.
 *
 * Computes the geographic bounds of the BGC cell that contains a point.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.BeidouGridBounds = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    var FIRST_LEVEL_LAT_CODES = "ABCDEFGHIJKLMNOPQRSTUV";
    var EARTH_RADIUS_METERS = 6371008.8;
    var EARTH_EQUATORIAL_RADIUS_METERS = 6378137;
    var THETA0_RAD = Math.PI / 180;
    var THETA_MIN_RAD = THETA0_RAD / (3600 * 2048);
    var GRID_BOUNDARY_EPSILON = 1e-12;
    var HEIGHT_LEVEL_BITS = [0, 7, 10, 11, 15, 19, 20, 23, 26, 29, 32];

    var LEVEL_SPECS = [
        null,
        {chars: 3},
        {cols: 12, rows: 8},
        {cols: 2, rows: 3},
        {cols: 15, rows: 10},
        {cols: 15, rows: 15},
        {cols: 2, rows: 2},
        {cols: 8, rows: 8},
        {cols: 8, rows: 8},
        {cols: 8, rows: 8},
        {cols: 8, rows: 8}
    ];

    function assertFiniteNumber(value, name) {
        if (typeof value !== "number" || !isFinite(value)) {
            throw new TypeError(name + " must be a finite number");
        }
    }

    function assertLevel(level) {
        if (level == null) {
            return 10;
        }

        if (Math.floor(level) !== level || level < 1 || level > 10) {
            throw new RangeError("BGC level must be an integer from 1 to 10");
        }

        return level;
    }

    function clampIndex(index, max) {
        if (index < 0) {
            return 0;
        }

        if (index >= max) {
            return max - 1;
        }

        return index;
    }

    function toRadians(degrees) {
        return degrees * Math.PI / 180;
    }

    function heightToLayer(height) {
        assertFiniteNumber(height, "height");

        if (height <= -EARTH_EQUATORIAL_RADIUS_METERS) {
            throw new RangeError("height is outside the valid BGC domain");
        }

        return Math.floor(
            (THETA0_RAD / THETA_MIN_RAD) *
            (Math.log((height + EARTH_EQUATORIAL_RADIUS_METERS) / EARTH_EQUATORIAL_RADIUS_METERS) / Math.log(1 + THETA0_RAD))
        );
    }

    function layerToHeight(layer) {
        assertFiniteNumber(layer, "layer");

        return EARTH_EQUATORIAL_RADIUS_METERS * (
            Math.pow(1 + THETA0_RAD, layer * THETA_MIN_RAD / THETA0_RAD) - 1
        );
    }

    function toUnsigned32(value) {
        return BigInt.asUintN(32, BigInt(value));
    }

    function unsigned32ToSignedNumber(value) {
        var signed = BigInt.asIntN(32, value);

        return Number(signed);
    }

    function distanceMeters(lon1, lat1, lon2, lat2) {
        var phi1 = toRadians(lat1);
        var phi2 = toRadians(lat2);
        var dPhi = toRadians(lat2 - lat1);
        var dLambda = toRadians(lon2 - lon1);
        var sinPhi = Math.sin(dPhi / 2);
        var sinLambda = Math.sin(dLambda / 2);
        var a = sinPhi * sinPhi + Math.cos(phi1) * Math.cos(phi2) * sinLambda * sinLambda;
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        return EARTH_RADIUS_METERS * c;
    }

    function getHeightBounds(height, level) {
        var targetLevel = assertLevel(level);
        var layer;
        var unsignedLayer;
        var bits;
        var shift;
        var unsignedMin;
        var unsignedMaxExclusive;
        var minLayer;
        var maxLayerExclusive;
        var minHeight;
        var maxHeight;

        layer = heightToLayer(height);
        unsignedLayer = toUnsigned32(layer);
        bits = HEIGHT_LEVEL_BITS[targetLevel];
        shift = 32 - bits;
        unsignedMin = (unsignedLayer >> BigInt(shift)) << BigInt(shift);
        unsignedMaxExclusive = unsignedMin + (1n << BigInt(shift));
        minLayer = unsigned32ToSignedNumber(unsignedMin);
        maxLayerExclusive = unsignedMaxExclusive === (1n << 32n) ?
            0 :
            unsigned32ToSignedNumber(unsignedMaxExclusive);
        minHeight = layerToHeight(minLayer);
        maxHeight = layerToHeight(maxLayerExclusive);

        return {
            level: targetLevel,
            layer: layer,
            minLayer: minLayer,
            maxLayerExclusive: maxLayerExclusive,
            minHeight: minHeight,
            maxHeight: maxHeight,
            centerHeight: minHeight + (maxHeight - minHeight) / 2,
            heightMeters: maxHeight - minHeight
        };
    }

    function firstLevelBounds(longitude, latitude) {
        var zone = Math.floor((longitude + 180) / 6) + 1;
        zone = clampIndex(zone - 1, 60) + 1;

        var absLat = Math.abs(latitude);
        var latBand = clampIndex(Math.floor(absLat / 4), FIRST_LEVEL_LAT_CODES.length);
        var minLat = latitude >= 0 ? latBand * 4 : -(latBand + 1) * 4;

        return {
            west: -180 + (zone - 1) * 6,
            south: minLat,
            width: 6,
            height: 4
        };
    }

    function refineBounds(bounds, spec, longitude, latitude) {
        var cellWidth = bounds.width / spec.cols;
        var cellHeight = bounds.height / spec.rows;
        var rawCol = clampIndex(Math.floor((longitude - bounds.west) / cellWidth), spec.cols);
        var rawRow = clampIndex(Math.floor((latitude - bounds.south) / cellHeight - GRID_BOUNDARY_EPSILON), spec.rows);

        bounds.west += rawCol * cellWidth;
        bounds.south += rawRow * cellHeight;
        bounds.width = cellWidth;
        bounds.height = cellHeight;
    }

    function getCellBounds(longitude, latitude, level) {
        var targetLevel = assertLevel(level);
        var bounds;
        var currentLevel;
        var east;
        var north;
        var centerLon;
        var centerLat;

        assertFiniteNumber(longitude, "longitude");
        assertFiniteNumber(latitude, "latitude");

        if (longitude < -180 || longitude > 180) {
            throw new RangeError("longitude must be in [-180, 180]");
        }

        if (latitude <= -88 || latitude >= 88) {
            throw new RangeError("latitude must be in (-88, 88); polar BGC is not implemented");
        }

        bounds = firstLevelBounds(longitude, latitude);

        for (currentLevel = 2; currentLevel <= targetLevel; currentLevel++) {
            refineBounds(bounds, LEVEL_SPECS[currentLevel], longitude, latitude);
        }

        east = bounds.west + bounds.width;
        north = bounds.south + bounds.height;
        centerLon = bounds.west + bounds.width / 2;
        centerLat = bounds.south + bounds.height / 2;

        return {
            level: targetLevel,
            west: bounds.west,
            south: bounds.south,
            east: east,
            north: north,
            centerLon: centerLon,
            centerLat: centerLat,
            widthDegrees: bounds.width,
            heightDegrees: bounds.height,
            widthMeters: distanceMeters(bounds.west, centerLat, east, centerLat),
            heightMeters: distanceMeters(centerLon, bounds.south, centerLon, north)
        };
    }

    return {
        getCellBounds: getCellBounds,
        getHeightBounds: getHeightBounds,
        distanceMeters: distanceMeters
    };
}));
