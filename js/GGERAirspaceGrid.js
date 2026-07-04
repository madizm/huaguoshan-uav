/*
 * GGER airspace grid visualization adapter for Cesium.
 *
 * Keeps the public GGERAirspaceGrid module name while delegating rendering to
 * the shared AirspaceGridRenderer implementation.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./AirspaceGridRenderer"), require("./GGERGridCode"), require("./GGERGridBounds"));
    } else {
        root.GGERAirspaceGrid = factory(root.AirspaceGridRenderer, root.GGERGridCode, root.GGERGridBounds);
    }
}(typeof self !== "undefined" ? self : this, function(AirspaceGridRenderer, GGERGridCode, GGERGridBounds) {
    "use strict";

    return AirspaceGridRenderer.createGridModule({
        moduleName: "GGERAirspaceGrid",
        displayName: "GGER 网格",
        codeName: "GGER",
        selectedEntityName: "GGER 空域选中单元",
        selectionMessagePrefix: "已选中 GGER 空域单元：",
        missingDependencyMessage: "GGERGridCode and GGERGridBounds are required",
        GridCode: GGERGridCode,
        GridBounds: GGERGridBounds,
        minLevel: 1,
        maxLevel: 32,
        fallbackAutoLevel: 8,
        defaults: {
            enabled: false,
            verticalEnabled: false,
            sliceEnabled: false,
            labelsEnabled: false,
            autoLevel: true,
            level: 19,
            maxAutoLevel: 23,
            anchorHeight: 0,
            stackCount: 3,
            maxStackCount: 10,
            maxStackedCells: 12000,
            currentHeight: 120,
            maxCells: 3000,
            maxLabels: 60,
            targetCellPixels: 120,
            debounceMs: 180,
            minLatitude: -89.999999,
            maxLatitude: 89.999999,
            rectanglePaddingCells: 1
        },
        levelByHeight: [
            {height: 3000000, level: 8},
            {height: 500000, level: 11},
            {height: 120000, level: 14},
            {height: 20000, level: 18},
            {height: 3000, level: 20},
            {height: 800, level: 22},
            {height: 200, level: 23},
            {height: 0, level: 24}
        ]
    });
}));
