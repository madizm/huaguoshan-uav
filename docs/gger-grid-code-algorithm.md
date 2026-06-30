# GGER 地球空间网格编码规则 JS 实现说明

本文整理 GB/T 40087-2021《地球空间网格编码规则》的 GGER 编码计算逻辑，以及本项目中的 JS 实现和 iBEST-DB 验证方式。当前实现见 `js/GGERGridCode.js`。

## 资料来源

- GB/T 40087-2021《地球空间网格编码规则》：国家标准全文公开系统，标准号 GB/T 40087-2021，发布日期 2021-04-30，实施日期 2021-04-30。
- 项目内 iBEST-DB 手册：`GEOVIS iBEST-DB V6.1.0 用户手册_LLM优化版.md`。
- iBEST-DB 验证函数：`ST_AsGridcell(lng, lat, level)`、`ST_AsGridcell3D(lng, lat, height, level)`、`ST_AsText(gridcell, 'GGER')`。

## GGER 与 GeoSOT 的关系

GGER 是 GeoSOT 网格编码的文本表达形式，和 iBEST-DB 的 `gridcell` 层级完整兼容。

| 项目 | 说明 |
|---|---|
| 层级范围 | 0-32 级；iBEST-DB 构造函数使用 1-32 级 |
| 2D 格式 | `G` + 每层 1 位四进制码元，例如 `G001310322230230` |
| 3D 格式 | `GZ` + 每层 1 位八进制码元，例如 `GZ002620644460460` |
| 2D 码元数量 | 等于层级数 |
| 3D 码元数量 | 等于层级数 |

## 坐标扩展规则

GeoSOT 使用扩展的度分秒整数索引。32 位坐标索引由以下字段组成：

```text
9 bits degree + 6 bits minute + 6 bits second + 11 bits second_fraction
```

其中：

- `degree` 扩展到 0-511。
- 东经、北纬使用自身绝对度数。
- 西经、南纬在绝对度数上加 256。
- `minute` 取 0-59，但编码空间扩展为 0-63。
- `second` 取 0-59，但编码空间扩展为 0-63。
- `second_fraction` 将 1 秒继续分成 2048 份。

计算伪代码：

```text
absValue = abs(coord)
degree = floor(absValue)
minute = floor((absValue - degree) * 60)
second = floor((((absValue - degree) * 60) - minute) * 60)
fraction = floor((secondFloat - second) * 2048)

degreeCode = coord < 0 ? degree + 256 : degree
index32 = (((degreeCode * 64 + minute) * 64 + second) * 2048) + fraction
```

示例：

```text
116.315222 deg E -> 116 deg 18 min 54 sec ... -> level 15 xy index x = 116 * 64 + 18 = 7442
39.910278 deg N  -> 39 deg 54 min 36 sec ...  -> level 15 xy index y = 39 * 64 + 54 = 2550
```

## 二维 GGER 编码

二维 GGER 按 32 位经向索引 `x` 和 32 位纬向索引 `y` 做 Morton 交织。每一层从高位到低位取 1 个 `x` bit 和 1 个 `y` bit，组成 1 个四进制码元：

```text
digit = yBit * 2 + xBit
```

对第 `level` 级，从 bit 31 取到 bit `32 - level`：

```text
code = "G"
for bitIndex from 31 down to 32 - level:
    xBit = bit(x, bitIndex)
    yBit = bit(y, bitIndex)
    code += yBit * 2 + xBit
```

北京样例：

```text
lng = 116.315222
lat = 39.910278
level = 15

GGER 2D = G001310322230230
```

## 三维 GGER 编码

三维 GGER 在二维的 `x/y` 之外加入 32 位高度层号 `z`。每一层取 1 个 `x` bit、1 个 `y` bit、1 个 `z` bit，组成 1 个八进制码元：

```text
digit = yBit * 4 + xBit * 2 + zBit
```

即：

```text
code = "GZ"
for bitIndex from 31 down to 32 - level:
    xBit = bit(x, bitIndex)
    yBit = bit(y, bitIndex)
    zBit = bit(z, bitIndex)
    code += yBit * 4 + xBit * 2 + zBit
```

## 高程层号

iBEST-DB 的 GGER 3D 高度维与 GeoSOT 3D 高度层号一致。计算分两步：

1. 根据高度得到普通角秒累计层号，单位为 `1/2048"`。
2. 将普通 `60 min / 60 sec` 的累计层号改写为 GeoSOT 扩展 DMS 索引，其中分、秒字段按 64 进制存储。

常量：

```text
r0 = 6378137 m
theta0 = pi / 180
theta = theta0 / (3600 * 2048)
```

地上高度 `H >= 0`：

```text
arcSecondFractions = floor((theta0 / theta) * log((H + r0) / r0) / log(1 + theta0))
```

地下高度 `H < 0`，设 `D = abs(H)`：

```text
arcSecondFractions = floor((theta0 / theta) * log(r0 / (r0 - D)) / log(1 + theta0))
```

将 `arcSecondFractions` 转为扩展 DMS 索引：

```text
fraction = arcSecondFractions % 2048
totalSeconds = floor(arcSecondFractions / 2048)
second = totalSeconds % 60
totalMinutes = floor(totalSeconds / 60)
minute = totalMinutes % 60
degree = floor(totalMinutes / 60)

layer = (((degree * 64 + minute) * 64 + second) * 2048) + fraction
z = H < 0 ? 2^31 + layer : layer
```

示例：

| 高程 | 普通角秒累计层号 | 扩展 DMS 后 layer / z |
|---:|---:|---:|
| `100 m` | `6680` | `6680` |
| `9999 m` | `667483` | `708443` |
| `-10 m` | `668` | `2147483648 + 668 = 2147484316` |
| `-1234 m` | `82448` | `2147483648 + 82448 = 2147566096` |

## iBEST-DB 验证

验证 SQL：

```sql
SELECT
  ST_AsText(ST_AsGridcell(116.315222, 39.910278, 15), 'GGER'),
  ST_AsText(ST_AsGridcell3D(116.315222, 39.910278, 100, 32), 'GGER');
```

结果：

```text
G001310322230230
GZ00262064446046062063523002211204
```

已对以下样本和层级批量比对 JS 与 iBEST-DB 输出：

- 北京：`116.315222, 39.910278, 100`
- 赤道附近：`0.1, -0.1, 1`
- 纽约：`-73.9857, 40.7484, 381`
- 悉尼：`151.2093, -33.8688, 58`
- 北京地下高度：`116.315222, 39.910278, -10`
- 高空与深地下样例：`9999m`、`52800m`、`-1234m`
- 层级：`1, 2, 3, 4, 5, 8, 9, 12, 15, 20, 21, 26, 27, 32`

批量结果完全一致。

## JS API

```js
const GGERGridCode = require("./js/GGERGridCode");

GGERGridCode.encode2D(116.315222, 39.910278, 15);
// "G001310322230230"

GGERGridCode.encode3D(116.315222, 39.910278, 100, 32);
// "GZ00262064446046062063523002211204"
```

自动测试：

```bash
npm test
```
