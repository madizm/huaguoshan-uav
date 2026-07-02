# 飞行路径规划与管理功能实施计划

## 1. 目标

新增“飞行路径规划”能力，支持用户在前端或 API 中设置：

- **起点**：飞行路径第一个控制点。
- **终点**：飞行路径最后一个控制点。
- **途径点 / 途经点**：按顺序经过的中间控制点，可为空，可多个。

并提供路径规划结果的管理能力：

1. 新建并保存路径规划方案。
2. 查询方案列表、方案详情和最近计算结果。
3. 修改起点、终点、途径点及规划参数。
4. 删除 / 归档方案。
5. 触发路径计算 / 重新计算。
6. 将路径结果返回给前端用于三维地图展示。

路径规划继续复用当前障碍物体系：

```text
citydb_grid.flight_obstacles
public.flight_obstacles(id, grids)
```

第一版优先接入 iBEST-DB / geomgrids 路径函数：

```sql
ST_FindGridsPath(...)
ST_RouteFromGridsPath(...)
ST_SmoothRouteFromGridsPath(...)
```

同时结合 `docs/GEOVIS iBEST-DB V6.1.0 轨迹功能速查.md` 中的 `best_geotrack` 轨迹能力，把规划结果进一步沉淀为 `trajectory` 对象，用于后续轨迹管理、时空查询、长度统计、压缩、相似度分析和实飞轨迹对比。

---

## 2. 范围与非目标

## 2.1 本期范围

- 支持单条飞行路径方案的起点、终点、途径点管理。
- 支持按途径点顺序分段规划：

```text
start -> waypoint_1 -> waypoint_2 -> ... -> end
```

- 支持保存规划输入、规划参数、规划状态和规划结果摘要。
- 支持查询：
  - 方案列表
  - 方案详情
  - 控制点列表
  - 最近一次成功规划结果
- 支持前端在三维地图上绘制控制点和规划路径。

## 2.2 暂不包含

- 多机协同路径规划。
- 动态实时重规划。
- 飞控协议下发。
- 气象、通信链路、能耗、电池模型等高级约束。
- 复杂曲线航迹编辑器。第一版以点序列 + 网格路径结果为主。

---

## 3. 总体架构

```text
前端 tianditu-3d.html
  ├─ 设置起点 / 终点 / 途径点
  ├─ 保存路径方案
  ├─ 查询路径方案列表 / 详情
  └─ 展示规划结果
          ↓ PostgREST RPC / REST
backend SQL functions
  ├─ flight_path.create_plan(...)
  ├─ flight_path.update_plan(...)
  ├─ flight_path.list_plans(...)
  ├─ flight_path.get_plan(...)
  ├─ flight_path.delete_plan(...)
  └─ flight_path.compute_plan(...)
          ↓ PostgreSQL / PostGIS / iBEST-DB
flight_path.plan
flight_path.plan_point
flight_path.plan_result
  └─ route_traj trajectory
          ↓ 读取障碍
public.flight_obstacles(id, grids)
          ↓
ST_FindGridsPath 分段规划
          ↓
GT_MakeTrajectory / GT_length / GT_2DIntersects / GT_Compress
```

设计原则：

1. **输入和结果分离**：用户保存的是路径方案，计算输出保存为结果版本。
2. **途径点有序**：所有控制点通过 `seq` 保持严格顺序。
3. **高度语义明确**：路径输入高度字段必须标注高程基准，默认沿用项目 terrain / airspace 的统一约束。
4. **可重复计算**：每次计算记录规划参数、障碍版本和结果摘要，方便追溯。
5. **规划路径和轨迹对象并存**：`grid_path` 保留路径规划原始网格结果，`route_geom` 便于前端展示，`route_traj` 便于 iBEST-DB 轨迹分析。
6. **前端展示轻量**：列表查询不返回完整路径 geometry / trajectory，详情或结果接口再返回。

---

## 4. 数据模型设计

建议新增独立 schema：

```sql
create schema if not exists flight_path;
```

iBEST-DB 轨迹能力依赖扩展：

```sql
create extension if not exists best_iot cascade;
create extension if not exists best_geotrack cascade;
```

说明：当前项目路径规划本身依赖 geomgrids / `ST_FindGridsPath`；轨迹管理能力建议显式安装 `best_geotrack`，因为 `trajectory` 类型和 `GT_*` 函数由该扩展暴露。

## 4.1 路径方案表：`flight_path.plan`

```sql
create table if not exists flight_path.plan (
  id bigserial primary key,
  name text not null,
  description text,

  status text not null default 'draft',
  -- draft / planned / computed / failed / archived

  detail_level integer not null default 19,
  cruise_height_m double precision,
  height_datum text not null default 'AMSL',
  -- AMSL / AGL / ELLIPSOID，第一版建议只允许 AMSL，AGL 后续扩展

  planning_time timestamptz not null default now(),
  has_below boolean not null default false,
  safety_buffer_m double precision not null default 0,

  metadata jsonb not null default '{}'::jsonb,

  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_computed_at timestamptz
);
```

建议约束：

```sql
alter table flight_path.plan
  add constraint flight_path_plan_status_chk
  check (status in ('draft', 'planned', 'computed', 'failed', 'archived'));

alter table flight_path.plan
  add constraint flight_path_plan_height_datum_chk
  check (height_datum in ('AMSL', 'AGL', 'ELLIPSOID'));
```

建议索引：

```sql
create index if not exists flight_path_plan_status_idx
  on flight_path.plan(status);

create index if not exists flight_path_plan_updated_at_idx
  on flight_path.plan(updated_at desc);
```

## 4.2 控制点表：`flight_path.plan_point`

起点、终点、途径点统一保存为控制点。

```sql
create table if not exists flight_path.plan_point (
  id bigserial primary key,
  plan_id bigint not null references flight_path.plan(id) on delete cascade,

  point_role text not null,
  -- start / waypoint / end

  seq integer not null,
  name text,

  lon double precision not null,
  lat double precision not null,
  height_m double precision,
  height_datum text not null default 'AMSL',

  geom geometry(PointZ, 4326),
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique(plan_id, seq)
);
```

建议约束：

```sql
alter table flight_path.plan_point
  add constraint flight_path_plan_point_role_chk
  check (point_role in ('start', 'waypoint', 'end'));

alter table flight_path.plan_point
  add constraint flight_path_plan_point_lon_chk
  check (lon >= -180 and lon <= 180);

alter table flight_path.plan_point
  add constraint flight_path_plan_point_lat_chk
  check (lat >= -90 and lat <= 90);
```

写入规则：

1. 每个 `plan_id` 必须且只能有一个 `start`。
2. 每个 `plan_id` 必须且只能有一个 `end`。
3. `waypoint` 可为 0..N 个。
4. `seq` 必须连续排序：

```text
0: start
1..N: waypoint
N+1: end
```

`geom` 建议由 trigger 自动生成：

```sql
ST_SetSRID(ST_MakePoint(lon, lat, coalesce(height_m, plan.cruise_height_m, 0)), 4326)
```

## 4.3 规划结果表：`flight_path.plan_result`

```sql
create table if not exists flight_path.plan_result (
  id bigserial primary key,
  plan_id bigint not null references flight_path.plan(id) on delete cascade,

  result_status text not null,
  -- success / failed

  detail_level integer not null,
  planning_time timestamptz not null,
  obstacle_table text not null default 'flight_obstacles',
  obstacle_field text not null default 'grids',

  grid_path gridcell[],
  route_geom geometry,
  smooth_route_geom geometry,
  route_traj trajectory,
  smooth_route_traj trajectory,

  segment_count integer not null default 0,
  grid_cell_count integer,
  traj_point_count integer,
  distance_m double precision,
  duration_s double precision,
  error_message text,

  params jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
```

建议索引：

```sql
create index if not exists flight_path_plan_result_plan_idx
  on flight_path.plan_result(plan_id, created_at desc);

create index if not exists flight_path_plan_result_route_gix
  on flight_path.plan_result using gist(route_geom);

create index if not exists flight_path_plan_result_route_traj_2dt_gix
  on flight_path.plan_result using gist(route_traj trajgist_ops_2dt);
```

轨迹字段说明：

- `route_geom` / `smooth_route_geom` 当前实现使用通用 `geometry` 类型，而不是强制 `LineStringZ` typmod；原因是 iBEST-DB 的极短路径可能先返回 `Point`，实现会尽量回退为起终点 `LineString`，但保留通用类型可避免 Z/M 维度差异导致结果落库失败。
- `route_traj`：由 `route_geom` 和规划时间线构造的 iBEST-DB `trajectory`，用于轨迹查询和分析。
- `smooth_route_traj`：由 `smooth_route_geom` 构造，主要用于展示与平滑后轨迹分析。
- `traj_point_count`：可由 `GT_leafCount(route_traj)` 得到。
- `distance_m`：优先由 `GT_length(route_traj)` 计算；如果轨迹对象构造失败，则回退到 PostGIS 长度计算。
- `duration_s`：第一版可按规划参数中的巡航速度估算；没有速度时允许为空。

---

## 5. 路径计算流程

## 5.1 输入点序列

读取控制点并按 `seq` 排序：

```sql
select *
from flight_path.plan_point
where plan_id = :plan_id
order by seq;
```

校验：

1. 控制点数量不少于 2。
2. 第一项必须是 `start`。
3. 最后一项必须是 `end`。
4. 中间项必须全部是 `waypoint`。
5. 所有点必须具备可计算高度：`height_m` 或方案级 `cruise_height_m`。

高度基准处理：

- `AMSL`：`height_m` 直接作为海拔高度传给 `ST_AsGridcell3D`。
- `AGL`：后端通过 `terrain.dem_tile` 采样点位地形高程，并转换为 `terrain_height_amsl + height_m` 后再规划。
- 由于当前地形障碍是保守的 geomgrid prism，点位精确 DEM 高程 + AGL 仍可能落入同一个地形障碍 block。当前实现会对 AGL 点位自动向上抬升到不再命中 `source_kind = 'terrain'` 的高度，再参与规划；建筑、禁飞区、临时管制区仍会正常阻断。

## 5.2 分段调用 `ST_FindGridsPath`

对相邻点两两规划：

```text
segment_0 = start -> waypoint_1
segment_1 = waypoint_1 -> waypoint_2
...
segment_n = waypoint_n -> end
```

每段输入：

```sql
ST_AsGridcell3D(lon, lat, height_m, detail_level)
```

每段规划：

```sql
select ST_FindGridsPath(
  :start_cell,
  :end_cell,
  'flight_obstacles',
  'grids',
  :has_below
);
```

将所有 segment 的 `gridcell[]` 拼接为完整路径。拼接时去掉后一段第一个 cell，避免段间重复。

## 5.3 生成路径 geometry

优先生成两类结果：

```sql
ST_RouteFromGridsPath(:grid_path)
ST_SmoothRouteFromGridsPath(:grid_path)
```

如果 iBEST-DB 支持带原始起终点参数的 `ST_RouteFromGridsPath`，则优先使用带点匹配版本，以减少起点和终点偏移。

## 5.4 构造 iBEST-DB 轨迹对象

结合 `GEOVIS iBEST-DB V6.1.0 轨迹功能速查`，规划结果应从 `LineStringZ` 进一步构造为 `trajectory`：

```sql
GT_MakeTrajectory(
  route_geom,
  timeline,
  attrs_json
)
```

## 5.4.1 时间线生成

第一版规划输入通常只有点和高度，没有真实飞行时间线。建议按以下优先级生成：

1. 如果用户提供每个控制点的计划到达时间，则按控制点分段插值。
2. 如果用户提供巡航速度 `cruise_speed_mps`，则按路径长度估算每个轨迹点时间。
3. 如果两者都没有，则使用 `planning_time` 作为起始时间，并按默认速度生成估算时间线。

建议在 `plan.metadata` 或后续独立字段中保存：

```json
{
  "cruise_speed_mps": 10.0,
  "timeline_mode": "estimated"
}
```

## 5.4.2 轨迹属性

`GT_MakeTrajectory` 的 `attrs_json.leafcount` 必须等于轨迹点数量。建议第一版写入以下属性：

| 属性 | 类型 | 含义 |
|---|---|---|
| `seq` | integer | 轨迹点序号 |
| `height_m` | float | 点高度 |
| `speed_mps` | float | 估算速度 |
| `segment_index` | integer | 所属分段 |
| `point_kind` | string | start / waypoint / path / end |

最小构造示例：

```sql
select GT_MakeTrajectory(
  :route_geom,
  :timeline,
  :attrs_json::cstring
);
```

## 5.4.3 轨迹分析落库

构造成功后同步计算并保存：

```sql
GT_leafCount(route_traj)  -- traj_point_count
GT_length(route_traj)     -- distance_m，单位米
GT_duration(route_traj)   -- 可换算 duration_s
```

可选优化：

```sql
GT_Compress(route_traj, :dist_threshold)
GT_deviation(route_traj, compressed_traj)
```

压缩结果不应替代原始规划结果。建议未来新增 `compressed_route_traj` 或只在导出 / 展示时临时压缩。

## 5.5 失败处理

任一分段失败时：

1. `plan_result.result_status = 'failed'`
2. 记录失败 segment 序号、起点、终点和错误信息到 `error_message / params`。
3. `plan.status = 'failed'`
4. 前端提示用户调整高度、途径点或障碍时间。

---

## 6. API / RPC 设计

第一版优先使用 PostgREST RPC，便于和当前 backend SQL 文件保持一致。

当前实现文件：`backend/create_flight_path_planning_rpc.sql`。

说明：实现 schema 为 `flight_path`，同时提供 `citydb.*` 包装函数以适配当前 `pgrest.conf` 中的默认 RPC schema。PostgREST endpoint 使用包装函数名，例如：

```text
POST /rpc/create_flight_path_plan
POST /rpc/list_flight_path_plans
POST /rpc/get_flight_path_plan
POST /rpc/compute_flight_path_plan
POST /rpc/get_latest_flight_path_result
```

## 6.1 新建并保存方案

```sql
flight_path.create_plan(
  p_name text,
  p_description text,
  p_detail_level integer,
  p_cruise_height_m double precision,
  p_height_datum text,
  p_planning_time timestamptz,
  p_points jsonb
) returns bigint
```

PostgREST 包装函数：

```sql
citydb.create_flight_path_plan(...)
```

`p_points` 示例：

```json
[
  {"role":"start", "name":"起点", "lon":119.23, "lat":34.66, "height_m":120},
  {"role":"waypoint", "name":"途径点1", "lon":119.25, "lat":34.65, "height_m":120},
  {"role":"end", "name":"终点", "lon":119.30, "lat":34.63, "height_m":120}
]
```

## 6.2 更新方案

```sql
flight_path.update_plan(
  p_plan_id bigint,
  p_name text,
  p_description text,
  p_detail_level integer,
  p_cruise_height_m double precision,
  p_height_datum text,
  p_planning_time timestamptz,
  p_points jsonb
) returns void
```

PostgREST 包装函数：

```sql
citydb.update_flight_path_plan(...)
```

更新策略：

- 方案基础字段直接更新。
- 控制点采用“整组替换”策略：删除旧点，按新 `p_points` 重建。
- 更新后将 `status` 重置为 `planned` 或 `draft`，避免旧结果被误认为当前结果。

## 6.3 查询方案列表

```sql
flight_path.list_plans(
  p_keyword text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
```

PostgREST 包装函数：

```sql
citydb.list_flight_path_plans(...)
```

返回字段建议：

```text
id
name
description
status
detail_level
cruise_height_m
height_datum
planning_time
point_count
waypoint_count
last_computed_at
updated_at
```

列表不返回完整 geometry，避免响应过大。

## 6.4 查询方案详情

```sql
flight_path.get_plan(p_plan_id bigint)
```

PostgREST 包装函数：

```sql
citydb.get_flight_path_plan(...)
```

返回：

```json
{
  "plan": {...},
  "points": [...],
  "latest_result": {
    "id": 1,
    "result_status": "success",
    "distance_m": 1234.5,
    "grid_cell_count": 512,
    "created_at": "..."
  }
}
```

## 6.5 查询最新路径结果

```sql
flight_path.get_latest_result(p_plan_id bigint)
```

返回前端展示所需字段：

```text
plan_id
result_id
result_status
route_geojson
smooth_route_geojson
distance_m
duration_s
grid_cell_count
traj_point_count
error_message
created_at
```

其中 geometry 输出建议使用：

```sql
ST_AsGeoJSON(route_geom)::jsonb
ST_AsGeoJSON(smooth_route_geom)::jsonb
```

轨迹对象不直接通过 JSON 返回；如需返回轨迹统计信息，通过 `GT_*` 函数转换为摘要字段：

```sql
GT_leafCount(route_traj) as traj_point_count,
GT_length(route_traj) as distance_m,
GT_duration(route_traj) as duration
```

## 6.6 删除 / 归档方案

默认采用软删除：

```sql
flight_path.archive_plan(p_plan_id bigint) returns void
```

将 `status = 'archived'`。

如确需物理删除，再提供管理员接口：

```sql
flight_path.delete_plan(p_plan_id bigint) returns void
```

## 6.7 触发计算

```sql
flight_path.compute_plan(p_plan_id bigint) returns bigint
```

返回 `plan_result.id`。

PostgREST 包装函数：

```sql
citydb.compute_flight_path_plan(...)
```

## 6.8 基于 trajectory 的路径结果查询

结合 iBEST-DB 轨迹索引能力，可补充以下查询 RPC：

### 6.8.1 按时间范围查询

```sql
flight_path.search_results_by_time(
  p_start_time timestamp,
  p_end_time timestamp,
  p_limit integer default 50,
  p_offset integer default 0
)
```

内部可使用：

```sql
route_traj #&# GT_MakeBoxT(p_start_time, p_end_time)
```

### 6.8.2 按空间范围查询

```sql
flight_path.search_results_by_bbox(
  p_xmin double precision,
  p_ymin double precision,
  p_xmax double precision,
  p_ymax double precision,
  p_start_time timestamp default '-infinity',
  p_end_time timestamp default 'infinity',
  p_limit integer default 50,
  p_offset integer default 0
)
```

内部可使用：

```sql
GT_2DIntersects(
  route_traj,
  ST_MakeEnvelope(p_xmin, p_ymin, p_xmax, p_ymax, 4326),
  p_start_time,
  p_end_time
)
```

### 6.8.3 路径相似度 / 重复路径查询

后续可基于 `GT_lcsDistance`、`GT_JaccardSimilarity` 实现：

```sql
flight_path.find_similar_results(
  p_result_id bigint,
  p_distance_tolerance_m double precision default 20,
  p_time_lag interval default null
)
```

用于识别相近规划路径、常用航线模板或实飞偏航对比。

---

## 7. 前端交互设计

## 7.1 控制点编辑

在 `frontend/tianditu-3d.html` 中新增“路径规划”面板：

1. 点击地图设置起点。
2. 点击地图设置终点。
3. 点击地图追加途径点。
4. 支持拖拽或删除途径点。
5. 支持通过表单精确输入经纬度和高度。
6. 控制点列表支持上移 / 下移途径点顺序。

## 7.2 方案管理

面板功能：

- 新建方案
- 保存方案
- 查询方案列表
- 加载方案详情
- 删除 / 归档方案
- 计算路径
- 重新计算路径

## 7.3 可视化样式

建议样式：

| 对象 | 样式 |
|---|---|
| 起点 | 绿色图标 / marker |
| 终点 | 红色图标 / marker |
| 途径点 | 蓝色编号 marker |
| 原始折线 | 灰色虚线 |
| 规划路径 | 高亮实线 |
| 平滑路径 | 更粗的发光线，可开关 |
| 失败分段 | 红色虚线 |

---

## 8. 与障碍物和空域限制的关系

路径规划障碍输入继续使用：

```text
public.flight_obstacles(id, grids)
```

因此已接入的障碍会自动参与避障：

- 建筑物
- 地形障碍
- 长期禁飞区
- 临时管制区 / 临时禁飞区

注意事项：

1. 计算前应确认障碍物化视图已刷新。
2. 如果按 `planning_time` 计算临时空域，需要先按同一 `planning_time` 刷新 `citydb_grid.flight_obstacles` 或准备对应的 active wrapper。
3. 不应为了前端展示性能降低路径规划用障碍精度。
4. `ST_FindGridsPath` 调用必须解析到带 `flight_obstacles_grids_gin_idx` 的 `citydb_grid.flight_obstacles` 物化视图。当前后端函数通过 `set search_path = flight_path, citydb_grid, public, pg_temp` 保证传入未限定表名 `flight_obstacles` 时优先命中索引物化视图；如果解析到 `public.flight_obstacles` 兼容 view，5–8km 路径计算会从约 1–2 秒退化到约 90 秒以上。

---

## 9. 安全与权限

建议权限分层：

| 角色 | 能力 |
|---|---|
| 只读用户 | 查询方案和结果 |
| 规划用户 | 新建、修改、计算、归档自己的方案 |
| 管理员 | 查询和删除所有方案 |

如果 PostgREST 暂未接入认证，第一版至少通过 schema 权限限制直接表写入，只暴露 RPC。

---

## 10. 实施步骤

## 阶段 1：数据库表和基础 RPC

1. 新增 `backend/create_flight_path_planning_rpc.sql`。
2. 安装 / 校验 `best_iot`、`best_geotrack` 扩展。
3. 创建 `flight_path.plan`、`flight_path.plan_point`、`flight_path.plan_result`。
4. 实现：
   - `create_plan`
   - `update_plan`
   - `list_plans`
   - `get_plan`
   - `archive_plan`
5. 使用 SQL 样例完成保存和查询验收。

## 阶段 2：路径计算 RPC

1. 实现 `compute_plan`。
2. 支持无途径点路径：`start -> end`。
3. 支持多途径点分段路径。
4. 保存成功 / 失败结果。
5. 使用 `GT_MakeTrajectory` 生成 `route_traj` / `smooth_route_traj`。
6. 使用 `GT_length`、`GT_leafCount`、`GT_duration` 生成结果摘要。
7. 输出 GeoJSON 给前端。

## 阶段 2.5：轨迹查询增强

1. 创建 `route_traj trajgist_ops_2dt` GiST 索引。
2. 实现按时间范围查询结果。
3. 实现按空间 bbox 查询结果。
4. 预留相似路径查询接口。

## 阶段 3：前端路径规划面板

1. 增加路径规划 UI 面板。
2. 支持地图点选起点、终点、途径点。
3. 支持保存、查询、加载、归档。
4. 支持计算并展示路径。
5. 支持错误提示和失败分段展示。

当前前端实现位置：`frontend/tianditu-3d.html` 的 `Flight Path Planner` 面板。已接入：

- `create_flight_path_plan`
- `update_flight_path_plan`
- `list_flight_path_plans`
- `get_flight_path_plan`
- `archive_flight_path_plan`
- `compute_flight_path_plan`
- `get_latest_flight_path_result`

前端点选 AGL 控制点时，会显示：

```text
输入高度：120m AGL
估算计算高度：terrain height + 120m ≈ N m AMSL
```

最终权威计算高度仍以后端 `flight_path.effective_height_amsl(...)` 和地形障碍清除逻辑为准。

## 阶段 4：E2E 验收与优化

1. 构造穿越障碍的起终点，验证路径绕飞。
2. 构造包含 2 个以上途径点的路径，验证按序经过。
3. 验证保存后刷新页面仍可查询并恢复展示。
4. 验证归档后默认列表不显示。
5. 验证临时管制区在不同 `planning_time` 下影响路径。

---

## 11. 验收标准

| 编号 | 验收项 | 预期 |
|---|---|---|
| P1 | 新建方案 | 可保存起点、终点和 0..N 个途径点 |
| P2 | 查询列表 | 可按状态 / 关键字分页查询 |
| P3 | 查询详情 | 返回方案基础信息、控制点和最新结果摘要 |
| P4 | 更新方案 | 修改点位后旧计算结果不会被误认为最新有效结果 |
| P5 | 无途径点计算 | `start -> end` 可生成路径 |
| P6 | 多途径点计算 | 路径按 `seq` 依次经过所有途径点 |
| P7 | 避障 | 路径不穿越 `public.flight_obstacles` 中的障碍网格 |
| P8 | 保存结果 | 成功结果包含 grid path、route geometry、route trajectory、距离和 cell 数 |
| P9 | 失败处理 | 失败时保存错误信息，前端可读 |
| P10 | 前端展示 | 控制点、原始折线、规划路径样式清晰 |
| P11 | 轨迹统计 | `GT_length`、`GT_leafCount`、`GT_duration` 能返回结果摘要 |
| P12 | 轨迹查询 | 可按时间范围 / 空间范围查询已规划路径结果 |

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| `ST_FindGridsPath` 不支持 schema-qualified tableName | 计算失败 | 保持 `public.flight_obstacles(id, grids)` wrapper，但传给函数的表名使用未限定名 `flight_obstacles` |
| `flight_obstacles` 解析到 public view | 路径计算严重变慢 | 在 `compute_plan` 的 `search_path` 中把 `citydb_grid` 放在 `public` 前面，确保命中物化视图 GIN 索引 |
| 点高度基准混用 | 路径高度错误 | 强制保存 `height_datum`，第一版限制为 AMSL |
| 途径点过多 | 计算慢或失败 | 限制单方案途径点数量，例如 20 个以内 |
| 障碍视图未按规划时间刷新 | 临时禁飞区判断错误 | 计算前明确刷新策略或记录障碍版本 |
| 路径结果 geometry 过大 | API 响应慢 | 列表只返回摘要，详情接口再返回 GeoJSON |
| 分段中某一段不可达 | 整条路径失败 | 保存失败 segment，前端高亮问题段 |
| `trajectory` 时间线和点数不一致 | `GT_MakeTrajectory` 构造失败 | 构造前校验 `timeline` 数量、geometry 点数和 `attrs_json.leafcount` 一致 |
| 轨迹索引维度过多影响性能 | 查询变慢 | 默认使用 `trajgist_ops_2dt`，高频 3D 查询再补充 `trajgist_ops_3dt` |

---

## 13. 后续扩展

1. 精细化 AGL 高度：从“点位 DEM 采样 + terrain geomgrid 清除”升级为沿线连续净空检查。
2. 支持路径代价权重：距离、风险、禁限飞缓冲、地形净空。
3. 支持路径版本比较。
4. 支持导出 GeoJSON / KML / CZML。
5. 支持任务航线模板。
6. 支持批量路径规划和异步计算队列。
7. 支持规划轨迹与实飞轨迹对比：`GT_lcsDistance`、`GT_JaccardSimilarity`、`GT_deviation`。
8. 支持历史轨迹分表和实时轨迹表：`BESTDB_ShardingTrajectoryTable`、`BESTDB_CreateRealtimeTable`。
