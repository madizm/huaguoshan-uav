# GGER 空域三维分割可视化实施计划

> 本文档替代原 BGC（北斗网格码）空域可视化方案。可视化网格算法统一切换为 GB/T 40087-2021《地球空间网格编码规则》的 GGER / GeoSOT 编码；算法依据见 `docs/gger-grid-code-algorithm.md`。

## 1. 背景与目标

基于 `docs/gger-grid-code-algorithm.md` 中整理的 GGER 编码算法，以及当前工程已有的：

- `js/GGERGridCode.js`：二维 / 三维 GGER 编码。
- `frontend/tianditu-3d.html`：Cesium + 天地图三维底图展示页面。
- 原 `js/BeidouAirspaceGrid.js` / `js/BeidouGridBounds.js`：可作为迁移参考，但后续网格计算不再使用 BGC 规则。

实现一套面向空域的 GGER 三维分割可视化能力：根据 Cesium 相机缩放级别，实时渲染当前可视域内的 GGER 网格，并严格按照 GGER / GeoSOT 三维高度层号剖分算法展示当前 level 对应的高度单元，同时支持高度单元向上堆叠。

核心目标：

1. 基于 zoom / camera height 自动选择 GGER level。
2. 实时计算当前可视域内的 GGER 二维网格。
3. 按 GGER level 对应的 GeoSOT 高度层厚度展示三维空域分割，而不是使用固定 `0-300m` 人工高度范围。
4. 支持点击查询单元的二维 GGER、三维 GGER、经纬度边界、高度层边界与尺寸信息。
5. 在花果山三维底图、3D Tiles 与 DEM 场景中保持可交互性能。

## 2. 实施范围

### 2.1 第一版范围

- 自动选择 GGER level。
- 当前可视域二维 GGER 网格线实时渲染。
- 按当前 GGER level 的高度层厚度渲染空域柱网线框。
- 支持从基准高度开始向上堆叠多个 GGER 高度单元。
- 当前高度层切片展示。
- 点击单元显示 2D / 3D GGER 编码与边界信息。
- 默认最高自动层级限制到 GGER level 23，避免 level 24-32 在大视域下爆量；更高层级仅允许小视域或手动模式。

### 2.2 暂不纳入第一版

- 服务端网格切片。
- level 24-32 全视域实时渲染。
- 大规模体素实体填充。
- 多用户协同标绘。
- BGC / GGER 双编码并行展示；如有需要，作为后续兼容功能单独实现。

## 3. 总体架构

建议新增或重命名浏览器端模块：

```text
js/GGERGridBounds.js
js/GGERAirspaceGrid.js
```

其中：

- `GGERGridBounds.js`：提供 GGER 二维网格边界、高度层边界、连续堆叠高度层、距离估算等能力。
- `GGERAirspaceGrid.js`：封装 Cesium 空域网格可视化逻辑，避免继续膨胀 `frontend/tianditu-3d.html`。

调用方式示例：

```js
var airspaceGrid = GGERAirspaceGrid.create(state.viewer, {
  anchorHeight: 0,
  stackCount: 3,
  currentHeight: 120,
  defaultLevel: 19,
  maxAutoLevel: 23,
  maxCells: 3000,
  targetCellPixels: 120,
  enabled: false
});
```

模块职责：

1. 监听 Cesium 相机变化。
2. 根据相机高度 / 屏幕分辨率推导 GGER level。
3. 获取当前可视域经纬度矩形。
4. 枚举可视域内 GGER 网格单元。
5. 调用 `GGERGridCode` / `GGERGridBounds` 生成编码、二维边界、GGER 高度层边界与向上堆叠层。
6. 管理 Cesium Polyline / Entity / Primitive 渲染对象生命周期。
7. 提供 UI 需要的状态回调与点击查询能力。

## 4. Zoom Level 到 GGER Level 策略

### 4.1 推荐策略：屏幕像素自适应

每次相机稳定后执行：

1. 获取视图中心点。
2. 根据当前相机高度、视场角和画布尺寸估算 meters-per-pixel。
3. 计算各 GGER level 网格在当前纬度下的近似米制宽高。
4. 选择屏幕上单元宽度接近 `targetCellPixels` 的 GGER level。
5. 加入 hysteresis，避免缩放临界点频繁跳级。
6. 若预计单元数量超过 `maxCells`，自动降低 level。

### 4.2 兜底映射表

GGER 标准 level 范围为 `0-32`；前端可视化手动层级使用 `1-32`，其中 level 0 代表全局根网格，不作为实时视域网格绘制层级。赤道附近常用尺度如下：level 9 约 `1° / 111km`，level 15 约 `1′ / 1.85km`，level 19 约 `4″ / 124m`，level 23 约 `0.25″ / 7.7m`。

当屏幕尺寸估算不可用时，使用相机高度映射：

| Cesium Camera Height | 推荐 GGER Level |
|---:|---:|
| > 3,000 km | 6-8 |
| 500 km - 3,000 km | 9-11 |
| 120 km - 500 km | 12-14 |
| 20 km - 120 km | 15-18 |
| 3 km - 20 km | 19-20 |
| 800 m - 3 km | 21-22 |
| 200 m - 800 m | 23 |
| < 200 m | 24+，默认需手动开启 |

第一版自动模式建议最大只到 level 23。level 24-26 可作为手动模式或小视域实验模式。level 27-32 只建议用于选中单元、剖面分析或离线计算，不建议全视域实时绘制。

## 5. 可视域网格生成方案

### 5.1 输入

- Cesium 当前相机。
- Cesium 当前 view rectangle。
- 当前 GGER level。
- 高度基准：`anchorHeight`，用于确定起始 GGER 高度层。
- 向上堆叠层数：`stackCount`。
- 当前高度：`currentHeight`，用于定位当前 GGER 高度层。
- 单元上限：`maxCells`。

### 5.2 计算流程

1. 使用 `viewer.camera.computeViewRectangle(viewer.scene.globe.ellipsoid)` 获取当前可视域。
2. 将 rectangle 转换为经纬度范围。
3. 对可视域外扩一个网格单元宽度，避免相机轻微移动导致边缘闪烁。
4. 在可视范围内按当前 level 的 GGER 网格步长采样。
5. 对每个采样点调用：

```js
var bounds = GGERGridBounds.getCellBounds(lon, lat, level);
var code2D = GGERGridCode.encode2D(bounds.centerLon, bounds.centerLat, level);
```

6. 使用 `code2D` 去重。
7. 若单元数超过 `maxCells`：
   - 自动降低 GGER level；或
   - 缩小渲染范围到屏幕中心区域；或
   - 显示“当前视域网格过密”的状态提示。

### 5.3 GGER 二维边界计算

GGER / GeoSOT 使用 32 位扩展 DMS 整数索引。`GGERGridBounds.getCellBounds(lon, lat, level)` 应复用 `GGERGridCode.coordinateToIndex()` 的索引规则：

```text
9 bits degree + 6 bits minute + 6 bits second + 11 bits second_fraction
```

边界计算流程：

```text
x = coordinateToIndex(lon)
y = coordinateToIndex(lat)
step = 2 ^ (32 - level)
minX = floor(x / step) * step
maxX = minX + step
minY = floor(y / step) * step
maxY = minY + step
west/east = extendedDmsIndexToLongitude(minX/maxX)
south/north = extendedDmsIndexToLatitude(minY/maxY)
```

返回值建议包含：

```js
{
  west: 119.26,
  south: 34.64,
  east: 119.27,
  north: 34.65,
  centerLon: 119.265,
  centerLat: 34.645,
  widthMeters: 123.4,
  heightMeters: 123.6,
  xRange: { min: "...", maxExclusive: "..." },
  yRange: { min: "...", maxExclusive: "..." }
}
```

注意事项：

- 经纬度输入范围遵循 `GGERGridCode`：longitude `[-180, 180]`，latitude `[-90, 90]`。
- 西经 / 南纬使用 degree 加 256 的扩展编码，边界反算时必须还原符号。
- 由于 GeoSOT 扩展 DMS 中 minute / second 字段为 6 bit，边界反算需要显式处理 60-63 的扩展区间，避免采样跨越无效自然 DMS 段时出现重复或倒序。

### 5.4 高度层生成方案

空域高度不能再使用固定 `0-300m` 范围，而应完全由 GGER 三维高度层号决定。

`GGERGridBounds.getHeightBounds(height, level)` 应复用 `GGERGridCode.heightToLayer(height)`，先把高度转换为 32 位 `z` 层号，再按目标 level 截断得到当前高度所在的 GGER 高度单元：

```js
var heightBounds = GGERGridBounds.getHeightBounds(anchorHeight, level);
```

近地面常用 level 的高度层厚度约为：

| GGER Level | 近地面高度层厚度 | 赤道附近水平尺度 |
|---:|---:|---:|
| 15 | 1,839.6 m | 1,855.3 m |
| 19 | 122.6 m | 123.7 m |
| 20 | 61.3 m | 61.8 m |
| 21 | 30.7 m | 30.9 m |
| 22 | 15.3 m | 15.5 m |
| 23 | 7.66 m | 7.73 m |
| 24 | 3.83 m | 3.87 m |
| 25 | 1.92 m | 1.93 m |
| 26 | 0.958 m | 0.966 m |
| 29 | 0.120 m | 0.121 m |
| 32 | 0.015 m | 0.015 m |

向上堆叠时，不应简单用固定米制步长相加，而应按 GGER 高度层边界逐层推进：

```js
var layers = GGERGridBounds.getStackedHeightBounds(anchorHeight, level, stackCount);
```

建议 API：

```js
GGERGridBounds.getHeightBounds(height, level)
GGERGridBounds.getHeightBoundsByLayer(layer, level)
GGERGridBounds.getStackedHeightBounds(anchorHeight, level, stackCount)
```

其中 `getStackedHeightBounds()` 返回从 `anchorHeight` 所在高度层开始向上的连续 GGER 高度单元数组。

### 5.5 输出数据结构

```js
{
  level: 19,
  code2D: "G001310322230230....",
  bounds: {
    west: 119.26,
    south: 34.64,
    east: 119.261,
    north: 34.641,
    centerLon: 119.2605,
    centerLat: 34.6405,
    widthMeters: 123.4,
    heightMeters: 123.6
  },
  height: {
    anchorHeight: 0,
    stackCount: 3,
    layers: [
      { minHeight: 0, maxHeight: 122.6, heightMeters: 122.6 },
      { minHeight: 122.6, maxHeight: 245.2, heightMeters: 122.6 },
      { minHeight: 245.2, maxHeight: 367.9, heightMeters: 122.7 }
    ],
    currentHeight: 120,
    currentHeightBounds: {}
  }
}
```

## 6. 三维空域分割展示方案

### 6.1 模式 A：当前 GGER 高度层空域柱网

将每个二维 GGER 网格按当前 level 对应的 GGER 高度层拉伸为柱体线框。柱体底面和顶面不再来自人工 `minHeight/maxHeight`，而来自：

```js
var layer = GGERGridBounds.getHeightBounds(anchorHeight, level);
var bottom = layer.minHeight;
var top = layer.maxHeight;
```

渲染内容：

- 当前 GGER 高度层底部网格边线。
- 当前 GGER 高度层顶部网格边线。
- 四角垂直线。
- 诊断面板显示该 level 的真实高度层厚度。

优点：

- 与三维 GGER 编码算法严格一致。
- 不再被 `0-300m` 人工范围限制。
- 同一 level 下水平剖分和垂直剖分同步表达。

### 6.2 模式 B：向上堆叠高度层

在当前 GGER 高度层基础上，支持向上连续堆叠 `stackCount` 个高度层。

示例：

```js
var layers = GGERGridBounds.getStackedHeightBounds(anchorHeight, level, stackCount);
```

渲染内容：

- 每个高度层的顶部水平网格。
- 整体外框垂直线。
- 可选显示每一层内部水平切片线。
- 每层可使用不同透明度或渐变色，越高越淡。

交互建议：

- `anchorHeight`：起始高度，默认 0m 或地形采样高度。
- `stackCount`：向上堆叠层数，默认 3，最大值受性能限制。
- `stackMode`：`single` / `stacked`。

### 6.3 模式 C：当前高度层切片

用户通过滑块选择 `currentHeight`，系统展示该高度所在的 GGER 高度层，而不是仅绘制一张任意高度平面。

调用：

```js
var heightBounds = GGERGridBounds.getHeightBounds(currentHeight, level);
var code3D = GGERGridCode.encode3D(centerLon, centerLat, currentHeight, level);
```

展示内容：

- 当前高度对应 GGER 高度层的上下边界。
- 当前高度层顶部 / 底部切片线。
- 当前高度层编码。

### 6.4 模式 D：选中单元三维体素

默认不渲染所有实体体块。用户点击某个单元后，只对选中单元渲染半透明体素。

展示内容：

- 选中二维网格 + 选中高度层组成的三维体素。
- 选中单元加粗边框。
- 若处于堆叠模式，可高亮当前层，淡化其他堆叠层。
- 右侧面板展示完整 2D / 3D GGER 信息。

## 7. Cesium 渲染实现建议

### 7.1 第一版渲染方式

- 大量网格线：优先使用 `Cesium.PolylineCollection`。
- 选中单元：使用 `viewer.entities.add()` 创建 polygon / polyline。
- 标签：默认关闭，只对选中单元或中心少量单元显示。

### 7.2 网格线样式

建议延续当前页面东方山海风格：

- 普通网格线：青绿色半透明。
- 顶部空域线：金色半透明。
- 当前高度切片：琥珀色。
- 选中单元：朱砂色边框。
- 选中体块：朱砂色低透明度填充。

### 7.3 线段去重

相邻网格共享边界。为降低绘制量，需要对线段去重：

```text
key = round(lon1, precision) + "," + round(lat1, precision) + ":" + round(lon2, precision) + "," + round(lat2, precision) + ":" + height
```

对 key 做端点排序，避免同一条边正反重复。

## 8. 前端 UI 改造

在 `frontend/tianditu-3d.html` 增加或调整图层开关：

```text
GGER 网格
空域柱网
高度切片
网格编码
```

增加参数区：

```text
GGER Level: Auto / 1-32
起始高度 Anchor Height: 0m
堆叠层数 Stack Count: 3
当前高度 Current Height: 120m
最大二维单元数 Max Cells: 3000
```

扩展诊断面板：

```text
GGER Level: 19
Visible Cells: 842
GGER Height Unit: 122.6m
Stacked Height Range: 0.0 - 367.9m
Current Height Layer: 0.0 - 122.6m
Selected 2D GGER: ...
Selected 3D GGER: ...
```

## 9. 性能控制

必须实现：

1. 相机变化防抖：建议 `150ms - 250ms`。
2. 仅在以下条件满足时重算网格：
   - GGER level 变化；
   - view rectangle 移动超过一定比例；
   - 起始高度 / 堆叠层数 / 当前高度变化；
   - 图层开关状态变化。
3. 单元数量限制：默认 `maxCells = 3000`。
4. 网格线段去重。
5. 标签默认关闭。
6. level 24 以上必须手动开启或强制小范围。
7. 堆叠模式下控制三维复杂度：`visibleCells * stackCount` 超过阈值时自动降低 stackCount、降低 level 或提示。
8. stackCount 默认 3，建议最大 10；level 23 以上默认最大 5，避免高度层过密造成视觉噪声。

后续优化：

- Web Worker 计算网格。
- 按 view tile 缓存网格。
- 使用 Primitive 批量几何替代 Entity。
- 使用屏幕空间误差控制显示密度。

## 10. 验证计划

### 10.1 算法验证

使用 `docs/gger-grid-code-algorithm.md` 中的样例：

```js
GGERGridCode.encode2D(116.315222, 39.910278, 15)
// "G001310322230230"

GGERGridCode.encode3D(116.315222, 39.910278, 100, 32)
// "GZ00262064446046062063523002211204"
```

验证边界：

- 网格中心点重新编码后应得到相同 GGER。
- 点击同一单元不同位置应得到相同 GGER。
- 高度层边界满足 `heightBounds.minHeight <= currentHeight < heightBounds.maxHeight`。
- `GGERGridBounds.getHeightBounds()` 的 `z` 层号前缀应与 `GGERGridCode.encode3D()` 同 level 高度码元一致。

### 10.2 可视化验证

在花果山区域进行手工 E2E 验证：

1. 打开页面后默认不影响原有天地图、3D Tiles、DEM 图层。
2. 开启“GGER 网格”后出现当前视域网格。
3. 缩放地图时 GGER level 自动变化且无明显闪烁。
4. 拖拽地图时网格实时更新。
5. 开启“空域柱网”后显示当前 GGER level 对应的真实高度层线框。
6. 调整堆叠层数后，空域柱网可按 GGER 高度层向上连续堆叠。
7. 调整当前高度后，高度切片吸附到对应 GGER 高度层。
8. 点击单元后右侧面板显示 2D / 3D GGER 编码。
9. 大视域下不会卡死，能自动降级或提示。

## 11. 分阶段实施计划

### Phase 1：二维可视域 GGER 网格

交付物：

- `js/GGERGridBounds.js`
- `js/GGERAirspaceGrid.js`（或将 `js/BeidouAirspaceGrid.js` 迁移并重命名）
- `frontend/tianditu-3d.html` 接入 GGER 网格图层开关
- 当前可视域二维网格线渲染
- 自动 GGER level 推导
- 单元点击查询 2D GGER

验收标准：

- 花果山区域可实时显示 GGER 网格。
- 缩放 / 平移后网格正确更新。
- 点击单元可显示二维编码与经纬度边界。
- 北京样例 level 15 输出 `G001310322230230`。

### Phase 2：GGER 高度层空域柱网与向上堆叠

交付物：

- 将现有 `minHeight/maxHeight` 人工范围改为 `anchorHeight + GGER height layer` 模型。
- `GGERGridBounds.js` 新增高度层 API：`getHeightBoundsByLayer(layer, level)` 与 `getStackedHeightBounds(anchorHeight, level, stackCount)`。
- 空域柱网按当前 GGER level 的真实高度层边界渲染。
- 支持 `stackCount` 向上堆叠多个高度单元。
- 当前高度切片吸附到其所在 GGER 高度层。
- 选中单元显示对应高度层的 3D GGER 编码。

验收标准：

- 空域高度不再固定为 `0-300m`。
- level 变化时，高度层厚度同步变化，例如 level 19 约 122.6m、level 23 约 7.66m。
- `stackCount = 1/3/5` 时可看到连续向上的高度层堆叠。
- 当前高度切片随滑块实时更新，并显示吸附后的 GGER 高度层上下边界。
- 选中单元能显示三维 GGER 编码与高度层范围。

### Phase 3：性能与交互优化

交付物：

- 线段去重。
- 视域缓存。
- Hover 高亮。
- Label 密度控制。
- 手动 level 模式。

验收标准：

- `maxCells <= 3000` 时交互流畅。
- 大视域下系统不会卡死。
- 自动 / 手动层级切换稳定。

### Phase 4：测试与文档

交付物：

- 算法测试样例。
- 浏览器手工测试清单。
- 用户说明文档。

验收标准：

- 现有 GGER 编码样例全部通过。
- 页面集成不破坏原有 3D Tiles / DEM / 天地图图层能力。

## 12. 当前状态与下一步最小实现

当前已有：

1. `js/GGERGridCode.js` 已实现 GGER 2D / 3D 编码，并已按 iBEST-DB 样例验证。
2. 前端空域网格入口已切换为 `GGERAirspaceGrid` / `GGERGridBounds`，Live Diagnostics 展示 `GGER Level` 与 GGER 编码。

下一步最小实现聚焦“验证与完善 GGER 可视化”：

1. 使用花果山场景做浏览器 E2E 验证，确认 level 自动选择、平移缩放和点击查询正常。
2. 对 `GGERGridBounds.js` 增加 Node 单元测试，覆盖二维边界、高度层、连续堆叠高度层。
3. 对 level 24-32 增加强制小视域保护与更明确的性能提示。
4. 当前高度切片持续按其所在 GGER 高度层展示，而不是任意高度平面。

完成后，三维空域分割将与 GGER / GeoSOT 的水平 level 和垂直高度 level 保持一致。
