# 多源飞行障碍 geomgrids 视图实施计划

## 1. 目标

在不修改 3DCityDB 标准表结构的前提下，将不同来源的飞行障碍分别生成 `geomgrids` 物化视图，再通过统一总视图提供给航线规划与前端展示。

目标来源包括：

- 建筑模型：3DCityDB `citydb.geometry_data`
- 地形：`terrain.dem_tile` / DEM 派生体
- 禁飞区：长期有效 polygon / volume
- 临时管制区：带时间窗口的 polygon / volume

对外展示仍然只使用 **GGER** 编码，不输出 BGC。

## 2. 总体架构

```text
citydb_grid.obstacles_buildings
citydb_grid.obstacles_terrain
citydb_grid.obstacles_no_fly_zones
citydb_grid.obstacles_temp_control_active
        ↓ union all
citydb_grid.flight_obstacles
        ↓ thin wrapper
public.flight_obstacles(id, grids)
```

设计原则：

1. 各来源独立生成、独立刷新、独立验收。
2. 总障碍视图只做统一字段与 `UNION ALL`，不丢失来源信息。
3. `grids geomgrids` 是唯一用于空间计算和 GIN 索引的核心字段。
4. GGER 文本码只在展示视图或 RPC 中按需生成。
5. `public.flight_obstacles(id, grids)` 仅作为 `ST_FindGridsPath` 兼容包装。

## 3. 统一字段契约

每个来源物化视图都应输出相同字段：

```sql
source_kind     text,        -- building / terrain / no_fly_zone / temp_control
source_id       text,        -- 来源内部唯一 ID
source_name     text,
dimension       smallint,    -- 2 / 3
detail_level    integer,
is_agg          boolean,
grids           geomgrids,
valid_from      timestamptz,
valid_to        timestamptz,
priority        integer,
generated_at    timestamptz
```

建议唯一键：

```sql
(source_kind, source_id)
```

## 4. 分来源实现

### 4.1 建筑障碍

建筑障碍已独立为：

```sql
citydb_grid.obstacles_buildings
```

来源：

```sql
citydb.feature
citydb.geometry_data
```

网格化：

```sql
public.ST_AsGrids3D(public.ST_Transform(geometry, 4326), :detail_level, :is_agg)
```

建议输出：

```sql
'building' as source_kind,
geometry_id::text as source_id,
coalesce(objectid, feature_id::text) as source_name
```

### 4.2 地形障碍

来源：

```sql
terrain.dem_dataset
terrain.dem_tile
```

地形不能只做 2D footprint。对于飞行避障，应把地形转换为 3D 占用体后执行 `ST_AsGrids3D(...)`。

当前实现支持两种模式，均生成同一个物化视图：

```sql
citydb_grid.obstacles_terrain
```

- `tile-bbox`：按 DEM tile 的 footprint envelope 与 tile 级 `min_elevation/max_elevation` 生成粗粒度 bbox prism，作为兼容/回退模式。
- `block-prism`：按 DEM raster 像元块生成局部 prism；当前数据库使用 `terrain_block_size_pixels = 4`，即 4x4 DEM 像元一个 block。

详细计算公式、`source_id` 规则和精细化验收见 `docs/refined_flight_obstacles_plan.md`。

### 4.3 禁飞区

业务 schema/table 已由刷新脚本自动创建：

```sql
create schema if not exists airspace;

create table if not exists airspace.no_fly_zone (
  id bigserial primary key,
  name text not null,
  geom geometry(MultiPolygon, 4326) not null,
  min_height double precision default 0,
  max_height double precision,
  safety_buffer_m double precision default 0,
  enabled boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
```

生成规则：

- 水平安全缓冲：`ST_Buffer(geom::geography, safety_buffer_m)::geometry`
- 垂直范围：`min_height` 到 `max_height`
- 转换为 3D volume 后执行 `ST_AsGrids3D`

### 4.4 临时管制区

临时管制区与禁飞区类似，但必须包含有效时间：

```sql
create table if not exists airspace.temp_control_zone (
  id bigserial primary key,
  name text not null,
  geom geometry(MultiPolygon, 4326) not null,
  min_height double precision default 0,
  max_height double precision,
  safety_buffer_m double precision default 0,
  valid_from timestamptz not null,
  valid_to timestamptz not null,
  status text not null default 'planned', -- planned / active / cancelled
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
```

由于 `ST_FindGridsPath` 只接受障碍表名和字段名，建议维护一个“当前有效”物化视图：

```sql
citydb_grid.obstacles_temp_control_active
```

筛选条件：

```sql
status in ('planned', 'active')
and now() >= valid_from
and now() < valid_to
```

如果未来需要按计划起飞时间查询，可增加脚本参数 `--planning-time`，在刷新 active 视图时使用指定时间替代 `now()`。

## 5. 总障碍视图

```sql
create materialized view citydb_grid.flight_obstacles as
select * from citydb_grid.obstacles_buildings
union all
select * from citydb_grid.obstacles_terrain
union all
select * from citydb_grid.obstacles_no_fly_zones
union all
select * from citydb_grid.obstacles_temp_control_active;
```

索引：

```sql
create unique index flight_obstacles_source_uidx
on citydb_grid.flight_obstacles (source_kind, source_id);

create index flight_obstacles_source_kind_idx
on citydb_grid.flight_obstacles (source_kind);

create index flight_obstacles_grids_gin_idx
on citydb_grid.flight_obstacles
using gin (grids gin_grids_ops);
```

兼容包装视图：

```sql
create or replace view public.flight_obstacles as
select
  row_number() over (order by source_kind, source_id) as id,
  grids
from citydb_grid.flight_obstacles;
```

## 6. GGER 展示视图

```sql
create or replace view citydb_grid.flight_obstacles_codes_view as
select
  source_kind,
  source_id,
  source_name,
  dimension,
  detail_level,
  public.ST_nCells(grids)::integer as cell_count,
  public.ST_AsText(grids, 'GGER') as gger_grids,
  valid_from,
  valid_to,
  priority,
  generated_at
from citydb_grid.flight_obstacles;
```

该视图不包含 BGC 字段。

## 7. 脚本与刷新入口

多源障碍刷新脚本已落地：

```bash
scripts/refresh_citydb_obstacle_grids.py
```

常用来源参数：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py --source buildings
uv run scripts/refresh_citydb_obstacle_grids.py --source terrain
uv run scripts/refresh_citydb_obstacle_grids.py --source no-fly-zones
uv run scripts/refresh_citydb_obstacle_grids.py --source temp-control
uv run scripts/refresh_citydb_obstacle_grids.py --source all
```

精细化模式参数：

```bash
--airspace-mode bbox|polygon-prism
--terrain-mode tile-bbox|block-prism
--terrain-block-size-pixels 4
```

`--source all` 顺序：

1. 刷新 `obstacles_buildings`
2. 刷新 `obstacles_terrain`
3. 刷新 `obstacles_no_fly_zones`
4. 刷新 `obstacles_temp_control_active`
5. 刷新 / 重建 `citydb_grid.flight_obstacles`
6. 重建 `public.flight_obstacles`
7. 重建 `citydb_grid.flight_obstacles_codes_view`
8. 执行 `notify pgrst, 'reload schema'`

## 8. 落地状态与后续

已完成：

1. 将建筑障碍迁移为 `citydb_grid.obstacles_buildings`。
2. 新建统一总视图 `citydb_grid.flight_obstacles`。
3. 新增 `airspace.no_fly_zone` 与 `citydb_grid.obstacles_no_fly_zones`。
4. 新增 `airspace.temp_control_zone` 与 `citydb_grid.obstacles_temp_control_active`。
5. 实现地形障碍 `citydb_grid.obstacles_terrain`，当前推荐 `block-prism`。
6. 新增 `public.flight_obstacles(id, grids)` 兼容包装。
7. 新增 GGER-only 展示视图与 PostgREST RPC。
8. 前端已支持飞行障碍图层和 `source_kind` 过滤。

后续工作集中在精细避障文档中维护：

- terrain 视域 bbox RPC。
- 实际 no-fly/temp-control 业务数据 E2E 验收。
- 可选 `obstacle_work` staging 表。
- 可选 `terrain.clearance_grid` / height-band 路径规划主输入。

## 9. 验收项

| # | 验收项 | 预期 |
|---|---|---|
| 1 | 每个来源物化视图字段一致 | 可直接 `UNION ALL` |
| 2 | 总视图有 `(source_kind, source_id)` 唯一索引 | 支持 concurrent refresh |
| 3 | 总视图 `grids` 有 GIN 索引 | `&& / @> / <@` 可走 `gin_grids_ops` |
| 4 | `public.flight_obstacles(id, grids)` 可用于 `ST_FindGridsPath` | 航线规划可读取所有来源障碍 |
| 5 | GGER 展示视图不输出 BGC | 对外编码保持 GGER-only |
| 6 | 临时管制区按时间窗口生效 | 过期或取消区域不进入 active 视图 |
| 7 | 前端可按 `source_kind` 过滤/展示 | 建筑、地形、禁飞区、临时管制区可区分 |

## 10. 实施状态

状态：**多源飞行障碍已实施，精细避障第一阶段已落地**。

本文只保留当前整体架构、统一契约和运行入口；精细避障的算法细节、计算公式、测试记录和后续路线集中维护在 `docs/refined_flight_obstacles_plan.md`，避免两份文档重复发散。

当前推荐刷新命令：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

兼容粗粒度/回退模式仍可使用默认参数：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py --source all --grant-role web_anon
```

空域禁限飞快速刷新已支持：

```bash
# 只重建长期禁飞区并同步统一总障碍视图
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source no-fly-zones \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon

# 只重建临时禁飞/管制区并同步统一总障碍视图
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source temp-control \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon

# 同时重建长期禁飞区与临时禁飞/管制区，不重算建筑和地形
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source airspace \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

当前已落地对象：

- `scripts/refresh_citydb_obstacle_grids.py`：统一创建/刷新多源障碍物化视图，支持 `--refresh-total` 与 `--source airspace`。
- `citydb_grid.obstacles_buildings`
- `citydb_grid.obstacles_terrain`
- `citydb_grid.obstacles_no_fly_zones`
- `citydb_grid.obstacles_temp_control_active`
- `citydb_grid.flight_obstacles`
- `public.flight_obstacles(id, grids)`
- `citydb_grid.flight_obstacles_codes_view`
- `public/citydb.list_flight_obstacles_gger(...)` / `citydb.list_flight_obstacles_gger(...)`
- `scripts/seed_airspace_zones.py`：按现有 `airspace.no_fly_zone` / `airspace.temp_control_zone` 表结构导入 GeoJSON。
- `data/airspace/huaguoshan_no_fly_zone.geojson` / `data/airspace/huaguoshan_temp_control.geojson` 示例数据。
- 前端 `frontend/tianditu-3d.html` 的飞行障碍图层、来源过滤、刷新/定位/清除与详情面板。

当前数据库快照：

```text
citydb_grid.obstacles_buildings: 18 rows
citydb_grid.obstacles_terrain: 3022 rows
citydb_grid.obstacles_no_fly_zones: 1 row
citydb_grid.obstacles_temp_control_active: 1 row
citydb_grid.flight_obstacles: 3042 rows
```

当前关键模式：

- airspace：推荐 `polygon-prism`，保留 `bbox` 回退。
- terrain：推荐 `block-prism`，保留 `tile-bbox` 回退。
- 对外展示/RPC：仍保持 GGER-only，不输出 BGC。
- 路径规划兼容：`public.flight_obstacles(id, grids)` 仍可作为 `ST_FindGridsPath` 障碍输入。

已完成验证摘要：

- 统一物化视图字段一致，可 `UNION ALL`。
- `citydb_grid.flight_obstacles` 与各 source view 已建立 `(source_kind, source_id)` 唯一索引、`source_kind` 索引和 `grids gin_grids_ops` GIN 索引。
- `public.flight_obstacles(id, grids)` wrapper 可查询。
- `citydb_grid.flight_obstacles_codes_view` 与 PostgREST RPC 保持 GGER-only。
- `list_flight_obstacles_gger` 可查询 terrain 精细障碍。
- L 形 polygon 测试中 `polygon-prism` 比 `bbox` 生成更少 cells，验证凹形缺口不再被完整 bbox 误占用。
- `_pi_validation_` 长期禁飞区与临时禁飞区已通过 `--source airspace --refresh-total` 和 `--refresh-only --source airspace --refresh-total` 验证，并可通过 `list_flight_obstacles_gger` 分来源查询。
- 前端 `frontend/tianditu-3d.html` 浏览器验证通过：开启飞行障碍后加载 20 条，其中长期禁飞区 1 条、临时禁飞/管制 1 条；关闭建筑后可单独展示 2 条禁限飞详情。

精细化实现细节见：`docs/refined_flight_obstacles_plan.md`。
