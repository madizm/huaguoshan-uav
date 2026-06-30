/*
 * BeiDou Grid Code (BGC) encoder for GB/T 39409-2020.
 *
 * Supports the non-polar latitude range used by iBEST-DB ST_asBGC:
 * -88 < latitude < 88, -180 <= longitude <= 180.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.BeidouGridCode = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    var FIRST_LEVEL_LAT_CODES = "ABCDEFGHIJKLMNOPQRSTUV";
    var BASE15 = "0123456789ABCDE";
    var BASE16 = "0123456789ABCDEF";
    var EARTH_EQUATORIAL_RADIUS_METERS = 6378137;
    var THETA0_RAD = Math.PI / 180;
    var THETA_MIN_RAD = THETA0_RAD / (3600 * 2048);
    var GRID_BOUNDARY_EPSILON = 1e-12;

    var LEVEL_SPECS = [
        null,
        {chars: 3},
        {cols: 12, rows: 8, type: "pair", xDigits: "0123456789AB", yDigits: "01234567"},
        {cols: 2, rows: 3, type: "z", digits: "012345"},
        {cols: 15, rows: 10, type: "pair", xDigits: BASE15, yDigits: "0123456789"},
        {cols: 15, rows: 15, type: "pair", xDigits: BASE15, yDigits: BASE15},
        {cols: 2, rows: 2, type: "z", digits: "0123"},
        {cols: 8, rows: 8, type: "pair", xDigits: "01234567", yDigits: "01234567"},
        {cols: 8, rows: 8, type: "pair", xDigits: "01234567", yDigits: "01234567"},
        {cols: 8, rows: 8, type: "pair", xDigits: "01234567", yDigits: "01234567"},
        {cols: 8, rows: 8, type: "pair", xDigits: "01234567", yDigits: "01234567"}
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

    function encodeFirstLevel(longitude, latitude) {
        var hemisphere = latitude >= 0 ? "N" : "S";
        var zone = Math.floor((longitude + 180) / 6) + 1;
        zone = clampIndex(zone - 1, 60) + 1;

        var absLat = Math.abs(latitude);
        var latBand = clampIndex(Math.floor(absLat / 4), FIRST_LEVEL_LAT_CODES.length);
        var minLat = hemisphere === "N" ? latBand * 4 : -(latBand + 1) * 4;

        return {
            code: hemisphere + String(zone).padStart(2, "0") + FIRST_LEVEL_LAT_CODES.charAt(latBand),
            minLon: -180 + (zone - 1) * 6,
            minLat: minLat,
            width: 6,
            height: 4,
            eastHemisphere: longitude >= 0,
            northHemisphere: latitude >= 0
        };
    }

    function encodeSubLevel(state, spec, longitude, latitude) {
        var cellWidth = state.width / spec.cols;
        var cellHeight = state.height / spec.rows;
        var rawCol = clampIndex(Math.floor((longitude - state.minLon) / cellWidth), spec.cols);
        var rawRow = clampIndex(Math.floor((latitude - state.minLat) / cellHeight - GRID_BOUNDARY_EPSILON), spec.rows);
        var codeCol = state.eastHemisphere ? rawCol : spec.cols - 1 - rawCol;
        var codeRow = state.northHemisphere ? rawRow : spec.rows - 1 - rawRow;
        var code;

        if (spec.type === "z") {
            code = spec.digits.charAt(codeRow * spec.cols + codeCol);
        } else {
            code = spec.xDigits.charAt(codeCol) + spec.yDigits.charAt(codeRow);
        }

        state.minLon += rawCol * cellWidth;
        state.minLat += rawRow * cellHeight;
        state.width = cellWidth;
        state.height = cellHeight;

        return code;
    }

    function encode2DSegments(longitude, latitude, level) {
        var targetLevel = assertLevel(level);
        assertFiniteNumber(longitude, "longitude");
        assertFiniteNumber(latitude, "latitude");

        if (longitude < -180 || longitude > 180) {
            throw new RangeError("longitude must be in [-180, 180]");
        }

        if (latitude <= -88 || latitude >= 88) {
            throw new RangeError("latitude must be in (-88, 88); polar BGC is not implemented");
        }

        var firstLevel = encodeFirstLevel(longitude, latitude);
        var state = {
            minLon: firstLevel.minLon,
            minLat: firstLevel.minLat,
            width: firstLevel.width,
            height: firstLevel.height,
            eastHemisphere: firstLevel.eastHemisphere,
            northHemisphere: firstLevel.northHemisphere
        };
        var segments = [firstLevel.code.charAt(0), firstLevel.code.slice(1)];
        var currentLevel;

        for (currentLevel = 2; currentLevel <= targetLevel; currentLevel++) {
            segments.push(encodeSubLevel(state, LEVEL_SPECS[currentLevel], longitude, latitude));
        }

        return segments;
    }

    function encode2D(longitude, latitude, level) {
        return encode2DSegments(longitude, latitude, level).join("");
    }

    function toUnsigned32Bits(value) {
        return BigInt.asUintN(32, BigInt(value));
    }

    function getBits(bits, startBit, length) {
        return Number((bits >> BigInt(startBit - 1)) & ((1n << BigInt(length)) - 1n));
    }

    function encodeHeightSegments(height) {
        assertFiniteNumber(height, "height");

        if (height <= -EARTH_EQUATORIAL_RADIUS_METERS) {
            throw new RangeError("height is outside the valid BGC domain");
        }

        var layer = Math.floor(
            (THETA0_RAD / THETA_MIN_RAD) *
            (Math.log((height + EARTH_EQUATORIAL_RADIUS_METERS) / EARTH_EQUATORIAL_RADIUS_METERS) / Math.log(1 + THETA0_RAD))
        );
        var bits = toUnsigned32Bits(layer);
        var a11 = getBits(bits, 1, 3).toString(8);
        var a10 = getBits(bits, 4, 3).toString(8);
        var a9 = getBits(bits, 7, 3).toString(8);
        var a8 = getBits(bits, 10, 3).toString(8);
        var a7 = String(getBits(bits, 13, 1));
        var a6 = BASE16.charAt(getBits(bits, 14, 4));
        var a5 = BASE16.charAt(getBits(bits, 18, 4));
        var a4 = String(getBits(bits, 22, 1));
        var a3 = getBits(bits, 23, 3).toString(8);
        var a1a2 = String(getBits(bits, 26, 6)).padStart(2, "0");
        var a0 = String(getBits(bits, 32, 1));

        return [a0, a1a2, a3, a4, a5, a6, a7, a8, a9, a10, a11];
    }

    function encode3D(longitude, latitude, height, level) {
        var targetLevel = assertLevel(level);
        var xy = encode2DSegments(longitude, latitude, targetLevel);
        var z = encodeHeightSegments(height);
        var code = xy[0] + z[0] + xy[1] + z[1];
        var currentLevel;

        for (currentLevel = 2; currentLevel <= targetLevel; currentLevel++) {
            code += xy[currentLevel] + z[currentLevel];
        }

        return code;
    }

    return {
        encode2D: encode2D,
        encode3D: encode3D,
        encode2DSegments: encode2DSegments,
        encodeHeightSegments: encodeHeightSegments
    };
}));
