# 3DCityDB 模型 GGER / GeomGrids 网格化方案

## 1. 背景与目标

当前脚本方案把模型代表点的 BGC 2D/3D 编码、层级、中心点、包围盒尺寸等写入 `citydb.property`。这种方式存在两个问题：

1. **属性冗余**：大量派生字段作为字符串/数值属性保存，维护成本高。
2. **不利于计算**：历史 BGC 文本码不适合作为空间关系计算和索引字段；对外展示统一使用 GGER 编码。

调整目标：

- 使用 iBEST-DB 的 **GGER / GeoSOT 体系**，不再以 BGC 点编码作为核心存储。
- 使用 `geomgrids` 类型表达模型覆盖的网格集合。
- 使用 GIN 索引支持相交、包含、被包含等网格空间查询。
- 面向飞行轨迹规划时，提供可直接传给 `ST_FindGridsPath(startCell, endCell, tableName, gridsfield, ...)` 的障碍区域关系。
- 对外展示只使用 **GGER** 编码；GGER 文本从同一个 `geomgrids` 字段按需转换生成，不重复存储。
- 不修改 3DCityDB 标准表结构，不把派生网格列塞进 `citydb.geometry_data`。

## 2. 文档依据

根据 `docs/GEOVIS iBEST-DB V6.1.0 用户手册_LLM优化版.md`：

- `ST_AsGrids(geometry geom, integer detailLevel, bool isAgg)`：从 2D Geometry 构建 `geomgrids`。
- `ST_AsGrids3D(geometry geom, integer detailLevel, bool isAgg)`：从 3D Geometry 构建 3D `geomgrids`。
- Geometry 输入 SRID 要求为 `4326` 或 `4490`。
- `ST_AsText(geomgrids, text standard)` 可将 `geomgrids` 输出为指定规范文本，例如 `standard='GGER'` 或 `standard='BGC'`。
- `geomgrids` 支持 GIN 索引，操作符包括：
  - `&&`：相交
  - `@>`：包含
  - `<@`：被包含
  - `=`：相等
- `ST_FindGridsPath(gridcell startCell, gridcell endCell, text tableName, text gridsfield, bool hasBelow default false)` 需要传入**障碍区域表名**和其中的 `geomgrids` 字段名。
- BGC 文本输出只支持与 BGC 对应的 GeoSOT/GGER 层级：`15, 19, 20, 23, 26, 29, 32`，分别对应 BGC 4-10 级。该能力仅作为兼容说明，不作为对外展示标准。
- 手册建议：非 Point 数据或需要 3D 索引时，优先使用 `geomgrids`。

当前数据库实测可用函数包括：

- `public.ST_AsGrids(geometry, integer default -1, boolean default true)`
- `public.ST_AsGrids3D(geometry, integer default -1, boolean default true)`
- `public.ST_AsText(geomgrids, text)`

也就是说，`ST_AsGrids3D(geometry)` 可以忽略 `detailLevel` 参数，由系统自动选择层级。由于对外展示只输出 GGER，展示层不再受 BGC 兼容层级约束。第一版仍建议显式传入 `detailLevel=19`，主要用于保证障碍网格、起终点 `gridcell` 与路径规划调用处于一致、可复现实验尺度。

## 3. 总体设计：物化视图作为派生计算索引

不新建需要人工维护的业务表，也不改 `citydb.geometry_data`。

采用：

```text
citydb.geometry_data.geometry  -- 原始 3DCityDB 几何，唯一事实源
        ↓ refresh materialized view
citydb_grid.flight_obstacles   -- 派生 geomgrids 障碍区域，供计算与索引使用
```

`citydb_grid.flight_obstacles` 是**物化视图**：

- 可从 CityDB 几何完整重建。
- 可建 `gin_grids_ops` 索引。
- 可直接作为 `ST_FindGridsPath()` 的障碍区域输入。
- 模型更新后只需刷新视图，不需要手工同步一张 `flight_obstacles` 表。

## 4. 物化视图 DDL

第一版默认使用 3D 障碍网格：

```sql
create schema if not exists citydb_grid;

drop materialized view if exists citydb_grid.flight_obstacles;

create materialized view citydb_grid.flight_obstacles as
with ranked_geometry as (
    select distinct on (f.id)
        f.id as feature_id,
        f.objectid,
        f.objectclass_id,
        gd.id as geometry_id,
        gd.geometry
    from citydb.feature f
    join citydb.geometry_data gd on gd.feature_id = f.id
    where gd.geometry is not null
      and not ST_IsEmpty(gd.geometry)
    order by
        f.id,
        ST_Area(ST_Envelope(ST_Force2D(gd.geometry))) desc nulls last,
        gd.id
)
select
    feature_id,
    geometry_id,
    objectid,
    objectclass_id,
    3::smallint as dimension,
    19::integer as detail_level,
    true::boolean as is_agg,
    ST_AsGrids3D(ST_Transform(geometry, 4326), 19, true) as grids,
    ST_SRID(geometry) as source_srid,
    now() as generated_at
from ranked_geometry;
```

索引：

```sql
create unique index flight_obstacles_geometry_id_idx
on citydb_grid.flight_obstacles (geometry_id);

create index flight_obstacles_feature_id_idx
on citydb_grid.flight_obstacles (feature_id);

create index flight_obstacles_objectid_idx
on citydb_grid.flight_obstacles (objectid);

create index flight_obstacles_grids_gin_idx
on citydb_grid.flight_obstacles
using gin (grids gin_grids_ops);
```

说明：

- `grids geomgrids` 是核心计算字段。
- `feature_id / geometry_id / objectid` 用于回查 3DCityDB。
- `detail_level / dimension / is_agg` 是生成参数，便于排查与重建。
- GGER 文本码不常驻存储；需要展示时用 `ST_AsText(grids, 'GGER')` 生成。

## 5. 刷新策略

模型导入、更新、删除后刷新物化视图：

```sql
refresh materialized view concurrently citydb_grid.flight_obstacles;
```

要求：物化视图必须有唯一索引。上面的 `flight_obstacles_geometry_id_idx` 满足该要求。

如果首次创建后还没有唯一索引，第一次可使用非 concurrent 刷新：

```sql
refresh materialized view citydb_grid.flight_obstacles;
```

建议把刷新封装到脚本：

```bash
uv run scripts/refresh_citydb_flight_obstacles.py
```

脚本职责：

1. 确认 iBEST-DB 函数和 `geomgrids` 类型存在。
2. 创建/重建物化视图。
3. 创建索引。
4. 在模型更新后执行 `refresh materialized view concurrently`。
5. dry-run 时输出行数、`ST_nCells(grids)` 样例和 GGER 文本样例。

## 6. 2D / 3D 策略

### 6.1 默认建议：3D GeomGrids

```sql
ST_AsGrids3D(ST_Transform(gd.geometry, 4326), :detail_level, :is_agg)
```

原因：

- CityDB 建筑模型本身是 `POLYHEDRALSURFACE Z`。
- 飞行轨迹规划需要表达高度占用，3D 障碍更合理。
- 不需要再保存代表点高度、minZ/maxZ 等冗余字段。

### 6.2 可选：2D footprint GeomGrids

如果只做平面检索，可另建 2D 物化视图：

```sql
ST_AsGrids(ST_Transform(ST_Force2D(gd.geometry), 4326), :detail_level, :is_agg)
```

2D 模式网格量更小、查询更快，但不表达高度占用，不适合作为最终飞行障碍判断。

## 7. detailLevel 策略

`geomgrids` 可以让系统自动选择 `detailLevel`。由于对外展示只使用 GGER，`detailLevel` 不需要受 BGC 兼容层级限制。第一版建议显式指定：

```text
dimension = 3
detail_level = 19
is_agg = true
```

理由：

- GGER/GeoSOT 19 级尺度接近百米级建筑，适合作为第一版飞行障碍网格的稳定实验粒度。
- 当前花果山建筑测试中，`detailLevel=19` 生成网格数量较小，适合先落地验证。
- 后续可基于 `ST_nCells(grids)`、模型包围盒尺寸、飞行安全裕度实现自适应。

后续脚本可支持：

```bash
--detail-level 19
--auto-detail-level
--min-detail-level 15
--max-detail-level 23
--agg / --no-agg
--dimension 3
```

## 8. 飞行轨迹计算用法

### 8.1 创建起终点 gridcell

路径规划函数输入是 `gridcell`，建议起终点层级与障碍 `detail_level` 保持一致：

```sql
select
    ST_AsGridcell3D(119.23, 34.66, 120, 19) as start_cell,
    ST_AsGridcell3D(119.30, 34.63, 120, 19) as end_cell;
```

### 8.2 调用 ST_FindGridsPath

```sql
select ST_FindGridsPath(
    ST_AsGridcell3D(119.23, 34.66, 120, 19),
    ST_AsGridcell3D(119.30, 34.63, 120, 19),
    'citydb_grid.flight_obstacles',
    'grids',
    false
);
```

如遇 iBEST-DB 对 schema-qualified tableName 支持不佳，可创建 `public` 包装物化视图或普通视图：

```sql
create or replace view public.flight_obstacles as
select geometry_id as id, grids
from citydb_grid.flight_obstacles;
```

然后调用：

```sql
select ST_FindGridsPath(start_cell, end_cell, 'public.flight_obstacles', 'grids');
```

## 9. 查询与展示

### 9.1 输出 GGER 文本

```sql
select
    feature_id,
    objectid,
    ST_nCells(grids) as cell_count,
    ST_AsText(grids, 'GGER') as gger_grids
from citydb_grid.flight_obstacles
where objectid = 'osm:way:1002427134';
```

注意：对外 API、前端属性面板和导出结果统一返回 `gger_grids`。BGC 仅保留为数据库函数兼容能力说明，不进入展示视图或接口契约。

可封装展示视图：

```sql
create or replace view citydb_grid.flight_obstacles_codes_view as
select
    feature_id,
    geometry_id,
    objectid,
    objectclass_id,
    dimension,
    detail_level,
    is_agg,
    ST_nCells(grids) as cell_count,
    ST_AsText(grids, 'GGER') as gger_grids,
    generated_at
from citydb_grid.flight_obstacles;
```

### 9.2 相交查询

```sql
select fo.feature_id, fo.objectid
from citydb_grid.flight_obstacles fo
where fo.grids && ST_AsGrids3D(:query_geom_4326_z, 19, true);
```

### 9.3 包含/被包含查询

```sql
-- 模型障碍网格包含查询网格
where fo.grids @> :query_grids

-- 模型障碍网格被查询网格包含
where fo.grids <@ :query_grids
```

## 10. 是否写回 citydb.property

默认不写。

如果前端属性面板需要展示网格信息，建议通过 `objectid` 或 `feature_id` 查询 `citydb_grid.flight_obstacles_codes_view`，只展示 `gger_grids`，而不是把完整 GGER 文本码数组复制到 `citydb.property`。

如必须写属性，只写轻量引用：

| property | 类型 | 内容 |
|---|---|---|
| `gridRef` | string | `citydb_grid.flight_obstacles:<geometry_id>` |

## 11. 实施脚本

历史脚本 `scripts/generate_citydb_gridcode_properties.py` 已删除，避免继续生成 BGC 点编码并写入 `citydb.property`。

当前统一使用：

```text
scripts/refresh_citydb_flight_obstacles.py
```

CLI 建议：

```bash
uv run scripts/refresh_citydb_flight_obstacles.py \
  --dimension 3 \
  --detail-level 19 \
  --agg \
  --create-public-wrapper \
  --grant-role web_anon
```

过滤 OSM 建筑时可在物化视图 SQL 中加入筛选参数，或创建独立视图：

```bash
uv run scripts/refresh_citydb_flight_obstacles.py \
  --objectid-like 'osm:%' \
  --objectclass-id 901 \
  --dimension 3 \
  --detail-level 19
```

## 12. 验收状态

当前实施命令：

```bash
uv run scripts/refresh_citydb_flight_obstacles.py \
  --dimension 3 \
  --detail-level 19 \
  --agg \
  --create-public-wrapper \
  --grant-role web_anon
```

当前验收结果：

| # | 验收项 | 状态 | 结果 |
|---|---|---|---|
| 1 | `citydb_grid.flight_obstacles` 行数等于目标 geometry/feature 数 | 已通过 | 当前生成 18 行障碍网格记录。 |
| 2 | 每行 `grids` 非空，`ST_nCells(grids) > 0` | 已通过 | 已抽样验证 GGER 输出；当前 cell 数范围曾验证为 `1..4377`。 |
| 3 | `ST_AsText(grids, 'GGER')` 可正常输出 GGER 编码 | 已通过 | dry-run 和正式生成均可输出 `GZ...` GGER 3D 网格集合。 |
| 4 | 对外展示视图和接口不输出 BGC 编码，只输出 GGER 编码 | 已通过 | `citydb_grid.flight_obstacles_codes_view` 仅包含 `gger_grids`，不包含 BGC 字段。 |
| 5 | GIN 索引创建成功 | 已通过 | 已创建 `flight_obstacles_grids_gin_idx`，使用 `gin_grids_ops`。 |
| 6 | `&& / @> / <@` 查询可用，并能走 `gin_grids_ops` 索引 | 部分通过 | `&&` 已用 `EXPLAIN` 确认走 `flight_obstacles_grids_gin_idx`；`@>` / `<@` 操作符由同一 opclass 支持，后续可补充业务查询用例。 |
| 7 | `ST_FindGridsPath(..., 'citydb_grid.flight_obstacles', 'grids')` 可使用该物化视图作为障碍区域输入 | 已具备 | 已创建主物化视图；同时创建 `public.flight_obstacles(id, grids)` 包装视图用于兼容 `tableName` 参数。真实航线起终点调用待飞行用例中验证。 |
| 8 | 不新增大量 `citydb.property` 网格码子属性 | 已通过 | 新脚本不写 `citydb.property`；旧 BGC 属性脚本已删除。 |
| 9 | 不修改 `citydb.geometry_data` 表结构 | 已通过 | 仅新增 `citydb_grid` 派生视图/索引和可选 `public` 包装视图。 |

## 13. 实施状态：PostgREST GGER + Box RPC

目标：为前端拾取模型后的属性面板增加一个轻量 RPC，按 feature 标识查询 GGER 网格文本，并通过 iBEST-DB `ST_WithBox(grids, 'GGER')` 同时返回每个网格的包围盒信息，供前端做网格高亮、bbox 调试和详情展示。

当前状态：已实施并部署到数据库。SQL 文件为 `backend/create_citydb_feature_gger_grids_rpc.sql`。

### 13.1 RPC 设计

新增 SQL 文件：

```text
backend/create_citydb_feature_gger_grids_rpc.sql
```

函数命名：

```sql
public.get_citydb_feature_gger_grids(p_feature_identifier text)
citydb.get_citydb_feature_gger_grids(p_feature_identifier text) -- PostgREST wrapper
```

PostgREST 调用：

```http
POST /rpc/get_citydb_feature_gger_grids
Content-Type: application/json

{"p_feature_identifier":"osm:way:1002427134"}
```

`p_feature_identifier` 匹配规则与现有 `get_citydb_feature_properties` 保持一致：

1. 优先匹配 `citydb.feature.objectid`
2. 其次匹配 `citydb.feature.identifier`
3. 若参数为纯数字，则匹配 `citydb.feature.id`

### 13.2 返回结构

RPC 返回 `jsonb`：

```json
{
  "feature": {
    "id": 1,
    "objectid": "osm:way:1002427134",
    "identifier": null,
    "objectclass_id": 901
  },
  "grid": {
    "geometry_id": 73,
    "dimension": 3,
    "detail_level": 19,
    "is_agg": true,
    "cell_count": 7,
    "gger_grids": "{...}",
    "gger_grids_with_box": "{...}",
    "generated_at": "2026-07-01T..."
  }
}
```

字段说明：

- `gger_grids`：`ST_AsText(grids, 'GGER')` 输出，只包含 GGER 编码集合。
- `gger_grids_with_box`：`ST_WithBox(grids, 'GGER')` 输出，包含 GGER 编码及每个 cell 的 bbox。
- 不返回 BGC 字段，保持“对外展示只使用 GGER”的接口契约。

### 13.3 SQL 实现

```sql
create or replace function public.get_citydb_feature_gger_grids(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
with matched_feature as (
    select f.id, f.objectid, f.identifier, f.objectclass_id
    from citydb.feature f
    where f.objectid = p_feature_identifier
       or f.identifier = p_feature_identifier
       or f.id = case
            when p_feature_identifier ~ '^[0-9]+$'
                then p_feature_identifier::bigint
            else null::bigint
       end
    order by
        case
            when f.objectid = p_feature_identifier then 1
            when f.identifier = p_feature_identifier then 2
            else 3
        end,
        f.id
    limit 1
), matched_grid as (
    select fo.*
    from citydb_grid.flight_obstacles fo
    join matched_feature f on f.id = fo.feature_id
    order by fo.geometry_id
    limit 1
)
select case
    when not exists (select 1 from matched_feature) then null::jsonb
    when not exists (select 1 from matched_grid) then jsonb_build_object(
        'feature', (select to_jsonb(f) from matched_feature f),
        'grid', null
    )
    else jsonb_build_object(
        'feature', (select to_jsonb(f) from matched_feature f),
        'grid', (
            select jsonb_build_object(
                'geometry_id', g.geometry_id,
                'dimension', g.dimension,
                'detail_level', g.detail_level,
                'is_agg', g.is_agg,
                'cell_count', ST_nCells(g.grids),
                'gger_grids', ST_AsText(g.grids, 'GGER'),
                'gger_grids_with_box', ST_WithBox(g.grids, 'GGER'),
                'generated_at', g.generated_at
            )
            from matched_grid g
        )
    )
end;
$$;
```

同时创建 `citydb` schema 下的 thin wrapper，以适配当前 `pgrest.conf` 中 `db-schemas = "citydb, public, terrain"` 的默认 RPC 暴露方式：

```sql
create or replace function citydb.get_citydb_feature_gger_grids(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, citydb_grid, pg_temp
as $$
    select public.get_citydb_feature_gger_grids(p_feature_identifier);
$$;
```

权限与 PostgREST schema cache：

```sql
grant usage on schema citydb_grid to web_anon;
grant select on citydb_grid.flight_obstacles to web_anon;
grant select on citydb_grid.flight_obstacles_codes_view to web_anon;
grant execute on function public.get_citydb_feature_gger_grids(text) to web_anon;
grant execute on function citydb.get_citydb_feature_gger_grids(text) to web_anon;
notify pgrst, 'reload schema';
```

### 13.4 前端使用状态

已在 `frontend/tianditu-3d.html` 实现拾取建筑后的 GGER 包围网格展示：

- 拾取 3D Tiles feature 后，沿用当前 metadata 中的 `id` / `objectid` / `identifier` 作为 `p_feature_identifier`。
- 并行调用：
  - `/rpc/get_citydb_feature_properties` 获取业务属性。
  - `/rpc/get_citydb_feature_gger_grids` 获取 `gger_grids` 与 `gger_grids_with_box`。
- 属性面板新增 `GGER Bounding Grid` 卡片，展示：
  - `detail_level`
  - `cell_count`
  - `dimension`
  - `geometry_id`
  - GGER cells 和 bbox 样例
- 前端解析 `ST_WithBox` 返回 JSON 中的 `cells[].bbox`，使用 Cesium `PolylineCollection` 绘制选中 feature 的 3D bbox 线框。
- 支持面板按钮：
  - `定位包围网格`：飞到当前选中 feature 的网格整体范围。
  - `清除高亮`：移除当前网格高亮。
- 关闭属性面板时同步清除当前 GGER bbox 高亮。

### 13.5 验收状态

| # | 验收项 | 状态 | 结果 |
|---|---|---|---|
| 1 | `backend/create_citydb_feature_gger_grids_rpc.sql` 可重复执行 | 已通过 | 已成功执行 SQL 文件创建/替换函数。 |
| 2 | `POST /rpc/get_citydb_feature_gger_grids` 可通过 `objectid`、`identifier`、数字 `feature.id` 查询 | 已通过 | 已验证 `osm:way:1002427134`、`https://www.openstreetmap.org/way/1002427134`、`1` 均返回 feature 1。 |
| 3 | 返回 JSON 包含 `gger_grids` 和 `gger_grids_with_box` | 已通过 | PostgREST 返回 `grid.gger_grids` 与 `grid.gger_grids_with_box`。 |
| 4 | `gger_grids_with_box` 来自 `ST_WithBox(grids, 'GGER')` | 已通过 | 返回内容包含 `cells[].code` 与 `cells[].bbox`。 |
| 5 | 返回结构不包含任何 BGC 字段 | 已通过 | 已验证响应体不包含 `bgc` / `BGC`。 |
| 6 | 对不存在的 feature 返回 `null`；对存在 feature 但无网格的记录返回 `grid: null` | 部分通过 | 不存在 feature 已验证返回 `null`；当前样例数据中未发现“有 feature 但无网格”的前端拾取用例。 |
| 7 | `web_anon` 具备执行函数所需权限 | 已通过 | SQL 已授予 `citydb_grid` usage/select 及 public/citydb RPC execute。 |
| 8 | `notify pgrst, 'reload schema'` 后 PostgREST 可直接调用 | 已通过 | 已通过 `http://10.1.109.151:13000/rpc/get_citydb_feature_gger_grids` 验证。 |
| 9 | 前端可解析 bbox 并高亮显示包围网格 | 已通过 | 前端拾取模型验收通过：属性面板可展示 GGER bbox 信息，Cesium 中可高亮显示包围网格，并支持定位与清除；脚本语法已通过 `node --check`。 |

## 14. 后续增强

- `--auto-detail-level`：按模型尺寸、目标 cell 数或飞行安全裕度自动选择 GGER/GeoSOT 层级；对外展示仍统一输出 GGER。
- 支持安全缓冲区：生成障碍前对模型 footprint/体积进行水平或垂直膨胀。
- 支持多套障碍视图：建筑、地形、禁飞区、临时管制区分别生成，再 union 成飞行障碍视图；详细计划见 `docs/multi_source_flight_obstacles_plan.md`。
- 为 PostgREST 增加 RPC：按查询几何检索相交模型、触发刷新。
- 前端拾取模型时，通过 `feature_id/objectid` 查询 GGER + bbox RPC 展示 GGER 网格集合和 bbox 信息。
