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

当前 `citydb_grid.flight_obstacles` 中的建筑逻辑后续应重命名为：

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

地形不能只做 2D footprint。对于飞行避障，应把地形转换为 3D 占用体：

```text
DEM footprint + min/max elevation + terrain clearance
        ↓
3D prism / box
        ↓
ST_AsGrids3D(...)
```

第一版可按 DEM tile 生成粗粒度体：

```text
min_z = min_elevation - underground_tolerance
max_z = max_elevation + terrain_clearance_m
```

后续可按更细 DEM cell 或预处理 mesh 切片生成更精细体。

### 4.3 禁飞区

建议新增业务 schema/table：

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

## 7. 脚本改造计划

将当前建筑专用脚本：

```bash
scripts/refresh_citydb_flight_obstacles.py
```

扩展或拆分为多源脚本：

```bash
scripts/refresh_citydb_obstacle_grids.py
```

建议参数：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py --source buildings
uv run scripts/refresh_citydb_obstacle_grids.py --source terrain
uv run scripts/refresh_citydb_obstacle_grids.py --source no-fly-zones
uv run scripts/refresh_citydb_obstacle_grids.py --source temp-control
uv run scripts/refresh_citydb_obstacle_grids.py --source all
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

## 8. 落地顺序

1. 保持当前功能不变，将现有建筑物化视图逻辑迁移为 `obstacles_buildings`。
2. 新建总视图 `flight_obstacles`，第一阶段只 union 建筑来源。
3. 新增 `airspace.no_fly_zone` 与 `obstacles_no_fly_zones`。
4. 新增 `airspace.temp_control_zone` 与 `obstacles_temp_control_active`。
5. 最后实现地形障碍，因为地形 3D volume、clearance 和粒度策略最复杂。

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

已新增多源刷新脚本：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py --source all --grant-role web_anon
```

当前实现内容：

- `citydb_grid.obstacles_buildings`：由 `citydb.feature` / `citydb.geometry_data` 生成建筑障碍。
- `citydb_grid.obstacles_terrain`：由 `terrain.dem_tile` 生成第一版 DEM tile 级粗粒度 3D bbox prism 障碍，使用 `min_elevation - underground_tolerance` 到 `max_elevation + terrain_clearance_m`。
- `airspace.no_fly_zone` / `airspace.temp_control_zone`：脚本自动创建业务表。
- `citydb_grid.obstacles_no_fly_zones` / `citydb_grid.obstacles_temp_control_active`：由 airspace polygon 生成第一版粗粒度 3D bbox prism 障碍；临时管制区按 `valid_from` / `valid_to` 与 `status` 筛选。
- `citydb_grid.flight_obstacles`：统一 `UNION ALL` 总物化视图，已建 `(source_kind, source_id)` 唯一索引与 `grids gin_grids_ops` GIN 索引。
- `public.flight_obstacles(id, grids)`：保留给 `ST_FindGridsPath` 的兼容包装。
- `citydb_grid.flight_obstacles_codes_view`：仅输出 GGER 展示码，不输出 BGC。
- `public/citydb.list_flight_obstacles_gger(...)`：新增前端列表 RPC，按 `source_kind` 返回 GGER 与可选 `ST_WithBox` bbox。
- `frontend/tianditu-3d.html`：新增“飞行障碍”图层、source_kind 过滤、刷新/定位/清除操作，以及多源障碍线框渲染和详情面板。

注意：地形、禁飞区、临时管制区第一版为了安全和 SQL 可维护性，使用 footprint envelope 的 3D bbox prism 表达占用体，可能在 XY 上保守扩大障碍范围。后续如需更精细避障，可升级为按 polygon 精确挤出或按 DEM cell/mesh 切片生成。
