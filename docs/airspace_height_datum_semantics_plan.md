# 空域禁限飞高度基准完整语义支持计划

## 1. 背景与问题

当前 P1 前端已增加“高度基准”选择，用于解决两个直接问题：

1. 山区有地形高程时，绘制点、线、预览面可能被地形遮挡。
2. 如果 `max_height` 低于地形高程，禁飞区会被埋在地形下，生成的 grids 对展示和避障都没有实际意义。

当前临时处理方式是：

```text
前端选择 AGL
  ↓
保存前采样地形
  ↓
把用户输入的离地高度转换成 AMSL 绝对高度
  ↓
写入 airspace.min_height / airspace.max_height
  ↓
刷新脚本仍按绝对高度生成 grids
```

这可以短期保证“可见”和“可刷新”，但没有完整表达业务语义：

- 高度基准没有保存入库。
- 编辑时无法知道原始输入是 `AGL` 还是 `AMSL`。
- 地形数据变化后，已转换入库的高度不会重新解释。
- SQL / curl / 导入脚本绕过前端时不会自动处理 AGL。
- grids 生成阶段没有显式理解高度基准。

因此需要把高度基准作为一等业务语义，贯穿：

```text
数据模型 → PostgREST CRUD → 前端编辑 → grids 生成 → 验收
```

---

## 2. 目标

实现禁限飞区高度的完整语义支持：

1. 业务表持久化高度基准。
2. 支持 `AMSL` 与 `AGL` 两种高度语义。
3. 前端按语义展示、编辑、校验和保存。
4. grids 刷新脚本在生成 airspace prism 时显式处理高度基准。
5. 自动刷新 worker 保持兼容。
6. 保持现有 GGER-only 对外展示和路径规划接口不变。

非目标：

1. 不修改 3DCityDB 标准表结构。
2. 不改变 `citydb_grid.flight_obstacles` 对外字段契约。
3. 不在本阶段实现复杂审计 / 审批 / 多用户权限体系。
4. 不在业务表中保存每个 terrain sample 的明细；如需审计，后续引入 staging 表。

---

## 3. 高度语义定义

### 3.1 AMSL

`AMSL` 表示绝对海拔高度 / 当前数据库使用的垂直基准高度。

业务含义：

```text
min_height = 绝对最低高度
max_height = 绝对最高高度
```

刷新时：

```text
min_z = coalesce(min_height, 0)
max_z = coalesce(max_height, default_zone_max_height)
```

### 3.2 AGL

`AGL` 表示相对地表高度。

业务含义：

```text
min_height = 离地最低高度
max_height = 离地最高高度
```

刷新时必须结合地形：

```text
local_min_z = terrain_z + min_height
local_max_z = terrain_z + max_height
```

注意：AGL 不能简单用整个 polygon 的 `terrain_min` / `terrain_max` 生成一个大 prism，否则会产生过度阻塞或高度误差。推荐按 DEM block / terrain block 分片生成局部 prism。

---

## 4. 数据模型迁移

### 4.1 新增字段

对两张业务表增加高度基准字段：

```sql
alter table airspace.no_fly_zone
  add column if not exists height_datum text not null default 'AMSL',
  add constraint no_fly_zone_height_datum_chk
    check (height_datum in ('AMSL', 'AGL'));

alter table airspace.temp_control_zone
  add column if not exists height_datum text not null default 'AMSL',
  add constraint temp_control_zone_height_datum_chk
    check (height_datum in ('AMSL', 'AGL'));
```

现有数据默认 `AMSL`，因为历史 `min_height/max_height` 已按绝对高度进入刷新链路。

### 4.2 是否保存原始输入

短期建议不新增 `input_min_height/input_max_height`，直接规定：

```text
min_height / max_height 的语义由 height_datum 决定。
```

即：

| height_datum | min_height / max_height 含义 |
|---|---|
| `AMSL` | 绝对高度 |
| `AGL` | 离地高度 |

这样表结构最小，且 PostgREST CRUD 简单。

如后续需要保存“展示值”和“计算值”双轨，可再扩展：

```sql
computed_min_height double precision
computed_max_height double precision
computed_at timestamptz
```

但 P1 完整语义阶段不建议引入，避免双写不一致。

### 4.3 索引与约束

新增普通索引，便于筛选和巡检：

```sql
create index if not exists no_fly_zone_height_datum_idx
  on airspace.no_fly_zone (height_datum);

create index if not exists temp_control_zone_height_datum_idx
  on airspace.temp_control_zone (height_datum);
```

高度约束建议：

```sql
alter table airspace.no_fly_zone
  add constraint no_fly_zone_height_range_chk
    check (max_height is null or max_height > coalesce(min_height, 0));

alter table airspace.temp_control_zone
  add constraint temp_control_zone_height_range_chk
    check (max_height is null or max_height > coalesce(min_height, 0));
```

如果历史数据可能违反，先巡检再加约束。

---

## 5. PostgREST CRUD 影响

### 5.1 直接表接口

`airspace` schema 已直接暴露，前端继续使用：

```text
/no_fly_zone
/temp_control_zone
```

新增字段参与 `select`、`insert`、`patch`：

```json
{
  "name": "花果山核心禁飞区",
  "geom": "{...GeoJSON...}",
  "height_datum": "AGL",
  "min_height": 0,
  "max_height": 300,
  "safety_buffer_m": 20,
  "enabled": true
}
```

### 5.2 授权脚本更新

`backend/create_airspace_postgrest_crud.sql` 需要：

1. 增加字段迁移 DDL。
2. 继续授权 `web_anon` CRUD。
3. 保持 `airspace_changed` trigger 不变。

trigger payload 可增加 `height_datum`，方便 worker 日志观察：

```json
{
  "kind": "no_fly_zone",
  "id": 123,
  "operation": "update",
  "height_datum": "AGL"
}
```

worker 不依赖该字段，仅记录即可。

---

## 6. 前端改造计划

文件：

```text
frontend/tianditu-3d.html
```

### 6.1 绘制 preview

保持当前已改策略：

1. vertex point 贴地。
2. label 贴地，并禁用深度遮挡。
3. polyline `clampToGround = true`。
4. polygon preview 贴地半透明展示。
5. preview 是 UI 反馈，不代表最终空域高度体。

### 6.2 表单语义

新增 / 保留字段：

```text
高度基准：AMSL / AGL
最低高度
最高高度
地形采样摘要
```

文案规则：

- `AGL`：显示“离地高度，保存后按离地语义入库”。
- `AMSL`：显示“海拔高度，保存前校验高于地形”。

### 6.3 保存逻辑

完整语义阶段不再把 AGL 转换为 AMSL 入库。

保存 payload：

```text
height_datum = 用户选择
min_height   = 用户输入值
max_height   = 用户输入值
```

保存前仍采样地形做 UX 校验：

- `AMSL`：必须满足 `max_height > terrain_max + margin`。
- `AGL`：必须满足 `max_height > margin`，例如 `> 10m`。

这只是前端快速校验；最终有效高度以刷新脚本计算为准。

### 6.4 编辑逻辑

读取已有记录时：

```text
height_datum = row.height_datum || 'AMSL'
min_height/max_height 原样展示
```

不再默认把已有记录都当 AMSL，除非字段为空。

### 6.5 列表展示

列表文案从：

```text
AMSL 0–300m
```

改为：

```text
AGL 0–300m
AMSL 120–500m
```

如果 `height_datum` 缺失，显示：

```text
AMSL legacy 0–300m
```

---

## 7. grids 生成改造计划

文件：

```text
scripts/refresh_citydb_obstacle_grids.py
```

当前 airspace 生成逻辑：

```text
airspace polygon footprint
  ↓
make_polygon_prism_3d(footprint, min_z, max_z)
  ↓
ST_AsGrids3D(...)
```

需要拆分为两条路径：

```text
AMSL zone → 原有 polygon prism
AGL zone  → terrain-aware local prism pieces
```

### 7.1 AMSL 路径

不变：

```sql
where height_datum = 'AMSL' or height_datum is null
```

```text
min_z = coalesce(min_height, 0)
max_z = coalesce(max_height, default_zone_max_height)
```

### 7.2 AGL 路径：推荐 block-prism

复用 terrain DEM block 思路。

已有 terrain 处理中，`--terrain-mode block-prism` 逻辑大致是：

```text
terrain.dem_tile raster pixels
  ↓
按 terrain_block_size_pixels 聚合
  ↓
block footprint + min/max elevation
  ↓
make_bbox_prism_3d
```

AGL airspace 可以使用相同地形 block 作为采样基础：

```text
zone polygon footprint
  ↓
与 DEM block footprint 相交
  ↓
local_footprint = ST_Intersection(zone_footprint, block_footprint)
  ↓
local_min_z = block_min_elevation + zone.min_height
local_max_z = block_max_elevation + zone.max_height
  ↓
make_polygon_prism_3d(local_footprint, local_min_z, local_max_z)
  ↓
ST_AsGrids3D
```

这样可避免用全区 `terrain_max` 把整个 polygon 顶部抬得过高，也避免山谷和山脊共用一个高度。

### 7.3 AGL fallback 路径

如果没有 DEM / terrain block 数据，可选 fallback：

```text
terrain_min/max 缺失
  ↓
跳过该 AGL zone 并记录 warning
```

不建议默认为 AMSL，因为这会误解释高度语义。

刷新脚本输出：

```text
WARNING: skipped AGL airspace zone #123 because no terrain DEM intersects its footprint.
```

### 7.4 AGL 物化视图结构

`citydb_grid.obstacles_no_fly_zones` / `obstacles_temp_control_active` 对外结构保持不变。

内部 SQL 可以：

```text
AMSL rows
union all
AGL block rows aggregated by zone
```

注意 source_id 仍应保持业务 zone id：

```text
source_id = zone.id::text
source_name = zone.name
```

如果 AGL 分片产生多行，需要二选一：

#### 方案 A：每个分片一行

```text
source_id = zone.id || ':agl:' || block_id
```

优点：实现简单。  
缺点：前端详情会看到多个同名禁飞区。

#### 方案 B：按 zone 聚合 geomgrids

```sql
ST_UnionGrids(array_agg(piece_grids)) as grids
source_id = zone.id::text
```

优点：对外仍是一条业务禁飞区。  
缺点：需要确认 iBEST-DB 是否有稳定的 geomgrids 聚合函数；若已有 `ST_Union` / grids aggregate 可用，应优先用。

推荐：优先调研 / 验证方案 B；如不支持，再采用方案 A 并在前端合并展示。

### 7.5 source metadata

统一输出可继续保持：

```text
source_kind = 'no_fly_zone' / 'temp_control'
priority = 1000 / 1100
valid_from / valid_to 不变
```

可选在 codes view 或调试视图中增加：

```text
height_datum
```

但不强制改变现有 `list_flight_obstacles_gger` 返回契约，除非前端需要显示。

---

## 8. 自动刷新 worker 影响

文件：

```text
scripts/watch_airspace_refresh.py
```

无需大改。

只要 airspace 表变更继续触发：

```text
NOTIFY airspace_changed
```

worker 仍执行：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --refresh-only \
  --source airspace \
  --refresh-total \
  --airspace-mode polygon-prism \
  --grant-role web_anon
```

但如果 AGL 生成依赖 DEM block，而相关 AGL SQL 需要重建物化视图定义，则首次部署后应执行非 `--refresh-only`：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source airspace \
  --refresh-total \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

之后 worker 可继续 `--refresh-only`。

---

## 9. 导入脚本影响

文件：

```text
scripts/seed_airspace_zones.py
```

新增参数：

```text
--height-datum AMSL|AGL
```

默认：

```text
AMSL
```

示例：

```bash
uv run scripts/seed_airspace_zones.py \
  --kind no-fly-zone \
  --name 花果山核心禁飞区 \
  --height-datum AGL \
  --min-height 0 \
  --max-height 300 \
  --safety-buffer-m 20 \
  --geojson data/airspace/huaguoshan_no_fly_zone.geojson
```

导入脚本只保存语义，不做 AGL 转换。

---

## 10. RPC / 前端展示影响

### 10.1 PostgREST direct CRUD

直接表接口自然返回 `height_datum`。

### 10.2 flight obstacles RPC

当前 `list_flight_obstacles_gger` 返回障碍视图字段，不返回业务表高度基准。

短期不强制修改。

如果前端点击障碍详情要显示高度基准，可以后续增强 RPC：

```text
height_datum
min_height
max_height
```

但这会改变 RPC 输出，建议单独作为展示增强。

---

## 11. E2E 验收计划

### 11.1 数据模型验收

```sql
select id, name, height_datum, min_height, max_height
from airspace.no_fly_zone
order by id desc;
```

预期：

```text
历史数据 height_datum = AMSL
新建 AGL 数据 height_datum = AGL
```

### 11.2 前端保存验收

1. 新建禁飞区。
2. 选择 `AGL`。
3. 输入 `0–300m`。
4. 绘制 polygon。
5. 保存。
6. 查询数据库：

```sql
select height_datum, min_height, max_height
from airspace.no_fly_zone
where name = '...';
```

预期：

```text
height_datum = AGL
min_height = 0
max_height = 300
```

### 11.3 AMSL 校验验收

在高地形区域选择 `AMSL`，输入明显低于地形的 max height。

预期：

```text
前端阻止保存，并提示 max_height 必须高于 terrainMax + margin
```

### 11.4 AGL grids 验收

新建 AGL 禁飞区后刷新：

```bash
uv run scripts/refresh_citydb_obstacle_grids.py \
  --source airspace \
  --refresh-total \
  --airspace-mode polygon-prism \
  --terrain-mode block-prism \
  --terrain-block-size-pixels 4 \
  --grant-role web_anon
```

检查：

```sql
select source_kind, source_id, source_name, public.ST_nCells(grids) as cells
from citydb_grid.flight_obstacles
where source_kind in ('no_fly_zone', 'temp_control')
order by source_kind, source_id;
```

预期：

1. AGL 禁飞区进入 `flight_obstacles`。
2. `ST_WithBox(grids, 'GGER')` 的 bbox 高度范围约等于地形高度 + AGL 输入范围。
3. 前端飞行障碍图层可见。
4. 路径规划避开该区域。

### 11.5 worker 验收

启动：

```bash
uv run scripts/watch_airspace_refresh.py --dry-run-refresh --once
```

写入 / 修改一条 airspace 记录。

预期：

```text
worker 收到 airspace_changed NOTIFY
输出 refresh command
```

正式 worker 去掉 `--dry-run-refresh`。

---

## 12. 推荐实施顺序

### Phase 1：表结构与前端语义

1. 新增 `height_datum` 字段和约束。
2. PostgREST CRUD select / insert / patch 支持 `height_datum`。
3. 前端保存不再把 AGL 转 AMSL，而是原样保存语义。
4. 编辑时按 `height_datum` 回显。
5. 前端保留 terrain 采样校验。

### Phase 2：刷新脚本 AMSL / AGL 分支

1. 修改 no-fly-zone SQL。
2. 修改 temp-control SQL。
3. AMSL 走原逻辑。
4. AGL 与 DEM block 相交生成 terrain-aware prism。
5. 验证是否可按 zone 聚合 geomgrids；不能聚合则采用分片 source_id。

### Phase 3：导入脚本与文档

1. `seed_airspace_zones.py` 增加 `--height-datum`。
2. 更新 P1 文档和验收说明。
3. 增加示例 AGL GeoJSON 导入命令。

### Phase 4：E2E 验收

1. 数据库字段验收。
2. 前端 AGL / AMSL 保存验收。
3. AGL grids 高度范围验收。
4. 自动刷新 worker 验收。
5. 路径规划绕飞验收。

---

## 13. 风险与决策点

| 风险 / 决策点 | 影响 | 建议 |
|---|---|---|
| AGL 分片后无法聚合 geomgrids | 一个业务禁飞区可能变多条障碍 | 优先调研 grids 聚合函数；无聚合时前端按 source_id 前缀合并展示 |
| DEM 覆盖缺失 | AGL 无法计算绝对高度 | AGL zone 无 DEM 时跳过并 warning，不自动当 AMSL |
| 地形垂直基准与飞行高度基准不一致 | 高度误差 | 继续遵循 `docs/terrain_vertical_datum.md`，必要时增加 datum metadata |
| 高频编辑触发频繁刷新 | DB 压力 | 继续使用 worker debounce + advisory lock |
| 匿名写入仍开放 | 安全风险 | 生产化前补权限 / RLS / admin role |
| AGL 生成 SQL 复杂 | 实现风险 | 先做 block-prism，后续再引入 staging 表审计 |

---

## 14. 结论

完整语义支持应从“前端 AGL 转 AMSL”升级为：

```text
height_datum 持久化入库
  ↓
前端按 height_datum 展示和校验
  ↓
刷新脚本按 AMSL / AGL 分支生成 grids
  ↓
AGL 使用 terrain-aware block-prism
  ↓
flight_obstacles 对外契约保持不变
```

这样才能确保：

1. 用户输入语义不丢失。
2. 编辑已有记录时语义清晰。
3. 任何写入路径都能被刷新脚本正确解释。
4. grids 与路径规划真正考虑地形高程。
