# Terrain 高程基准记录

## 1. 当前 terrain 数据集

当前已导入的地形高程数据集：

| 字段 | 值 |
| --- | --- |
| `dataset_key` | `copernicus-dem-glo30-huaguoshan` |
| 数据源 | Copernicus DEM GLO-30 |
| 数据类型 | 开放 DEM/DSM 派生高程数据 |
| 水平坐标系 | `EPSG:32650`，WGS 84 / UTM zone 50N |
| 水平单位 | 米 |
| 高程单位 | 米 |
| 数据库位置 | `terrain.dem_dataset`、`terrain.dem_tile` |
| 3DCityDB 语义对象 | `ReliefFeature` + `RasterRelief` |

> 该数据不是 LiDAR、倾斜摄影、无人机航测模型或权威三维城市模型。

## 2. 垂直基准说明

当前 `terrain` 中的 `z` 值直接来自 Copernicus DEM GLO-30 原始高程值。

实际含义应按 Copernicus DEM 产品说明理解为：

```text
EGM2008 geoid / orthometric height / metres
```

也就是近似“海拔高程”或“正高”，而不是 WGS84 椭球高。

当前数据库中建议记录为：

```text
EGM2008 geoid, orthometric height, metres; source: Copernicus DEM GLO-30
```

## 3. 与 EPSG:32650 的关系

`EPSG:32650` 只定义水平坐标：

```text
x/y = WGS 84 / UTM zone 50N，单位米
```

它不自动定义垂直基准。因此本项目当前三维坐标的完整解释是：

```text
x/y = EPSG:32650
z   = Copernicus DEM GLO-30 高程，近似 EGM2008 正高，单位米
```

不要把当前 `z` 直接解释为：

- WGS84 椭球高
- 本地工程相对高程
- 无人机 GNSS 原始高度
- 精密测绘高程

## 4. 建筑物 z 值含义

现有 OSM 建筑 LoD1 已按 DEM 更新基底高程：

```text
building_base_z = terrain.get_elevation_for_geom(footprint, 'median', dataset_key)
building_roof_z = building_base_z + derived_height
```

其中：

- `building_base_z` 使用 Copernicus DEM 高程基准。
- `derived_height` 来自 OSM `height`、`building:levels` 或默认高度。
- OSM 建筑高度可能缺失或不准确。

## 5. 对无人机路径规划的影响

如果后续进行 AGL 高度计算：

```text
AGL = drone_z - terrain_z
```

必须确保 `drone_z` 与 `terrain_z` 使用同一垂直基准。

如果无人机提供的是 GNSS/WGS84 椭球高，需要先做大地水准面改正：

```text
orthometric_height = ellipsoid_height - geoid_undulation
```

否则可能产生几十米级高度偏差。

## 6. 当前数据库状态

状态：**已记录并同步到数据库**。

当前 `terrain.dem_dataset.vertical_datum` 已更新为：

```text
EGM2008 geoid, orthometric height, metres; source: Copernicus DEM GLO-30
```

当前 3DCityDB `RasterRelief` 的通用属性 `verticalDatum` 也已同步为同一文本。

当前建筑物 LoD1 已使用 DEM terrain 高程作为基底高程，建筑 z 的解释与本文件一致。

## 7. 后续建议

1. 后续引入其他 DEM/DSM/LiDAR 数据时，必须记录：
   - 垂直基准
   - 高程单位
   - 数据源
   - 处理流程
   - 是否经过 geoid/ellipsoid 转换

2. UAV 路径规划模块应显式声明输入高度基准，不允许混用椭球高和正高。

3. 如果无人机只提供 WGS84/GNSS 椭球高，应在进入路径规划和碰撞检测前转换到与 terrain 一致的正高基准，或在系统中明确维护双高程字段。
