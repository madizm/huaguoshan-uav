/*
 * GGER / GeoSOT bounds helper for GB/T 40087-2021.
 *
 * Computes the geographic bounds of the GGER cell that contains a point,
 * plus GeoSOT-3D height-layer bounds for airspace visualization.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./GGERGridCode"));
    } else {
        root.GGERGridBounds = factory(root.GGERGridCode);
    }
}(typeof self !== "undefined" ? self : this, function(GGERGridCode) {
    "use strict";

    var EARTH_RADIUS_METERS = 6371008.8;
    var EARTH_EQUATORIAL_RADIUS_METERS = 6378137;
    var THETA0_RAD = Math.PI / 180;
    var DMS_FRACTION_SCALE = 2048;
    var UNDERGROUND_FLAG = 2147483648;
    var UINT32_SIZE = 4294967296n;

    function assertFiniteNumber(value, name) {
        if (typeof value !== "number" || !isFinite(value)) {
            throw new TypeError(name + " must be a finite number");
        }
    }

    function assertLevel(level) {
        if (level == null) {
            return 32;
        }

        if (Math.floor(level) !== level || level < 1 || level > 32) {
            throw new RangeError("GGER visualization level must be an integer from 1 to 32");
        }

        return level;
    }

    function assertLongitude(longitude) {
        assertFiniteNumber(longitude, "longitude");
        if (longitude < -180 || longitude > 180) {
            throw new RangeError("longitude must be in [-180, 180]");
        }
    }

    function assertLatitude(latitude) {
        assertFiniteNumber(latitude, "latitude");
        if (latitude < -90 || latitude > 90) {
            throw new RangeError("latitude must be in [-90, 90]");
        }
    }

    function toRadians(degrees) {
        return degrees * Math.PI / 180;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
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

    function levelStep(level) {
        return 1n << BigInt(32 - assertLevel(level));
    }

    function floorToLevelIndex(index, level) {
        var step = levelStep(level);
        return (BigInt(index) / step) * step;
    }

    function coordinateToIndex(value) {
        if (!GGERGridCode || typeof GGERGridCode.coordinateToIndex !== "function") {
            throw new Error("GGERGridCode.coordinateToIndex is required");
        }
        return GGERGridCode.coordinateToIndex(value);
    }

    function heightToLayer(height) {
        if (!GGERGridCode || typeof GGERGridCode.heightToLayer !== "function") {
            throw new Error("GGERGridCode.heightToLayer is required");
        }
        return GGERGridCode.heightToLayer(height);
    }

    function indexToCoordinate(index, axis) {
        var unsigned = BigInt.asUintN(32, BigInt(index));
        var fractions = Number(unsigned % BigInt(DMS_FRACTION_SCALE));
        var total = unsigned / BigInt(DMS_FRACTION_SCALE);
        var seconds = Number(total % 64n);
        total = total / 64n;
        var minutes = Number(total % 64n);
        var degreeCode = Number(total / 64n);
        var negative = degreeCode >= 256;
        var degrees = negative ? degreeCode - 256 : degreeCode;
        var value = degrees + minutes / 60 + (seconds + fractions / DMS_FRACTION_SCALE) / 3600;

        if (negative) {
            value = -value;
        }

        return axis === "lat" ? clamp(value, -90, 90) : clamp(value, -180, 180);
    }

    function getCellBounds(longitude, latitude, level) {
        var targetLevel = assertLevel(level);
        var x;
        var y;
        var minX;
        var minY;
        var maxX;
        var maxY;
        var west;
        var east;
        var south;
        var north;
        var centerLon;
        var centerLat;

        assertLongitude(longitude);
        assertLatitude(latitude);

        x = coordinateToIndex(longitude);
        y = coordinateToIndex(latitude);
        minX = floorToLevelIndex(x, targetLevel);
        minY = floorToLevelIndex(y, targetLevel);
        maxX = minX + levelStep(targetLevel);
        maxY = minY + levelStep(targetLevel);

        west = indexToCoordinate(minX, "lon");
        east = indexToCoordinate(maxX >= UINT32_SIZE ? UINT32_SIZE - 1n : maxX, "lon");
        south = indexToCoordinate(minY, "lat");
        north = indexToCoordinate(maxY >= UINT32_SIZE ? UINT32_SIZE - 1n : maxY, "lat");

        if (east < west) {
            var tmpLon = west;
            west = east;
            east = tmpLon;
        }
        if (north < south) {
            var tmpLat = south;
            south = north;
            north = tmpLat;
        }

        centerLon = (west + east) / 2;
        centerLat = (south + north) / 2;

        return {
            level: targetLevel,
            west: west,
            south: south,
            east: east,
            north: north,
            centerLon: centerLon,
            centerLat: centerLat,
            widthDegrees: east - west,
            heightDegrees: north - south,
            widthMeters: distanceMeters(west, centerLat, east, centerLat),
            heightMeters: distanceMeters(centerLon, south, centerLon, north),
            xRange: {min: minX.toString(), maxExclusive: maxX.toString()},
            yRange: {min: minY.toString(), maxExclusive: maxY.toString()}
        };
    }

    function extendedDmsIndexToArcSecondFractions(index) {
        var value = Math.floor(Number(index));
        var fractions = value % DMS_FRACTION_SCALE;
        var total = Math.floor(value / DMS_FRACTION_SCALE);
        var seconds = total % 64;
        total = Math.floor(total / 64);
        var minutes = total % 64;
        var degrees = Math.floor(total / 64);

        return (((degrees * 60 + minutes) * 60 + seconds) * DMS_FRACTION_SCALE) + fractions;
    }

    function arcSecondFractionsToHeight(value, underground) {
        var exponent = value / (3600 * DMS_FRACTION_SCALE);
        var factor = Math.pow(1 + THETA0_RAD, exponent);

        if (underground) {
            return -EARTH_EQUATORIAL_RADIUS_METERS * (1 - 1 / factor);
        }

        return EARTH_EQUATORIAL_RADIUS_METERS * (factor - 1);
    }

    function layerToHeight(z) {
        var unsigned = Number(BigInt.asUintN(32, BigInt(z)));
        var underground = unsigned >= UNDERGROUND_FLAG;
        var layer = underground ? unsigned - UNDERGROUND_FLAG : unsigned;
        var arcSecondFractions = extendedDmsIndexToArcSecondFractions(layer);

        return arcSecondFractionsToHeight(arcSecondFractions, underground);
    }

    function heightBoundsFromUnsignedMin(unsignedMin, level, layer) {
        var targetLevel = assertLevel(level);
        var step = levelStep(targetLevel);
        var unsignedMaxExclusive = unsignedMin + step;
        var cappedMax = unsignedMaxExclusive >= UINT32_SIZE ? UINT32_SIZE - 1n : unsignedMaxExclusive;
        if (unsignedMin < BigInt(UNDERGROUND_FLAG) && cappedMax >= BigInt(UNDERGROUND_FLAG)) {
            cappedMax = BigInt(UNDERGROUND_FLAG) - 1n;
        }
        var minHeight = layerToHeight(unsignedMin);
        var maxHeight = layerToHeight(cappedMax);
        var minLayer = Number(BigInt.asUintN(32, unsignedMin));
        var maxLayerExclusive = Number(BigInt.asUintN(32, unsignedMaxExclusive));

        if (maxHeight < minHeight) {
            var tmp = minHeight;
            minHeight = maxHeight;
            maxHeight = tmp;
        }

        return {
            level: targetLevel,
            layer: layer == null ? minLayer : layer,
            minLayer: minLayer,
            maxLayerExclusive: maxLayerExclusive,
            minHeight: minHeight,
            maxHeight: maxHeight,
            centerHeight: minHeight + (maxHeight - minHeight) / 2,
            heightMeters: maxHeight - minHeight
        };
    }

    function getHeightBounds(height, level) {
        var targetLevel = assertLevel(level);
        var z;
        var unsignedLayer;
        var unsignedMin;

        assertFiniteNumber(height, "height");
        z = heightToLayer(height);
        unsignedLayer = BigInt.asUintN(32, BigInt(z));
        unsignedMin = floorToLevelIndex(unsignedLayer, targetLevel);

        return heightBoundsFromUnsignedMin(unsignedMin, targetLevel, z);
    }

    function getHeightBoundsByLayer(layer, level) {
        var targetLevel = assertLevel(level);
        var unsignedLayer;
        var unsignedMin;

        assertFiniteNumber(layer, "layer");
        unsignedLayer = BigInt.asUintN(32, BigInt(Math.floor(layer)));
        unsignedMin = floorToLevelIndex(unsignedLayer, targetLevel);

        return heightBoundsFromUnsignedMin(unsignedMin, targetLevel, Math.floor(layer));
    }

    function getStackedHeightBounds(anchorHeight, level, stackCount) {
        var targetLevel = assertLevel(level);
        var count = stackCount == null ? 1 : stackCount;
        var anchor = getHeightBounds(anchorHeight, targetLevel);
        var step = levelStep(targetLevel);
        var start = BigInt(anchor.minLayer);
        var layers = [];
        var i;
        var layer;

        if (Math.floor(count) !== count || count < 0) {
            throw new RangeError("stackCount must be a non-negative integer");
        }

        for (i = 0; i < count; i++) {
            layer = start + step * BigInt(i);
            if (layer >= UINT32_SIZE) {
                break;
            }
            layers.push(heightBoundsFromUnsignedMin(layer, targetLevel, Number(layer)));
        }

        return layers;
    }

    return {
        getCellBounds: getCellBounds,
        getHeightBounds: getHeightBounds,
        getHeightBoundsByLayer: getHeightBoundsByLayer,
        getStackedHeightBounds: getStackedHeightBounds,
        distanceMeters: distanceMeters,
        layerToHeight: layerToHeight,
        indexToCoordinate: indexToCoordinate
    };
}));
