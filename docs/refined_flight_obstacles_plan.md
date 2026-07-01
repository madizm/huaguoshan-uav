# 精细飞行障碍 geomgrids 避障实施方案

## 1. 背景、文档分工与目标

`docs/multi_source_flight_obstacles_plan.md` 维护多源飞行障碍的**整体架构、统一字段契约、刷新入口和当前数据库状态**。

本文专门维护精细避障的**算法设计、计算公式、实现模式、验证方法和后续路线**，避免两份文档重复记录同一套状态。

当前状态：

- 建筑：直接使用 3DCityDB 3D geometry 生成 `ST_AsGrids3D`，无需 bbox 替代。
- 地形：已从 DEM tile 级 bbox 回退模式升级出 `block-prism` 精细模式。
- 禁飞区 / 临时管制区：已从 envelope bbox 回退模式升级出 `polygon-prism` 精确 footprint 挤出模式。

本方案目标是在保持现有对外契约不变的前提下，持续提高地形、禁飞区、临时管制区的占用体精度：

```text
精确 polygon / DEM cell / mesh slice
        ↓
3D occupied volume / grid cell candidates
        ↓
geomgrids
        ↓
citydb_grid.obstacles_*
        ↓
citydb_grid.flight_obstacles
```

约束：

1. 不修改 3DCityDB 标准表结构。
2. `citydb_grid.flight_obstacles` 统一字段契约保持不变。
3. `public.flight_obstacles(id, grids)` 继续兼容 `ST_FindGridsPath`。
4. 前端与 RPC 继续 GGER-only，不输出 BGC。
5. 第一阶段优先提高 XY 精度，第二阶段再提高 Z / terrain 精度。

## 2. 总体策略

精细化分三类处理：

| 来源 | 当前问题 | 精细化策略 |
|---|---|---|
| 禁飞区 | polygon 被 envelope 放大 | 按 polygon 本体生成 3D 占用体或先 2D 网格裁剪再补高度层 |
| 临时管制区 | 同禁飞区，且有时间窗口 | 同禁飞区，并保留 active materialized view |
| 地形 | DEM tile 级 bbox 过粗，整 tile 的 max_z 抬高所有位置 | 按 DEM cell / 分块 mesh / height band 生成局部 3D 占用 |

推荐路线：

1. **Phase A：精确 airspace polygon**
   - 禁飞区、临时管制区从 envelope bbox prism 升级为 polygon footprint 占用。
   - 这是收益最高、风险最低的改造。

2. **Phase B：DEM cell/block 地形障碍**
   - 将 DEM tile 切成可控大小的 block/cell。
   - 每个 block 用局部 min/max elevation + clearance 生成占用。
   - 避免整 tile 一个超大 prism。

3. **Phase C：height grid / clearance grid**
   - 预计算通行性表，供路径规划直接查询。
   - 将建筑、地形、airspace 合并成飞行高度层占用网格。

4. **Phase D：mesh slicing / exact volume**
   - 在需要更高精度时，引入 DEM mesh/TIN 或 DSM/LiDAR 数据。
   - 按高度切片生成更精细 geomgrids。

## 3. 数据库设计边界

### 3.1 输出契约

精细化实现不改变多源障碍统一字段契约。所有 `citydb_grid.obstacles_*` 物化视图仍输出 `source_kind/source_id/source_name/dimension/detail_level/is_agg/grids/valid_from/valid_to/priority/generated_at`。

完整契约以 `docs/multi_source_flight_obstacles_plan.md` 为准；本文只描述各来源如何把业务 geometry / DEM 转换为 `grids geomgrids`。

### 3.2 当前实现：直接在物化视图内生成

第一阶段没有新增持久化 `obstacle_work` staging 表，而是在 `scripts/refresh_citydb_obstacle_grids.py` 生成物化视图 SQL 时直接完成：

- airspace polygon → `make_polygon_prism_3d(...)` / `make_bbox_prism_3d(...)` → `ST_AsGrids3D(...)`
- DEM raster pixels → block aggregate → `make_bbox_prism_3d(...)` → `ST_AsGrids3D(...)`

这样可以减少迁移面，并保持现有刷新流程简单。

### 3.3 后续可选 staging schema

如后续需要审计中间结果、复用 terrain block、做增量刷新或分析局部误差，可再引入可重建的派生 schema：

```sql
create schema if not exists obstacle_work;
```

建议表：

```sql
create table if not exists obstacle_work.airspace_volume_piece (
  id bigserial primary key,
  source_kind text not null,
  source_id text not null,
  source_name text,
  piece_id integer not null,
  geom geometry not null,
  min_height double precision not null,
  max_height double precision not null,
  valid_from timestamptz,
  valid_to timestamptz,
  priority integer not null,
  generated_at timestamptz not null default now(),
  unique (source_kind, source_id, piece_id)
);

create table if not exists obstacle_work.terrain_block (
  id bigserial primary key,
  dataset_key text not null,
  tile_id text not null,
  block_id text not null,
  geom geometry(Polygon, 32650) not null,
  min_elevation double precision not null,
  max_elevation double precision not null,
  mean_elevation double precision,
  clearance_m double precision not null,
  generated_at timestamptz not null default now(),
  unique (dataset_key, tile_id, block_id)
);
```

`obstacle_work.*` 应视为可删除、可重建的派生数据，不是业务主数据。

## 4. Airspace polygon 精细化方案

Airspace 来源包括：

- `airspace.no_fly_zone` → `citydb_grid.obstacles_no_fly_zones`
- `airspace.temp_control_zone` → `citydb_grid.obstacles_temp_control_active`

两类来源共用同一套占用体生成逻辑。临时管制区额外按 `valid_from/valid_to/status` 过滤当前 active 窗口。

### 4.1 已实现模式：`polygon-prism`

当前精细模式新增 helper：

```sql
citydb_grid.make_polygon_prism_3d(
  p_footprint geometry,
  p_min_z double precision,
  p_max_z double precision
) returns geometry
```

实现要点：

1. `ST_Force2D(p_footprint)` 去除旧 Z。
2. `ST_MakeValid(...)` 修复无效 polygon。
3. `ST_CollectionExtract(..., 3)` 只保留 polygon/multipolygon 面要素。
4. `ST_Force3DZ(clean_footprint, min_z)` 给底面赋 Z。
5. `ST_Extrude(..., 0, 0, max_z - min_z)` 沿 Z 方向挤出。
6. 如果 `min_z = max_z`，自动给 `0.01m` 最小厚度。

物化视图中最终网格化：

```sql
ST_AsGrids3D(
  ST_Transform(citydb_grid.make_polygon_prism_3d(footprint, min_z, max_z), 4326),
  :detail_level,
  :is_agg
)
```

相比 `bbox` 模式，`polygon-prism` 使用 polygon 本体 footprint，不会把 L 形、凹多边形等缺口整体填成 envelope。

### 4.2 回退模式：`bbox`

`bbox` 模式继续保留，用于兼容和快速回退：

```sql
citydb_grid.make_bbox_prism_3d(footprint, min_z, max_z)
```

它对 `ST_Envelope(ST_Force2D(footprint))` 生成 3D bbox prism，计算简单但会扩大 XY 占用范围。

### 4.3 高度与安全缓冲

Airspace 预处理逻辑：

```text
footprint = ST_Buffer(geom::geography, safety_buffer_m)::geometry  -- safety_buffer_m > 0
footprint = geom                                                  -- safety_buffer_m <= 0
min_z     = coalesce(min_height, 0)
max_z     = coalesce(max_height, default_zone_max_height)
```

禁飞区输出：

```text
source_kind = 'no_fly_zone'
source_id   = no_fly_zone.id::text
priority    = 1000
valid_from  = null
valid_to    = null
```

临时管制区输出：

```text
source_kind = 'temp_control'
source_id   = temp_control_zone.id::text
priority    = 1100
valid_from  = temp_control_zone.valid_from
valid_to    = temp_control_zone.valid_to
```

active 筛选：

```sql
status in ('planned', 'active')
and planning_time >= valid_from
and planning_time < valid_to
```

### 4.4 后续增强：分片与 grid-stack

后续如遇大型/复杂 polygon，可增加：

- `ST_Subdivide(geom, max_vertices)` 分片，避免单个复杂 volume 过大。
- `grid-stack` 模式：先生成精确 2D footprint grids，再按垂直高度层组合为 3D grids。

`grid-stack` 对复杂 polyhedral surface 更稳健，但需要确认 iBEST-DB 是否提供从 2D cell + height layer 构造 3D `gridcell` / `geomgrids` 的函数。

## 5. 地形精细化方案

地形来源：

```sql
terrain.dem_dataset
terrain.dem_tile
```

输出物化视图：

```sql
citydb_grid.obstacles_terrain
```

公共输出：

```text
source_kind   = 'terrain'
dimension     = 3
is_agg        = :is_agg
detail_level  = ST_DetailLevel(grids)
priority      = 50
valid_from    = null
valid_to      = null
generated_at  = now()
```

### 5.1 已实现精细模式：`block-prism`

`block-prism` 将 DEM raster 拆为像元 polygon，再按 `terrain_block_size_pixels` 聚合成局部 block。当前推荐/已验证参数：

```text
terrain_block_size_pixels = 4
terrain_clearance_m = 30
underground_tolerance_m = 0
```

在 30m DEM 下，4x4 像元约等于 120m x 120m 的地面块。

计算流程：

```sql
ST_PixelAsPolygons(dem_tile.rast, 1, true)
```

像元分组键：

```text
block_x = floor((pixel_x - 1) / terrain_block_size_pixels)
block_y = floor((pixel_y - 1) / terrain_block_size_pixels)
```

每个 block 生成一个局部地形 prism：

```text
footprint = ST_Envelope(ST_Collect(pixel_geom))
min_z     = min(pixel_elevation) - underground_tolerance_m
max_z     = max(pixel_elevation) + terrain_clearance_m
volume    = citydb_grid.make_bbox_prism_3d(footprint, min_z, max_z)
grids     = ST_AsGrids3D(ST_Transform(volume, 4326), detail_level, is_agg)
```

记录标识：

```text
source_id   = dataset_key || ':' || dem_tile.id || ':block:' || block_x || ':' || block_y
source_name = dataset_key || ':' || coalesce(dem_tile.tile_id, dem_tile.id) || ':block:' || block_x || ':' || block_y
```

收益：

- 平地 block 不再被同一 DEM tile 内的山顶 max elevation 抬高。
- 相比 tile 级 bbox，局部高度约束更接近真实地形。
- 与现有 `public.flight_obstacles(id, grids)` 兼容。

代价：

- `citydb_grid.obstacles_terrain` 行数从 tile 数增加到 block 数。
- 前端不应默认全量打开 terrain；应继续限制行数，后续增加按视域加载。

### 5.2 回退模式：`tile-bbox`

`tile-bbox` 每条 `terrain.dem_tile` 生成一条地形障碍：

```text
footprint = terrain.dem_tile.extent
min_z     = terrain.dem_tile.min_elevation - underground_tolerance_m
max_z     = terrain.dem_tile.max_elevation + terrain_clearance_m
volume    = citydb_grid.make_bbox_prism_3d(footprint, min_z, max_z)
grids     = ST_AsGrids3D(ST_Transform(volume, 4326), detail_level, is_agg)
```

记录标识：

```text
source_id   = dataset_key || ':' || dem_tile.id
source_name = dataset_key || ':' || coalesce(dem_tile.tile_id, dem_tile.id)
```

该模式计算最快，但一个 tile 内所有位置共享 tile 级 `min/max_elevation`，会保守扩大高度占用。

### 5.3 后续模式：`cell-prism`

如果 block 级仍过粗，可按 DEM 像元生成：

```text
one raster pixel → one terrain prism
footprint = pixel polygon
min_z = elevation - tolerance
max_z = elevation + clearance
```

适用场景：

- 小范围低空路径规划。
- DEM/DSM 分辨率较高且项目范围较小。

风险：

- 行数和 geomgrids cell 数显著增加。
- `ST_AsGrids3D` 对大量小 geometry 的计算成本高。
- 前端必须按视域加载。

### 5.4 后续模式：terrain height bands / clearance grid

路径规划更理想的表达是：

```text
cell below terrain_z + clearance is occupied
cell above terrain_z + clearance is free/unknown
```

后续可预生成：

```sql
terrain.clearance_grid
```

建议字段：

```sql
create table if not exists terrain.clearance_grid (
  id bigserial primary key,
  dataset_key text not null,
  horizontal_code text not null,
  vertical_band integer not null,
  min_height double precision not null,
  max_height double precision not null,
  status text not null, -- occupied / free / unknown
  source_kind text not null default 'terrain',
  source_ref text,
  generated_at timestamptz not null default now(),
  unique (dataset_key, horizontal_code, vertical_band)
);
```

`citydb_grid.obstacles_terrain` 继续作为 `ST_FindGridsPath` 兼容层，`terrain.clearance_grid` 可作为未来路径规划主输入。

## 6. 建筑精细化补充

建筑当前已使用 CityDB 3D geometry 直接 `ST_AsGrids3D`，无需 bbox 替代。

后续可补充：

1. 建筑安全 buffer：
   - 水平 buffer：例如 2m / 5m。
   - 垂直 buffer：roof_z + rotor_clearance。
2. 坡地建筑多 base_z：
   - 对大坡度建筑，单一 base_z 可能不足。
   - 可按 footprint 分片或使用 terrain-aware base surface。
3. LoD2/roof shape：
   - 若未来导入 LoD2，直接使用更精细 roof geometry。

## 7. 脚本实现状态与参数

实施脚本：

```bash
scripts/refresh_citydb_obstacle_grids.py
```

第一阶段已实现参数：

```bash
--airspace-mode bbox|polygon-prism
--terrain-mode tile-bbox|block-prism
--terrain-block-size-pixels 4
--terrain-clearance-m 30
--underground-tolerance-m 0
```

当前推荐执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

保留回退执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode bbox \
  --terrain-mode tile-bbox \
  --grant-role web_anon
```

尚未实现、后续可增加：

```bash
--airspace-mode grid-stack
--airspace-subdivide-vertices 128
--terrain-mode cell-prism|height-band
--rebuild-staging
--skip-staging
```

当前脚本仍直接生成物化视图，不创建持久化 `obstacle_work` staging 表。

## 8. 前端展示策略

前端已经支持按 `source_kind` 过滤和 GGER bbox 线框渲染。精细化后需要注意：

1. 地形障碍数量会显著增加，默认仍不自动开启 `terrain`。
2. `list_flight_obstacles_gger` 应继续限制 `p_limit <= 1000`。
3. 地形建议增加按视域 bbox 查询的 RPC：

```sql
list_flight_obstacles_gger_in_bbox(
  p_west double precision,
  p_south double precision,
  p_east double precision,
  p_north double precision,
  p_source_kind text default null,
  p_limit integer default 1000
)
```

4. 前端加载策略：
   - 禁飞区 / 临时管制区：可全量加载。
   - 建筑：按需加载或限制数量。
   - 地形：只按当前视域加载。

## 9. 性能与索引

### 9.1 必备索引

```sql
create unique index ... on citydb_grid.obstacles_* (source_kind, source_id);
create index ... on citydb_grid.obstacles_* (source_kind);
create index ... on citydb_grid.obstacles_* using gin (grids gin_grids_ops);
```

staging 表：

```sql
create index ... on obstacle_work.terrain_block using gist (geom);
create index ... on obstacle_work.airspace_volume_piece using gist (geom);
```

### 9.2 数据量控制

| 模式 | 精度 | 数据量 | 默认建议 |
|---|---|---|---|
| tile-bbox | 低 | 最少 | 仅用于回退 |
| block-prism 4x4 | 中 | 中等 | 推荐默认 |
| block-prism 2x2 | 高 | 较大 | 小范围使用 |
| cell-prism | 最高 | 最大 | 离线/局部使用 |
| height-band | 路径规划友好 | 可控 | 中长期目标 |

### 9.3 并发刷新

保持每个源视图有唯一索引后，可支持：

```sql
refresh materialized view concurrently citydb_grid.obstacles_terrain;
refresh materialized view concurrently citydb_grid.flight_obstacles;
```

对于 staging rebuild，建议：

1. 写入 temp table。
2. 创建索引。
3. transaction 内 rename/swap。
4. refresh dependent materialized views。

## 10. 验收标准

### 10.1 Airspace 精度验收

| # | 验收项 | 预期 |
|---|---|---|
| A1 | 非矩形禁飞区不再按 envelope 整体占用 | polygon 外明显空白区域不生成障碍 grid |
| A2 | MultiPolygon 可拆分生成 | 每个 piece 有唯一 source_id |
| A3 | safety_buffer_m 生效 | buffer 后占用范围变大且可解释 |
| A4 | min_height/max_height 生效 | ST_WithBox 高度范围符合输入 |
| A5 | 临时管制区时间窗口生效 | 过期/取消不进入 active 视图 |

### 10.2 Terrain 精度验收

| # | 验收项 | 预期 |
|---|---|---|
| T1 | tile-bbox 可回退 | 参数切换后仍可生成当前结果 |
| T2 | block-prism 行数 > tile 数 | 一个 DEM tile 被拆成多个 terrain blocks |
| T3 | 局部 max_z 不再使用整 tile max_z | 平地区域 max_z 明显低于山顶区域 |
| T4 | terrain_clearance_m 生效 | max_z = local max elevation + clearance |
| T5 | GIN 查询可用 | `grids` 上 `&& / @> / <@` 可走 `gin_grids_ops` |

### 10.3 路径规划验收

| # | 验收项 | 预期 |
|---|---|---|
| P1 | `public.flight_obstacles(id, grids)` 可用 | `ST_FindGridsPath` 能读取统一障碍表 |
| P2 | 精细模式减少误阻塞 | 与 bbox 模式相比，非障碍空白区域可通行 |
| P3 | 高度层正确 | 高于 terrain + clearance 的路线不被地形阻塞 |
| P4 | GGER-only | RPC / 前端仍不输出 BGC |

## 11. 测试方案

### 11.1 单元 SQL 测试

构造一个 L 形禁飞区：

```sql
insert into airspace.no_fly_zone (...)
values ('L-shape test', ST_Multi(ST_GeomFromText('POLYGON((...))', 4326)), 0, 120, 0);
```

比较：

```text
bbox mode cell_count
polygon-prism/grid-stack mode cell_count
```

预期：精细模式 cell_count 更少，且不覆盖 L 形缺口。

### 11.2 DEM block 测试

当前第一阶段没有持久化 `obstacle_work.terrain_block`，可直接检查 `citydb_grid.obstacles_terrain`：

```sql
select count(*)
from citydb_grid.obstacles_terrain
where source_id like '%:block:%';
```

预期：行数大于 DEM tile 数。当前数据库为 3750 条 terrain block 障碍。

也可通过 RPC 抽样检查 `ST_WithBox` 输出，确认不同 block 的高度范围不再统一使用整 tile 的最大高程。

### 11.3 E2E 测试

1. 执行刷新脚本：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

2. 打开前端：

```text
frontend/tianditu-3d.html
```

3. 验证：
   - 禁飞区边界不再显示为完整 bbox。
   - 地形开启后不再一个 DEM tile 全域统一高盒。
   - RPC 返回仍为 GGER-only。

## 12. 风险与决策点

| 风险 | 影响 | 应对 |
|---|---|---|
| iBEST-DB 对复杂 PolyhedralSurface 支持不稳定 | airspace prism 生成失败 | 使用 grid-stack 路线 |
| DEM cell-prism 数据量过大 | 刷新慢、前端卡顿 | 默认 block-prism，地形按视域加载 |
| 30m DEM 本身精度有限 | 低空避障仍不够精细 | 引入 DSM/LiDAR/航测模型 |
| 高程基准混用 | 路径高度判断错误 | 继续使用 `docs/terrain_vertical_datum.md` 约束 |
| `ST_FindGridsPath` 仅接受表名字段名 | 难以按时间/视域动态过滤 | 维护 active materialized view 或临时障碍表 |

## 13. 实施路线

### 13.1 已完成

1. 实现 `--airspace-mode polygon-prism`。
2. 将 no-fly-zone 与 temp-control 复用同一 airspace pipeline。
3. 对 L 形 polygon 做 bbox vs polygon-prism 精度对比。
4. 实现 `--terrain-mode block-prism --terrain-block-size-pixels 4`。
5. 重建 `citydb_grid.obstacles_terrain` 与 `citydb_grid.flight_obstacles`。
6. 验证 RPC 与展示输出仍为 GGER-only。

### 13.2 下一步

1. 为 terrain 增加按当前视域 bbox 查询的 RPC，避免前端一次加载全部 terrain blocks。
2. 对实际 no-fly-zone / temp-control 业务数据做 polygon-prism E2E 验收。
3. 评估是否需要 `obstacle_work` staging 表以支持审计与增量刷新。
4. 评估是否需要 `terrain.clearance_grid` 作为路径规划主输入。
5. 如引入更高精度 DSM/LiDAR，再评估 `cell-prism` 或 mesh slicing。

## 14. 第一阶段完成定义与达成情况

第一阶段目标与当前达成情况：

| 目标 | 当前状态 |
|---|---|
| 禁飞区 / 临时管制区支持非 envelope bbox 模式 | 已实现 `polygon-prism`，保留 `bbox` 回退 |
| airspace polygon 凹形缺口不被完整 bbox 误占用 | 已通过 L 形 polygon 对比测试验证 |
| 地形支持 block-prism 模式 | 已实现，当前数据库使用 4x4 DEM 像元块 |
| `citydb_grid.flight_obstacles` 字段契约不变 | 已保持不变 |
| 前端和 RPC 无 schema-breaking 变更 | 已保持兼容 |
| `public.flight_obstacles(id, grids)` 继续可用于 `ST_FindGridsPath` | 已保持兼容 |


## 15. 实施状态

状态：**第一阶段已实施并在当前数据库验证通过**。

已在 `scripts/refresh_citydb_obstacle_grids.py` 中新增：

- `--airspace-mode bbox|polygon-prism`
- `--terrain-mode tile-bbox|block-prism`
- `--terrain-block-size-pixels`
- `citydb_grid.make_polygon_prism_3d(...)` helper，基于 `ST_MakeValid` / `ST_CollectionExtract` / `ST_Extrude` 将 polygon footprint 精确挤出为 3D 占用体。
- DEM block-prism 生成逻辑，基于 `ST_PixelAsPolygons` 按像元块计算局部 `min_elevation` / `max_elevation`。

当前刷新命令：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

当前数据库结果：

```text
citydb_grid.obstacles_buildings: 18 rows
citydb_grid.obstacles_terrain: 3750 rows
citydb_grid.obstacles_no_fly_zones: 0 rows
citydb_grid.obstacles_temp_control_active: 0 rows
citydb_grid.flight_obstacles: 3768 rows
```

验证结果：

- L 形 polygon 测试：`polygon-prism` 为 96 cells，`bbox` 为 121 cells，证明凹形缺口不会被完整 bbox 占用。
- `public.flight_obstacles(id, grids)` wrapper 可查询，保持 `ST_FindGridsPath` 兼容。
- `list_flight_obstacles_gger` RPC 可查询 terrain 精细障碍，且响应不包含 BGC。
- `citydb_grid.obstacles_terrain` 已重建唯一索引、`source_kind` 索引和 `grids gin_grids_ops` GIN 索引。

与原方案的差异：

- 第一阶段未新增持久化 `obstacle_work` staging 表；当前采用物化视图内直接生成方式，减少迁移面并保持现有刷新流程简单。若后续需要审计、分块复用或增量刷新，再引入 `obstacle_work.airspace_volume_piece` / `obstacle_work.terrain_block`。
