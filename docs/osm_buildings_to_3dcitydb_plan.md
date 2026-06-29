# OSM 建筑物导入 3DCityDB 实施计划

## 1. 目标

从用户给定 GeoJSON Polygon 覆盖区域内获取 OpenStreetMap 建筑物数据，按 3DCityDB 5.1 / PostgreSQL 模式写入数据库，生成可查询的 LoD1 简模建筑。

> 数据来源为 OpenStreetMap / Overpass API。OSM 的建筑轮廓和高度标签由社区维护，可能缺失或不准确；本方案不会声称数据来自 LiDAR、倾斜摄影、DEM/DSM、3D Tiles 或权威三维城市模型。

## 2. 输入区域

输入 polygon 坐标顺序为 `[lng, lat]`：

```json
[[119.23062143399773,34.6640111299246],[119.3058473500937,34.66387620237016],[119.30574254976909,34.63041169680007],[119.23071540183122,34.630255366340634],[119.23062143399773,34.6640111299246]]
```

派生 bbox：

- south: `34.630255366340634`
- west: `119.23062143399773`
- north: `34.6640111299246`
- east: `119.3058473500937`

面积约 25 km²，Overpass 查询可能较大；实施时优先使用 polygon 过滤，必要时按网格切分请求并去重。

## 3. 数据获取方案

1. 使用 Overpass API：`https://overpass-api.de/api/interpreter`。
2. 同时请求 `way["building"]` 和 `relation["building"]`。
3. 优先使用 polygon 查询，避免 bbox 外建筑进入结果；如 Overpass 超时，则改为 bbox/网格查询后在本地用 polygon 精确裁剪。
4. 请求模板：

```overpass
[out:json][timeout:60];
(
  way["building"](poly:"34.6640111299246 119.23062143399773 34.66387620237016 119.3058473500937 34.63041169680007 119.30574254976909 34.630255366340634 119.23071540183122 34.6640111299246 119.23062143399773");
  relation["building"](poly:"34.6640111299246 119.23062143399773 34.66387620237016 119.3058473500937 34.63041169680007 119.30574254976909 34.630255366340634 119.23071540183122 34.6640111299246 119.23062143399773");
);
out body geom;
```

## 4. 解析与清洗

- 保留 OSM `type/id/tags/geometry/members`。
- `way`：读取 `element.geometry` 作为外环。
- `relation`：按 multipolygon 成员组装 outer/inner rings；无法可靠组装的 relation 记录到失败清单。
- 跳过少于 3 个点、非闭合且无法闭合、自交或面积异常的轮廓。
- 对重复对象按 `osm:{type}:{id}` 去重。
- 对落在 polygon 边界外的几何进行本地二次过滤。

## 5. 高度规则

按以下优先级生成 LoD1 高度（米）：

1. `height` 可解析：如 `12`, `12 m`, `12.5m`。
2. `building:levels` 可解析：`levels * 2.2`。
3. 默认值：`10` 米。

同时保留高度来源：`height_tag` / `levels_tag` / `default`。如后续需要绝对海拔，需额外引入 DEM；本次默认以局部地面 `z=0` 挤出。

## 6. 坐标与几何

- OSM 原始坐标：WGS84，经纬度 `EPSG:4326`。
- 入库建议坐标：`EPSG:32650`（WGS84 / UTM zone 50N），该区域在 119E 附近，适合以米为单位生成 3D 几何。
- 转换流程：`lon/lat -> EPSG:32650 x/y`，z 使用 `0..height`。
- 生成 LoD1 几何：建筑 footprint 挤出为 `POLYHEDRALSURFACE Z` 或兼容的 `MULTIPOLYGON Z` 闭合外壳；入库前用 PostGIS 校验 `ST_IsValid`。
- `geometry_data.geometry_properties.type` 官方枚举来自 `citydb-tool/citydb-model/src/main/java/org/citydb/model/geometry/GeometryType.java`：

| type | 几何类型 |
| ---: | --- |
| 1 | Point |
| 2 | MultiPoint |
| 3 | LineString |
| 4 | MultiLineString |
| 5 | Polygon |
| 6 | CompositeSurface |
| 7 | TriangulatedSurface |
| 8 | MultiSurface |
| 9 | Solid |
| 10 | CompositeSolid |
| 11 | MultiSolid |

本次建筑 LoD1 挤出若写入 `POLYHEDRALSURFACE Z` / `Solid`，`geometry_properties` 根节点应使用 `{"type": 9}`；如以多面组成的表面几何写入，则使用 `{"type": 8}`。

## 7. 3DCityDB 表映射

依据 `3dcitydb-schema.dbs` 和 3DCityDB 5.1.3 初始化实例：

### 7.1 必需元数据

- 确认 `citydb.objectclass` 已包含 `Building`：`objectclass_id = 901`。
- 确认 `citydb.namespace`：`core = 1`, `bldg = 10`, `gen = 3`。
- 确认 `citydb.datatype`：`GeometryProperty = 11`, `Integer = 3`, `String = 5`, `Code = 14`, `Double = 4`。
- 确认 `citydb.database_srs` 包含 `32650`，否则插入。

### 7.2 每栋建筑写入

1. `citydb.feature`
   - `objectclass_id = 901`
   - `objectid = 'osm:{way|relation}:{id}'`
   - `identifier = 'https://www.openstreetmap.org/{way|relation}/{id}'`
   - `identifier_codespace = 'https://www.openstreetmap.org'`
   - `envelope = 建筑 3D envelope`
   - `lineage = 'OpenStreetMap via Overpass API'`

2. `citydb.geometry_data`
   - `feature_id = feature.id`
   - `geometry = LoD1 3D shell/solid geometry, SRID 32650`
   - `geometry_properties = 3DCityDB geometry properties JSON`（实施时按 5.1 schema 校验 type 枚举）

3. `citydb.property`
   - 几何关联：`datatype_id = 11`, `namespace_id = 1`, `name = 'lod1Solid'`, `val_lod = '1'`, `val_geometry_id = geometry_data.id`
   - 楼层：如有 `building:levels`，写 `name = 'storeysAboveGround'`, `namespace_id = 10`, `datatype_id = 3`, `val_int = levels`
   - 建筑分类：`building=*` 可写为 `name = 'class'`, `namespace_id = 10`, `datatype_id = 14`, `val_string = tags.building`
   - OSM 追溯字段：写外部引用或通用属性，至少保留 OSM URL、原始 tags JSON、高度来源、导入批次。

## 8. 幂等与事务

- 所有导入在单个事务或分批事务中执行。
- 以 `objectid = 'osm:{type}:{id}'` 作为业务唯一键。
- 重复导入时：先查已有 feature；若存在，则清理该 feature 的 property/geometry_data 后更新，或跳过未变化对象。
- 注意外键：`property.feature_id` 不级联删除，不能直接删除 feature；需要显式删除相关 property，再处理 geometry_data/feature。

## 9. 实施步骤

1. 编写导入脚本（建议 Python + `uv` 管理依赖）：
   - HTTP：请求 Overpass。
   - 几何：Shapely 解析/修复/挤出。
   - 坐标转换：pyproj。
   - 数据库：psycopg 连接 PostgreSQL/PostGIS。
2. 增加配置项：数据库连接串、目标 SRID、默认高度、Overpass timeout、批大小。
3. 实现 Overpass 查询、重试、限流和网格切分。
4. 实现 OSM way/relation 解析和本地 polygon 过滤。
5. 实现高度解析和 LoD1 几何生成。
6. 实现 3DCityDB 元数据校验和数据写入。
7. 输出导入报告：请求数量、建筑总数、成功数、跳过数、失败原因、默认高度使用比例。
8. 增加端到端验证 SQL：数量、SRID、有效几何、随机抽样高度和 envelope。

## 10. 验收标准

- 目标 polygon 内建筑已写入 `citydb.feature`，`objectclass_id = 901`。
- 每个成功建筑至少有一条 `geometry_data` 和一条 `lod1Solid` property。
- 几何 SRID 为 32650，且主要几何通过 `ST_IsValid`。
- 导入报告列出 OSM 数据缺失/不准确的限制说明。
- 重复执行导入不会产生重复建筑。

## 11. 风险与待确认项

- Overpass 对 25 km² 区域可能超时，需要网格切分。
- OSM 高度缺失可能很多，默认高度建筑会较多。
- `geometry_properties.type` 数值枚举已对照官方 `citydb-tool` 代码确认；实施时仍需确保实际 PostGIS 几何类型与该枚举一致。
- 如果要求真实地表高程或贴地建筑，需要额外 DEM 数据源；当前计划仅做 `z=0` 到 `height` 的 LoD1 挤出。

## 12. 实施状态

状态：**已实施并通过当前验收**。

实施脚本：

- `scripts/import_osm_buildings_to_3dcitydb.py`

已完成内容：

- 已通过 Overpass 获取项目 polygon 内 OSM 建筑数据。
- 已将原始 Overpass 响应缓存到 `data/overpass_huaguoshan_buildings.json`。
- 已解析 OSM `way["building"]` / `relation["building"]`。
- 已按 `height`、`building:levels * 2.2`、默认 `10m` 推导建筑高度。
- 已将建筑 footprint 从 `EPSG:4326` 投影到 `EPSG:32650`。
- 已生成 LoD1 `POLYHEDRALSURFACE Z` solid。
- 已按 `objectid = 'osm:{type}:{id}'` 实现幂等更新。
- 已写入 3DCityDB：`citydb.feature`、`citydb.geometry_data`、`citydb.property`。
- 已确认建筑 solid 使用官方几何枚举 `geometry_properties = {"type": 9}`。
- 后续已接入 DEM terrain，高程基底不再固定为 `z=0`；建筑现在可通过 `--base-z-mode terrain` 使用 `terrain.dem_tile` 采样得到 `base_z`。

当前数据库验收结果：

```text
OSM Building feature count: 17
LoD1 lod1Solid property count: 17
geometry count: 17
geometry SRID EPSG:32650 count: 17
geometry type ST_PolyhedralSurface count: 17
ST_IsClosed count: 17
terrain-elevated building count: 17
```

当前高度来源统计：

```text
default height: 16
building:levels-derived height: 1
height tag: 0
```

最近一次建筑导入命令：

```bash
uv run scripts/import_osm_buildings_to_3dcitydb.py \
  --load-overpass-json data/overpass_huaguoshan_buildings.json \
  --base-z-mode terrain \
  --execute
```

注意：OSM 建筑轮廓和高度标签仍为社区维护数据，可能缺失或不准确；当前 LoD1 只适合近似建模、可视化和粗粒度空间分析。
