/*
 * BeiDou airspace grid visualization for Cesium.
 *
 * Renders the current camera view as 2D / 3D BeiDou Grid Code cells and
 * exposes click-to-query BGC metadata. Depends on BeidouGridCode,
 * BeidouGridBounds and a browser Cesium runtime.
 */
(function(root, factory) {
    "use strict";

    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./BeidouGridCode"), require("./BeidouGridBounds"));
    } else {
        root.BeidouAirspaceGrid = factory(root.BeidouGridCode, root.BeidouGridBounds);
    }
}(typeof self !== "undefined" ? self : this, function(BeidouGridCode, BeidouGridBounds) {
    "use strict";

    var DEFAULTS = {
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
    };

    var LEVEL_BY_HEIGHT = [
        {height: 3000000, level: 1},
        {height: 500000, level: 2},
        {height: 120000, level: 3},
        {height: 20000, level: 4},
        {height: 3000, level: 5},
        {height: 800, level: 6},
        {height: 200, level: 7},
        {height: 0, level: 8}
    ];

    var STACK_LAYER_COLORS = [
        "#5eead4",
        "#f6c85f",
        "#ff8f5f",
        "#8bd17c",
        "#80b7ff",
        "#c084fc",
        "#f472b6",
        "#67e8f9",
        "#facc15",
        "#a3e635"
    ];

    function extend(target) {
        var i;
        var source;
        var key;

        for (i = 1; i < arguments.length; i++) {
            source = arguments[i] || {};
            for (key in source) {
                if (Object.prototype.hasOwnProperty.call(source, key)) {
                    target[key] = source[key];
                }
            }
        }

        return target;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    function isFiniteNumber(value) {
        return typeof value === "number" && isFinite(value);
    }

    function roundCoord(value) {
        return Math.round(value * 1000000000) / 1000000000;
    }

    function formatCodeKey(bounds) {
        return [
            roundCoord(bounds.west),
            roundCoord(bounds.south),
            roundCoord(bounds.east),
            roundCoord(bounds.north)
        ].join(":");
    }

    function getCesium() {
        /* global Cesium */
        if (typeof Cesium === "undefined") {
            throw new Error("Cesium runtime is required for BeidouAirspaceGrid");
        }

        return Cesium;
    }

    function createColor(css, alpha) {
        var Cesium = getCesium();
        var color = Cesium.Color.fromCssColorString(css);

        return isFiniteNumber(alpha) ? color.withAlpha(alpha) : color;
    }

    function createColorMaterial(color) {
        var Cesium = getCesium();

        return Cesium.Material.fromType(Cesium.Material.ColorType || "Color", {
            color: color
        });
    }

    function createLayerMaterials(alpha) {
        return STACK_LAYER_COLORS.map(function(color) {
            return createColorMaterial(createColor(color, alpha));
        });
    }

    function toDegreesRectangle(rectangle) {
        var Cesium = getCesium();
        var west = Cesium.Math.toDegrees(rectangle.west);
        var south = Cesium.Math.toDegrees(rectangle.south);
        var east = Cesium.Math.toDegrees(rectangle.east);
        var north = Cesium.Math.toDegrees(rectangle.north);

        if (east < west) {
            west = -180;
            east = 180;
        }

        return {
            west: clamp(west, -180, 180),
            south: clamp(south, DEFAULTS.minLatitude, DEFAULTS.maxLatitude),
            east: clamp(east, -180, 180),
            north: clamp(north, DEFAULTS.minLatitude, DEFAULTS.maxLatitude)
        };
    }

    function getFallbackRectangle(viewer) {
        var Cesium = getCesium();
        var cartographic = viewer.camera.positionCartographic;
        var lon = Cesium.Math.toDegrees(cartographic.longitude);
        var lat = Cesium.Math.toDegrees(cartographic.latitude);
        var height = Math.max(cartographic.height, 1);
        var span = clamp(height / 110000, 0.003, 30);

        return {
            west: clamp(lon - span, -180, 180),
            south: clamp(lat - span, DEFAULTS.minLatitude, DEFAULTS.maxLatitude),
            east: clamp(lon + span, -180, 180),
            north: clamp(lat + span, DEFAULTS.minLatitude, DEFAULTS.maxLatitude)
        };
    }

    function getViewRectangle(viewer) {
        var rectangle;

        if (viewer.camera.computeViewRectangle) {
            rectangle = viewer.camera.computeViewRectangle(viewer.scene.globe.ellipsoid);
        }

        return rectangle ? toDegreesRectangle(rectangle) : getFallbackRectangle(viewer);
    }

    function estimateMetersPerPixel(viewer, rectangle) {
        var widthMeters;
        var canvasWidth = viewer.scene.canvas.clientWidth || viewer.scene.canvas.width || 1;
        var centerLat = (rectangle.south + rectangle.north) / 2;

        widthMeters = BeidouGridBounds.distanceMeters(rectangle.west, centerLat, rectangle.east, centerLat);

        if (!isFiniteNumber(widthMeters) || widthMeters <= 0) {
            return null;
        }

        return widthMeters / canvasWidth;
    }

    function levelFromHeight(height, maxLevel) {
        var i;
        var level = 1;

        for (i = 0; i < LEVEL_BY_HEIGHT.length; i++) {
            if (height > LEVEL_BY_HEIGHT[i].height) {
                level = LEVEL_BY_HEIGHT[i].level;
                break;
            }
        }

        return clamp(level, 1, maxLevel);
    }

    function chooseAutoLevel(viewer, rectangle, options, previousLevel) {
        var metersPerPixel = estimateMetersPerPixel(viewer, rectangle);
        var centerLon = (rectangle.west + rectangle.east) / 2;
        var centerLat = clamp((rectangle.south + rectangle.north) / 2, options.minLatitude, options.maxLatitude);
        var bestLevel = levelFromHeight(viewer.camera.positionCartographic.height, options.maxAutoLevel);
        var bestScore = Number.POSITIVE_INFINITY;
        var level;
        var bounds;
        var cellPixels;
        var score;

        if (metersPerPixel) {
            for (level = 1; level <= options.maxAutoLevel; level++) {
                bounds = BeidouGridBounds.getCellBounds(centerLon, centerLat, level);
                cellPixels = Math.max(bounds.widthMeters, bounds.heightMeters) / metersPerPixel;
                score = Math.abs(Math.log(Math.max(cellPixels, 1) / options.targetCellPixels));
                if (score < bestScore) {
                    bestScore = score;
                    bestLevel = level;
                }
            }
        }

        if (previousLevel && Math.abs(bestLevel - previousLevel) === 1) {
            bounds = BeidouGridBounds.getCellBounds(centerLon, centerLat, previousLevel);
            cellPixels = metersPerPixel ? Math.max(bounds.widthMeters, bounds.heightMeters) / metersPerPixel : options.targetCellPixels;
            if (cellPixels > options.targetCellPixels * 0.72 && cellPixels < options.targetCellPixels * 1.55) {
                return previousLevel;
            }
        }

        return bestLevel;
    }

    function expandRectangle(rectangle, level, options) {
        var centerLon = (rectangle.west + rectangle.east) / 2;
        var centerLat = clamp((rectangle.south + rectangle.north) / 2, options.minLatitude, options.maxLatitude);
        var bounds = BeidouGridBounds.getCellBounds(centerLon, centerLat, level);
        var padLon = bounds.widthDegrees * options.rectanglePaddingCells;
        var padLat = bounds.heightDegrees * options.rectanglePaddingCells;

        return {
            west: clamp(rectangle.west - padLon, -180, 180),
            south: clamp(rectangle.south - padLat, options.minLatitude, options.maxLatitude),
            east: clamp(rectangle.east + padLon, -180, 180),
            north: clamp(rectangle.north + padLat, options.minLatitude, options.maxLatitude)
        };
    }

    function enumerateCells(rectangle, level, maxCells, options) {
        var padded = expandRectangle(rectangle, level, options);
        var cells = [];
        var seen = Object.create(null);
        var epsilon = 1e-10;
        var lat = clamp(padded.south + epsilon, options.minLatitude, options.maxLatitude);
        var lon;
        var rowBounds;
        var bounds;
        var key;
        var code2D;
        var guardRows = 0;
        var guardCols;

        while (lat < padded.north && guardRows < maxCells + 1000) {
            rowBounds = BeidouGridBounds.getCellBounds(clamp(padded.west + epsilon, -180, 180), lat, level);
            lon = clamp(padded.west + epsilon, -180, 180);
            guardCols = 0;

            while (lon < padded.east && guardCols < maxCells + 1000) {
                bounds = BeidouGridBounds.getCellBounds(lon, lat, level);
                key = formatCodeKey(bounds);

                if (!seen[key]) {
                    code2D = BeidouGridCode.encode2D(bounds.centerLon, bounds.centerLat, level);
                    seen[key] = true;
                    cells.push({
                        level: level,
                        code2D: code2D,
                        bounds: bounds
                    });

                    if (cells.length > maxCells) {
                        return {
                            cells: cells,
                            exceeded: true
                        };
                    }
                }

                if (bounds.east <= lon) {
                    break;
                }
                lon = clamp(bounds.east + epsilon, -180, 180);
                guardCols++;
            }

            if (rowBounds.north <= lat) {
                break;
            }
            lat = clamp(rowBounds.north + epsilon, options.minLatitude, options.maxLatitude);
            guardRows++;
        }

        return {
            cells: cells,
            exceeded: false
        };
    }

    function normalizeSegmentKey(a, b) {
        var first = a.join(",");
        var second = b.join(",");

        return first < second ? first + "|" + second : second + "|" + first;
    }

    function addEdge(edges, lon1, lat1, height1, lon2, lat2, height2, type, layerIndex) {
        var a = [roundCoord(lon1), roundCoord(lat1), Math.round(height1 * 1000) / 1000];
        var b = [roundCoord(lon2), roundCoord(lat2), Math.round(height2 * 1000) / 1000];
        var key = normalizeSegmentKey(a, b);

        if (!edges[key] || type === "slice") {
            edges[key] = {
                lon1: lon1,
                lat1: lat1,
                height1: height1,
                lon2: lon2,
                lat2: lat2,
                height2: height2,
                type: type,
                layerIndex: isFiniteNumber(layerIndex) ? layerIndex : null
            };
        }
    }

    function addRectangleEdges(edges, bounds, height, type, layerIndex) {
        addEdge(edges, bounds.west, bounds.south, height, bounds.east, bounds.south, height, type, layerIndex);
        addEdge(edges, bounds.east, bounds.south, height, bounds.east, bounds.north, height, type, layerIndex);
        addEdge(edges, bounds.east, bounds.north, height, bounds.west, bounds.north, height, type, layerIndex);
        addEdge(edges, bounds.west, bounds.north, height, bounds.west, bounds.south, height, type, layerIndex);
    }

    function addVerticalEdges(edges, bounds, minHeight, maxHeight, layerIndex) {
        addEdge(edges, bounds.west, bounds.south, minHeight, bounds.west, bounds.south, maxHeight, "vertical", layerIndex);
        addEdge(edges, bounds.east, bounds.south, minHeight, bounds.east, bounds.south, maxHeight, "vertical", layerIndex);
        addEdge(edges, bounds.east, bounds.north, minHeight, bounds.east, bounds.north, maxHeight, "vertical", layerIndex);
        addEdge(edges, bounds.west, bounds.north, minHeight, bounds.west, bounds.north, maxHeight, "vertical", layerIndex);
    }

    function clearCollection(collection) {
        if (collection && collection.removeAll) {
            collection.removeAll();
        }
    }

    function createCollections(viewer) {
        var Cesium = getCesium();

        return {
            lines: viewer.scene.primitives.add(new Cesium.PolylineCollection()),
            labels: viewer.scene.primitives.add(new Cesium.LabelCollection())
        };
    }

    function destroyPrimitive(viewer, primitive) {
        if (primitive && !primitive.isDestroyed()) {
            viewer.scene.primitives.remove(primitive);
        }
    }

    function createRenderer(viewer, userOptions) {
        var Cesium = getCesium();
        var options = extend({}, DEFAULTS, userOptions || {});
        var collections = createCollections(viewer);
        var materials = {
            base: createColorMaterial(createColor("#5eead4", 0.58)),
            top: createColorMaterial(createColor("#d7a846", 0.72)),
            vertical: createColorMaterial(createColor("#fff7df", 0.34)),
            slice: createColorMaterial(createColor("#ffb84d", 0.84)),
            layers: createLayerMaterials(0.82)
        };
        var selectedEntity = null;
        var handler = new Cesium.ScreenSpaceEventHandler(viewer.scene.canvas);
        var updateTimer = null;
        var lastLevel = options.level;
        var lastStats = {
            enabled: options.enabled,
            level: options.level,
            cells: 0,
            exceeded: false,
            message: "北斗网格未开启"
        };

        function emitStatus(message, extra) {
            lastStats = extend({}, lastStats, extra || {}, {message: message});
            if (typeof options.onStatus === "function") {
                options.onStatus(lastStats);
            }
        }

        function emitSelection(selection) {
            if (typeof options.onSelection === "function") {
                options.onSelection(selection);
            }
        }

        function getStackCount(cellCount) {
            var requested = parseInt(options.stackCount, 10);
            var maxStackCount = parseInt(options.maxStackCount, 10);
            var effective;

            if (!isFiniteNumber(requested) || requested < 1) requested = 1;
            if (!isFiniteNumber(maxStackCount) || maxStackCount < 1) maxStackCount = 10;
            requested = Math.min(requested, maxStackCount);
            effective = requested;

            if (options.verticalEnabled && cellCount > 0 && cellCount * effective > options.maxStackedCells) {
                effective = Math.max(1, Math.floor(options.maxStackedCells / cellCount));
            }

            return {
                requested: requested,
                effective: effective,
                downgraded: effective !== requested
            };
        }

        function getHeightModel(level, cellCount) {
            var stack = getStackCount(cellCount || 0);
            var anchorHeight = Number(options.anchorHeight);
            var currentHeight = Number(options.currentHeight);
            var layers;
            var firstLayer;
            var lastLayer;
            var stackMinHeight;
            var stackMaxHeight;
            var stackHeightMeters;
            var currentLayer;
            var maxCurrentHeight;

            if (!isFiniteNumber(anchorHeight)) anchorHeight = 0;
            layers = BeidouGridBounds.getStackedHeightBounds(anchorHeight, level, stack.effective);
            if (!layers.length) {
                layers = [BeidouGridBounds.getHeightBounds(anchorHeight, level)];
            }

            firstLayer = layers[0];
            lastLayer = layers[layers.length - 1];
            stackMinHeight = firstLayer.minHeight;
            stackMaxHeight = lastLayer.maxHeight;
            stackHeightMeters = stackMaxHeight - stackMinHeight;
            if (!isFiniteNumber(currentHeight)) currentHeight = firstLayer.centerHeight;
            maxCurrentHeight = stackMaxHeight - Math.max(Math.abs(stackMaxHeight) * 1e-12, 1e-9);
            currentHeight = clamp(currentHeight, stackMinHeight, maxCurrentHeight);
            currentLayer = BeidouGridBounds.getHeightBounds(currentHeight, level);

            return {
                anchorHeight: anchorHeight,
                currentHeight: currentHeight,
                currentLayer: currentLayer,
                firstLayer: firstLayer,
                lastLayer: lastLayer,
                layers: layers,
                stackCount: stack.effective,
                requestedStackCount: stack.requested,
                stackDowngraded: stack.downgraded,
                stackMinHeight: stackMinHeight,
                stackMaxHeight: stackMaxHeight,
                stackHeightMeters: stackHeightMeters,
                unitHeightMeters: firstLayer.heightMeters
            };
        }

        function drawLines(cells, heightModel) {
            var edges = Object.create(null);
            var keys;
            var edge;
            var material;
            var i;

            clearCollection(collections.lines);
            clearCollection(collections.labels);

            cells.forEach(function(cell) {
                if (options.verticalEnabled) {
                    heightModel.layers.forEach(function(layer, layerIndex) {
                        if (layerIndex === 0) {
                            addRectangleEdges(edges, cell.bounds, layer.minHeight, "layer", layerIndex);
                        }
                        addRectangleEdges(edges, cell.bounds, layer.maxHeight, "layer", layerIndex);
                        addVerticalEdges(edges, cell.bounds, layer.minHeight, layer.maxHeight, layerIndex);
                    });
                } else {
                    addRectangleEdges(edges, cell.bounds, heightModel.stackMinHeight, "base");
                }
                if (options.sliceEnabled) {
                    addRectangleEdges(edges, cell.bounds, heightModel.currentLayer.minHeight, "slice");
                    addRectangleEdges(edges, cell.bounds, heightModel.currentLayer.maxHeight, "slice");
                }
            });

            keys = Object.keys(edges);
            for (i = 0; i < keys.length; i++) {
                edge = edges[keys[i]];
                material = isFiniteNumber(edge.layerIndex) ? materials.layers[Math.abs(edge.layerIndex) % materials.layers.length] : materials[edge.type] || materials.base;
                collections.lines.add({
                    positions: [
                        Cesium.Cartesian3.fromDegrees(edge.lon1, edge.lat1, edge.height1),
                        Cesium.Cartesian3.fromDegrees(edge.lon2, edge.lat2, edge.height2)
                    ],
                    width: edge.type === "slice" ? 2.4 : (isFiniteNumber(edge.layerIndex) ? 1.5 : 1.2),
                    material: material
                });
            }

            if (options.labelsEnabled) {
                drawLabels(cells, heightModel.currentLayer.centerHeight);
            }
        }

        function drawLabels(cells, height) {
            var center = getViewCenter();
            var sorted = cells.slice().sort(function(a, b) {
                var da = Math.pow(a.bounds.centerLon - center.lon, 2) + Math.pow(a.bounds.centerLat - center.lat, 2);
                var db = Math.pow(b.bounds.centerLon - center.lon, 2) + Math.pow(b.bounds.centerLat - center.lat, 2);
                return da - db;
            });
            var count = Math.min(sorted.length, options.maxLabels);
            var i;
            var cell;

            for (i = 0; i < count; i++) {
                cell = sorted[i];
                collections.labels.add({
                    position: Cesium.Cartesian3.fromDegrees(cell.bounds.centerLon, cell.bounds.centerLat, height + 8),
                    text: cell.code2D,
                    font: "600 13px Microsoft YaHei",
                    fillColor: createColor("#fff7df", 0.94),
                    outlineColor: createColor("#083d33", 0.96),
                    outlineWidth: 3,
                    style: Cesium.LabelStyle.FILL_AND_OUTLINE,
                    scaleByDistance: new Cesium.NearFarScalar(500, 1.0, 50000, 0.25),
                    distanceDisplayCondition: new Cesium.DistanceDisplayCondition(0, 90000),
                    disableDepthTestDistance: Number.POSITIVE_INFINITY
                });
            }
        }

        function getViewCenter() {
            var rectangle = getViewRectangle(viewer);
            return {
                lon: (rectangle.west + rectangle.east) / 2,
                lat: (rectangle.south + rectangle.north) / 2
            };
        }

        function getRenderableCells(rectangle, requestedLevel) {
            var level = requestedLevel;
            var result;

            while (level >= 1) {
                result = enumerateCells(rectangle, level, options.maxCells, options);
                if (!result.exceeded || level === 1) {
                    return {
                        level: level,
                        cells: result.cells,
                        exceeded: result.exceeded,
                        downgraded: level !== requestedLevel
                    };
                }
                level--;
            }

            return {level: 1, cells: [], exceeded: true, downgraded: true};
        }

        function refreshNow() {
            var rectangle;
            var requestedLevel;
            var renderable;
            var heightModel;
            var message;

            if (!options.enabled) {
                clearCollection(collections.lines);
                clearCollection(collections.labels);
                emitStatus("北斗网格未开启", {enabled: false, cells: 0, level: options.level});
                return;
            }

            rectangle = getViewRectangle(viewer);
            requestedLevel = options.autoLevel ? chooseAutoLevel(viewer, rectangle, options, lastLevel) : options.level;
            renderable = getRenderableCells(rectangle, requestedLevel);
            lastLevel = renderable.level;
            options.level = renderable.level;
            heightModel = getHeightModel(renderable.level, renderable.cells.length);

            drawLines(renderable.cells, heightModel);

            message = "北斗网格 L" + renderable.level + "：" + renderable.cells.length + " 个可视单元";
            if (renderable.downgraded) {
                message += "，已因密度过高自动降级";
            }
            if (heightModel.stackDowngraded) {
                message += "，堆叠层数已降至 " + heightModel.stackCount;
            }
            if (options.verticalEnabled) {
                message += "，BGC 高度层 " + heightModel.unitHeightMeters.toFixed(2) + "m，堆叠 " + heightModel.stackCount + " 层";
            }

            emitStatus(message, {
                enabled: true,
                level: renderable.level,
                requestedLevel: requestedLevel,
                cells: renderable.cells.length,
                exceeded: renderable.exceeded,
                downgraded: renderable.downgraded,
                anchorHeight: heightModel.anchorHeight,
                stackCount: heightModel.stackCount,
                requestedStackCount: heightModel.requestedStackCount,
                stackDowngraded: heightModel.stackDowngraded,
                stackMinHeight: heightModel.stackMinHeight,
                stackMaxHeight: heightModel.stackMaxHeight,
                unitHeightMeters: heightModel.unitHeightMeters,
                layers: heightModel.layers,
                currentHeight: heightModel.currentHeight,
                currentLayer: heightModel.currentLayer,
                minHeight: heightModel.stackMinHeight,
                maxHeight: heightModel.stackMaxHeight
            });
        }

        function scheduleRefresh() {
            if (updateTimer) {
                clearTimeout(updateTimer);
            }
            updateTimer = setTimeout(function() {
                updateTimer = null;
                refreshNow();
            }, options.debounceMs);
        }

        function removeSelection() {
            if (selectedEntity) {
                viewer.entities.remove(selectedEntity);
                selectedEntity = null;
            }
        }

        function showSelection(bounds, heightBounds) {
            var hierarchy = Cesium.Cartesian3.fromDegreesArray([
                bounds.west, bounds.south,
                bounds.east, bounds.south,
                bounds.east, bounds.north,
                bounds.west, bounds.north
            ]);

            removeSelection();
            selectedEntity = viewer.entities.add({
                name: "北斗空域选中单元",
                polygon: {
                    hierarchy: hierarchy,
                    height: heightBounds.minHeight,
                    extrudedHeight: heightBounds.maxHeight,
                    material: createColor("#d85a35", 0.18),
                    outline: true,
                    outlineColor: createColor("#fff7df", 0.92)
                },
                polyline: {
                    positions: Cesium.Cartesian3.fromDegreesArrayHeights([
                        bounds.west, bounds.south, heightBounds.maxHeight,
                        bounds.east, bounds.south, heightBounds.maxHeight,
                        bounds.east, bounds.north, heightBounds.maxHeight,
                        bounds.west, bounds.north, heightBounds.maxHeight,
                        bounds.west, bounds.south, heightBounds.maxHeight
                    ]),
                    width: 3,
                    material: createColor("#d85a35", 0.95),
                    clampToGround: false
                }
            });
        }

        function pickCartographic(position) {
            var scene = viewer.scene;
            var ray;
            var cartesian;

            if (scene.pickPositionSupported) {
                cartesian = scene.pickPosition(position);
            }

            if (!cartesian) {
                ray = viewer.camera.getPickRay(position);
                cartesian = ray ? scene.globe.pick(ray, scene) : null;
            }

            if (!cartesian) {
                cartesian = viewer.camera.pickEllipsoid(position, scene.globe.ellipsoid);
            }

            return cartesian ? Cesium.Cartographic.fromCartesian(cartesian) : null;
        }

        function handleClick(movement) {
            var cartographic;
            var lon;
            var lat;
            var level;
            var bounds;
            var heightBounds;
            var heightModel;
            var currentHeight;
            var selection;

            if (!options.enabled) {
                return;
            }

            cartographic = pickCartographic(movement.position);
            if (!cartographic) {
                return;
            }

            lon = Cesium.Math.toDegrees(cartographic.longitude);
            lat = clamp(Cesium.Math.toDegrees(cartographic.latitude), options.minLatitude, options.maxLatitude);
            level = lastLevel || options.level;
            heightModel = getHeightModel(level, 0);
            currentHeight = heightModel.currentHeight;
            bounds = BeidouGridBounds.getCellBounds(lon, lat, level);
            heightBounds = heightModel.currentLayer;
            selection = {
                level: level,
                lon: lon,
                lat: lat,
                code2D: BeidouGridCode.encode2D(bounds.centerLon, bounds.centerLat, level),
                code3D: BeidouGridCode.encode3D(bounds.centerLon, bounds.centerLat, currentHeight, level),
                bounds: bounds,
                heightBounds: heightBounds,
                anchorHeight: heightModel.anchorHeight,
                stackCount: heightModel.stackCount,
                layers: heightModel.layers,
                stackMinHeight: heightModel.stackMinHeight,
                stackMaxHeight: heightModel.stackMaxHeight,
                unitHeightMeters: heightModel.unitHeightMeters,
                minHeight: heightModel.stackMinHeight,
                maxHeight: heightModel.stackMaxHeight,
                currentHeight: currentHeight
            };

            showSelection(bounds, heightBounds);
            emitSelection(selection);
            emitStatus("已选中北斗空域单元：" + selection.code2D, {
                selectedCode2D: selection.code2D,
                selectedCode3D: selection.code3D
            });
        }

        handler.setInputAction(handleClick, Cesium.ScreenSpaceEventType.LEFT_CLICK);
        viewer.camera.changed.addEventListener(scheduleRefresh);

        return {
            refresh: scheduleRefresh,
            refreshNow: refreshNow,
            getOptions: function() {
                return extend({}, options);
            },
            getStats: function() {
                return extend({}, lastStats);
            },
            setEnabled: function(value) {
                options.enabled = Boolean(value);
                scheduleRefresh();
            },
            setVerticalEnabled: function(value) {
                options.verticalEnabled = Boolean(value);
                scheduleRefresh();
            },
            setSliceEnabled: function(value) {
                options.sliceEnabled = Boolean(value);
                scheduleRefresh();
            },
            setLabelsEnabled: function(value) {
                options.labelsEnabled = Boolean(value);
                scheduleRefresh();
            },
            setAutoLevel: function(value) {
                options.autoLevel = Boolean(value);
                scheduleRefresh();
            },
            setLevel: function(value) {
                var level = parseInt(value, 10);
                if (level >= 1 && level <= 10) {
                    options.level = level;
                    lastLevel = level;
                    options.autoLevel = false;
                    scheduleRefresh();
                }
            },
            setAnchorHeight: function(height) {
                if (isFiniteNumber(Number(height))) {
                    options.anchorHeight = Number(height);
                    scheduleRefresh();
                }
            },
            setStackCount: function(value) {
                var stackCount = parseInt(value, 10);
                if (stackCount >= 1) {
                    options.stackCount = stackCount;
                    scheduleRefresh();
                }
            },
            setHeights: function(minHeight) {
                if (isFiniteNumber(Number(minHeight))) options.anchorHeight = Number(minHeight);
                scheduleRefresh();
            },
            setCurrentHeight: function(height) {
                if (isFiniteNumber(Number(height))) {
                    options.currentHeight = Number(height);
                    scheduleRefresh();
                }
            },
            setMaxCells: function(value) {
                var maxCells = parseInt(value, 10);
                if (maxCells >= 1) {
                    options.maxCells = maxCells;
                    scheduleRefresh();
                }
            },
            clearSelection: function() {
                removeSelection();
                emitSelection(null);
            },
            destroy: function() {
                if (updateTimer) {
                    clearTimeout(updateTimer);
                }
                viewer.camera.changed.removeEventListener(scheduleRefresh);
                handler.destroy();
                removeSelection();
                destroyPrimitive(viewer, collections.lines);
                destroyPrimitive(viewer, collections.labels);
            }
        };
    }

    function create(viewer, options) {
        if (!BeidouGridCode || !BeidouGridBounds) {
            throw new Error("BeidouGridCode and BeidouGridBounds are required");
        }
        if (!viewer || !viewer.scene || !viewer.camera) {
            throw new TypeError("A Cesium Viewer instance is required");
        }

        return createRenderer(viewer, options || {});
    }

    return {
        create: create,
        _private: {
            enumerateCells: enumerateCells,
            chooseAutoLevel: chooseAutoLevel,
            levelFromHeight: levelFromHeight
        }
    };
}));
