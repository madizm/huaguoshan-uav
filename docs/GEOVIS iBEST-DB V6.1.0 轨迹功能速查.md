# GEOVIS iBEST-DB V6.1.0 轨迹功能速查

> 来源：`GEOVIS iBEST-DB V6.1.0 用户手册.pdf` 第 109-227 页。本文面向 coding agent 检索和实现，保留函数名、签名、用途、关键参数、索引/查询注意事项。

## 快速入口

手册快速入门使用 `best_iot`。在当前测试库中，`best_iot` 只提供 IoT/分表能力；`trajectory` 类型和 `GT_*` 轨迹函数由 `best_geotrack` 暴露。建议初始化时同时安装：

```sql
CREATE EXTENSION best_iot CASCADE;
CREATE EXTENSION best_geotrack CASCADE;

CREATE TABLE taxi(
  id varchar(20),
  update_time timestamp,
  geom geometry
);

SELECT BESTDB_ShardingTrajectoryTable('taxi', 'update_time');
SELECT BESTDB_IOTCreateRealtimeTable('taxi', 'taxirel', 'id', 'update_time');
```

常见对象：

| 名称 | 含义 |
| --- | --- |
| `trajectory` | 一系列轨迹点、时间、空间和属性组成的高维轨迹对象 |
| `Trajectory Point` | 某一时刻的空间位置及属性值，支持 2D/3D 坐标 |
| `timeline` | 轨迹点对应的时间序列 |
| `spatial` | 轨迹空间对象，通常为 `POINT` 或 `LINESTRING` |
| `attributes` | 每个轨迹点的属性序列，如速度、方向、状态等 |
| `boxndf` | 轨迹/几何的多维外包框，支持 XY/Z/T 维度 |

## 轨迹构造

### `GT_MakeTrajectory`

创建 `trajectory` 对象。

```sql
trajectory GT_MakeTrajectory(geometry spatial, tsrange timespan, cstring attrs_json);
trajectory GT_MakeTrajectory(geometry spatial, timestamp start, timestamp end, cstring attrs_json);
trajectory GT_MakeTrajectory(geometry spatial, timestamp[] timeline, cstring attrs_json);
trajectory GT_MakeTrajectory(float8[] x, float8[] y, integer srid, timestamp[] timeline, text[] attr_field_names, ...);
```

关键规则：

- `spatial` 必须是 `POINT` 或 `LINESTRING`，可为 2D 或 3D。
- `timeline` 数量必须与 `spatial` 中的点数一致。
- 如果传入 `tsrange` 或 `start/end`，系统按点数对时间插值。
- `srid` 必须存在；空间计算依赖 SRID。
- `attrs_json.leafcount` 必须等于轨迹点数，也必须等于每个属性 `value` 数量。

`attrs_json` 支持字段类型：

| 类型 | 长度规则 |
| --- | --- |
| `integer` | `1`、`2`、`4`、`8` |
| `float` | `4`、`8` |
| `string` | 默认 `64`，最大 `253` |
| `timestamp` | 默认 `8` |
| `bool` | 默认 `1` |

最小 JSON 形态：

```json
{
  "leafcount": 3,
  "attributes": {
    "velocity": {
      "type": "integer",
      "length": 2,
      "nullable": true,
      "value": [120, 130, 140]
    }
  }
}
```

## 轨迹编辑和预处理

| 函数 | 签名 | 用途 |
| --- | --- | --- |
| `GT_Append` | `trajectory GT_Append(trajectory traj, geometry spatial, timestamp[] timespan, text str_attrs_json)` | 向原轨迹追加轨迹点/轨迹段 |
| `GT_Append` | `trajectory GT_Append(trajectory traj, trajectory tail)` | 拼接子轨迹 |
| `GT_CleanVelocityNoise` | `trajectory GT_CleanVelocityNoise(trajectory traj, float4 tolerance default 3, integer boxCount default 15)` | 基于速度和 3 sigma 原则清洗异常点 |
| `GT_SplitTrajectory` | `trajectory[] GT_SplitTrajectory(trajectory traj, text splitConfig default '{}')` | 按时间、角度或速度将长轨迹分段 |
| `GT_AttrDeduplicate` | `trajectory GT_AttrDeduplicate(trajectory traj, cstring attr_field_name)` | 按属性字段去重轨迹点，首尾点保留 |
| `GT_Compress` | `trajectory GT_Compress(trajectory traj, float8 dist)` | 按欧式距离阈值有损压缩 |
| `GT_Compress` | `trajectory GT_Compress(trajectory traj, float8 dist, float8 angle, float8 acceleration)` | 同时按距离、角度、加速度压缩 |
| `GT_Compress` | `trajectory GT_Compress(trajectory traj, float8 dist, float8 angle, float8 acceleration, cstring velocity_field)` | 使用速度属性字段计算加速度并压缩 |
| `GT_CompressSED` | `trajectory GT_CompressSED(trajectory traj, float8 dist)` | 按时间同步距离 SED 有损压缩 |
| `GT_SetSRID` | `trajectory GT_SetSRID(trajectory traj, int srid)` | 设置 SRID，不改变坐标值 |
| `GT_Transform` | `trajectory GT_Transform(trajectory traj, int srid)` | 转换到目标空间参考系，原轨迹必须有 SRID |
| `GT_subTrajectorySpatial` | `geometry GT_subTrajectorySpatial(trajectory traj, timestamp starttime, timestamp endtime)` | 截取时间段内的轨迹几何 |
| `GT_subTrajectorySpatial` | `geometry GT_subTrajectorySpatial(trajectory traj, tsrange range)` | 同上，使用 `tsrange` |
| `GT_subTrajectory` | `trajectory GT_subTrajectory(trajectory traj, timestamp starttime, timestamp endtime)` | 截取子轨迹 |
| `GT_subTrajectory` | `trajectory GT_subTrajectory(trajectory traj, tsrange range)` | 同上，使用 `tsrange` |
| `GT_Sort` | `trajectory GT_Sort(trajectory traj)` | 按时间升序重排轨迹点 |

`GT_CleanVelocityNoise` 注意事项：

- 要求轨迹点数大于 2；点数小于等于 2 时直接返回原轨迹。
- `tolerance` 默认 `3`，范围 `0.1-10.0`。
- `boxCount` 默认 `15`，范围 `5-1000`。

`GT_SplitTrajectory` 的 `splitConfig`：

```json
{"type": "time", "timethreshold": 60000}
{"type": "angle", "anglethreshold": 60.0}
{"type": "velocity", "velocitythreshold": 10.0}
```

实测注意：`type` 不能省略；只传 `{"timethreshold": 60000}` 会报 `need specify splittype`。

阈值规则：

- `time`: `timethreshold`，单位毫秒，范围 `1-86400000`。
- `angle`: `anglethreshold`，单位度，范围 `0.00001-180.0`。
- `velocity`: `velocitythreshold`，单位 m/s，范围 `0.001-10000000.0`。

## 轨迹分析

| 函数 | 签名 | 用途 |
| --- | --- | --- |
| `GT_deviation` | `float8 GT_deviation(trajectory traj, trajectory after_oper_traj)` | 计算处理后轨迹与原轨迹的偏差，常用于压缩评估 |
| `GT_attrIntMax` | `int8 GT_attrIntMax(trajectory traj, cstring attr_field_name)` | integer 属性最大值 |
| `GT_attrIntMin` | `int8 GT_attrIntMin(trajectory traj, cstring attr_field_name)` | integer 属性最小值 |
| `GT_attrIntAverage` | `int8 GT_attrIntAverage(trajectory traj, cstring attr_field_name)` | integer 属性平均值 |
| `GT_attrFloatMax` | `float8 GT_attrFloatMax(trajectory traj, cstring attr_field_name)` | float 属性最大值 |
| `GT_attrFloatMin` | `float8 GT_attrFloatMin(trajectory traj, cstring attr_field_name)` | float 属性最小值 |
| `GT_attrFloatAverage` | `float8 GT_attrFloatAverage(trajectory traj, cstring attr_field_name)` | float 属性平均值 |
| `GT_leafCount` | `integer GT_leafCount(trajectory traj)` | 轨迹点数量 |
| `GT_duration` | `interval GT_duration(trajectory traj)` | 轨迹持续时间 |
| `GT_TimeAtPoint` | `timestamp[] GT_TimeAtPoint(trajectory traj, geometry g)` | 轨迹通过某位置的时间集合 |
| `GT_samplingInterval` | `interval GT_samplingInterval(trajectory traj)` | 轨迹采样间隔 |
| `GT_trajAttrsMeanMax` | `SETOF record GT_trajAttrsMeanMax(trajectory traj, cstring attr_field_name, out interval duration, out float8 max)` | Mean-Max 滑动窗口统计 |
| `GT_length` | `float8 GT_length(trajectory traj)` | 行程总长度，单位米 |
| `GT_euclideanDistance` | `float GT_euclideanDistance(trajectory traj1, trajectory traj2)` | 两轨迹欧氏距离，结果已标准化 |
| `GT_mdistance` | `float[] GT_mdistance(trajectory traj1, trajectory traj2)` | 相同时间点的欧氏距离数组，未标准化 |

`GT_length` 的 SRID 规则：

- 轨迹有 SRID 时按轨迹 SRID 计算。
- 无 SRID 时默认 `4490`。
- SRID 为 `4490/4326` 时按椭球面长度计算，单位米。
- 其他 SRID 按几何数值计算，类似 PostGIS `ST_Length(Geometry)`。

### LCSS / Jaccard 相似度

| 函数 | 签名 | 返回/用途 |
| --- | --- | --- |
| `GT_lcsSimilarity` | `integer GT_lcsSimilarity(trajectory traj1, trajectory traj2, float8 dist, text unit default 'M')` | LCSS 匹配点数量 |
| `GT_lcsSimilarity` | `integer GT_lcsSimilarity(trajectory traj1, trajectory traj2, float8 dist, interval lag, text unit default 'M')` | 增加时间容差 |
| `GT_lcsDistance` | `float8 GT_lcsDistance(trajectory traj1, trajectory traj2, float8 dist, text unit default 'M')` | `1 - LCSS / min(leafcount)` |
| `GT_lcsDistance` | `float8 GT_lcsDistance(trajectory traj1, trajectory traj2, float8 dist, interval lag, text unit default 'M')` | 增加时间容差 |
| `GT_lcsSubDistance` | `float8 GT_lcsSubDistance(trajectory traj1, trajectory traj2, float8 dist, text unit default 'M')` | LCSS 轨迹段与 `traj1` 对应子段的距离 |
| `GT_lcsSubDistance` | `float8 GT_lcsSubDistance(trajectory traj1, trajectory traj2, float8 dist, interval lag, text unit default 'M')` | 增加时间容差 |
| `GT_JaccardSimilarity` | `record GT_JaccardSimilarity(trajectory tr1, trajectory tr2, double tol_dist, text unit default '{}', interval tol_time default NULL, timestamp ts default '-infinity', timestamp te default 'infinity')` | 返回 `(nleaf1,nleaf2,inter1,inter2,jaccard_lower,jaccard_upper)` |

LCSS 参数：

- `dist`: 空间距离容差，单位通常为米。
- `lag`: 时间容差。
- `unit`: `M` 米、`KM` 千米、`D` 度。
- 无 SRID 时通常按 `4326`。

`GT_JaccardSimilarity` 的 `unit` JSON：

```json
{"Projection":"auto","Unit":"M","useSpheroid":true}
```

字段含义：

- `Projection`: `auto` 或目标 SRID 字符串；不传则按原坐标系。
- `Unit`: `null` 表示坐标欧氏距离；`M` 表示使用坐标系单位，通常为米。
- `useSpheroid`: 当 `Unit=M` 时有效，`true` 使用椭球体，`false` 使用球体近似。

## 属性过滤

| 函数 | 签名 | 返回 |
| --- | --- | --- |
| `GT_attrIntFilter` | `int8[] GT_attrIntFilter(trajectory traj, cstring attr_field_name, cstring operator, int8 value)` | integer 属性过滤结果 |
| `GT_attrIntFilter` | `int8[] GT_attrIntFilter(trajectory traj, cstring attr_field_name, cstring operator, int8 value1, int8 value2)` | integer 区间过滤 |
| `GT_attrFloatFilter` | `float8[] GT_attrFloatFilter(trajectory traj, cstring attr_field_name, cstring operator, float8 value)` | float 属性过滤结果 |
| `GT_attrFloatFilter` | `float8[] GT_attrFloatFilter(trajectory traj, cstring attr_field_name, cstring operator, float8 value1, float8 value2)` | float 区间过滤 |
| `GT_attrTimestampFilter` | `timestamp[] GT_attrTimestampFilter(trajectory traj, cstring attr_field_name, cstring operator, timestamp value)` | timestamp 属性过滤结果 |
| `GT_attrTimestampFilter` | `timestamp[] GT_attrTimestampFilter(trajectory traj, cstring attr_field_name, cstring operator, timestamp value1, timestamp value2)` | timestamp 区间过滤 |
| `GT_attrNullFilter` | `trajectory GT_attrNullFilter(trajectory traj, cstring attr_field_name)` | 属性为空的轨迹点构成的新轨迹 |
| `GT_attrNotNullFilter` | `trajectory GT_attrNotNullFilter(trajectory traj, cstring attr_field_name)` | 属性非空的轨迹点构成的新轨迹 |

支持的 `operator`：

```text
=  !=  >  <  >=  <=  []  ()  [)  (]
```

区间语义：

- `[]`: 闭区间。
- `()`: 开区间。
- `[)`: 左闭右开。
- `(]`: 左开右闭。

## 外包框和时空计算

### 构造外包框

```sql
boxndf GT_MakeBoxZ(float8 zmin, float8 zmax);
boxndf GT_MakeBoxT(timestamp tmin, timestamp tmax);
boxndf GT_MakeBox2D(float8 xmin, float8 ymin, float8 xmax, float8 ymax);
boxndf GT_MakeBox2DT(float8 xmin, float8 ymin, timestamp tmin, float8 xmax, float8 ymax, timestamp tmax);
boxndf GT_MakeBox3D(float8 xmin, float8 ymin, float8 zmin, float8 xmax, float8 ymax, float8 zmax);
boxndf GT_MakeBox3DT(float8 xmin, float8 ymin, float8 zmin, timestamp tmin, float8 xmax, float8 ymax, float8 zmax, timestamp tmax);
```

从对象构造外包框：

```sql
boxndf GT_MakeBox(geometry geom);
boxndf GT_MakeBox(trajectory traj);
boxndf GT_MakeBox(geometry geom, timestamp ts, timestamp te);
boxndf GT_MakeBox(trajectory traj, timestamp ts, timestamp te);
boxndf GT_MakeBox(timestamp ts, timestamp te);
```

注意：`boxndf` 内部用 `float` 表示，边界可能略大于输入值。

### 外包框工具函数

| 函数 | 签名 | 用途 |
| --- | --- | --- |
| `GT_boxndfToGeom` | `geometry GT_boxndfToGeom(boxndf box)` | 外包框转 Geometry；无 XY 维度时返回空 |
| `GT_ExpandSpatial` | `boxndf GT_ExpandSpatial(boxndf box, float8 len)` | 扩大空间范围，下界减 `len`，上界加 `len` |
| `GT_XMin/GT_YMin/GT_ZMin` | `float8 GT_XMin(boxndf box)` 等 | 指定维度最小值 |
| `GT_TMin` | `timestamp GT_TMin(boxndf box)` | 时间维最小值 |
| `GT_XMax/GT_YMax/GT_ZMax` | `float8 GT_XMax(boxndf box)` 等 | 指定维度最大值 |
| `GT_TMax` | `timestamp GT_TMax(boxndf box)` | 时间维最大值 |
| `GT_HasXY/GT_HasZ/GT_HasT` | `bool GT_HasXY(boxndf box)` 等 | 判断外包框是否包含指定维度 |

缺失维度返回规则：

- 缺失 X/Y/Z 时，`Min/Max` 返回 `NaN`。
- 缺失 T 时，文档描述返回 `-infinity`。

## 外包框算子

维度标记：

| 标记 | 维度 |
| --- | --- |
| 无标记 | XY 二维 |
| `/` | Z 维 |
| `#` | T 维 |

类别标记：

| 类别 | 含义 |
| --- | --- |
| `&&` 或 `&` | 相交 |
| `@>` | 包含 |
| `<@` | 被包含 |

标记位置：

- 维度标记在类别标记内部，如 `&#&`：除 XY 外还匹配该维度。
- 维度标记在类别标记两侧，如 `#&#`：仅考虑该维度，不考虑 XY。
- Z/T 同时存在时，Z 标记在前。

### 相交类

| 算子 | 维度 | 支持对象 |
| --- | --- | --- |
| `/&/` | Z | `geometry` / `trajectory` / `boxndf` |
| `#&#` | T | `trajectory` / `boxndf` |
| `&&` | XY | `geometry` / `trajectory` / `boxndf` |
| `&/&` | XYZ | `geometry` / `trajectory` / `boxndf` |
| `&#&` | XYT | `trajectory` / `boxndf` |
| `&/#&` | XYZT | `trajectory` / `boxndf` |

### 包含类

| 算子 | 维度 |
| --- | --- |
| `/@>/` | Z 包含 |
| `#@>#` | T 包含 |
| `@>` | XY 包含 |
| `@/>` | XYZ 包含 |
| `@#>` | XYT 包含 |
| `@/#>` | XYZT 包含 |

### 被包含类

| 算子 | 维度 |
| --- | --- |
| `/<@/` | Z 被包含 |
| `#<@#` | T 被包含 |
| `<@` | XY 被包含 |
| `</@` | XYZ 被包含 |
| `<#@` | XYT 被包含 |
| `</#@` | XYZT 被包含 |

## 轨迹关系和时空谓词

### 便捷关系函数

| 函数 | 签名 | 说明 |
| --- | --- | --- |
| `GT_intersects` | `boolean GT_intersects(trajectory traj, tsrange range, geometry g)` | 指定时间段内轨迹和几何是否相交 |
| `GT_intersects` | `boolean GT_intersects(trajectory traj, timestamp t1, timestamp t2, geometry g)` | 同上 |
| `GT_equals` | `boolean GT_equals(trajectory traj, tsrange range, geometry g)` | 指定时间段内轨迹段与几何是否相同 |
| `GT_equals` | `boolean GT_equals(trajectory traj, timestamp t1, timestamp t2, geometry g)` | 同上 |
| `GT_distanceWithin` | `boolean GT_distanceWithin(trajectory traj, tsrange range, geometry g, float8 d)` | 指定时间段内轨迹段是否距几何 `d` 以内 |
| `GT_distanceWithin` | `boolean GT_distanceWithin(trajectory traj, timestamp t1, timestamp t2, geometry g, float8 d)` | 同上 |
| `GT_intersection` | `geometry GT_intersection(trajectory traj, tsrange range, geometry g)` | 轨迹段与几何交集 |
| `GT_difference` | `geometry GT_difference(trajectory traj, tsrange range, geometry g)` | 轨迹段与几何差集 |
| `GT_nearestApproachPoint` | `geometry GT_nearestApproachPoint(...)` | 最近接近点 |
| `GT_nearestApproachDistance` | `float8 GT_nearestApproachDistance(...)` | 最近接近距离 |
| `GT_durationWithin` | `boolean GT_durationWithin(trajectory traj1, trajectory traj2, tsrange range, interval i)` | 两轨迹经过空间相交点的时间差是否在区间内 |

文档中 `GT_intersection`、`GT_nearestApproachPoint`、`GT_nearestApproachDistance` 同时覆盖轨迹-几何和轨迹-轨迹场景，可按参数类型选择。

### 维度化 Intersects

```sql
bool GT_{2D|3D}Intersects(geometry geom, trajectory traj);
bool GT_{2D|3D}Intersects(trajectory traj, geometry geom);
bool GT_{2D|3D}Intersects(geometry geom, trajectory traj, timestamp ts, timestamp te);
bool GT_{2D|3D}Intersects(trajectory traj, geometry geom, timestamp ts, timestamp te);

bool GT_{Z|T|2D|2DT|3D|3DT}Intersects(boxndf box, trajectory traj);
bool GT_{Z|T|2D|2DT|3D|3DT}Intersects(trajectory traj, boxndf box);
bool GT_{Z|T|2D|2DT|3D|3DT}Intersects(boxndf box, trajectory traj, timestamp ts, timestamp te);
bool GT_{Z|T|2D|2DT|3D|3DT}Intersects(trajectory traj, boxndf box, timestamp ts, timestamp te);

bool GT_{2D|2DT|3D|3DT}Intersects(trajectory traj1, trajectory traj2);
bool GT_{2D|2DT|3D|3DT}Intersects(trajectory traj1, trajectory traj2, timestamp ts, timestamp te);
```

别名规则：直接调用 `GT_intersects(...)` 等价于：

- 有 `geometry` 参数时：`GT_2DIntersects(...)`。
- 两个参数都是 `trajectory` 时：`GT_3DTIntersects(...)`。

索引指定版本：

```sql
bool GT_{2D|2DT|3D|3DT}Intersects_IndexLeft(trajectory traj1, trajectory traj2, timestamp ts, timestamp te);
```

用于两个轨迹列比较时手动指定使用第一个参数所在列的索引。

### 维度化 DWithin

```sql
bool GT_{2D|3D}DWithin(geometry geom, trajectory traj, float8 dist);
bool GT_{2D|3D}DWithin(trajectory traj, geometry geom, float8 dist);
bool GT_{2D|3D}DWithin(geometry geom, trajectory traj, timestamp ts, timestamp te, float8 dist);
bool GT_{2D|3D}DWithin(trajectory traj, geometry geom, timestamp ts, timestamp te, float8 dist);

bool GT_{2D|2DT|3D|3DT}DWithin(boxndf box, trajectory traj, float8 dist);
bool GT_{2D|2DT|3D|3DT}DWithin(trajectory traj, boxndf box, float8 dist);
bool GT_{2D|2DT|3D|3DT}DWithin(boxndf box, trajectory traj, timestamp ts, timestamp te, float8 dist);
bool GT_{2D|2DT|3D|3DT}DWithin(trajectory traj, boxndf box, timestamp ts, timestamp te, float8 dist);

bool GT_{2D|2DT|3D|3DT}DWithin(trajectory traj1, trajectory traj2, float8 dist);
bool GT_{2D|2DT|3D|3DT}DWithin(trajectory traj1, trajectory traj2, timestamp ts, timestamp te, float8 dist);
```

实测注意：当前 `best_geotrack 6.1.0` 库中没有 `GT_2DDWithin(trajectory, geometry, float8)` 和 `GT_2DDWithin(geometry, trajectory, float8)` 三参重载；2D 轨迹-几何距离判断需使用带 `timestamp ts, timestamp te` 的重载，或改用 `GT_3DDWithin(..., float8)`。

规则：

- `2D/3D` 判断空间投影距离是否小于等于 `dist`。
- `2DT/3DT` 判断某一时间点上指定维度距离是否小于等于 `dist`。
- 直接调用 `GT_distanceWithin(...)` 等价于 `GT_2DDWithin(...)` 或 `GT_3DTDWithin(...)`。

索引指定版本：

```sql
bool GT_{2D|2DT|3D|3DT}DWithin_IndexLeft(trajectory traj1, trajectory traj2, float8 dist);
bool GT_{2D|2DT|3D|3DT}DWithin_IndexLeft(trajectory traj1, trajectory traj2, timestamp ts, timestamp te, float8 dist);
```

### Within / Contains

```sql
bool GT_TWithin(tsrange r, trajectory traj);
bool GT_TWithin(trajectory traj, tsrange r);
bool GT_2DWithin(geometry geom, trajectory traj);
bool GT_2DWithin(trajectory traj, geometry geom);
bool GT_2DWithin(geometry geom, trajectory traj, timestamp ts, timestamp te);
bool GT_2DWithin(trajectory traj, geometry geom, timestamp ts, timestamp te);
bool GT_{2D|2DT|3D|3DT}Within(trajectory traj, boxndf box);
bool GT_{2D|2DT|3D|3DT}Within(trajectory traj, boxndf box, timestamp ts, timestamp te);

bool GT_TContains(tsrange r, trajectory traj);
bool GT_TContains(trajectory traj, tsrange r);
bool GT_2DContains(geometry geom, trajectory traj);
bool GT_2DContains(trajectory traj, geometry geom);
bool GT_2DContains(geometry geom, trajectory traj, timestamp ts, timestamp te);
bool GT_2DContains(trajectory traj, geometry geom, timestamp ts, timestamp te);
bool GT_{2D|2DT|3D|3DT}Contains(boxndf box, trajectory traj);
bool GT_{2D|2DT|3D|3DT}Contains(boxndf box, trajectory traj, timestamp ts, timestamp te);
```

注意：

- `Within(a,b)` 等价于交换参数的 `Contains(b,a)`。
- 对 `geometry` 类型，目前文档只说明支持二维操作。
- 部分 `geometry` 类型，如 `POLYHEDRALSURFACE`，不支持 `GT_Within` / `GT_Contains`。
- 对缺失维度，系统视为任意值，即该维度自动满足条件。

## 轨迹查询和索引

### GiST 索引

```sql
CREATE INDEX [index_name]
ON table_name
USING GIST(traj_col [operator_family]);
```

支持加速：

- 外包框算子。
- `GT_ndIntersects`。
- `GT_ndDWithin`。
- `GT_ndContains`。
- `GT_ndWithin`。

算子族：

| 算子族 | 维度 | 适用查询 |
| --- | --- | --- |
| `trajgist_ops_z` | Z | 仅 Z 轴范围 |
| `trajgist_ops_t` | T | 仅时间范围 |
| `trajgist_ops_2d` | XY | 二维空间 |
| `trajgist_ops_2dt` | XYT | 二维、时间、二维时空混合 |
| `trajgist_ops_3d` | XYZ | 二维、三维、Z 轴 |
| `trajgist_ops_3dt` | XYZT | 全部维度 |

建议：

- 同一个查询通常索引维度越少越快。
- 默认常用 `trajgist_ops_2dt`。
- 高频特定维度查询可额外建对应维度索引。

示例：

```sql
CREATE INDEX ON taxi USING GIST(traj trajgist_ops_2dt);

EXPLAIN
SELECT id
FROM taxi
WHERE GT_2DTIntersects(
  traj,
  GT_MakeBox2DT(116.0, 39.0, '2010-01-01', 117.0, 40.0, '2010-01-02')
);
```

数据量较小时可能走顺序扫描，可临时验证：

```sql
SET enable_seqscan = false;
```

## 轨迹访问函数

| 函数 | 签名 | 用途 |
| --- | --- | --- |
| `GT_attrDefinition` | `text GT_attrDefinition(trajectory traj)` | 获取属性定义 |
| `GT_attrSize` | `integer GT_AttrSize(trajectory traj)` | 属性数量 |
| `GT_attrName` | `text GT_attrName(trajectory traj)` | 全部属性名称 |
| `GT_attrName` | `text GT_attrName(trajectory traj, integer index)` | 按索引取属性名称，索引从 0 开始 |
| `GT_attrType` | `text GT_attrType(trajectory traj, integer index)` | 按索引取属性类型 |
| `GT_attrType` | `text GT_attrType(trajectory traj, text name)` | 按名称取属性类型 |
| `GT_attrLength` | `integer GT_attrLength(trajectory traj, integer index)` | 按索引取属性长度 |
| `GT_attrLength` | `integer GT_attrLength(trajectory traj, text name)` | 按名称取属性长度 |
| `GT_attrNullable` | `bool GT_attrNullable(trajectory traj, integer index)` | 按索引判断属性是否可空 |
| `GT_attrNullable` | `bool GT_attrNullable(trajectory traj, text name)` | 按名称判断属性是否可空 |
| `GT_startTime` | `timestamp GT_StartTime(trajectory traj)` | 起始时间 |
| `GT_endTime` | `timestamp GT_EndTime(trajectory traj)` | 结束时间 |
| `GT_trajectorySpatial` | `geometry GT_trajectorySpatial(trajectory traj)` | 轨迹几何 |
| `GT_trajSpatial` | `geometry GT_trajSpatial(trajectory traj)` | 轨迹几何别名 |
| `GT_trajectoryTemporal` | `text GT_trajectoryTemporal(trajectory traj)` | 时间线 |
| `GT_trajTemporal` | `text GT_trajTemporal(trajectory traj)` | 时间线别名 |
| `GT_trajAttrs` | `text GT_trajAttrs(trajectory traj)` | 属性信息 |
| `GT_pointAtTime` | `geometry GT_pointAtTime(trajectory traj, timestamp t)` | 指定时刻的位置点 |
| `GT_velocityAtTime` | `float8 GT_velocityAtTime(trajectory traj, timestamp t)` | 指定时刻速度 |
| `GT_accelerationAtTime` | `float8 GT_accelerationAtTime(trajectory traj, timestamp t)` | 指定时刻加速度 |
| `GT_trajAttrsAsText` | `text[] GT_trajAttrsAsText(trajectory traj, text attr_name)` | 文本属性数组 |
| `GT_trajAttrsAsInteger` | `integer[] GT_trajAttrsAsInteger(trajectory traj, text attr_name)` | 整数属性数组 |
| `GT_trajAttrsAsDouble` | `float8[] GT_trajAttrsAsDouble(trajectory traj, text attr_name)` | 浮点属性数组 |
| `GT_trajAttrsAsBool` | `bool[] GT_trajAttrsAsBool(trajectory traj, text attr_name)` | 布尔属性数组 |
| `GT_trajAttrsAsTimestamp` | `timestamp[] GT_trajAttrsAsTimestamp(trajectory traj, text attr_name)` | 时间戳属性数组 |
| `GT_SRID` | `int GT_SRID(trajectory traj)` | 轨迹 SRID，默认值为 0 |

属性类型返回值：

```text
integer
float
string
timestamp
bool
```

## 轨迹表管理

### `BESTDB_CompressHistoryTrajectory`

无损压缩历史轨迹表，将多条数据合并成一条数据，不减少轨迹点总数。

```sql
BESTDB_CompressHistoryTrajectory(
  historyTableName text,
  idFieldName text,
  trajFieldName text,
  startTime timestamp,
  endTime timestamp,
  trajPointCount integer default 10
);
```

参数：

| 参数 | 含义 |
| --- | --- |
| `historyTableName` | 历史表名 |
| `idFieldName` | ID 字段名 |
| `trajFieldName` | 轨迹字段名 |
| `startTime` / `endTime` | 压缩时间范围 |
| `trajPointCount` | 压缩后每条数据包含的最小轨迹点数；最后一条可能小于该值 |

### `BESTDB_ShardingTrajectoryTable`

按时间对新插入数据分表。

```sql
boolean BESTDB_ShardingTrajectoryTable(
  text tableName,
  text trajOrTimestampFieldName,
  interval timeStep default '1 hour'
);
```

规则：

- `trajOrTimestampFieldName` 可是 `trajectory` 列，也可是普通 `timestamp` 列。
- 如果指定 `trajectory` 列，则用轨迹起始时间作为分表依据。
- 返回值总为 `true`，错误时抛异常。

### `BESTDB_CreateRealtimeTable`

创建实时数据表，并在历史表插入新数据时自动更新每个对象的最新数据。

```sql
boolean BESTDB_CreateRealtimeTable(
  text historyTableName,
  text realtimeTableName,
  text idFieldName,
  text trajFieldName
);
```

说明：

- 历史表保存各对象产生的时序/时空数据。
- 实时表只保存每个 `id` 的最新数据。
- 创建的实时表比历史表多一个 `grids` 字段，用于记录位置信息北斗网格码，可用于聚合查询、热力图等。

### `BESTDB_ShowChunks`

显示指定时间范围内的历史分表名称。

```sql
setof text BESTDB_ShowChunks(text tableName, timestamp older_than default NULL, timestamp newer_than default NULL);
setof text BESTDB_ShowChunks(text tableName, interval older_than default NULL, interval newer_than default NULL);
```

示例：

```sql
SELECT BESTDB_ShowChunks('taxi', older_than => '2010-01-01'::timestamp);
SELECT BESTDB_ShowChunks('taxi', newer_than => '2 days'::interval);
SELECT BESTDB_ShowChunks('taxi', older_than => '2 days'::interval, newer_than => '5 days'::interval);
```

### `BESTDB_DropChunks`

删除指定时间范围内的分表及数据。

```sql
setof text BESTDB_DropChunks(text tableName, timestamp older_than default NULL, timestamp newer_than default NULL);
setof text BESTDB_DropChunks(text tableName, interval older_than default NULL, interval newer_than default NULL);
```

示例：

```sql
SELECT BESTDB_DropChunks('taxi', older_than => '2010-01-01'::timestamp);
SELECT BESTDB_DropChunks('taxi', newer_than => '2 days'::interval);
SELECT BESTDB_DropChunks('taxi', older_than => '2 days'::interval, newer_than => '5 days'::interval);
```

## 常用实现模板

### 创建轨迹表、分表、索引

```sql
CREATE EXTENSION best_iot CASCADE;

CREATE TABLE taxi (
  id varchar(20),
  traj trajectory
);

SELECT BESTDB_ShardingTrajectoryTable('taxi', 'traj', '1 days');

CREATE INDEX taxi_traj_2dt_gist
ON taxi USING GIST(traj trajgist_ops_2dt);
```

### 写入一条轨迹

```sql
INSERT INTO taxi(id, traj)
VALUES (
  'test',
  GT_MakeTrajectory(
    ST_GeomFromText('LINESTRING(116.294 39.9731,116.294 39.9834)', 4326),
    ARRAY['2015-08-13 00:00:10'::timestamp, '2015-08-13 00:00:39'::timestamp],
    '{"leafcount":2,"attributes":{"speed":{"type":"float","length":8,"nullable":true,"value":[10.1,12.3]}}}'
  )
);
```

### 时间段内空间相交查询

```sql
SELECT id
FROM taxi
WHERE GT_2DIntersects(
  traj,
  ST_GeomFromText('POLYGON((116 39,117 39,117 40,116 40,116 39))', 4326),
  '2015-08-13 00:00:00'::timestamp,
  '2015-08-13 12:00:00'::timestamp
);
```

### 时空外包框查询

```sql
SELECT id
FROM taxi
WHERE traj &#& GT_MakeBox2DT(
  116.0, 39.0, '2015-08-13 00:00:00'::timestamp,
  117.0, 40.0, '2015-08-13 12:00:00'::timestamp
);
```

### 压缩并评估偏差

```sql
SELECT
  id,
  GT_leafCount(traj) AS before_points,
  GT_leafCount(GT_Compress(traj, 0.001, 5, 0.3)) AS after_points,
  GT_deviation(traj, GT_Compress(traj, 0.001, 5, 0.3)) AS deviation
FROM taxi;
```

## 兼容和 OCR 注意

PostgreSQL 函数名默认不区分大小写，文档示例中可能混用 `GT_MakeTrajectory`、`GT_makeTrajectory`、`GT_Intersects`、`GT_intersects`。本文统一保留驼峰/规范写法，实际 SQL 中未加双引号时大小写等价。

PDF 抽取中存在少量拼写或排版问题，coding agent 遇到时按下表映射：

| PDF/OCR 形态 | 建议使用 |
| --- | --- |
| `GT_lcsDisatance` | `GT_lcsDistance` |
| `GT_lcsSubDisatance` | `GT_lcsSubDistance` |
| `GT_2dIntersects` / `GT_2dtIntersects` / `GT_3dIntersects` / `GT_3dtIntersects` | `GT_2DIntersects` / `GT_2DTIntersects` / `GT_3DIntersects` / `GT_3DTIntersects` |
| `GT_2dDWithin` / `GT_2dtDWithin` / `GT_3dDWithin` / `GT_3dtDWithin` | `GT_2DDWithin` / `GT_2DTDWithin` / `GT_3DDWithin` / `GT_3DTDWithin` |
| `GT_2dContains` / `GT_2dtContains` / `GT_3dContains` / `GT_3dtContains` | `GT_2DContains` / `GT_2DTContains` / `GT_3DContains` / `GT_3DTContains` |
| `GT_2dWithin` | `GT_2DWithin` |
| `BESTDB_IOTCreateRealtimeTable` | 快速入门处出现；轨迹表章节的规范函数为 `BESTDB_CreateRealtimeTable` |

## 函数名索引

```text
BESTDB_CompressHistoryTrajectory
BESTDB_CreateRealtimeTable
BESTDB_DropChunks
BESTDB_ShowChunks
BESTDB_ShardingTrajectoryTable
GT_2DContains
GT_2DDWithin
GT_2DDWithin_IndexLeft
GT_2DIntersects
GT_2DIntersects_IndexLeft
GT_2DWithin
GT_2DTContains
GT_2DTDWithin
GT_2DTDWithin_IndexLeft
GT_2DTIntersects
GT_2DTIntersects_IndexLeft
GT_2DTWithin
GT_3DContains
GT_3DDWithin
GT_3DDWithin_IndexLeft
GT_3DIntersects
GT_3DIntersects_IndexLeft
GT_3DWithin
GT_3DTContains
GT_3DTDWithin
GT_3DTDWithin_IndexLeft
GT_3DTIntersects
GT_3DTIntersects_IndexLeft
GT_3DTWithin
GT_Append
GT_AttrDeduplicate
GT_AttrSize
GT_CleanVelocityNoise
GT_Compress
GT_CompressSED
GT_EndTime
GT_ExpandSpatial
GT_HasT
GT_HasXY
GT_HasZ
GT_JaccardSimilarity
GT_MakeBox
GT_MakeBox2D
GT_MakeBox2DT
GT_MakeBox3D
GT_MakeBox3DT
GT_MakeBoxT
GT_MakeBoxZ
GT_MakeTrajectory
GT_SRID
GT_SetSRID
GT_Sort
GT_SplitTrajectory
GT_StartTime
GT_TContains
GT_TMax
GT_TMin
GT_TWithin
GT_TimeAtPoint
GT_Transform
GT_XMax
GT_XMin
GT_YMax
GT_YMin
GT_ZMax
GT_ZMin
GT_accelerationAtTime
GT_attrDefinition
GT_attrFloatAverage
GT_attrFloatFilter
GT_attrFloatMax
GT_attrFloatMin
GT_attrIntAverage
GT_attrIntFilter
GT_attrIntMax
GT_attrIntMin
GT_attrLength
GT_attrName
GT_attrNotNullFilter
GT_attrNullFilter
GT_attrNullable
GT_attrTimestampFilter
GT_attrType
GT_boxndfToGeom
GT_deviation
GT_difference
GT_distanceWithin
GT_duration
GT_durationWithin
GT_endTime
GT_equals
GT_euclideanDistance
GT_intersection
GT_intersects
GT_lcsDistance
GT_lcsSimilarity
GT_lcsSubDistance
GT_leafCount
GT_length
GT_mdistance
GT_nearestApproachDistance
GT_nearestApproachPoint
GT_pointAtTime
GT_samplingInterval
GT_startTime
GT_subTrajectory
GT_subTrajectorySpatial
GT_trajAttrs
GT_trajAttrsAsBool
GT_trajAttrsAsDouble
GT_trajAttrsAsInteger
GT_trajAttrsAsText
GT_trajAttrsAsTimestamp
GT_trajAttrsMeanMax
GT_trajSpatial
GT_trajTemporal
GT_trajectorySpatial
GT_trajectoryTemporal
GT_velocityAtTime
```
