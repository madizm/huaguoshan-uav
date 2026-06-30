/*
 * GGER encoder for GB/T 40087-2021.
 *
 * GGER is the textual form of the GeoSOT grid code:
 * - 2D: "G" plus one base-4 digit per level.
 * - 3D: "GZ" plus one base-8 digit per level.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.GGERGridCode = factory();
    }
}(typeof self !== "undefined" ? self : this, function() {
    "use strict";

    var EARTH_EQUATORIAL_RADIUS_METERS = 6378137;
    var THETA0_RAD = Math.PI / 180;
    var THETA_MIN_RAD = THETA0_RAD / (3600 * 2048);
    var DMS_FRACTION_SCALE = 2048;
    var UNDERGROUND_FLAG = 2147483648;

    function assertFiniteNumber(value, name) {
        if (typeof value !== "number" || !isFinite(value)) {
            throw new TypeError(name + " must be a finite number");
        }
    }

    function assertLevel(level) {
        if (level == null) {
            return 32;
        }

        if (Math.floor(level) !== level || level < 0 || level > 32) {
            throw new RangeError("GGER level must be an integer from 0 to 32");
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

    function coordinateToIndex(value) {
        // GeoSOT expands each coordinate into a 32-bit DMS index:
        // 9 bits degree, 6 bits minute, 6 bits second, 11 bits 1/2048-second fraction.
        var absValue = Math.abs(value);
        var totalSeconds = absValue * 3600;
        var degrees = Math.floor(totalSeconds / 3600);
        var minuteSeconds = totalSeconds - degrees * 3600;
        var minutes = Math.floor(minuteSeconds / 60);
        var secondValue = minuteSeconds - minutes * 60;
        var seconds = Math.floor(secondValue);
        var fractions = Math.floor((secondValue - seconds) * DMS_FRACTION_SCALE);
        var degreeCode = degrees + (value < 0 ? 256 : 0);

        if (minutes >= 60) {
            minutes = 0;
            degreeCode += 1;
        }

        if (seconds >= 60) {
            seconds = 0;
            minutes += 1;
        }

        if (fractions >= DMS_FRACTION_SCALE) {
            fractions = 0;
            seconds += 1;
        }

        return BigInt(
            (((degreeCode * 64 + minutes) * 64 + seconds) * DMS_FRACTION_SCALE) + fractions
        );
    }

    function heightToLayer(height) {
        assertFiniteNumber(height, "height");

        if (height <= -EARTH_EQUATORIAL_RADIUS_METERS) {
            throw new RangeError("height is outside the valid GGER domain");
        }

        // GeoSOT-3D height first maps ellipsoidal height to accumulated 1/2048"
        // angular layers, then stores that layer count in the same extended DMS
        // layout used by longitude/latitude. Underground heights use bit 31 as a flag.
        var absoluteHeight = Math.abs(height);
        var heightRatio = height < 0 ?
            EARTH_EQUATORIAL_RADIUS_METERS / (EARTH_EQUATORIAL_RADIUS_METERS - absoluteHeight) :
            (absoluteHeight + EARTH_EQUATORIAL_RADIUS_METERS) / EARTH_EQUATORIAL_RADIUS_METERS;
        var arcSecondFractions = Math.floor(
            (THETA0_RAD / THETA_MIN_RAD) *
            (Math.log(heightRatio) / Math.log(1 + THETA0_RAD))
        );
        var layer = arcSecondFractionsToExtendedDmsIndex(arcSecondFractions);

        return height < 0 ? UNDERGROUND_FLAG + layer : layer;
    }

    function arcSecondFractionsToExtendedDmsIndex(value) {
        // Convert ordinary 60-minute/60-second accumulated fractions into the
        // GeoSOT storage layout where minute and second fields are 6-bit values.
        var fractions = value % DMS_FRACTION_SCALE;
        var totalSeconds = Math.floor(value / DMS_FRACTION_SCALE);
        var seconds = totalSeconds % 60;
        var totalMinutes = Math.floor(totalSeconds / 60);
        var minutes = totalMinutes % 60;
        var degrees = Math.floor(totalMinutes / 60);

        return (((degrees * 64 + minutes) * 64 + seconds) * DMS_FRACTION_SCALE) + fractions;
    }

    function bitAt(value, bitIndex) {
        return Number((value >> BigInt(bitIndex)) & 1n);
    }

    function encode2D(longitude, latitude, level) {
        var targetLevel = assertLevel(level);
        var x;
        var y;
        var code;
        var bitIndex;
        var xBit;
        var yBit;

        assertLongitude(longitude);
        assertLatitude(latitude);

        x = coordinateToIndex(longitude);
        y = coordinateToIndex(latitude);
        code = "G";

        // Each level consumes one high-to-low bit from x and y, producing one
        // base-4 Morton digit in the order used by iBEST-DB GGER output.
        for (bitIndex = 31; bitIndex >= 32 - targetLevel; bitIndex--) {
            xBit = bitAt(x, bitIndex);
            yBit = bitAt(y, bitIndex);
            code += String(yBit * 2 + xBit);
        }

        return code;
    }

    function encode3D(longitude, latitude, height, level) {
        var targetLevel = assertLevel(level);
        var x;
        var y;
        var z;
        var code;
        var bitIndex;
        var xBit;
        var yBit;
        var zBit;

        assertLongitude(longitude);
        assertLatitude(latitude);

        x = coordinateToIndex(longitude);
        y = coordinateToIndex(latitude);
        z = BigInt(heightToLayer(height));
        code = "GZ";

        // 3D GGER extends the 2D Morton digit with one height bit, yielding one
        // base-8 digit per level.
        for (bitIndex = 31; bitIndex >= 32 - targetLevel; bitIndex--) {
            xBit = bitAt(x, bitIndex);
            yBit = bitAt(y, bitIndex);
            zBit = bitAt(z, bitIndex);
            code += String(yBit * 4 + xBit * 2 + zBit);
        }

        return code;
    }

    return {
        encode2D: encode2D,
        encode3D: encode3D,
        coordinateToIndex: coordinateToIndex,
        heightToLayer: heightToLayer
    };
}));
