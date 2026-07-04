/*
 * BeiDou airspace grid visualization adapter for Cesium.
 *
 * Keeps the public BeidouAirspaceGrid module name while delegating rendering to
 * the shared AirspaceGridRenderer implementation.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./AirspaceGridRenderer"), require("./BeidouGridCode"), require("./BeidouGridBounds"));
    } else {
        root.BeidouAirspaceGrid = factory(root.AirspaceGridRenderer, root.BeidouGridCode, root.BeidouGridBounds);
    }
}(typeof self !== "undefined" ? self : this, function(AirspaceGridRenderer, BeidouGridCode, BeidouGridBounds) {
    "use strict";

    return AirspaceGridRenderer.createGridModule({
        moduleName: "BeidouAirspaceGrid",
        displayName: "北斗网格",
        codeName: "BGC",
        selectedEntityName: "北斗空域选中单元",
        selectionMessagePrefix: "已选中北斗空域单元：",
        missingDependencyMessage: "BeidouGridCode and BeidouGridBounds are required",
        GridCode: BeidouGridCode,
        GridBounds: BeidouGridBounds,
        minLevel: 1,
        maxLevel: 10,
        fallbackAutoLevel: 1,
        defaults: {
            enabled: false,
            verticalEnabled: false,
            sliceEnabled: false,
            labelsEnabled: false,
            autoLevel: true,
            level: 5,
            maxAutoLevel: 7,
            anchorHeight: 0,
            stackCount: 3,
            maxStackCount: 10,
            maxStackedCells: 12000,
            currentHeight: 120,
            maxCells: 3000,
            maxLabels: 60,
            targetCellPixels: 120,
            debounceMs: 180,
            minLatitude: -87.999999,
            maxLatitude: 87.999999,
            rectanglePaddingCells: 1
        },
        levelByHeight: [
            {height: 3000000, level: 1},
            {height: 500000, level: 2},
            {height: 120000, level: 3},
            {height: 20000, level: 4},
            {height: 3000, level: 5},
            {height: 800, level: 6},
            {height: 200, level: 7},
            {height: 0, level: 8}
        ]
    });
}));
