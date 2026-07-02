# 空域禁限飞功能实施计划

> 本文已按当前数据库实际表结构同步。查询库：`huaguoshan_projd`；查询对象：`airspace.no_fly_zone`、`airspace.temp_control_zone`。

## 1. 目标

本计划将“禁飞区功能”统一为**空域禁限飞功能**，覆盖：

- **长期禁飞区**：`source_kind = 'no_fly_zone'`
- **临时禁飞区 / 临时管制区**：`source_kind = 'temp_control'`

目标是在**不修改现有 airspace 业务表结构**、不修改 3DCityDB 标准表结构、不改变现有 GGER-only 对外契约的前提下，实现：

1. 禁限飞区数据录入。
2. polygon-prism geomgrids 生成。
3. 汇总到统一飞行障碍视图。
4. PostgREST 查询。
5. 前端可视化。
6. 路径规划避障接入。
7. 高频空域变化场景下的快速刷新。

---

## 2. 当前代码基础

相关文件：

```text
scripts/refresh_citydb_obstacle_grids.py
backend/create_flight_obstacles_gger_rpc.sql
frontend/tianditu-3d.html
docs/multi_source_flight_obstacles_plan.md
docs/refined_flight_obstacles_plan.md
```

已有能力：

1. 多源障碍物化视图：
   - `citydb_grid.obstacles_buildings`
   - `citydb_grid.obstacles_terrain`
   - `citydb_grid.obstacles_no_fly_zones`
   - `citydb_grid.obstacles_temp_control_active`
   - `citydb_grid.flight_obstacles`
2. airspace polygon 处理模式：
   - `--airspace-mode bbox`
   - `--airspace-mode polygon-prism`
3. PostgREST RPC：
   - `list_flight_obstacles_gger(...)`
4. 前端飞行障碍图层已包含来源过滤：
   - 建筑
   - 地形
   - 禁飞区
   - 临时管制

当前主要缺口：

1. 缺少禁飞区 / 临时禁飞区数据导入脚本和示例数据。
2. 前端缺少面向禁限飞空域的样式和详情展示增强。
3. 刷新脚本缺少“只刷新 airspace，然后刷新总视图”的快速模式。
4. 缺少完整 E2E 验收说明。
5. 如需在线管理，还缺少新增、修改、禁用禁限飞区的管理 RPC。

---

## 3. 当前数据库实际表结构

## 3.1 查询结果摘要

当前库表已存在，且以现有结构为准：

```text
airspace.no_fly_zone
airspace.temp_control_zone
```

当前记录数：

```text
airspace.no_fly_zone:       total = 1, enabled = 1
airspace.temp_control_zone: total = 1, active_now = 1
```

---

## 3.2 长期禁飞区：`airspace.no_fly_zone`

当前字段：

| 字段 | 类型 | 可空 | 默认值 | 说明 |
|---|---|---:|---|---|
| `id` | `bigint` | 否 | sequence | 主键 |
| `name` | `text` | 否 | 无 | 禁飞区名称 |
| `geom` | `geometry(MultiPolygon, 4326)` | 否 | 无 | 禁飞区平面范围 |
| `min_height` | `double precision` | 是 | `0` | 最低高度，单位米 |
| `max_height` | `double precision` | 是 | `null` | 最高高度，空值由刷新脚本使用默认最大高度 |
| `safety_buffer_m` | `double precision` | 是 | `0` | 水平安全缓冲距离，单位米 |
| `enabled` | `boolean` | 是 | `true` | 是否启用 |
| `created_at` | `timestamptz` | 是 | `now()` | 创建时间 |
| `updated_at` | `timestamptz` | 是 | `now()` | 更新时间 |

约束：

```text
no_fly_zone_pkey primary key (id)
```

索引：

```text
no_fly_zone_pkey        btree(id)
no_fly_zone_geom_gix    gist(geom)
no_fly_zone_enabled_idx btree(enabled)
```

进入障碍计算的条件：

```sql
enabled is true
and geom is not null
and not ST_IsEmpty(geom)
```

刷新脚本中的处理语义：

```text
footprint = geom 或 ST_Buffer(geom::geography, safety_buffer_m)::geometry
min_z     = coalesce(min_height, 0)
max_z     = coalesce(max_height, --default-zone-max-height)
priority  = 1000 固定值，由视图生成，不来自业务表字段
```

统一输出到 `citydb_grid.flight_obstacles` 时：

```text
source_kind = 'no_fly_zone'
source_id   = id::text
source_name = name
valid_from  = null
valid_to    = null
priority    = 1000
```

---

## 3.3 临时禁飞区：`airspace.temp_control_zone`

当前字段：

| 字段 | 类型 | 可空 | 默认值 | 说明 |
|---|---|---:|---|---|
| `id` | `bigint` | 否 | sequence | 主键 |
| `name` | `text` | 否 | 无 | 临时禁飞区名称 |
| `geom` | `geometry(MultiPolygon, 4326)` | 否 | 无 | 临时禁飞区平面范围 |
| `min_height` | `double precision` | 是 | `0` | 最低高度，单位米 |
| `max_height` | `double precision` | 是 | `null` | 最高高度，空值由刷新脚本使用默认最大高度 |
| `safety_buffer_m` | `double precision` | 是 | `0` | 水平安全缓冲距离，单位米 |
| `valid_from` | `timestamptz` | 否 | 无 | 生效开始时间 |
| `valid_to` | `timestamptz` | 否 | 无 | 生效结束时间 |
| `status` | `text` | 否 | `'planned'` | 状态 |
| `created_at` | `timestamptz` | 是 | `now()` | 创建时间 |
| `updated_at` | `timestamptz` | 是 | `now()` | 更新时间 |

约束：

```text
temp_control_zone_pkey primary key (id)
temp_control_zone_valid_window_chk check (valid_to > valid_from)
temp_control_zone_status_chk check (status in ('planned', 'active', 'cancelled'))
```

索引：

```text
temp_control_zone_pkey              btree(id)
temp_control_zone_geom_gix          gist(geom)
temp_control_zone_active_window_idx btree(status, valid_from, valid_to)
```

进入障碍计算的条件以当前脚本为准：

```sql
status in ('planned', 'active')
and planning_time >= valid_from
and planning_time < valid_to
and geom is not null
and not ST_IsEmpty(geom)
```

说明：

- 当前脚本不是只纳入 `status = 'active'`，而是纳入 `planned` 和 `active` 中当前规划时间有效的记录。
- `planning_time` 默认是 `now()`。
- 如果传入 `--planning-time`，则按指定规划时间筛选。
- `cancelled` 不进入障碍计算。

刷新脚本中的处理语义：

```text
footprint = geom 或 ST_Buffer(geom::geography, safety_buffer_m)::geometry
min_z     = coalesce(min_height, 0)
max_z     = coalesce(max_height, --default-zone-max-height)
priority  = 1100 固定值，由视图生成，不来自业务表字段
```

统一输出到 `citydb_grid.flight_obstacles` 时：

```text
source_kind = 'temp_control'
source_id   = id::text
source_name = name
valid_from  = valid_from
valid_to    = valid_to
priority    = 1100
```

---

## 4. 总体数据链路

### 4.1 长期禁飞区链路

```text
airspace.no_fly_zone
  ↓
citydb_grid.obstacles_no_fly_zones
  ↓
citydb_grid.flight_obstacles
  ↓
public.flight_obstacles / PostgREST RPC / 前端 / 路径规划
```

### 4.2 临时禁飞区链路

```text
airspace.temp_control_zone
  ↓
citydb_grid.obstacles_temp_control_active
  ↓
citydb_grid.flight_obstacles
  ↓
public.flight_obstacles / PostgREST RPC / 前端 / 路径规划
```

### 4.3 统一障碍链路

```text
citydb_grid.obstacles_buildings
citydb_grid.obstacles_terrain
citydb_grid.obstacles_no_fly_zones
citydb_grid.obstacles_temp_control_active
  ↓ union all
citydb_grid.flight_obstacles
  ↓
public.flight_obstacles(id, grids)
citydb_grid.flight_obstacles_codes_view
public/citydb.list_flight_obstacles_gger(...)
```

---

## 5. geomgrids 生成策略

长期禁飞区与临时禁飞区共用 airspace polygon 处理逻辑。

推荐模式：

```bash
--airspace-mode polygon-prism
```

处理流程：

```text
MultiPolygon footprint + safety_buffer_m + min_height + max_height
  ↓
3D polygon prism
  ↓
ST_AsGrids3D
  ↓
geomgrids
  ↓
citydb_grid.obstacles_no_fly_zones / obstacles_temp_control_active
```

保留回退模式：

```bash
--airspace-mode bbox
```

默认推荐 `polygon-prism`，因为它可以避免把凹多边形、L 形多边形的缺口错误填充为完整 envelope bbox。

---

## 6. 刷新模式设计

## 6.1 两个刷新层级

禁限飞区链路中存在两个物化视图层级：

1. 单来源物化视图：
   - `citydb_grid.obstacles_no_fly_zones`
   - `citydb_grid.obstacles_temp_control_active`
2. 统一总障碍物化视图：
   - `citydb_grid.flight_obstacles`

因此调试时可以分阶段刷新；生产日常使用不一定需要两步。

---

## 6.2 首次接入 / 调试模式

### 只刷新长期禁飞区单来源

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source no-fly-zones \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

用途：

- 验证 `airspace.no_fly_zone` 数据。
- 验证 `safety_buffer_m` 和高度字段处理。
- 验证 polygon-prism geomgrids 生成。
- 单独检查 `citydb_grid.obstacles_no_fly_zones`。

### 只刷新临时禁飞区单来源

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source temp-control \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

用途：

- 验证 `airspace.temp_control_zone` 数据。
- 验证 `status in ('planned', 'active')` 与时间窗口过滤。
- 单独检查 `citydb_grid.obstacles_temp_control_active`。

### 最后执行全量汇总

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

---

## 6.3 日常全量刷新模式

生产或日常初始化推荐一步完成：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

预期依次重建 / 刷新：

```text
citydb_grid.obstacles_buildings
citydb_grid.obstacles_terrain
citydb_grid.obstacles_no_fly_zones
citydb_grid.obstacles_temp_control_active
citydb_grid.flight_obstacles
public.flight_obstacles
citydb_grid.flight_obstacles_codes_view
```

适用场景：

- 首次部署。
- 全量数据变化。
- 不在意刷新耗时。
- 希望所有来源状态完全一致。

---

## 6.4 高频变更优化：`--refresh-total`

已实现参数：

```bash
--refresh-total
```

语义：

```text
刷新当前指定 source 的单来源物化视图后，继续刷新统一总障碍视图，
但不重算其他 source。
```

### 长期禁飞区快速刷新

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source no-fly-zones \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

目标语义：

```text
刷新 citydb_grid.obstacles_no_fly_zones
刷新 citydb_grid.flight_obstacles
刷新 public.flight_obstacles / codes view
不刷新 buildings / terrain / temp-control
```

### 临时禁飞区快速刷新

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source temp-control \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

目标语义：

```text
刷新 citydb_grid.obstacles_temp_control_active
刷新 citydb_grid.flight_obstacles
刷新 public.flight_obstacles / codes view
不刷新 buildings / terrain / no-fly-zones
```

---

## 6.5 组合来源优化：`--source airspace`

已实现组合 source：

```bash
--source airspace
```

推荐命令：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source airspace \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

目标语义：

```text
刷新 citydb_grid.obstacles_no_fly_zones
刷新 citydb_grid.obstacles_temp_control_active
刷新 citydb_grid.flight_obstacles
刷新 public.flight_obstacles / codes view
不刷新 buildings / terrain
```

适用场景：

- 空域禁限飞频繁变化。
- 建筑和地形稳定。
- 希望快速让前端和路径规划看到最新空域限制。

---

## 7. 刷新脚本实现状态

主要修改文件：

```text
scripts/refresh_citydb_obstacle_grids.py
```

### 7.1 CLI 参数

已新增：

```python
parser.add_argument(
    "--refresh-total",
    action="store_true",
    help="After refreshing selected source view(s), also refresh/rebuild the unified flight_obstacles view without refreshing unrelated source views.",
)
```

扩展 `--source` 可选值：

```text
all
buildings
terrain
no-fly-zones
temp-control
airspace
```

其中 `airspace` 是组合来源，包含：

```text
no-fly-zones
temp-control
```

---

### 7.2 刷新流程

已实现逻辑：

```text
if source == all:
  refresh buildings
  refresh terrain
  refresh no-fly-zones
  refresh temp-control
  refresh total

elif source == airspace:
  refresh no-fly-zones
  refresh temp-control
  if refresh_total:
    refresh total

else:
  refresh selected source
  if refresh_total:
    refresh total
```

---

### 7.3 参数语义

当前实现语义：

1. `--source all` 隐式刷新统一总视图、wrapper 和 codes view。
2. `--source no-fly-zones|temp-control|airspace --refresh-total` 会刷新选中来源后重建统一总视图、wrapper 和 codes view。
3. `--source no-fly-zones|temp-control|airspace` 不带 `--refresh-total` 时只重建/刷新对应单来源视图；重建模式下会先移除依赖的统一总视图，完成后需再运行 `--refresh-total` 或 `--source all` 恢复统一总视图。
4. `--refresh-only` 模式下不改变 DDL，只刷新已有物化视图。

---

## 8. 数据导入

已新增通用导入脚本：

```text
scripts/seed_airspace_zones.py
```

该脚本已适配现有库表结构，不插入当前不存在的 `priority` 字段。

支持两类数据：

```bash
--kind no-fly-zone
--kind temp-control
```

通用参数：

```text
--dsn
--kind
--name
--min-height
--max-height
--safety-buffer-m
--geojson
```

临时禁飞区额外参数：

```text
--valid-from
--valid-to
--status planned|active|cancelled
```

### 8.1 导入长期禁飞区

```bash
uv run scripts/seed_airspace_zones.py \
  --kind no-fly-zone \
  --name 花果山核心禁飞区 \
  --min-height 0 \
  --max-height 300 \
  --safety-buffer-m 20 \
  --geojson data/airspace/huaguoshan_no_fly_zone.geojson
```

写入字段：

```text
name, geom, min_height, max_height, safety_buffer_m, enabled
```

### 8.2 导入临时禁飞区

```bash
uv run scripts/seed_airspace_zones.py \
  --kind temp-control \
  --name 花果山临时活动管制区 \
  --min-height 0 \
  --max-height 500 \
  --safety-buffer-m 20 \
  --valid-from "2026-07-02T08:00:00+08:00" \
  --valid-to "2026-07-02T18:00:00+08:00" \
  --status active \
  --geojson data/airspace/huaguoshan_temp_control.geojson
```

写入字段：

```text
name, geom, min_height, max_height, safety_buffer_m, valid_from, valid_to, status
```

### 8.3 示例数据

已新增目录：

```text
data/airspace/
```

已新增示例文件：

```text
data/airspace/huaguoshan_no_fly_zone.geojson
data/airspace/huaguoshan_temp_control.geojson
```

示例 GeoJSON 应输出 MultiPolygon 或可转换为 MultiPolygon；导入脚本需要将 Polygon 统一转为 MultiPolygon 后写入。

---

## 9. PostgREST RPC 计划

已有 RPC：

```text
backend/create_flight_obstacles_gger_rpc.sql
```

当前可通过 `p_source_kind` 查询单一来源：

```json
{
  "p_source_kind": "no_fly_zone",
  "p_limit": 20,
  "p_include_boxes": true
}
```

或：

```json
{
  "p_source_kind": "temp_control",
  "p_limit": 20,
  "p_include_boxes": true
}
```

短期方案：前端分别请求 `no_fly_zone` 与 `temp_control`，再合并结果。

中期可选增强：新增数组参数：

```sql
p_source_kinds text[] default null
```

示例请求：

```json
{
  "p_source_kinds": ["no_fly_zone", "temp_control"],
  "p_limit": 200,
  "p_include_boxes": true
}
```

P0 阶段不强制修改 RPC。

---

## 10. 可选管理 RPC

如果需要前端在线新增、编辑、禁用禁限飞区，新增：

```text
backend/create_airspace_zone_admin_rpc.sql
```

建议 RPC：

```text
citydb.create_no_fly_zone(...)
citydb.update_no_fly_zone(...)
citydb.disable_no_fly_zone(p_id bigint)
citydb.create_temp_control_zone(...)
citydb.update_temp_control_zone(...)
citydb.disable_temp_control_zone(p_id bigint)
citydb.list_airspace_zones(...)
```

注意：管理 RPC 也必须按现有表结构实现，不依赖 `priority` 字段。

安全建议：

1. 管理 RPC 不授予 `web_anon`。
2. 使用独立角色，例如 `web_admin`。
3. P0 阶段优先实现只读展示，不开放匿名写入。

---

## 11. 前端实施计划

主要修改文件：

```text
frontend/tianditu-3d.html
```

### 11.1 图层与文案调整

当前已有：

```text
禁飞区
临时管制
```

建议调整为：

```text
长期禁飞区
临时禁飞/管制
```

或保持按钮短文案，但在详情面板中明确类型。

---

### 11.2 样式增强

建议颜色：

```text
长期禁飞区 no_fly_zone：#ff3b30
临时禁飞 temp_control：#ffb000
```

样式策略：

- 长期禁飞区：红色、高 alpha、较粗线框。
- 临时禁飞区：橙黄色、高 alpha、较粗线框。
- 地形障碍保持低 alpha，避免遮挡空域重点。

---

### 11.3 详情面板增强

长期禁飞区显示：

```text
类型：长期禁飞区
名称
Source ID
Detail Level
Cell Count
Priority = 1000
```

临时禁飞区显示：

```text
类型：临时禁飞区 / 临时管制
名称
Source ID
有效开始时间 valid_from
有效结束时间 valid_to
Detail Level
Cell Count
Priority = 1100
```

说明：当前 RPC 返回的是障碍视图字段，不直接返回业务表的 `min_height`、`max_height`、`safety_buffer_m`。高度范围可从 `gger_grids_with_box` 的 cell bbox 解析得到整体 bounds 后展示。

---

### 11.4 空数据提示

当只看长期禁飞区且无结果时：

```text
当前没有启用的长期禁飞区。请先导入 airspace.no_fly_zone 并刷新障碍视图。
```

当只看临时禁飞区且无结果时：

```text
当前没有当前规划时间内有效的临时禁飞区。请检查 airspace.temp_control_zone 的 status、valid_from、valid_to，并刷新障碍视图。
```

---

## 12. 路径规划接入

现有兼容 wrapper：

```text
public.flight_obstacles(id, grids)
```

路径规划仍可使用：

```sql
select ST_FindGridsPath(
  start_cell,
  end_cell,
  'public.flight_obstacles',
  'grids'
);
```

只要禁限飞区已经进入 `citydb_grid.flight_obstacles`，路径规划会自动避开：

- 建筑
- 地形
- 长期禁飞区
- 当前规划时间有效的临时禁飞区

P0 阶段不需要改路径规划接口。

---

## 13. 文档更新计划

新增 / 更新本文档：

```text
docs/airspace_no_fly_feature_plan.md
```

同步更新：

```text
docs/multi_source_flight_obstacles_plan.md
docs/refined_flight_obstacles_plan.md
```

更新内容：

1. 禁飞区不只包含 `no_fly_zone`，也包含 `temp_control`。
2. 业务表以当前库表为准：`geom geometry(MultiPolygon, 4326)`、`safety_buffer_m`、无 `priority` 字段。
3. 长期禁飞区视图 priority 固定为 `1000`。
4. 临时禁飞区视图 priority 固定为 `1100`。
5. 临时禁飞区当前纳入条件为 `status in ('planned', 'active')` 且规划时间落入有效窗口。
6. 两步刷新不是强制，只用于调试和分阶段验收。
7. 日常推荐 `--source all`。
8. 高频空域变更推荐：
   - `--source no-fly-zones --refresh-total`
   - `--source temp-control --refresh-total`
   - `--source airspace --refresh-total`
9. 前端展示与 RPC 均保持 GGER-only。

---

## 14. E2E 验收计划

## 14.1 数据导入验收

长期禁飞区：

```sql
select id, name, min_height, max_height, safety_buffer_m, enabled, created_at, updated_at
from airspace.no_fly_zone
order by id desc;
```

临时禁飞区：

```sql
select id, name, min_height, max_height, safety_buffer_m, valid_from, valid_to, status, created_at, updated_at
from airspace.temp_control_zone
order by id desc;
```

---

## 14.2 全量刷新验收

执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source all \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

检查：

```sql
select source_kind, count(*)
from citydb_grid.flight_obstacles
group by source_kind
order by source_kind;
```

预期包含：

```text
building
terrain
no_fly_zone
temp_control
```

无业务数据的来源可以为 0 或无记录，但相关视图应可查询。

---

## 14.3 长期禁飞区快速刷新验收

修改或新增一条长期禁飞区后执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source no-fly-zones \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

检查单来源：

```sql
select count(*)
from citydb_grid.obstacles_no_fly_zones;
```

检查总视图：

```sql
select source_kind, source_id, source_name, priority
from citydb_grid.flight_obstacles
where source_kind = 'no_fly_zone';
```

预期：

```text
priority = 1000
```

---

## 14.4 临时禁飞区快速刷新验收

修改或新增一条 `status in ('planned', 'active')` 且当前规划时间有效的临时禁飞区后执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source temp-control \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

检查单来源：

```sql
select count(*)
from citydb_grid.obstacles_temp_control_active;
```

检查总视图：

```sql
select source_kind, source_id, source_name, valid_from, valid_to, priority
from citydb_grid.flight_obstacles
where source_kind = 'temp_control';
```

预期：

```text
priority = 1100
```

---

## 14.5 RPC 验收

长期禁飞区：

```bash
curl -X POST http://10.1.109.151:13000/rpc/list_flight_obstacles_gger \
  -H 'Content-Type: application/json' \
  -d '{"p_source_kind":"no_fly_zone","p_limit":20,"p_include_boxes":true}'
```

临时禁飞区：

```bash
curl -X POST http://10.1.109.151:13000/rpc/list_flight_obstacles_gger \
  -H 'Content-Type: application/json' \
  -d '{"p_source_kind":"temp_control","p_limit":20,"p_include_boxes":true}'
```

验收点：

- HTTP 200。
- 返回 JSON 数组。
- `source_kind` 正确。
- 包含 `gger_grids_with_box`。
- 不包含 BGC 字段。

---

## 14.6 前端验收

打开：

```text
frontend/tianditu-3d.html
```

验收长期禁飞区：

1. 开启“飞行障碍”。
2. 只保留“长期禁飞区”。
3. 点击“刷新障碍”。
4. 地图出现红色 GGER 3D 线框。
5. 点击线框后，右侧面板显示长期禁飞区详情。
6. 点击“定位障碍”可飞到对应范围。

验收临时禁飞区：

1. 开启“飞行障碍”。
2. 只保留“临时禁飞/管制”。
3. 点击“刷新障碍”。
4. 地图出现橙色 GGER 3D 线框。
5. 点击线框后，右侧面板显示 `valid_from` / `valid_to`。
6. `cancelled` 或不在规划时间窗口内的临时禁飞区不应进入展示结果。

---

## 14.7 路径规划验收

构造一组穿越禁限飞区的起终点，调用：

```sql
select ST_FindGridsPath(
  start_cell,
  end_cell,
  'public.flight_obstacles',
  'grids'
);
```

验收点：

1. 路径不会穿越长期禁飞区。
2. 路径不会穿越当前规划时间有效的临时禁飞区。
3. `cancelled` 或不在有效时间窗口内的临时禁飞区不影响当前规划。

---

## 15. 推荐实施顺序

### P0：只读展示与避障接入

已完成：

1. 按当前库表结构同步本文档。
2. 新增 `scripts/seed_airspace_zones.py`，适配现有字段。
3. 新增示例 GeoJSON：
   - `data/airspace/huaguoshan_no_fly_zone.geojson`
   - `data/airspace/huaguoshan_temp_control.geojson`
4. 给 `scripts/refresh_citydb_obstacle_grids.py` 增加：
   - `--refresh-total`
   - `--source airspace`
5. 增强前端禁限飞样式和详情面板。
6. 完成代码语法与 dry-run 基础验证。
7. 使用 `_pi_validation_` 示例长期禁飞区和临时禁飞区完成数据库 E2E 验证，并按要求保留验证数据。
8. 验证 `--source airspace --refresh-total` 重建链路。
9. 验证 `--refresh-only --source airspace --refresh-total` 快速刷新链路。
10. 验证 PostgREST `list_flight_obstacles_gger` 可分别查询 `no_fly_zone` 与 `temp_control`，且保持 GGER-only。
11. 完成浏览器级前端验证：飞行障碍图层可加载 18 个建筑 + 1 个长期禁飞区 + 1 个临时禁飞/管制；关闭建筑后可单独展示 2 条禁限飞障碍详情。
12. 前端验证截图：`/var/folders/8b/4l2w6ygx6cn3t1gq22lvfw0w0000gn/T/screenshot-2026-07-02T02-47-12-889Z.png`。

待按真实业务数据执行：

1. 将 `_pi_validation_` 示例数据替换为正式禁限飞区数据。
2. 完成路径规划绕飞 E2E 验收。

### P1：管理能力

1. 新增 `backend/create_airspace_zone_admin_rpc.sql`。
2. 提供禁限飞区新增、编辑、禁用、列表查询 RPC。
3. 增加权限控制，避免匿名写入。
4. 可选实现前端绘制 polygon 并保存。

### P2：高级能力

1. RPC 支持 `p_source_kinds text[]`。
2. 临时禁飞区支持按指定规划时间查询和前端切换。
3. 前端显示临时禁飞区状态：未开始、有效中、即将过期、已过期。
4. 如确实需要每个禁限飞区单独优先级，再评估是否给业务表增加 `priority` 字段；P0 不做表结构迁移。
5. 引入 `obstacle_work.airspace_volume_piece` staging 表，用于审计、增量刷新和复杂 polygon 分片。

---

## 16. 最终交付物清单

已新增：

```text
scripts/seed_airspace_zones.py
data/airspace/huaguoshan_no_fly_zone.geojson
data/airspace/huaguoshan_temp_control.geojson
```

已修改：

```text
scripts/refresh_citydb_obstacle_grids.py
frontend/tianditu-3d.html
docs/airspace_no_fly_feature_plan.md
docs/multi_source_flight_obstacles_plan.md
docs/refined_flight_obstacles_plan.md
```

可选新增：

```text
backend/create_airspace_zone_admin_rpc.sql
```

---

## 17. 结论

临时禁飞区应与长期禁飞区一并纳入计划。当前数据库已经存在两张业务表：

```text
airspace.no_fly_zone
airspace.temp_control_zone
```

实施时应以现有字段为准：

```text
geom = geometry(MultiPolygon, 4326)
safety_buffer_m = 水平安全缓冲
priority 不在业务表中，由障碍视图固定生成：no_fly_zone=1000，temp_control=1100
```

最终链路保持：

```text
长期禁飞区 no_fly_zone
临时禁飞区 temp_control
  ↓
polygon-prism geomgrids
  ↓
citydb_grid.flight_obstacles
  ↓
前端展示 + RPC 查询 + 路径规划避障
```

P0 阶段优先完成数据导入、增量刷新、前端展示和 E2E 验收；随后再扩展管理 RPC 和前端在线编辑能力。
