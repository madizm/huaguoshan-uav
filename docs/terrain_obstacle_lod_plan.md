# 地形飞行障碍 LOD / 自适应加载实施方案

## 0. 实施状态

状态：**已实施并验收通过**（2026-07-01）。

已完成：

- 后端 `scripts/refresh_citydb_obstacle_grids.py` 支持 `--terrain-lod-display` 与 `--terrain-lod-spec`。
- 已生成展示专用物化视图 `citydb_grid.obstacles_terrain_lod`。
- 已创建 LOD 视图索引：`(lod_level, source_kind, source_id)` unique、`lod_level`、`footprint_4326` GiST、`grids gin_grids_ops`。
- 已新增并部署 PostgREST RPC：
  - `public.list_flight_obstacles_gger_lod(...)`
  - `citydb.list_flight_obstacles_gger_lod(...)`
- RPC 输出保持 GGER-only，不包含 BGC。
- RPC 支持 bbox 过滤，并支持通过 `p_center_lon` / `p_center_lat` 优先返回视野中央附近地形障碍。
- 前端 `frontend/tianditu-3d.html` 支持 Terrain detail：`Auto LOD / Overview / Medium / Fine`。
- 前端 terrain 来源默认走 LOD RPC，不再走全量 `list_flight_obstacles_gger`。
- 前端按相机高度自动选择 LOD，并在 `camera.moveEnd` 后防抖刷新。
- 已修复低空斜视时使用 `computeViewRectangle()` bbox 中点导致中心点偏移的问题；现在使用屏幕中心 pick ray 优先加载视野中央区域。

实际生成结果：

| LOD | rows | cells |
|---:|---:|---:|
| 0 | 70 | 162 |
| 1 | 247 | 1181 |
| 2 | 3750 | 20778 |

统一规划障碍仍保持精细层：

```text
citydb_grid.obstacles_terrain: 3750 rows
citydb_grid.flight_obstacles: 3768 rows
```

验收结论：前端 Fine 级别视野中央优先加载表现已通过人工验收；规划层未降级。

## 1. 问题背景

当前精细化地形障碍已从 DEM tile 级 bbox 升级为 `block-prism`：

```text
terrain.dem_tile → 4x4 DEM pixel block → local prism → geomgrids
```

当前数据库结果：

```text
citydb_grid.obstacles_terrain: 3750 rows
citydb_grid.flight_obstacles: 3768 rows
```

这对路径规划是合理的：细粒度地形障碍减少误阻塞。但前端如果一次性加载全部 3750 个 terrain 方块，会带来：

1. RPC 响应大。
2. GGER `ST_WithBox` 展开成本高。
3. Cesium 线框 primitive 数量过多。
4. 地图高视角时视觉噪声过强。

如果不加载全部 terrain，又会导致用户无法判断地形障碍的整体分布。

目标：引入类似 grid level 自适应的 LOD 机制，并结合 iBEST-DB geomgrids agg 模式，实现：

- 高空视角：少量粗粒度地形障碍概览。
- 中空视角：当前视域内中粒度障碍。
- 低空/近景：当前视域内精细障碍。
- 路径规划仍使用精细 `public.flight_obstacles(id, grids)`，不因前端 LOD 降低安全性。
- 外部输出继续 GGER-only，不暴露 BGC。

## 2. 核心原则

### 2.1 规划层与展示层分离

不要为了前端性能降低路径规划安全精度。

建议保留现有精细规划层：

```text
citydb_grid.obstacles_terrain      -- 精细地形障碍，供 flight_obstacles union / ST_FindGridsPath 使用
citydb_grid.flight_obstacles       -- 统一规划障碍
public.flight_obstacles(id, grids) -- ST_FindGridsPath 兼容 wrapper
```

新增展示层：

```text
citydb_grid.obstacles_terrain_lod  -- 多层级地形障碍展示物化视图
public.list_flight_obstacles_gger_lod(...) -- 前端自适应查询 RPC
```

展示层可以低精度、聚合、按视域查询；规划层保持精细。

### 2.2 使用 iBEST-DB agg，但不要只依赖 agg

`ST_AsGrids3D(geom, detail_level, true)` 的 agg 模式能将连续子网格聚合，减少单个 geomgrids 的 cell 数。

但当前性能问题有两部分：

1. 每个 terrain block 都是一行，行数多。
2. 每行内部 cell 也可能多。

因此需要两级优化：

| 优化 | 解决问题 |
|---|---|
| LOD grouping / coarser block | 降低行数 |
| iBEST-DB agg=true | 降低每行 cell 数 |

## 3. LOD 设计

建议地形展示层生成 3 个 LOD：

| LOD | 用途 | DEM block size | geomgrids detail | agg | 加载策略 |
|---|---|---:|---:|---|---|
| 0 | 全域概览 | 32x32 pixels | 15 或 16 | true | 可全量加载 |
| 1 | 区域浏览 | 16x16 pixels | 17 | true | 当前视域 + buffer |
| 2 | 近景精细 | 4x4 pixels | 19 | true | 当前视域，小 limit |

当前 DEM 为 300 x 197 pixels：

```text
LOD0 32x32: 约 70 rows
LOD1 16x16: 约 250 rows
LOD2 4x4: 约 3750 rows
```

LOD2 与当前 `obstacles_terrain` 精度相同，但只按视域加载。

## 4. 数据库设计

### 4.1 新增 terrain LOD 物化视图

建议新增：

```sql
citydb_grid.obstacles_terrain_lod
```

字段建议：

```sql
source_kind      text,      -- terrain
source_id        text,      -- dataset:tile:lod:block_x:block_y
source_name      text,
lod_level        integer,   -- 0 / 1 / 2
block_size_px    integer,
dimension        smallint,
detail_level     integer,
is_agg           boolean,
grids            geomgrids,
footprint_4326   geometry(Polygon, 4326),
min_height       double precision,
max_height       double precision,
cell_count       integer,
generated_at     timestamptz
```

注意：

- 该视图是展示专用，不进入 `citydb_grid.flight_obstacles`。
- `footprint_4326` 用于 RPC bbox 过滤。
- `grids` 仍用 GIN 索引支持 geomgrids 查询。
- RPC 输出 GGER 与 `ST_WithBox`，不输出 BGC。

### 4.2 索引

```sql
create unique index obstacles_terrain_lod_uidx
on citydb_grid.obstacles_terrain_lod (lod_level, source_kind, source_id);

create index obstacles_terrain_lod_lod_idx
on citydb_grid.obstacles_terrain_lod (lod_level);

create index obstacles_terrain_lod_footprint_gix
on citydb_grid.obstacles_terrain_lod using gist (footprint_4326);

create index obstacles_terrain_lod_grids_gin_idx
on citydb_grid.obstacles_terrain_lod using gin (grids gin_grids_ops);
```

## 5. LOD 生成逻辑

### 5.1 SQL 生成思路

用 `ST_PixelAsPolygons` 展开 DEM 像元，然后按 LOD block size 分组：

```text
block_x = floor((pixel_x - 1) / block_size_px)
block_y = floor((pixel_y - 1) / block_size_px)
```

每个 block：

```text
footprint = ST_Envelope(ST_Collect(pixel_geom))
min_z = min(pixel_elevation) - underground_tolerance
max_z = max(pixel_elevation) + terrain_clearance
```

生成 geomgrids：

```sql
ST_AsGrids3D(
  ST_Transform(citydb_grid.make_bbox_prism_3d(footprint, min_z, max_z), 4326),
  lod_detail_level,
  true -- agg
)
```

### 5.2 默认 LOD 参数

建议脚本参数：

```bash
--terrain-lod-display
--terrain-lod-spec 0:32:15,1:16:17,2:4:19
```

含义：

```text
lod_level:block_size_pixels:detail_level
```

默认：

```text
0:32:15,1:16:17,2:4:19
```

可选：如果后续 DEM 分辨率更高，可使用：

```text
0:64:15,1:32:17,2:8:19,3:2:21
```

## 6. RPC 设计

### 6.1 新增 LOD 查询 RPC

建议新增：

```sql
public.list_flight_obstacles_gger_lod(
  p_source_kind text default 'terrain',
  p_lod_level integer default null,
  p_west double precision default null,
  p_south double precision default null,
  p_east double precision default null,
  p_north double precision default null,
  p_limit integer default 1000,
  p_include_boxes boolean default true
) returns jsonb
```

对于 terrain：

```sql
from citydb_grid.obstacles_terrain_lod
where source_kind = 'terrain'
  and (p_lod_level is null or lod_level = p_lod_level)
  and (
    bbox 参数为空
    or footprint_4326 && ST_MakeEnvelope(p_west, p_south, p_east, p_north, 4326)
  )
order by lod_level, source_id
limit p_limit
```

返回字段：

```json
{
  "source_kind": "terrain",
  "source_id": "...",
  "source_name": "...",
  "lod_level": 1,
  "block_size_px": 16,
  "detail_level": 17,
  "cell_count": 123,
  "min_height": 12.3,
  "max_height": 180.4,
  "gger_grids": "...",
  "gger_grids_with_box": "..."
}
```

### 6.2 保留现有 RPC

现有：

```sql
public.list_flight_obstacles_gger(...)
```

继续用于：

- building
- no_fly_zone
- temp_control
- 少量 terrain 调试

前端 terrain 默认改用 LOD RPC。

## 7. 前端自适应策略

### 7.1 相机高度到 LOD 映射

建议初始规则：

| Camera height | LOD | 查询范围 |
|---:|---:|---|
| > 8000m | 0 | 全域或大 bbox |
| 2000m - 8000m | 1 | 当前视域 bbox + 20% buffer |
| < 2000m | 2 | 当前视域 bbox + 10% buffer |

可配置：

```js
const TERRAIN_LOD_RULES = [
  { minHeight: 8000, lod: 0, limit: 200, bboxBuffer: 0.50 },
  { minHeight: 2000, lod: 1, limit: 500, bboxBuffer: 0.25 },
  { minHeight: 0, lod: 2, limit: 800, bboxBuffer: 0.15 }
];
```

### 7.2 加载触发

避免每帧请求。

触发点：

- terrain source filter 从 off → on。
- 相机 `moveEnd`。
- LOD level 变化。
- bbox 超出已缓存 bbox 的 60%。
- 用户点击“刷新障碍”。

防抖：

```text
300ms - 500ms
```

### 7.3 缓存键

```text
terrain:${lod}:${bboxTileKey}:${limit}
```

bboxTileKey 可用 coarse lon/lat 网格量化，例如：

```text
floor(west * 100), floor(south * 100), floor(east * 100), floor(north * 100)
```

### 7.4 渲染策略

高空 LOD0：

- 使用半透明填充或粗线框。
- 按 `max_height` 或 `cell_count` 设置颜色强度。

中空 LOD1：

- 使用线框 box。
- 颜色仍为 terrain 绿色，但透明度随高度增强。

低空 LOD2：

- 使用当前 Cesium `PolylineCollection` bbox 线框。
- 限制最大 primitive/cell budget。

建议预算：

```text
maxTerrainRowsRendered = 800
maxTerrainBoxesRendered = 5000
```

如果超过预算：

1. 优先显示离相机中心近的 block。
2. UI 显示“已按视域/预算裁剪”。
3. 提供“提高限制”按钮，但默认不全量。

## 8. UI 调整

当前 terrain 默认关闭是合理的。启用 LOD 后可改为：

- terrain source filter 默认仍可关闭，避免初次加载。
- 用户开启 terrain 后，默认加载 LOD0 概览。
- 面板显示：

```text
地形障碍：LOD1 · 已加载 236 / 限制 500 · agg=true · detail=17
```

增加可选控件：

```text
Terrain detail: Auto / Overview / Medium / Fine
```

默认 `Auto`。

## 9. 与 iBEST-DB agg 的结合方式

### 9.1 生成层面

所有展示 LOD 默认使用：

```sql
ST_AsGrids3D(..., detail_level, true)
```

其中 `true` 表示启用 geomgrids aggregation。

### 9.2 detail level 策略

不建议前端完全依赖 `--auto-detail-level`，因为视觉 LOD 需要稳定可预测。

建议：

- 展示层使用固定 detail：15 / 17 / 19。
- 规划层继续使用当前 detail 19 或按未来安全策略调整。
- `--auto-detail-level` 保留给离线试验。

### 9.3 聚合边界

agg 能合并 cell，但如果每行只有一个小 block，跨行不会合并。因此 LOD0/LOD1 必须先用更大的 DEM block grouping 降低行数，再使用 agg 降低 cell 数。

## 10. 实施步骤

### 阶段 1：后端 LOD 物化视图

1. 扩展 `scripts/refresh_citydb_obstacle_grids.py`：
   - 新增 `--terrain-lod-display`。
   - 新增 `--terrain-lod-spec`。
   - 新建 `citydb_grid.obstacles_terrain_lod`。
2. 为 LOD view 建索引：
   - unique `(lod_level, source_kind, source_id)`
   - gist `footprint_4326`
   - gin `grids gin_grids_ops`
3. 刷新后打印每个 LOD 的 row_count / cell_count。

### 阶段 2：LOD RPC

1. 新增 SQL 文件：

```text
backend/create_flight_obstacles_lod_rpc.sql
```

2. 创建：

```sql
public.list_flight_obstacles_gger_lod(...)
citydb.list_flight_obstacles_gger_lod(...)
```

3. 授权 `web_anon`。
4. `notify pgrst, 'reload schema'`。

### 阶段 3：前端自适应加载

1. 新增 terrain LOD 状态：

```js
state.flightObstacles.terrainLod = {
  mode: 'auto',
  currentLod: null,
  cache: {},
  loadedBbox: null,
  loading: false
};
```

2. terrain source filter 开启时，不走全量 `list_flight_obstacles_gger`。
3. 增加 `requestTerrainObstaclesLod()`。
4. 监听 Cesium camera moveEnd。
5. 根据 camera height 和 bbox 选择 LOD。
6. 更新面板摘要和状态提示。

### 阶段 4：体验与性能验收

1. 高空开启 terrain：加载 LOD0，前端不卡顿。
2. 缩放到中空：自动切换 LOD1。
3. 低空接近地形：自动切换 LOD2，只加载视域内 block。
4. 切换/移动过程中无明显闪烁。
5. RPC 响应不包含 BGC。

## 11. 验收标准

| # | 验收项 | 预期 |
|---|---|---|
| L1 | LOD0 row count 明显小于 3750 | 约几十行 |
| L2 | LOD1 row count 小于 LOD2 | 约几百行 |
| L3 | LOD2 与规划层精度一致或接近 | 视域内 4x4 block |
| L4 | 前端 terrain 高空加载不卡顿 | 首次 terrain 可视化 < 1s-2s |
| L5 | 相机缩放自动切换 LOD | 状态面板显示当前 LOD |
| L6 | bbox 过滤生效 | 低空只返回当前视域附近 terrain |
| L7 | GGER-only | RPC 响应不含 BGC |
| L8 | 规划安全不降级 | `public.flight_obstacles` 仍使用精细 terrain |

## 12. 风险与注意事项

| 风险 | 影响 | 应对 |
|---|---|---|
| LOD0 过粗导致视觉误判 | 用户以为障碍覆盖过大 | UI 明确显示“概览 LOD”，缩放后自动细化 |
| 低空频繁请求 | 网络/数据库压力 | moveEnd + debounce + bbox cache |
| GGER box 数量仍大 | Cesium 卡顿 | 行数和 box 双预算，超过时裁剪 |
| 规划/展示数据不一致 | 用户疑惑 | 面板区分“规划精度”和“展示 LOD” |
| DEM 30m 精度限制 | 低空仍不够精细 | 后续接 DSM/LiDAR/航测 |

## 13. 推荐默认策略

第一版推荐：

```text
规划层：
  citydb_grid.obstacles_terrain = block-prism, 4x4 pixels, detail 19, agg=true

展示层：
  LOD0 = 32x32 pixels, detail 15, agg=true, 可全量
  LOD1 = 16x16 pixels, detail 17, agg=true, 视域加载
  LOD2 = 4x4 pixels, detail 19, agg=true, 视域加载

前端：
  terrain 默认关闭
  开启后 Auto LOD
  高空 LOD0，中空 LOD1，低空 LOD2
```

该方案能同时满足：

- 路径规划安全精细。
- 前端高空有整体判断。
- 低空能查看细节。
- 不需要暴露 BGC。
