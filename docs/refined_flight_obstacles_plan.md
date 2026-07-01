# 精细飞行障碍 geomgrids 避障实施方案

## 1. 背景与目标

当前多源飞行障碍第一版已落地：

- 建筑：直接使用 3DCityDB 几何生成 `ST_AsGrids3D`。
- 地形：使用 DEM tile 的 footprint envelope + min/max elevation 生成粗粒度 3D bbox prism。
- 禁飞区 / 临时管制区：使用 polygon footprint envelope + 高度范围生成粗粒度 3D bbox prism。

该方案安全、SQL 简单，但对非矩形 polygon 和地形起伏会保守扩大障碍范围，导致路径规划可通行空间被过度占用。

本方案目标是在保持现有对外契约不变的前提下，将地形、禁飞区、临时管制区升级为更精细的占用体生成流程：

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

## 3. 数据库设计

### 3.1 保持现有输出契约

所有源物化视图仍输出：

```sql
source_kind     text,
source_id       text,
source_name     text,
dimension       smallint,
detail_level    integer,
is_agg          boolean,
grids           geomgrids,
valid_from      timestamptz,
valid_to        timestamptz,
priority        integer,
generated_at    timestamptz
```

### 3.2 新增派生 staging schema

建议新增 schema，用于保存可审计的中间占用体：

```sql
create schema if not exists obstacle_work;
```

建议表：

```sql
create table if not exists obstacle_work.airspace_volume_piece (
  id bigserial primary key,
  source_kind text not null,      -- no_fly_zone / temp_control
  source_id text not null,
  source_name text,
  piece_id integer not null,
  geom geometry not null,         -- 4326 geometry with Z or 2D footprint depending on method
  min_height double precision not null,
  max_height double precision not null,
  valid_from timestamptz,
  valid_to timestamptz,
  priority integer not null,
  generated_at timestamptz not null default now(),
  unique (source_kind, source_id, piece_id)
);

create index if not exists airspace_volume_piece_geom_gix
on obstacle_work.airspace_volume_piece using gist (geom);
```

地形分块表：

```sql
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

create index if not exists terrain_block_geom_gix
on obstacle_work.terrain_block using gist (geom);
```

说明：

- `obstacle_work.*` 是可删除、可重建的派生数据，不是业务主数据。
- 物化视图可直接从这些 staging 表生成，也可在脚本中 rebuild staging 后 rebuild views。

## 4. Airspace polygon 精细化方案

### 4.1 首选方法：2D 精确网格 + 垂直层组合

如果 iBEST-DB 的 `ST_AsGrids3D(geometry)` 对复杂 `POLYHEDRALSURFACE Z` 的支持或性能不稳定，则采用更稳健路线：

1. 对 airspace polygon 做安全缓冲。
2. 使用 `ST_AsGrids` 生成 2D footprint grids。
3. 将 2D cell 与高度层组合成 3D grid cells。
4. 汇总为 `geomgrids`。

优点：

- XY 精度由 polygon 本体决定，不再使用 bbox envelope。
- 可控地生成高度层，避免复杂 polyhedral surface 兼容性问题。
- 适合禁飞区、临时管制区这种规则高度范围。

风险：

- 需要确认 iBEST-DB 是否提供从 2D cell + height layer 构造 3D `gridcell` 的函数；若缺失，退回 4.2。

### 4.2 备选方法：polygon extrusion volume

新增 helper function：

```sql
citydb_grid.make_polygon_prism_3d(
  p_footprint geometry,
  p_min_z double precision,
  p_max_z double precision
) returns geometry
```

输出 `POLYHEDRALSURFACE Z`：

- bottom face：polygon exterior + holes，z = min_z
- top face：polygon exterior + holes，z = max_z
- side faces：外环与内环逐边生成 vertical patch

然后：

```sql
public.ST_AsGrids3D(
  public.ST_Transform(citydb_grid.make_polygon_prism_3d(footprint, min_z, max_z), 4326),
  :detail_level,
  :is_agg
)
```

注意事项：

- polygon 必须先 `ST_MakeValid`。
- MultiPolygon 应拆成 piece，避免单个复杂 volume 过大。
- hole 需要生成内壁，否则 volume 语义不完整。
- 对极小 polygon，应保留最小高度厚度，例如 `max_z = min_z + 0.01`。

### 4.3 分片规则

对大型禁飞区/临时管制区：

```sql
ST_Subdivide(geom, max_vertices)
```

建议参数：

```text
max_vertices = 128 或 256
```

每个 piece 生成独立 `source_id`：

```text
source_id = zone_id || ':piece:' || piece_id
```

总视图仍可 `UNION ALL`，但唯一键变为：

```text
(source_kind, source_id)
```

## 5. 地形精细化方案

### 5.1 Phase B1：DEM block prism

将当前 tile 级 prism 改为 block 级 prism。

流程：

```text
terrain.dem_tile raster
        ↓ split into blocks, e.g. 8x8 / 16x16 pixels
        ↓ per-block min/max/mean elevation
        ↓ block footprint polygon
        ↓ prism: min_z = min_elevation - tolerance
                 max_z = max_elevation + clearance
        ↓ ST_AsGrids3D
```

建议 block 策略：

| DEM 分辨率 | block pixels | 约等效地面尺寸 | 适用 |
|---|---:|---:|---|
| 30m | 4x4 | 120m | 第一版精细化，数据量适中 |
| 30m | 2x2 | 60m | 更精细，网格数更多 |
| 30m | 1x1 | 30m | 最精细但可能过重 |

默认建议：

```text
block_size_pixels = 4
terrain_clearance_m = 30
underground_tolerance_m = 0
```

### 5.2 Phase B2：DEM cell exact prism

如果 block 级仍过粗，则按 DEM 像元生成：

```text
one raster pixel → one terrain prism
```

每个 prism：

```text
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
- 前端不应默认加载全部地形障碍 bbox。

### 5.3 Phase B3：terrain height bands

对路径规划来说，地形障碍可表达为：

```text
cell below terrain_z + clearance is occupied
cell above terrain_z + clearance is free/unknown
```

因此可预生成高度层占用，而不是构造完整 prism 几何。

建议表：

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

后续路径规划可优先使用 `clearance_grid`，而 `citydb_grid.obstacles_terrain` 继续作为 `ST_FindGridsPath` 兼容层。

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

## 7. 脚本改造计划

扩展现有脚本：

```bash
scripts/refresh_citydb_obstacle_grids.py
```

新增参数建议：

```bash
--airspace-mode bbox|polygon-prism|grid-stack
--airspace-subdivide-vertices 128

--terrain-mode tile-bbox|block-prism|cell-prism|height-band
--terrain-block-size-pixels 4
--terrain-clearance-m 30
--underground-tolerance-m 0

--rebuild-staging
--skip-staging
```

推荐默认值演进：

```text
当前：
  airspace-mode = bbox
  terrain-mode  = tile-bbox

Phase A 后：
  airspace-mode = polygon-prism 或 grid-stack
  terrain-mode  = tile-bbox

Phase B 后：
  airspace-mode = polygon-prism/grid-stack
  terrain-mode  = block-prism
```

新增脚本内部步骤：

1. `ensure_obstacle_work_schema()`
2. `rebuild_airspace_volume_piece()`
3. `rebuild_terrain_block()`
4. `build_obstacles_no_fly_zones_sql()` 从 staging 或精确 helper 生成
5. `build_obstacles_temp_control_sql()` 从 staging 或精确 helper 生成
6. `build_obstacles_terrain_sql()` 从 `obstacle_work.terrain_block` 生成
7. rebuild `citydb_grid.flight_obstacles`
8. rebuild GGER codes view / PostgREST notify

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

选择一个包含山谷和平地的 DEM tile，生成 block：

```sql
select min(max_elevation), max(max_elevation), count(*)
from obstacle_work.terrain_block;
```

预期：不同 block 的 max_elevation 有明显差异。

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

## 13. 推荐实施顺序

1. 新增 `obstacle_work` schema 和 staging 表。
2. 实现 `--airspace-mode polygon-prism`：
   - 先支持无 hole polygon。
   - 再支持 MultiPolygon / hole / subdivide。
3. 对 no-fly-zone 做 L 形 polygon 精度验收。
4. 将 temp-control 复用同一 airspace pipeline。
5. 实现 `--terrain-mode block-prism --terrain-block-size-pixels 4`。
6. 对 DEM block 局部 elevation 做验收。
7. 前端增加 terrain 视域加载 RPC，避免一次加载全部 terrain cells。
8. 评估是否需要 `terrain.clearance_grid` 作为路径规划主输入。

## 14. 第一阶段完成定义

第一阶段完成后应达到：

- 禁飞区 / 临时管制区不再使用 envelope bbox prism。
- airspace polygon 的凹形缺口不会被误标记为障碍。
- 地形至少支持 block-prism 模式，且默认 block 级别可配置。
- `citydb_grid.flight_obstacles` 字段契约不变。
- 前端和 RPC 无需 schema-breaking 变更即可展示精细化结果。
- `ST_FindGridsPath` 仍可通过 `public.flight_obstacles(id, grids)` 使用所有来源障碍。
