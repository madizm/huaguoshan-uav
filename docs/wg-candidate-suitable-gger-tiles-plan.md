# W/G 候选空域与适飞空域 GGER 3D Tiles 实施计划

## 1. 目标

基于后端权威 DEM、GGER 三维网格和二维适飞基底范围，生成可在 Cesium 中切换展示的多级别 3D Tiles：

- W 候选空域
- G 候选空域
- W 适飞空域
- G 适飞空域
- MIXED 边界网格

点击任意体素时，以 GGER 网格为主语展示编码、层级、候选类别、适飞状态、AGL 高度范围和绝对高度范围。

## 2. 领域语义

### 2.1 空域类别候选区

W/G 候选空域是业务展示和分析候选层，不等同于正式划设的法规边界。

本项目第一版采用互斥语义：

```text
W 候选空域 = [0,120)m AGL
G 候选空域 = [120,300]m AGL
```

候选空域本身不扣除 B/C 等管制空域。

### 2.2 空域适飞基底范围

适飞基底范围来自二维 `MultiPolygon`，只表达水平范围。它已体现 B/C 等排除结果。

### 2.3 空域适飞区

真实适飞空域由候选空域叠加适飞基底范围得到：

```text
W 适飞空域 = W 候选空域 ∩ 适飞基底范围
G 适飞空域 = G 候选空域 ∩ 适飞基底范围
```

适飞叠加采用保守纳入策略：只要 GGER 3D cell 与适飞基底范围相交，就纳入 `suitable` 输出。该策略作为内部生成策略，不在普通前端详情中显式提示。

## 3. 高程与高度基准

- AGL 体素生成以后端权威 DEM 为准。
- 前端 Cesium 地形只用于视觉展示，不作为判定依据。
- 每次生成记录 DEM 元数据：

```text
dem_source
vertical_datum
resolution
generated_at
```

GGER 3D cell 的 bbox 是绝对高度范围；业务详情默认展示 AGL 高度范围，并保留绝对高度范围用于展开详情或调试。

## 4. 多级 GGER 策略

第一版采用固定 level 多套 tileset：

```text
candidate/level-19/tileset.json
candidate/level-20/tileset.json
candidate/level-21/tileset.json
suitable/level-19/tileset.json
suitable/level-20/tileset.json
suitable/level-21/tileset.json
```

后续优化点：生成单个层级 LOD tileset，让 root 使用粗 GGER level，children 使用更细 GGER level，由 Cesium 根据 geometricError 自动加载。

## 5. MIXED 网格规则

由于 GGER 3D 高度层是绝对高度层，而 W/G 边界是 `DEM + 120m` 的 AGL 曲面，部分 cell 可能跨越 W/G 边界。

处理规则：

```text
candidate_class = W / G / MIXED
w_coverage_ratio
g_coverage_ratio
dominant_class
is_mixed
dominant_threshold = 0.8
```

当 W 或 G 覆盖率达到阈值时，归为对应类别；否则归为 MIXED。

`candidate` 和 `suitable` tileset 都允许 MIXED。

前端切换默认显示 MIXED：

```text
W 模式：W + MIXED
G 模式：G + MIXED
```

MIXED 使用独立样式，避免误读为纯 W 或纯 G。

## 6. 3D Tiles 发布结构

发布两类 tileset：

```text
/tiles/airspace/
  candidate/
    level-19/tileset.json
    level-20/tileset.json
    level-21/tileset.json
  suitable/
    level-19/tileset.json
    level-20/tileset.json
    level-21/tileset.json
```

### 6.1 candidate tileset

表达 W/G 候选空域，可单独展示高度候选范围。

### 6.2 suitable tileset

表达叠加适飞基底后的真实适飞空域。`suitable` 中仍必须保留：

```text
candidate_class = W / G / MIXED
agl_range
```

以支持 W 适飞、G 适飞、全部适飞等切换。

## 7. 推荐 cell 属性

```json
{
  "gger_3d_code": "GZ...",
  "gger_2d_code": "G...",
  "level": 20,
  "tileset_kind": "candidate|suitable",
  "candidate_class": "W|G|MIXED",
  "suitability_status": "SUITABLE|NONE",
  "height_datum": "AGL",
  "agl_min": 0,
  "agl_max": 120,
  "bbox_min_lon": 119.1,
  "bbox_min_lat": 34.5,
  "bbox_min_h": 82.0,
  "bbox_max_lon": 119.101,
  "bbox_max_lat": 34.501,
  "bbox_max_h": 143.3,
  "dem_source": "huaguoshan_dem",
  "w_coverage_ratio": 0.92,
  "g_coverage_ratio": 0.08,
  "dominant_class": "W",
  "is_mixed": false
}
```

适飞覆盖率可在数据库中保留用于调试或审计，但普通前端不展示保守纳入策略和覆盖率。

## 8. 生成流程

### 8.1 candidate 生成

```text
选择 GGER level
  ↓
枚举研究范围内 GGER 3D cells
  ↓
使用后端权威 DEM 计算 cell 与 AGL 区间关系
  ↓
计算 W/G 覆盖率
  ↓
标记 W / G / MIXED
  ↓
生成 candidate 3D Tiles
```

### 8.2 suitable 生成

```text
读取 candidate cells
  ↓
与适飞基底 MultiPolygon 做水平相交判断
  ↓
相交即保守纳入
  ↓
保留 candidate_class 和 AGL 高度语义
  ↓
生成 suitable 3D Tiles
```

## 9. 前端交互

### 9.1 图层切换

建议提供：

```text
[ ] W 候选
[ ] G 候选
[ ] W 适飞
[ ] G 适飞
[ ] MIXED
[ ] GGER level 19/20/21
```

默认规则：

```text
W 模式显示 W + MIXED
G 模式显示 G + MIXED
```

### 9.2 点击详情

点击详情以 GGER 网格为主语：

```text
GGER 3D 编码：GZ...
GGER 2D 编码：G...
层级：Level 20
图层类型：candidate / suitable
候选类别：W / G / MIXED
适飞状态：适飞 / 无
高度基准：AGL
AGL 高度范围：[0,120) / [120,300]
绝对高度范围：...
```

不向普通用户显式展示“相交即纳入”策略和适飞覆盖率。

## 10. 当前实现入口

离线导出脚本：

```bash
# Dry-run：统计候选/适飞 cell 数量，不写文件
uv run scripts/export_wg_airspace_3dtiles.py \
  --input data/dem/lianyungang/copernicus-dem-glo30-lianyungang_epsg32650.tif \
  --levels 20 \
  --bounds 119.26,34.64,119.28,34.66

# 写出固定 level 3D Tiles
# 写出固定 level 3D Tiles
# 注意：全市范围 level 20/21 体素量很大，建议先用 --bounds 验证小范围，
# 再按业务片区分批导出；不要直接对全市同时导出 19,20,21。
uv run scripts/export_wg_airspace_3dtiles.py \
  --input data/dem/lianyungang/copernicus-dem-glo30-lianyungang_epsg32650.tif \
  --levels 19,20,21 \
  --suitable-footprint data/shifeikongyu.kml \
  --output exports/airspace/wg_gger \
  --execute

# 只生成候选空域，不生成 suitable
uv run scripts/export_wg_airspace_3dtiles.py \
  --levels 20 \
  --no-suitable-footprint \
  --execute
```

前端入口：`frontend/tianditu-3d.html` 的 `W/G 空域` 图层开关。第一版前端按固定 level 加载：

```text
exports/airspace/wg_gger/candidate/level-{level}/tileset.json
exports/airspace/wg_gger/suitable/level-{level}/tileset.json
```

## 11. 阶段计划

### Phase 1：语义和离线样例

- 固化 W/G 候选互斥规则。
- 准备一份适飞基底 MultiPolygon 样例。
- 用权威 DEM 生成 level 20 candidate 和 suitable 样例。
- 验证 GGER 编码、AGL 范围、MIXED 标记。

### Phase 2：3D Tiles 生成

- 生成 candidate 固定 level tileset。
- 生成 suitable 固定 level tileset。
- 每个 feature 写入 GGER 编码和分类属性。

### Phase 3：Cesium 展示

- 加载 candidate/suitable tileset。
- 支持 W/G/适飞切换。
- 支持 MIXED 默认显示和独立样式。
- 点击展示 GGER 网格详情。

### Phase 4：多级与性能

- 生成 level 19/20/21 多级 tileset。
- 前端按缩放切换固定 level。
- 控制每个 tile 的 cell 数量。
- 评估是否升级为单个层级 LOD tileset。

## 12. 已记录 ADR

- `docs/adr/0006-publish-airspace-gger-tiles-as-fixed-level-first.md`
- `docs/adr/0007-separate-wg-candidate-and-suitable-airspace-layers.md`
