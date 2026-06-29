# DEM 地形高程集成与 3DCityDB Relief 实施计划

## 1. 目标

在现有 OSM 建筑 LoD1 导入基础上，引入开源/开放 DEM 高程数据，用于：

1. 为建筑物生成近似真实的基底高程：`base_z = terrain_elevation`，`roof_z = base_z + building_height`。
2. 将整区地形高程写入数据库，支持后续无人机路径规划、AGL 高度计算、粗粒度碰撞检测和可视化。
3. 在 3DCityDB 中建立 CityGML Relief 语义对象，同时在独立 `terrain` schema 中保存实际 DEM 栅格/网格数据。

> DEM 数据不是 LiDAR、倾斜摄影、实测航测模型或权威三维城市模型。常见 30m 级 DEM 对低空无人机精细避障只适合做初步规划，后期仍需要更高精度 DSM/LiDAR/航测或实测障碍物数据。

## 2. 总体架构

采用“双层存储”：

```text
PostgreSQL / PostGIS
├─ citydb schema
│  ├─ Building LoD1
│  ├─ ReliefFeature
│  ├─ TINRelief / RasterRelief 元数据
│  └─ 与 DEM 数据集的引用属性
│
└─ terrain schema
   ├─ DEM raster tiles
   ├─ DEM 元数据
   ├─ 高程采样函数
   ├─ 地形 TIN / mesh 派生表，可选
   └─ UAV 路径规划用 height grid / clearance grid，后续实现
```

设计原则：

- 3DCityDB 负责 CityGML/城市对象语义和可导出模型。
- `terrain` schema 负责 DEM 原始数据、高程采样和路径规划计算。
- 不将 GeoTIFF 像素强塞进 `citydb.property`。
- `RasterRelief` 在 3DCityDB 中只保存语义对象、范围、元数据和对 `terrain.dem_tile` 的引用。

## 3. 推荐数据源

优先级建议：

| 数据源 | 分辨率 | 类型 | 用途 | 注意事项 |
| --- | ---: | --- | --- | --- |
| Copernicus DEM GLO-30 | 约 30m | DSM/DEM 产品 | 推荐首选 | 需记录许可、版本和垂直基准；可能含地物影响 |
| NASA SRTMGL1 v3 | 约 30m | 雷达高程 | 推荐备选 | 覆盖稳定，常用；山地/建筑区有误差 |
| ASTER GDEM v3 | 约 30m | 光学 DEM | 备选 | 噪声和伪影相对更多 |
| JAXA AW3D30 | 约 30m | DSM | 可选 | 注意下载方式和许可 |
| FABDEM | 约 30m | 去除地物的 DEM | 可选 | 商业/再分发许可需单独确认 |

本项目区域约在 `119E, 34.6N`，目标投影继续使用 `EPSG:32650`。

## 4. 数据处理流程

```text
下载 DEM GeoTIFF
  ↓
裁剪到项目 polygon + buffer
  ↓
重投影到 EPSG:32650
  ↓
按固定 tile 大小切片
  ↓
写入 terrain.dem_tile
  ↓
建立高程采样函数 terrain.get_elevation(x, y)
  ↓
用 terrain.get_elevation 更新建筑 LoD1 base_z / roof_z
  ↓
可选生成 TINRelief 写入 3DCityDB
  ↓
后续生成 UAV height grid / clearance grid
```

建议裁剪时给项目 polygon 外扩 buffer，例如 `500m` 或 `1000m`，避免路径规划时边界附近缺高程。

## 5. terrain schema 设计

### 5.1 schema

```sql
create schema if not exists terrain;
```

### 5.2 DEM 数据集元数据表

```sql
create table if not exists terrain.dem_dataset (
  id bigserial primary key,
  dataset_key text not null unique,
  source_name text not null,
  source_url text,
  license text,
  version text,
  horizontal_srid integer not null default 32650,
  vertical_datum text,
  resolution_m double precision,
  acquisition_info text,
  processing_info text,
  extent geometry(PolygonZ, 32650),
  created_at timestamptz not null default now()
);
```

### 5.3 DEM tile 表

PostGIS raster 扩展可用时，优先使用 `raster` 字段：

```sql
create extension if not exists postgis_raster;

create table if not exists terrain.dem_tile (
  id bigserial primary key,
  dataset_id bigint not null references terrain.dem_dataset(id) on delete cascade,
  tile_id text not null,
  rast raster not null,
  extent geometry(Polygon, 32650) not null,
  min_elevation double precision,
  max_elevation double precision,
  mean_elevation double precision,
  created_at timestamptz not null default now(),
  unique (dataset_id, tile_id)
);

create index if not exists dem_tile_extent_gix
  on terrain.dem_tile using gist (extent);
```

如果目标数据库未启用 `postgis_raster`，备选方案：

- 使用文件系统/对象存储保存 Cloud Optimized GeoTIFF。
- `terrain.dem_tile` 只保存 tile 路径、extent、统计值和 checksum。
- 高程采样由 Python/GDAL 服务或离线处理脚本完成。

### 5.4 高程采样函数

计划实现：

```sql
terrain.get_elevation(x double precision, y double precision, dataset_key text default null)
returns double precision
```

采样策略：

1. 找到覆盖点位的 DEM tile。
2. 使用 `ST_Value(rast, point)` 取值。
3. 如点落在 nodata，尝试邻近像元或周边 tile。
4. 返回单位为米的高程值。

后续可增加：

```sql
terrain.get_elevation(geom geometry, method text default 'median')
```

用于建筑 footprint：

- `centroid`：速度快，但坡地建筑误差可能较大。
- `min`：建筑底座更保守，避免建筑悬空。
- `median`：抗异常值较好，推荐默认。

## 6. 3DCityDB Relief 存储方案

3DCityDB 5.x 使用通用表存储 Relief 对象：

- `citydb.feature`
- `citydb.property`
- `citydb.geometry_data`

相关 `objectclass_id`：

| objectclass_id | 类型 |
| ---: | --- |
| 500 | ReliefFeature |
| 501 | AbstractReliefComponent |
| 502 | TINRelief |
| 503 | MassPointRelief |
| 504 | BreaklineRelief |
| 505 | RasterRelief |

Relief namespace：`namespace_id = 6`。

### 6.1 ReliefFeature

写入 `citydb.feature`：

```text
objectclass_id = 500
objectid = 'terrain:relief:huaguoshan:{dataset_key}'
identifier = 数据集标识或 URI
envelope = 项目范围 3D envelope
lineage = DEM 数据源和处理流程说明
```

写入 `citydb.property`：

- `name = 'lod'`
- `name = 'reliefComponent'`
  - `val_feature_id = TINRelief/RasterRelief feature id`
  - `val_relation_type = 1`

### 6.2 RasterRelief 元数据

`RasterRelief` 写入 `citydb.feature`：

```text
objectclass_id = 505
objectid = 'terrain:raster-relief:huaguoshan:{dataset_key}'
```

建议写入属性：

| property name | 内容 |
| --- | --- |
| `demSource` | DEM 数据源，例如 `Copernicus DEM GLO-30` |
| `demDatasetKey` | 对应 `terrain.dem_dataset.dataset_key` |
| `demTable` | `terrain.dem_tile` |
| `demResolution` | 分辨率，单位米 |
| `verticalDatum` | 垂直基准 |
| `processingInfo` | 裁剪、重投影、切片说明 |

`RasterRelief` 不直接保存 raster 像素值，实际 DEM 数据在 `terrain.dem_tile`。

### 6.3 TINRelief 可选派生

如果需要 CityGML 导出或三维可视化，可从 DEM 采样生成低/中分辨率 TIN：

- `TINRelief` 写入 `citydb.feature`，`objectclass_id = 502`。
- `extent` 几何写入 `citydb.geometry_data` 后通过 `property.name = 'extent'` 关联。
- `tin` 几何写入 `citydb.geometry_data` 后通过 `property.name = 'tin'` 关联。
- 推荐 PostGIS 表达：`MULTIPOLYGON Z`，每个 polygon 是一个三角面。
- `geometry_properties = {"type": 7}`，对应官方枚举 `TriangulatedSurface`。

注意：TIN 是 DEM 的派生简化产物，不作为路径规划的唯一高程源。

## 7. 建筑 LoD1 高程更新方案

现有建筑导入脚本目前以 `z=0` 生成 LoD1。引入 DEM 后改为：

```text
base_z = terrain.get_elevation(footprint, method='median')
roof_z = base_z + derived_height
```

更新内容：

1. 重建 `citydb.geometry_data.geometry` 的 `POLYHEDRALSURFACE Z`。
2. 更新 `citydb.feature.envelope`。
3. 保留/新增属性：
   - `derivedHeight`
   - `buildingHeightSource`
   - `terrainElevation`
   - `terrainElevationSource`
   - `terrainElevationMethod`
   - `verticalDatum`
   - `demDatasetKey`

建议高程采样方法默认使用 `median`，同时记录：

- centroid 高程
- footprint 顶点高程 min/max/median
- 地形坡度或高差估计

对于 footprint 内高差过大的建筑，标记质量风险：

```text
terrainDelta = max_sample_z - min_sample_z
terrainQualityFlag = 'large_terrain_delta'
```

## 8. UAV 路径规划预留设计

DEM 和建筑模型入库后，后续路径规划不直接遍历 3DCityDB 通用表，而是生成专用计算结构。

### 8.1 height grid

```sql
terrain.height_grid
```

字段建议：

- grid cell geometry
- ground elevation
- max obstacle elevation
- recommended minimum flight altitude
- source flags：DEM / building / no-fly-zone / manual obstacle

### 8.2 clearance grid

```sql
terrain.clearance_grid
```

用于记录不同高度层的可通行性：

- cell id
- altitude band
- occupied / free / unknown
- safety buffer

### 8.3 碰撞检测输入

后续障碍物来源：

- DEM 地形面
- 建筑 LoD1/LoD2
- 禁飞区 polygon
- 树木/林地高度估计
- 电塔、电线、通信塔等线性障碍物
- 人工标注障碍物

30m DEM 只能支持粗粒度地形避障；低空精细碰撞检测需要更高精度 DSM/LiDAR/航测模型。

## 9. 实施步骤

### 阶段 1：数据库准备

1. 检查 PostGIS raster 是否可用。
2. 创建 `terrain` schema。
3. 创建 `terrain.dem_dataset`、`terrain.dem_tile`。
4. 创建空间索引。
5. 确认 `citydb.objectclass` 中 Relief 类 id 存在。

### 阶段 2：DEM 获取与预处理

1. 选择数据源，优先 Copernicus DEM GLO-30 或 SRTMGL1。
2. 下载覆盖项目 polygon + buffer 的 GeoTIFF tile。
3. Mosaic 多个 tile，如需要。
4. 裁剪到项目范围 + buffer。
5. 重投影到 `EPSG:32650`。
6. 统一 nodata、单位和高程基准元数据。
7. 生成统计值：min/max/mean。

推荐使用 GDAL 命令或 Python/rasterio：

```text
gdalwarp -> gdal_translate -> raster2pgsql 或 Python 入库
```

### 阶段 3：写入 terrain schema

1. 插入 `terrain.dem_dataset` 元数据。
2. 切片写入 `terrain.dem_tile`。
3. 建立 `terrain.get_elevation` 采样函数。
4. 抽样验证若干经纬度点的高程。

本环境实测 PostGIS raster 可用，但数据库端 GDAL raster drivers 禁用，因此实施脚本不依赖
`ST_FromGDALRaster(bytea)`。实际采用本地 GDAL 裁剪/重投影后读取像元数组，再用
`ST_MakeEmptyRaster`、`ST_AddBand`、`ST_SetValues` 构造 PostGIS raster。

### 阶段 4：写入 3DCityDB Relief 元数据

1. 创建 `ReliefFeature`。
2. 创建 `RasterRelief`，引用 `terrain.dem_dataset` / `terrain.dem_tile`。
3. 通过 `reliefComponent` property 关联。
4. 可选生成 `TINRelief` 并写入简化 TIN 几何。

### 阶段 5：更新建筑绝对高程

1. 修改现有 OSM 建筑导入脚本，增加：
   - `--dem-dataset-key`
   - `--terrain-method median|min|centroid`
   - `--base-z-mode zero|terrain`
2. 对已有建筑重新采样 DEM 高程。
3. 重建 LoD1 solid。
4. 写入高程相关属性。
5. 输出质量报告。

### 阶段 6：路径规划派生数据，后续实现

1. 生成 height grid。
2. 合并建筑 roof_z 和 DEM ground_z。
3. 加安全缓冲高度。
4. 输出 UAV 规划服务可直接查询的表/视图。

## 10. 验收标准

### DEM 入库

- `terrain.dem_dataset` 至少有一条数据集记录。
- `terrain.dem_tile` 覆盖项目 polygon + buffer。
- DEM tile SRID 为 `32650`。
- min/max/mean 高程统计非空且数值合理。
- `terrain.get_elevation(x, y)` 在项目范围内可返回米制高程。

### 3DCityDB Relief

- `citydb.feature` 中存在 `ReliefFeature`，`objectclass_id = 500`。
- 存在 `RasterRelief` 或 `TINRelief` 子对象。
- `ReliefFeature` 通过 `property.name = 'reliefComponent'` 正确关联子对象。
- `RasterRelief` 记录了 DEM 数据源、分辨率、垂直基准和 `terrain.dem_tile` 引用。

### 建筑更新

- 建筑 LoD1 solid 不再从 `z=0` 起，而是从 terrain elevation 起。
- 每栋建筑记录：`terrainElevation`、`terrainElevationSource`、`demDatasetKey`。
- 建筑几何 SRID 仍为 `32650`。
- 重复执行不产生重复建筑、重复 Relief 对象或重复 DEM 数据集。

## 11. 风险与待确认项

1. **DEM 许可**：不同数据源下载和再分发限制不同，实施前需要确认。
2. **垂直基准**：DEM 高程基准需记录清楚，不能混同椭球高和正高。
3. **精度限制**：30m DEM 不适合精细低空避障。
4. **PostGIS raster 可用性**：目标数据库可能未安装 `postgis_raster` 扩展，需要准备外部 GeoTIFF 引用方案。
5. **3DCityDB RasterRelief 限制**：3DCityDB 5.x 没有专门 raster 像素字段，因此只保存 RasterRelief 元数据和引用。
6. **坡地建筑**：单个 base_z 可能不能表达大坡度建筑，需记录高差质量标记。
7. **性能**：路径规划不要实时扫 3DCityDB 通用表，应预生成 height grid / clearance grid。

## 12. 建议下一步

1. 检查目标数据库是否支持 `postgis_raster`。
2. 选定 DEM 数据源，优先 Copernicus DEM GLO-30；如下载受限，使用 SRTMGL1 v3。
3. 实现 `terrain` schema 和 DEM 导入脚本。
4. 实现高程采样函数。
5. 更新现有 OSM 建筑导入脚本，使建筑落到 DEM 地形高程上。
