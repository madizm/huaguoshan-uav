# GEOVIS iBEST-DB V6.1.0 用户手册 (LLM优化版)

> 本文档是GEOVIS iBEST-DB V6.1.0用户手册的整理版本，专门优化以便于大语言模型(LLM)理解和使用。
> 原始文档中的图片引用已移除，关键概念用文字描述替代。

---

## 目录

1. [概述](#概述)
2. [核心概念](#核心概念)
3. [数据类型](#数据类型)
4. [函数参考](#函数参考)
5. [快速入门示例](#快速入门示例)
6. [常见问题解答](#常见问题解答)

---

## 概述

GEOVIS iBEST-DB是一个基于PostgreSQL的地理空间数据库扩展，主要功能包括：

1. **地理网格模型**：基于GeoSOT理论实现的二维/三维空间网格数据模型
2. **北斗网格码**：支持BGC、GGER、RSLC等多种编码规范
3. **空间索引**：基于BTree和GIN的空间索引实现
4. **IoT时序数据**：高通量时空数据存储优化

### 主要扩展模块

| 扩展名称 | 功能描述 |
|---------|---------|
| `best_geomgrid` | 地理网格模型核心扩展 |
| `best_geomgrids` | 网格集合模型扩展 |
| `best_iot` | IoT时序数据扩展 |

---

## 核心概念

### GeoSOT-2D (地球表面剖分)

GeoSOT-2D是一种基于空间标志的全球地理位置框架和编码方法。通过对地球表面经纬度系统进行度分秒三次扩展，实现整度、整分、整秒的地球空间四叉树剖分，形成一个上至整个地球、下至厘米级面元的多尺度四叉树网格。

**层级范围**：0-32级
**编码格式**：二进制编码 + 层级

### GeoSOT-3D (地球三维立体剖分)

在平面网格基础上，通过高度维扩展，形成上至地球外围50万km空间、下至地心的空天地海全空间立体剖分网格。

**高度域规则**：对于任意剖分级数m，高度域剖分成2^2m层，地下为2^2m-1层，地上为2^2m-1层。

### 网格关系术语

| 术语 | 定义 |
|------|------|
| **单元网格(GridCell)** | GeoSOT中的一个单元网格，表示地球表面或三维空间中的一定地理区域范围 |
| **父网格** | 若cellA的层级+1=cellB的层级，且cellB由cellA分隔而来，则cellA为cellB的父网格 |
| **子网格** | 若cellA为cellB的父网格，则cellB为cellA的子网格 |
| **祖先网格** | 层级较小且通过多次分隔得到的上层网格 |
| **后代网格** | 层级较大且由祖先网格多次分隔得到的下层网格 |
| **亲属网格** | 两个网格相等，或互为祖先/后代关系 |

### 编码规范

#### GGER (地球空间网格编码规则)

- **标准**：GB/T 40087-2021
- **2D格式**：以`G`开头，每层级用四进制字符表示，如`G0013103220310311`
- **3D格式**：以`GZ`开头，每层级用八进制字符表示，如`GZ002242242026624`

#### BGC (北斗网格位置码)

- **标准**：GB/T 39409-2020
- **层级范围**：1-10级
- **兼容性**：4-10级与GeoSOT网格一一对应

#### RSLC (实景三维中国-基础地理实体位置码)

- **层级范围**：1-16级
- **2D编码**：26位数字字母混合编码
- **3D编码**：44位编码（二维编码+高度维编码）
- **兼容性**：4、8、10-16级与GeoSOT网格对应

---

## 数据类型

### gridcell (2D/3D)

表示GeoSOT-2D/GeoSOT-3D中的一个单元网格。

**存储结构**：
- 2D网格：`code`(二维编码, unsigned long) + `level`(网格层级, unsigned char)
- 3D网格：`code`(二维编码) + `zcode`(高度维编码, unsigned int) + `level`(网格层级)

**空间意义**：
- 2D gridCell：表示一个矩形空间范围
- 3D gridCell：表示一个近似立方体的空间范围

**支持的转换**：

| 源类型 | 目标类型 |
|-------|---------|
| text(GGER) | gridcell |
| 坐标点(lng,lat,level) | gridcell |
| geomgrids | gridcell |
| gridcell | text(GGER) |
| gridcell | geometry |
| gridcell | box |
| gridcell | geomgrids |

### geomgrids (2D/3D)

由层级相同或不同的gridcell集合组成，表示地球表面空间特定的区域范围。

**JSON输出格式**：
```json
{
  "cells": ["526536327332626432:12", "526537426844254208:12"],
  "detailLevel": 12,
  "nCell": 2,
  "is3d": false
}
```

**字段含义**：

| 参数名称 | 描述 |
|---------|------|
| cells | gridcell编码数组 |
| detailLevel | 最大层级 |
| nCell | gridcell数量 |
| is3d | 是否为3D网格集合 |

---

## 函数参考

### 一、GridCell 输入输出函数

#### ST_AsGridcell

通过经纬度和层级构建2D GridCell对象。

```sql
gridcell ST_AsGridcell(double lng, double lat, integer level)
```

| 参数 | 描述 |
|------|------|
| lng | 位置经度，范围[-180.0, 180.0] |
| lat | 位置纬度，范围[-88.0, 88.0] |
| level | 网格层级，范围[1,32]，默认12 |

**示例**：
```sql
SELECT ST_AsGridcell(113.22, 40.1, 12);
-- 结果: 531496224285523968:12
```

#### ST_AsGridcell3D

通过经度、纬度、高程和层级构建3D GridCell对象。

```sql
gridcell ST_AsGridcell3D(double lng, double lat, double height, integer level)
```

| 参数 | 描述 |
|------|------|
| lng | 位置点经度，范围[-180.0, 180.0] |
| lat | 位置点纬度，范围[-88.0, 88.0] |
| height | 位置点大地高(单位m)，范围[-6302106.7222, 528680167.3367] |
| level | 网格层级，范围[1,32]，默认12 |

**示例**：
```sql
SELECT ST_AsGridcell3D(113.22, 40.1, 100, 12);
-- 结果: 531496224285523968,0:12
```

#### ST_AsText(gridcell, text)

将gridcell转换为指定规范的文本编码。

```sql
text ST_AsText(gridcell cell, text standard default 'GGER')
```

| 参数 | 描述 |
|------|------|
| cell | gridcell对象 |
| standard | 网格标准：GGER、BGC、RSLC、RAW，默认GGER |

**支持的层级输出**：
- BGC：15、19、20、23、26、29、32层级
- RSLC：9、15、19、20、21、23、26、29、32层级

**示例**：
```sql
-- GGER格式输出
SELECT ST_AsText(ST_AsGridcell(116.315222, 39.910278, 15));
-- 结果: G001310322230230

-- BGC格式输出
SELECT ST_AsText(ST_AsGridcell(116.315222, 39.910278, 15), 'BGC');
-- 结果: N50J47534

-- RSLC格式输出
SELECT ST_AsText(ST_AsGridcell(116.315222, 39.910278, 15), 'RSLC');
-- 结果: NE104J2525034
```

#### ST_GridCellFromText

通过指定规范的文本编码构造gridcell。

```sql
gridcell ST_GridCellFromText(text code, text standard)
```

| 参数 | 描述 |
|------|------|
| code | 文本编码 |
| standard | 网格标准：GGER、BGC-2D、BGC-3D、RSLC-2D、RSLC-3D、RAW |

**示例**：
```sql
-- GGER 2D
SELECT ST_GridCellFromText('G001312100003', 'GGER');
-- 结果: 532553954471444480:12

-- BGC 2D
SELECT ST_GridCellFromText('N50I06033', 'BGC-2D');
-- 结果: 523402976891502592:15

-- RSLC 2D
SELECT ST_GridCellFromText('NE104J2525334328', 'RSLC-2D');
-- 结果: 526549775210774528:19
```

#### ST_AsGeometry(gridcell)

返回gridcell空间范围对应的Geometry对象。

```sql
geometry ST_AsGeometry(gridcell cell)
```

- 2D网格返回Polygon类型
- 3D网格返回POLYHEDRALSURFACE Z类型

#### ST_AsBox(gridcell)

返回gridcell的二维范围(box)。

```sql
box ST_AsBox(gridcell cell)
```

#### ST_AsBox3D(gridcell)

返回gridcell的三维范围(box3d)。

```sql
box ST_AsBox3D(gridcell cell)
```

---

### 二、GridCell 属性与计算函数

#### ST_Center(gridcell)

获取单元网格的二维几何中心点。

```sql
Point ST_Center(gridcell cell)
```

#### ST_Level(gridcell)

获取单元网格的层级。

```sql
integer ST_Level(gridcell cell)
```

#### ST_Is3D(gridcell)

判断gridcell是否为3D网格。

```sql
boolean ST_Is3D(gridcell cell)
```

#### ST_Force2D(gridcell)

将gridcell强制转换为2D网格。

```sql
gridcell ST_Force2D(gridcell cell)
```

#### ST_Force3D(gridcell)

将gridcell强制转换为3D网格。

```sql
gridcell ST_Force3D(gridcell cell)
```

#### ST_GetSidesLength(gridcell, text)

获取单元网格的边长。

```sql
float8[] ST_GetSidesLength(gridcell cell, text flag default 'M')
```

| 参数 | 描述 |
|------|------|
| cell | 单元网格 |
| flag | 'M'表示米，'D'表示度，默认'M' |

**返回值**：[东西向边长, 南北向边长, 高度边长]

#### ST_GetArea(gridcell)

获取单元网格的面积(平方米)。要求层级>=6。

```sql
float8 ST_GetArea(gridcell cell)
```

#### ST_GetVolume(gridcell)

获取单元网格的体积(立方米)。要求层级>=6。

```sql
float8 ST_GetVolume(gridcell cell)
```

#### ST_DistanceSpheroid(gridcell, gridcell, spheroid)

计算两个网格间的球面距离(米)。仅支持2D。

```sql
double ST_DistanceSpheroid(gridcell cell1, gridcell cell2,
    spheroid a_spheroid default 'SPHEROID["WGS 84",6378137,298.257223563]')
```

#### ST_Angle(gridcell, gridcell)

获取两个网格间的方位角(度)。仅支持2D。

```sql
float8 ST_Angle(gridcell cell1, gridcell cell2)
```

#### ST_Direction(gridcell, gridcell)

获取两个网格间的定性方向。

```sql
DIRECTION ST_Direction(gridcell cell1, gridcell cell2)
```

**返回值枚举**：NORTH, SOUTH, EAST, WEST, EAST_NORTH, EAST_SOUTH, WEST_NORTH, WEST_SOUTH, UNKNOWN

**方位角对应关系**：

| 定性方向 | 方位角区间(度) |
|---------|---------------|
| NORTH | (0,22.5] && (337.5,360] |
| EAST_NORTH | (22.5,67.5] |
| EAST | (67.5,112.5] |
| EAST_SOUTH | (112.5,157.5] |
| SOUTH | (157.5,202.5] |
| WEST_SOUTH | (202.5,247.5] |
| WEST | (247.5,292.5] |
| WEST_NORTH | (292.5,337.5] |

#### ST_GetNeibers(gridcell, integer)

获取网格的4邻域或8邻域。仅支持2D。

```sql
gridcell[] ST_GetNeibers(gridcell cell, integer count default -1)
```

| 参数 | 描述 |
|------|------|
| cell | 2D单元网格 |
| count | -1表示8邻域，4表示4邻域 |

#### ST_GetNeibers3D(gridcell, integer)

获取3D网格的6、18或26邻域。

```sql
gridcell[] ST_GetNeibers3D(gridcell cell, integer count default -1)
```

| 参数 | 描述 |
|------|------|
| cell | 3D单元网格 |
| count | -1表示26邻域，6表示6邻域，18表示18邻域 |

---

### 三、GridCell 网格关系函数

#### ST_GetParent(gridcell)

获取父网格。

```sql
gridcell ST_GetParent(gridcell cell)
```

#### ST_GetAncestor(gridcell, integer)

获取指定层级的祖先网格。

```sql
gridcell ST_GetAncestor(gridcell cell, integer level)
```

#### ST_GetDescendant(gridcell, integer)

获取后代网格数组。

```sql
gridcell[] ST_GetDescendant(gridcell cell, integer level)
```

**限制**：
- 2D：支持5代以内后代网格
- 3D：支持3代以内后代网格

#### ST_AncestorOf(gridcell, gridcell)

判断是否为祖先关系。

```sql
bool ST_AncestorOf(gridcell left, gridcell right)
```

#### ST_DescendantOf(gridcell, gridcell)

判断是否为后代关系。

```sql
bool ST_DescendantOf(gridcell left, gridcell right)
```

#### ST_FamilyOf(gridcell, gridcell)

判断是否为亲属关系。

```sql
bool ST_FamilyOf(gridcell left, gridcell right)
```

#### ST_GetNextBrother(gridcell)

获取给定gridcell同层级的下一个网格（按Code排序），用于在Btree索引下查询子网格。主要用于点数据基于网格聚合的场景。

```sql
gridcell ST_GetNextBrother(gridcell cell)
```

**原理**：gridcell在Btree索引下按code排序，cellC是CellA的NextBrother，如果cellB是cellA的子网格，则cellB肯定位于(cellA,cellC)区间。

**示例**：
```sql
SELECT ST_GetNextBrother('394383914082238464:18'::gridcell);
-- 结果: 394383914350673920:18
```

#### ST_GetNeiber(gridcell, integer)

获取指定方向的相邻网格。仅支持2D。

```sql
gridcell ST_GetNeiber(gridcell cell, integer neiberType)
```

| 参数 | 描述 |
|------|------|
| cell | 当前单元网格 |
| neiberType | 相邻网格类型：0-正北，1-东北，2-正东，3-东南，4-正南，5-西南，6-正西，7-西北 |

**示例**：
```sql
SELECT ST_GetNeiber(ST_AsGridcell(28.01, 39.5, 15), 3);
-- 结果: 170726169786712064:15
```

#### ST_GetNeiber3D(gridcell, integer)

获取指定方向的3D相邻网格。仅支持3D。

```sql
gridcell ST_GetNeiber3D(gridcell cell, integer neiberType)
```

| 参数 | 描述 |
|------|------|
| cell | 3D单元网格 |
| neiberType | 相邻网格类型(0-25)：0-正北，1-东北，...，8-正上，...，17-正下，...，25-西北下 |

#### ST_VisibilityAnalysis(gridcell, gridcell, text, text)

已知空间区域环境网格集合，求其中两个网格是否可视（即两个网格之间的连线没有其他网格遮挡）。

```sql
boolean ST_VisibilityAnalysis(gridcell cell1, gridcell cell2, text tableName, text field)
```

| 参数 | 描述 |
|------|------|
| cell1 | 单元网格起始点 |
| cell2 | 单元网格终止点 |
| tableName | 空间区域网格集合存储表 |
| field | 网格集合字段名，类型为geomgrids |

---

### 四、GridCell 空间关系函数

#### ST_Equals(gridcell, gridcell)

比较两个gridcell是否相等。仅支持2D。

```sql
bool ST_Equals(gridcell leftcell, gridcell rightcell)
```

#### ST_Intersects(gridcell, gridcell)

判断两个gridcell空间范围是否有交集。仅支持2D。

```sql
bool ST_Intersects(gridcell leftcell, gridcell rightcell)
```

#### ST_WithIn(gridcell, gridcell)

判断leftcell是否被rightcell完全覆盖。仅支持2D。

```sql
bool ST_WithIn(gridcell leftcell, gridcell rightcell)
```

#### ST_Contains(gridcell, gridcell)

判断leftcell是否完全覆盖rightcell。仅支持2D。

```sql
bool ST_Contains(gridcell leftcell, gridcell rightcell)
```

---

### 五、GridCell 操作符

| 操作符 | 描述 | 索引支持 |
|--------|------|----------|
| `=` | 判断相等 | BTree |
| `&&` | 判断相交 | 否 |
| `@>` | 判断包含 | 否 |
| `<@` | 判断被包含 | 否 |
| `<` | 小于比较 | BTree |
| `<=` | 小于等于 | BTree |
| `>` | 大于比较 | BTree |
| `>=` | 大于等于 | BTree |

---

### 六、GeomGrids 输入输出函数

#### ST_AsGrids(geometry...)

通过Geometry构建GeomGrids对象。

```sql
geomgrids ST_AsGrids(geometry geom, integer detailLevel, bool isAgg)
geomgrids ST_AsGrids(geometry geom, integer detailLevel)
geomgrids ST_AsGrids(geometry geom)
```

| 参数 | 描述 |
|------|------|
| geom | 几何对象，SRID需为4490或4326 |
| detailLevel | 打码最精细层级，范围[6,32] |
| isAgg | 是否开启网格聚合，默认true |

**网格模式**：
- **plain模式**：所有gridcell层级相同，数据量大
- **agg(aggregate)模式**：合并兄弟网格，减少存储空间

#### ST_AsGrids3D(geometry...)

通过3D Geometry构建3D GeomGrids对象。

```sql
geomgrids ST_AsGrids3D(geometry geom, integer detailLevel, bool isAgg)
```

要求geometry含有Z维度信息。

#### ST_AsGrids(gridcell[])

通过gridcell数组构建GeomGrids对象。

```sql
geomgrids ST_AsGrids(gridcell[] cells)
```

注意：数组中不能同时存在2D和3D网格。

#### ST_AsGrids(gridcell)

通过单个gridcell对象构建GeomGrids对象。

```sql
geomgrids ST_AsGrids(gridcell cell)
```

**示例**：
```sql
-- 2D
SELECT ST_AsGrids(ST_GridCellFromText('G00131032220212'));
-- 结果: {"cells":["526536739649486848:14"],"detailLevel":14,"is3d":false,"nCell":1}

-- 3D
SELECT ST_AsGrids(ST_GridCellFromText('GZ002626044'));
-- 结果: {"cells":["536632043098865664,0:9"],"detailLevel":9,"is3d":true,"nCell":1}
```

#### ST_AsText(geomgrids, text)

将GeomGrids转换为指定规范的文本。

```sql
text ST_AsText(geomgrids grids, text standard)
```

#### ST_AsGeometry(geomgrids)

返回GeomGrids对应的Geometry对象。

```sql
geometry ST_AsGeometry(geomgrids grids)
```

- 2D返回MultiPolygon
- 3D返回GEOMETRYCOLLECTION Z (POLYHEDRALSURFACE Z)

#### ST_WithBox(geomgrids, text)

输出网格码的同时包括网格Bbox信息。支持2D/3D。

```sql
text ST_WithBox(geomgrids grids, text standard)
```

| 参数 | 描述 |
|------|------|
| grids | 需要输出的网格集合对象 |
| standard | 规范标准：GGER（默认）。如果指定其他，则单元网格按原始方式输出 |

**返回值JSON字段**：

| 字段名称 | 描述 |
|---------|------|
| cells | gridcell编码数组 |
| detailLevel | 最大层级 |
| bbox | 包围盒信息，格式`(minLon,minLat,minHeight,maxLon,maxLat,maxHeight)`，2D时minHeight、maxHeight为0.0 |

**示例**：
```sql
-- 2D Grids输出BBox
SELECT ST_WithBox(ST_AsGrids(ST_GeomFromText('POINT(116.315 39.910)', 4326)));
-- 结果: {"cells":[{"bbox":"(116.2667 39.8000 0.0000,116.4000 39.9333 0.0000)","code":"G0013..."}]}

-- 3D Grids输出BBox
SELECT ST_WithBox(ST_AsGrids3D(...));
```

#### ST_AsGridCellArray(geomgrids)

将GeomGrids转换为gridcell数组。

```sql
gridcell[] ST_AsGridCellArray(geomgrids grids)
```

---

### 七、GeomGrids 属性函数

#### ST_Is3D(geomgrids)

判断是否为3D网格集合。

```sql
boolean ST_Is3D(geomgrids grids)
```

#### ST_DetailLevel(geomgrids)

获取最大层级。

```sql
integer ST_DetailLevel(geomgrids grids)
```

#### ST_nCells(geomgrids)

获取单元网格数量。

```sql
integer ST_nCells(geomgrids grids)
```

#### ST_GetArea(geomgrids)

获取网格集总面积(平方米)。

```sql
float8 ST_GetArea(geomgrids grids)
```

#### ST_Centroid(geomgrids)

返回网格集重心。仅支持2D。

```sql
point ST_Centroid(geomgrids grids)
```

#### ST_DistanceSpheroid(geomgrids, geomgrids, spheroid)

计算两个网格集的球面距离(米)。仅支持2D。

```sql
double ST_DistanceSpheroid(geomgrids grids1, geomgrids grids2,
    spheroid a_spheroid default 'SPHEROID["WGS 84",6378137,298.257223563]')
```

---

### 八、GeomGrids 空间关系函数

#### ST_Intersects(geomgrids, geomgrids)

判断两个Grids对象是否相交。支持GIN索引。

```sql
boolean ST_Intersects(geomgrids left, geomgrids right)
```

#### ST_Equals(geomgrids, geomgrids)

判断两个Geomgrids对象是否相等。支持GIN索引。

```sql
boolean ST_Equals(geomgrids left, geomgrids right)
```

#### ST_WithIn(geomgrids, geomgrids)

判断left是否被right包含。支持2D/3D。

```sql
boolean ST_WithIn(geomgrids left, geomgrids right)
```

#### ST_Contains(geomgrids, geomgrids)

判断left是否包含right。支持GIN索引。

```sql
boolean ST_Contains(geomgrids left, geomgrids right)
```

#### ST_Adjacent(geomgrids, geomgrids)

判断两个网格集是否相邻。不支持GIN索引。

```sql
boolean ST_Adjacent(geomgrids grids1, geomgrids grids2)
```

---

### 九、GeomGrids 叠置分析函数

#### ST_Intersection(geomgrids, geomgrids)

获取两个GeomGrids对象的交集。不支持索引。

```sql
geomgrids ST_Intersection(geomgrids left, geomgrids right)
```

#### ST_Union(geomgrids, geomgrids)

获取两个GeomGrids对象的并集。不支持索引。

```sql
geomgrids ST_Union(geomgrids left, geomgrids right)
```

---

### 十、GeomGrids 操作符

| 操作符 | 描述 | 索引支持 |
|--------|------|----------|
| `=` | 判断相等 | GIN |
| `&&` | 判断相交 | GIN |
| `@>` | 判断包含 | GIN |
| `<@` | 判断被包含 | GIN |

---

### 十一、BGC编码函数

#### ST_asBGC

经纬度坐标生成BGC-2D编码。

```sql
text ST_asBGC(double lng, double lat, int level)
```

| 参数 | 描述 |
|------|------|
| lng | 坐标经度，范围[-180,180] |
| lat | 坐标纬度，范围[-88,88] |
| level | BGC层级，范围[1,10] |

#### ST_asBGC3D

经纬度和高程生成BGC-3D编码。

```sql
text ST_asBGC3D(double lng, double lat, double height, int level)
```

#### ST_BGC2Box

通过BGC编码获取网格的box。

```sql
box ST_BGC2Box(text bgcode)
```

#### ST_BGC3D2Box

通过BGC-3D编码获取网格的box3d。

```sql
box ST_BGC3D2Box(text bgcode)
```

---

### 十二、RSLC编码函数

#### ST_asRSLC

经纬度坐标生成RSLC 2D编码。

```sql
text ST_asRSLC(double lng, double lat, int level)
```

| 参数 | 描述 |
|------|------|
| lng | 坐标经度，范围[-180,180] |
| lat | 坐标纬度，范围[-88,88] |
| level | 层级，范围[1,16] |

#### ST_asRSLC3D

经纬度和高程生成RSLC 3D编码。

```sql
text ST_asRSLC3D(double lng, double lat, double height, int level)
```

#### ST_RSLC2Box

通过RSLC 2D编码获取网格的box。

```sql
box ST_RSLC2Box(text RSLC2D)
```

#### ST_RSLC3D2Box

通过RSLC 3D编码获取网格的box3d。

```sql
box3d ST_RSLC3D2Box(text RSLC3D)
```

---

### 十三、路径规划函数

#### ST_FindGridsPath

基于A-Star算法的无路网规划，返回最优路径的gridcell集合。

```sql
gridcell[] ST_FindGridsPath(gridcell startCell, gridcell endCell,
    text tableName, text gridsfiled, bool hasBelow default false)
```

| 参数 | 描述 |
|------|------|
| startCell | 起始点网格 |
| endCell | 终止点网格 |
| tableName | 障碍区域表名 |
| gridsfiled | 障碍区域表中的geomgrids字段名 |
| hasBelow | 是否需要海平面以下网格，默认false |

#### ST_RouteFromGridsPath

将gridcell数组转换为Geometry路径。

```sql
geometry ST_RouteFromGridsPath(gridcell[] cells)
```

#### ST_RouteFromGridsPath(geometry, geometry, gridcell[])

将gridcell数组转换为Geometry路径，起始点和结束点根据指定点来匹配。

```sql
geometry ST_RouteFromGridsPath(geometry startPoint, geometry endPoint, gridcell[] gridcells)
```

| 参数 | 描述 |
|------|------|
| startPoint | 起始点 |
| endPoint | 终止点 |
| gridcells | gridcell对象集合 |

**示例**：
```sql
SELECT ST_AsText(ST_RouteFromGridsPath(
    ST_GeomFromText('POINT(9 10)'),
    ST_GeomFromText('POINT(11 10)'),
    ST_FindGridsPath(ST_AsGridCell(9,10), ST_AsGridCell(11,10), 'test', 'grids')
));
-- 结果: LINESTRING(9 10,9.0667 10.0667,...,11 10)
```

#### ST_SmoothRouteFromGridsPath

将gridcell集合压缩平滑成轨迹路径。

```sql
geometry ST_SmoothRouteFromGridsPath(gridcell[] cells, text tableName, text geomfiled)
```

---

### 十四、辅助函数

#### ST_ExturdeGeometry

将二维geometry拉伸成三维多面体。

```sql
geometry ST_ExturdeGeometry(geometry geom, float h, float z)
```

| 参数 | 描述 |
|------|------|
| geom | 二维geometry对象 |
| h | 底面大地高(米) |
| z | 拉伸高度(米) |

#### ST_Grids23dtiles

将GeomGrids导出为3DTiles模型。

```sql
text ST_Grids23dtiles(geomgrids grids, text savePath)
```

#### ST_CreateTableFromGeom

根据输入的geometry类型，对空间数据进行网格构建，将生成的网格集合存储到表中，并将每个网格对应的GGER、BGC、RSLC编码及geometry数据存储到表中。

```sql
integer ST_CreateTableFromGeom(text tableName, geometry geom, integer level, boolean gger, boolean bgc, boolean rslc)
```

| 参数 | 描述 |
|------|------|
| tableName | 生成的表名 |
| geom | 输入的geometry数据 |
| level | 网格码层级 |
| gger | 是否生成GGER码，默认true |
| bgc | 是否生成BGC码，默认false |
| rslc | 是否生成RSLC码，默认false |

**返回表字段**：

| 字段名称 | 描述 |
|---------|------|
| id | 自增类型 |
| cell | gridcell类型 |
| geom | cell对应的geometry类型 |
| gger | GGER码（gger=true时存在） |
| bgc | BGC码（bgc=true且level合法时存在） |
| rslc | RSLC码（rslc=true且level合法时存在） |

#### ST_Geom2Shpfile

根据输入的geometry类型，对空间数据进行网格构建，存储到表中并导出到Shapefile文件。

```sql
integer ST_Geom2Shpfile(text tableName, text shpfile_url, geometry geom, integer level, boolean gger, boolean bgc, boolean rslc)
```

| 参数 | 描述 |
|------|------|
| tableName | 生成的表名 |
| shpfile_url | 导出shpfile文件的绝对路径 |
| geom | 输入的geometry数据 |
| level | 网格码层级 |
| gger | 是否生成GGER码，默认true |
| bgc | 是否生成BGC码，默认false |
| rslc | 是否生成RSLC码，默认false |

**返回值**：导出到shpfile的记录数

#### ST_DrawGrids

二维网格绘制函数，返回网格线信息(JSON格式)。

```sql
text ST_DrawGrids(double west, double south, double east, double north, integer level)
text ST_DrawGrids(integer level)  -- 全球范围
```

---

## 快速入门示例

### GridCell 应用示例

```sql
-- 1. 创建扩展
CREATE EXTENSION best_geomgrid CASCADE;

-- 2. 创建含有gridcell字段的表
CREATE TABLE t_test(
    lng double precision,
    lat double precision,
    id int,
    cell gridcell
);

-- 3. 插入数据并生成25级网格
INSERT INTO t_test
SELECT id, x, y, ST_AsGridcell(x, y, 25)
FROM (
    SELECT id, -180+360*random() x, -88+176*random() y
    FROM generate_series(1, 1000000) t(id)
) t;

-- 4. 创建BTREE索引
CREATE INDEX t_test_cell_btree ON t_test USING btree(cell btree_gridcell_ops);

-- 5. 单网格查询
SELECT * FROM t_test
WHERE ST_Intersects(ST_GridCellFromText('G00131032'), cell);

-- 6. 多边形查询
WITH filtergrid AS (
    SELECT unnest(ST_AsGridCellArray(ST_AsGrids(
        ST_GeomFromText('POLYGON((116.168188 40.158828, 116.621415 40.137732, ...))')
    ))) AS cell
)
SELECT b.* FROM filtergrid a JOIN t_test b ON ST_Contains(a.cell, b.cell);

-- 7. 基于网格聚合统计
WITH filtergrid AS (
    SELECT unnest(ST_AsGridCellArray(ST_AsGrids(
        ST_GeomFromText('POLYGON((...))')
    ))) AS cell
)
SELECT a.cell, ST_AsBox(a.cell), COUNT(b.cell) AS num
FROM filtergrid a LEFT JOIN t_test b ON ST_Contains(a.cell, b.cell)
GROUP BY a.cell;

-- 8. 删除扩展
DROP EXTENSION best_geomgrid CASCADE;
```

### GeomGrids 应用示例

```sql
-- 1. 创建扩展
CREATE EXTENSION best_geomgrid CASCADE;

-- 2. 在含有Geometry字段的表中增加geomgrids字段
ALTER TABLE town_bound ADD COLUMN grids geomgrids;

-- 3. 通过geometry字段构建geomgrids对象
UPDATE town_bound SET grids = ST_AsGrids(geom);

-- 4. 创建GIN索引
CREATE INDEX idx_grid_town_bound ON town_bound USING gin(grids gin_grids_ops);

-- 5. 空间查询
-- 查询与指定范围相交的记录
SELECT gid, name FROM town_bound
WHERE grids && ST_AsGrids(ST_GeomFromText('POLYGON((...))'));

-- 查询被指定范围包含的记录
SELECT gid, name FROM town_bound
WHERE grids <@ ST_AsGrids(ST_GeomFromText('POLYGON((...))'));

-- 查询包含指定范围的记录
SELECT gid, name FROM town_bound
WHERE grids @> ST_AsGrids(ST_GeomFromText('POLYGON((...))'));
```

### 无路网路径规划示例

```sql
-- 1. 创建扩展
CREATE EXTENSION best_geomgrids CASCADE;

-- 2. 创建障碍区域表
CREATE TABLE barrierTable(id serial, grids geomgrids);

-- 3. 添加障碍区域数据
INSERT INTO barrierTable(grids)
VALUES(ST_AsGrids(ST_GeomFromText('POLYGON((116.4 36.2, 116.6 36.2, 116.6 36.4, 116.4 36.4, 116.4 36.2))')));

-- 4. 创建索引
CREATE INDEX barrierTable_grids_gin_idx
ON barrierTable USING gin(grids gin_grids_ops);

-- 5. 路径规划
SELECT ST_FindGridsPath(
    ST_AsGridcell(116.44, 36.29, 16),  -- 起点
    ST_AsGridcell(116.58, 36.54, 16),  -- 终点
    'barrierTable',                     -- 障碍表名
    'grids'                             -- 障碍字段名
);

-- 6. 生成路径Geometry
SELECT ST_AsText(ST_RouteFromGridsPath(ST_FindGridsPath(
    ST_AsGridcell(116.44, 36.29, 16),
    ST_AsGridcell(116.58, 36.54, 16),
    'barrierTable', 'grids'
)));
```

### IoT时序数据应用示例

```sql
-- 1. 创建扩展
CREATE EXTENSION best_iot CASCADE;

-- 2. 创建数据表
CREATE TABLE taxi(id varchar(20), update_time timestamp, geom geometry);

-- 3. 基于数据表创建超表
SELECT BESTDB_ShardingTrajectoryTable('taxi', 'update_time');

-- 4. 创建实时数据表
SELECT BESTDB_IOTCreateRealtimeTable('taxi', 'taxirel', 'id', 'update_time');

-- 5. 插入数据到历史表
INSERT INTO taxi VALUES('aaaafb', now(), ST_MakePoint(120, 90));

-- 6. 获取历史数据
SELECT * FROM taxi;

-- 7. 获取实时数据
SELECT * FROM taxirel;
```

---

## 空间索引

### gridcell BTree索引

gridcell数据格式支持BTree索引，目前仅支持2D。

```sql
-- 创建BTree索引
CREATE INDEX idx_cell ON t_test USING btree(cell btree_gridcell_ops);
```

**索引原理**：gridcell 2D网格码code是一个64位无符号整型，以code为排序顺序构建BTree索引。

**支持的操作符**：`<`, `<=`, `=`, `>=`, `>`

### geomgrids GIN索引

geomgrids数据格式支持GIN索引。

```sql
-- 创建GIN索引
CREATE INDEX idx_grids ON town_bound USING gin(grids gin_grids_ops);
```

**索引原理**：GIN是一种倒排索引，将Geomgrids对象中的各个GridCell叶节点及其6级以下的祖先节点作为分词构建查找树。

**支持的操作符**：`=`, `&&`, `@>`, `<@`

---

## 常见问题解答

### 1. GridCell与GeomGrids的适用场景分别是什么？

**GridCell**：
- 适用：Point数据类型的打码和空间索引
- 优点：打码速度快、索引性能高、索引数据量小
- 缺点：仅支持Point，空间运算/操作符/索引只支持2D

**GeomGrids**：
- 适用：任意Geometry对象的打码和空间索引
- 优点：适用于任意Geometry打码，支持2D/3D
- 缺点：相较于GridCell，打码速度慢，索引数据量大

**选择建议**：数据只有Point且不需要3D索引，优先使用GridCell；如果有NonPoint数据或需要3D索引，使用GeomGrids。

### 2. 如何实现快速打码？

函数ST_AsGrids(geometry)是CPU消耗较高的运算。PostgreSQL不支持并行update，但`CREATE TABLE AS SELECT`支持并行。

```sql
-- 环境设置
ALTER TABLE town_bound SET (parallel_workers = 4);
SET max_worker_processes = 16;
SET max_parallel_workers = 16;
SET max_parallel_workers_per_gather = 8;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
SET parallel_tuple_cost = 0;
SET parallel_setup_cost = 0;

-- 创建新表并打码
CREATE TABLE town_bound2 AS
SELECT gid, name, geom, ST_AsGrids(geom) FROM town_bound;
```

### 3. GeoSOT、GGER、BGC、RSLC之间的关系是什么？

| 编码规范 | 描述 | 层级范围 | 与GeoSOT关系 |
|---------|------|---------|-------------|
| GeoSOT | 剖分理论 | 0-32级 | 基础 |
| GGER | GB/T 40087-2021 | 0-32级 | 完全兼容 |
| BGC | GB/T 39409-2020 | 1-10级 | 4-10级对应 |
| RSLC | 实景三维中国 | 1-16级 | 部分层级对应 |

**使用建议**：
- 优先使用GGER，层级完整，可充分利用GridCell所有功能
- 仅在有BGC/RSLC输入输出需求时才使用BGC/RSLC

### 4. detailLevel参数如何选择？

- detailLevel越大，网格cell代表的区域范围越小，Grids中cell数量越多
- detailLevel每增加1，cell数量约为原来的3~4倍
- 对于Point/MultiPoint，默认detailLevel为12
- 对于其他类型，系统自动计算合适的detailLevel

### 5. agg模式和plain模式如何选择？

推荐使用**agg模式**（默认）：
- agg模式与plain模式外轮廓一致
- agg模式的cell数量约为plain模式的1/3
- detailLevel越大，agg较plain模式的压缩率越高

---

## 版本信息

- **文档版本**：V6.1.0 LLM优化版
- **原始版本**：GEOVIS iBEST-DB V6.1.0 用户手册
- **整理日期**：2026年

---

## 附录：函数速查表

### GridCell函数

| 类别 | 函数名 | 功能 |
|------|--------|------|
| 构造 | ST_AsGridcell | 经纬度构造2D网格 |
| 构造 | ST_AsGridcell3D | 经纬度高程构造3D网格 |
| 构造 | ST_GridCellFromText | 文本编码构造网格 |
| 构造 | ST_GridCellsFromTexts | 文本编码数组构造网格数组 |
| 输出 | ST_AsText | 转换为文本编码 |
| 输出 | ST_AsGeometry | 转换为Geometry |
| 输出 | ST_AsBox/ST_AsBox3D | 转换为Box |
| 属性 | ST_Center | 获取中心点 |
| 属性 | ST_Level | 获取层级 |
| 属性 | ST_Is3D | 判断是否3D |
| 属性 | ST_Force2D/ST_Force3D | 强制转换为2D/3D |
| 属性 | ST_GetSidesLength | 获取边长 |
| 属性 | ST_GetArea | 获取面积 |
| 属性 | ST_GetVolume | 获取体积 |
| 属性 | ST_DistanceSpheroid | 球面距离 |
| 属性 | ST_Angle | 方位角 |
| 属性 | ST_Direction | 定性方向 |
| 属性 | ST_GetNeibers | 获取4/8邻域网格 |
| 属性 | ST_GetNeibers3D | 获取6/18/26邻域网格 |
| 属性 | ST_GetNeiber | 获取指定方向相邻网格 |
| 属性 | ST_GetNeiber3D | 获取指定方向3D相邻网格 |
| 属性 | ST_GetCellFromAngle | 获取指定方位角的邻域网格 |
| 关系 | ST_GetParent | 获取父网格 |
| 关系 | ST_GetAncestor | 获取祖先网格 |
| 关系 | ST_GetDescendant | 获取后代网格 |
| 关系 | ST_AncestorOf | 判断祖先关系 |
| 关系 | ST_DescendantOf | 判断后代关系 |
| 关系 | ST_FamilyOf | 判断亲属关系 |
| 关系 | ST_GetNextBrother | 获取下一个兄弟网格 |
| 空间 | ST_Equals | 相等判断 |
| 空间 | ST_Intersects | 相交判断 |
| 空间 | ST_Contains | 包含判断 |
| 空间 | ST_WithIn | 被包含判断 |
| 分析 | ST_VisibilityAnalysis | 可视性分析 |

### GeomGrids函数

| 类别 | 函数名 | 功能 |
|------|--------|------|
| 构造 | ST_AsGrids | Geometry构造网格集 |
| 构造 | ST_AsGrids3D | 3D Geometry构造网格集 |
| 构造 | ST_AsGrids(gridcell[]) | gridcell数组构造网格集 |
| 构造 | ST_AsGrids(gridcell) | 单个gridcell构造网格集 |
| 输出 | ST_AsText | 转换为文本 |
| 输出 | ST_AsGeometry | 转换为Geometry |
| 输出 | ST_AsGridCellArray | 转换为gridcell数组 |
| 输出 | ST_WithBox | 输出网格码及BBox信息 |
| 属性 | ST_Is3D | 判断是否3D |
| 属性 | ST_DetailLevel | 获取最大层级 |
| 属性 | ST_nCells | 获取网格数量 |
| 属性 | ST_GetArea | 获取面积 |
| 属性 | ST_Centroid | 获取重心 |
| 属性 | ST_DistanceSpheroid | 球面距离 |
| 属性 | ST_Angle | 方位角 |
| 属性 | ST_Direction | 定性方向 |
| 空间 | ST_Intersects | 相交判断 |
| 空间 | ST_Equals | 相等判断 |
| 空间 | ST_Contains | 包含判断 |
| 空间 | ST_WithIn | 被包含判断 |
| 空间 | ST_Adjacent | 相邻判断 |
| 分析 | ST_Intersection | 交集运算 |
| 分析 | ST_Union | 并集运算 |

### 编码转换函数

| 函数名 | 功能 |
|--------|------|
| ST_asBGC | 生成BGC 2D编码 |
| ST_asBGC3D | 生成BGC 3D编码 |
| ST_BGC2Box | BGC 2D编码转Box |
| ST_BGC3D2Box | BGC 3D编码转Box3D |
| ST_asRSLC | 生成RSLC 2D编码 |
| ST_asRSLC3D | 生成RSLC 3D编码 |
| ST_RSLC2Box | RSLC 2D编码转Box |
| ST_RSLC3D2Box | RSLC 3D编码转Box3D |

### 路径规划函数

| 函数名 | 功能 |
|--------|------|
| ST_FindGridsPath | A-Star路径规划 |
| ST_FindAllGridsPath | 返回遍历的所有网格 |
| ST_RouteFromGridsPath | 网格数组转路径Geometry |
| ST_RouteFromGridsPath(带起点终点) | 带起点终点的路径转换 |
| ST_SmoothRouteFromGridsPath | 平滑路径 |

### 辅助函数

| 函数名 | 功能 |
|--------|------|
| ST_ExturdeGeometry | 二维geometry拉伸成三维多面体 |
| ST_Grids23dtiles | GeomGrids导出为3DTiles模型 |
| ST_CreateTableFromGeom | 根据geometry创建网格表 |
| ST_Geom2Shpfile | 导出网格数据到Shapefile |
| ST_DrawGrids | 二维网格绘制函数 |
| ST_DrawGrids3D | 三维网格绘制函数 |