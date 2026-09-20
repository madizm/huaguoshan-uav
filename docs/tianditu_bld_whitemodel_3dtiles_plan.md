# 天地图江苏建筑白膜 → 3D Tiles 实施方案

将天地图江苏 GeoServer GWC 矢量瓦片服务（`tdtjs:BLD`，建筑面 + 楼层数）离线转换为 Cesium 可直接加载的 3D Tiles 白膜，按楼层数拉伸（FLOOR × 3m），贴合 DEM 地形。

## 1. 数据源实测结论

服务：`https://jiangsu.tianditu.gov.cn/jsgeo/geoserver/gwc/service/tms/1.0.0/tdtjs%3ABLD@tdt_EPSG_4490_grid@pbf/{z}/{x}/{y}.pbf`
（请求需带 `User-Agent` 与 `Referer: https://jiangsu.tianditu.gov.cn/jsmap/index.html`）

实测样例瓦片（z16/54466/22680，连云港市区）解码结果：

- 单层 `BLD`，extent 4096，Polygon 建筑轮廓
- 属性：`ELEMID`（建筑唯一 ID）、`FLOOR`（楼层数，字符串）、`area` / `SHAPE_*`
- **无高度字段**，高度由 `FLOOR × 3m` 推算

网格定义（取自 TileMap 元数据 `tms/1.0.0/tdtjs%3ABLD@tdt_EPSG_4490_grid@pbf/`）：

- SRS：EPSG:4490（CGCS2000，椭球与 WGS84 厘米级差异，**全程按 4326 处理**）
- 瓦片跨度：`span(z) = 360° / 2^z`（z0 单瓦片 360°，z16 ≈ 0.00549° ≈ 500m）
- 瓦片编号为**全局原点 (-180, -90)**，TMS 风格 y 轴自南向北：
  `x = floor((lon + 180) / span)`，`y = floor((lat + 90) / span)`
- 数据范围（grid subset）：东经 112.5°~135°，北纬 22.5°~45°
- 可用级别：z0 ~ z20，建筑数据以 z16 为采集级别
- 另有 `tdtjs%3ABLD@EPSG%3A900913@pbf`（Web 墨卡托网格）备用

瓦片规模估算（z16）：

| 范围 | 瓦片数 | 说明 |
|---|---|---|
| 花果山片区 | ~874 | 首期试点 |
| 连云港主城区 | ~1,406 | 二期 |
| 连云港全市 | ~69,546 | 需按城区掩膜过滤，农村瓦片多为空 |

## 2. 总体流程

```
GWC TMS pbf 下载 (限速/断点续传/缓存)
        │
        ▼
MVT 解码 → 瓦片局部坐标(extent 4096) → EPSG:4490 经纬度
        │
        ▼
PostGIS staging（raw 域，按 ELEMID 去重 + 跨瓦片 ST_Union 重组）
        │
        ▼
白膜建模：height = FLOOR×3m，base_z 取 DEM 地形高程，ST_Extrude 出 POLYHEDRALSURFACE Z
        │
        ▼
导出物化视图（geom/id/class/material_data 契约）→ pg2b3dm → 3D Tiles 1.1
        │
        ▼
3d-tiles-validator 校验 → exports/ 静态托管 → Cesium Cesium3DTileset
```

复用既有 `citydb-3dtiles-export` 技能脚本的后半段（物化视图契约、pg2b3dm、校验），只新增前半段采集与建模。

## 3. 实施步骤

### S1 瓦片下载器 `scripts/tianditu_bld/download_tiles.py`

- uv 单文件脚本（inline metadata），输入 bbox + zoom（默认 16）
- 按第 1 节公式枚举 (x, y)，并发 4~8、间隔限速（≥100ms/请求），失败指数退避重试 3 次
- 落盘缓存 `data/tianditu-bld/{z}/{x}/{y}.pbf`（`data/` 已被 gitignore，天然不污染仓库）；已存在则跳过，支持断点续传
- 空瓦片（GWC 返回 204 或极小 body）记录为空标记文件，避免重复请求
- 全市采集时先与城区掩膜多边形求交，只下载命中瓦片

### S2 解码入库 staging

- `mapbox-vector-tile` 解码；瓦片内坐标 `(vx, vy)`（extent 4096）转经纬度：
  `lon = -180 + (x + vx/4096) × span`，`lat = -90 + (y + vy/4096) × span`
- 入 staging 表（按 ELEMID 幂等）：

```sql
create table raw.tianditu_bld_feature (
  elemid text primary key,
  floor_num integer,                       -- FLOOR 解析后，非法值置 null
  geom geometry(MultiPolygon, 4326) not null,  -- 跨瓦片 ST_Union 重组结果
  source_tiles integer not null default 1, -- 来源瓦片数，排查用
  ingested_at timestamptz not null default now()
);
```

- **跨瓦片切割重组**：同一 ELEMID 可能出现在相邻瓦片边界两侧，先按 `(elemid, tile)` 明细落 staging，再 `group by elemid` + `ST_Union` 合成完整轮廓；重跑时按瓦片增量 upsert
- `FLOOR` 为字符串且可能为空/非法：`nullif(trim(...), '')::integer`，失败回退 null

### S3 白膜建模

- 拉伸高度：`height_m = coalesce(floor_num, 1) × 3.0`，`floor_num` 上限截断（如 100）防异常值
- 基底高程：复用现有 terrain/DEM 数据，对每栋建筑质心 `ST_Value` 采样得 `base_z`（与既有 OSM 建筑导出同一基准，保证与地形贴合）
- 体块生成：`ST_Extrude(ST_Translate(ST_Force3D(...)), 0, 0, height_m)` 出 `POLYHEDRALSURFACE Z`，参考既有 OSM LoD1 建模 SQL

### S4 导出 3D Tiles

- 物化视图遵循 pg2b3dm 契约（与技能文档一致）：`geom`（3D）、`id`、`class='tianditu_bld'`、`material_data = jsonb_build_object(...)::json`（白色/浅灰材质）
- 附加属性：`gen_floor`、`gen_height_m`、`gen_elemid`，供前端拾取展示
- 本地 pg2b3dm 直接跑（PG13 兼容路径，不用 SQL/JSON 语法）
- 输出 `exports/tianditu-bld-3dtiles/`（exports/ 已 gitignore）

### S5 校验

- `npx 3d-tiles-validator --tilesetFile .../tileset.json`，目标 errors=0 / warnings=0
- 抽样核对：抽 10 栋已知楼层建筑比对拉伸高度；Cesium 中目视检查与影像底图套合

### S6 前端加载与部署

- `exports/` 已由 nginx 静态暴露；前端加白膜图层开关（`Cesium3DTileset`），挂在现有 layer-controller
- 拾取联动：点击建筑显示 ELEMID/楼层/高度

### S7 增量更新

- 重跑 S1（缓存命中则跳过）→ staging diff（ELEMID 新增/消失/轮廓变化）→ 重建受影响区域物化视图 → 重出瓦片
- 频率建议：季度级手动触发，不做自动同步

## 4. 风险与决策

| 风险 | 对策 |
|---|---|
| FLOOR 缺失/非法 | 默认 1 层；统计 null 占比，占比过高时评估是否换用面积估算 |
| 跨瓦片建筑被切碎 | 按 ELEMID + ST_Union 重组，S2 内置 |
| 4490 vs 4326 偏差 | 厘米级，白膜可视化可忽略；如需严格对齐再引入七参数 |
| 全市 7 万瓦片下载礼仪 | 限速 + 城区掩膜过滤 + 断点续传；仅离线低频执行 |
| 服务条款合规 | 数据用于内网可视化衍生产品；上线前确认天地图授权条款 |
| 无高度字段的精度局限 | 白膜为示意性体量，不作为权威城市模型（与技能文档口径一致） |

## 5. 分期与验收

| 期 | 范围 | 验收标准 |
|---|---|---|
| P0 技术验证 | 单瓦片（样例瓦片） | 解码→入库→拉伸→出瓦片全链路通，Cesium 中套合影像无偏移 |
| P1 试点 | 花果山片区（~874 瓦片） | 白膜覆盖片区，validator 0 错误，拾取显示楼层属性 |
| P2 主城区 | 连云港主城区（~1.4k 瓦片） | 城区白膜完整，漫游帧率 ≥30fps |
| P3 全市 | 城区掩膜过滤后全市 | 增量更新流程跑通一次 |

## 6. 涉及产物清单

- `scripts/tianditu_bld/download_tiles.py` — 下载器
- `scripts/tianditu_bld/ingest_tiles.py` — 解码入库
- `backend/create_tianditu_bld_whitemodel.sql` — staging 表 + 白膜建模 + 导出物化视图
- `exports/tianditu-bld-3dtiles/` — 3D Tiles 产物（不入库）
- 前端白膜图层开关（`frontend/src/features/` 新模块）
