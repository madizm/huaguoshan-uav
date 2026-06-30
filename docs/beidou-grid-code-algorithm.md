# 北斗网格位置码算法与 GeoSOT 对应关系

本文整理 GB/T 39409-2020 北斗网格位置码的计算逻辑，以及它和 iBEST-DB / GeoSOT 1-32 级网格的对应关系。当前 JS 编码实现见 `js/BeidouGridCode.js`，网格边界计算辅助实现见 `js/BeidouGridBounds.js`。

## 资料来源

- GB/T 39409-2020《北斗网格位置码》：国家标准全文公开系统，标准号 GB/T 39409-2020，发布日期 2020-11-19，实施日期 2021-06-01。
- 项目内 iBEST-DB 手册：`GEOVIS iBEST-DB V6.1.0 用户手册_LLM优化版.md`。
- iBEST-DB 验证函数：`ST_asBGC(lng, lat, level)`、`ST_asBGC3D(lng, lat, height, level)`、`ST_AsGridcell`、`ST_AsGridcell3D`、`ST_AsText(gridcell, 'BGC')`。

## BGC 与 GeoSOT 层级关系

BGC 是 GB/T 39409-2020 定义的北斗网格位置码，标准层级为 1-10 级。GeoSOT / iBEST `gridcell` 是 1-32 级连续剖分体系。两者不是同一套层级编号。

BGC 的 4-10 级与 GeoSOT / iBEST 的部分层级一一对应：

| BGC 层级 | BGC 网格角度 | 赤道附近约边长 | 对应 GeoSOT / iBEST gridcell 层级 |
|---:|---:|---:|---:|
| 1 | 6 deg x 4 deg | 667.9 km x 445.3 km | 不一一对应 |
| 2 | 30' x 30' | 55.66 km | 不一一对应 |
| 3 | 15' x 10' | 27.83 km x 18.55 km | 不一一对应 |
| 4 | 1' x 1' | 1.85 km | 15 |
| 5 | 4" x 4" | 123.7 m | 19 |
| 6 | 2" x 2" | 61.8 m | 20 |
| 7 | 1/4" x 1/4" | 7.73 m | 23 |
| 8 | 1/32" x 1/32" | 0.97 m | 26 |
| 9 | 1/256" x 1/256" | 12.1 cm | 29 |
| 10 | 1/2048" x 1/2048" | 1.5 cm | 32 |

iBEST-DB 手册中 `ST_AsText(gridcell, 'BGC')` 支持的 gridcell 层级为 `15, 19, 20, 23, 26, 29, 32`，正好对应 BGC 4-10 级。

## 二维 BGC 计算逻辑

输入：

- 经度 `lng`，范围 `[-180, 180]`。
- 纬度 `lat`。当前实现支持非极区，即 `-88 < lat < 88`。
- BGC 层级 `level`，范围 `[1, 10]`。

输出：

- 二维 BGC 文本码，例如 `N50J47534`。

### 第 1 级

第 1 级网格大小为 `6 deg x 4 deg`。

编码结构：

```text
半球标识 + 经向编号 + 纬向编号
N/S      + 01-60   + A-V
```

计算：

```text
hemisphere = lat >= 0 ? "N" : "S"
lonZone = floor((lng + 180) / 6) + 1
latBand = floor(abs(lat) / 4)
latCode = "ABCDEFGHIJKLMNOPQRSTUV"[latBand]
```

例如北京样例位于北半球、经向第 50 带、纬向 J 带，所以第 1 级为：

```text
N50J
```

### 第 2-10 级

后续每一级都在上一级网格内继续剖分。先按真实经纬度位置计算原始列号、行号：

```text
rawCol = floor((lng - parentMinLng) / childWidth)
rawRow = floor((lat - parentMinLat) / childHeight)
```

然后按所在东西半球、南北半球转换为编码列号、行号：

```text
codeCol = eastHemisphere  ? rawCol : cols - 1 - rawCol
codeRow = northHemisphere ? rawRow : rows - 1 - rawRow
```

各级剖分和码元如下：

| BGC 层级 | 父级内剖分 | 码元形式 | 码元范围 |
|---:|---:|---|---|
| 2 | 12 x 8 | 经向 1 位 + 纬向 1 位 | 经向 `0-B`，纬向 `0-7` |
| 3 | 2 x 3 | Z 序 1 位 | `0-5` |
| 4 | 15 x 10 | 经向 1 位 + 纬向 1 位 | 经向 `0-E`，纬向 `0-9` |
| 5 | 15 x 15 | 经向 1 位 + 纬向 1 位 | 经向 `0-E`，纬向 `0-E` |
| 6 | 2 x 2 | Z 序 1 位 | `0-3` |
| 7 | 8 x 8 | 经向 1 位 + 纬向 1 位 | 经向 `0-7`，纬向 `0-7` |
| 8 | 8 x 8 | 经向 1 位 + 纬向 1 位 | 经向 `0-7`，纬向 `0-7` |
| 9 | 8 x 8 | 经向 1 位 + 纬向 1 位 | 经向 `0-7`，纬向 `0-7` |
| 10 | 8 x 8 | 经向 1 位 + 纬向 1 位 | 经向 `0-7`，纬向 `0-7` |

Z 序码按编码列号、行号计算：

```text
zCode = codeRow * cols + codeCol
```

其中第 3 级为 `cols=2, rows=3`，第 6 级为 `cols=2, rows=2`。

## 三维 BGC 计算逻辑

三维 BGC 由二维 BGC 与高度维编码交叉组成。

输入：

- 经度 `lng`
- 纬度 `lat`
- 大地高 `height`，单位 m
- BGC 层级 `level`

输出示例：

```text
N050J0047050340D9011345100403410
```

### 高度方向整数编码

GB/T 39409-2020 附录 C 使用地球长半轴和 1/2048 秒角度跨度计算高度方向整数层号。

常量：

```text
r0 = 6378137 m
theta0 = pi / 180
theta = theta0 / (3600 * 2048)
```

高度方向整数编码：

```text
n = floor((theta0 / theta) * log((height + r0) / r0) / log(1 + theta0))
```

再把 `n` 按 32 位整数拆分为 `a0..a11`：

```text
a11 = bits 1..3   -> base 8
a10 = bits 4..6   -> base 8
a9  = bits 7..9   -> base 8
a8  = bits 10..12 -> base 8
a7  = bit 13      -> base 2
a6  = bits 14..17 -> base 16
a5  = bits 18..21 -> base 16
a4  = bit 22      -> base 2
a3  = bits 23..25 -> base 8
a1a2 = bits 26..31 -> base 64, 输出为两位十进制字符串 00-63
a0  = bit 32      -> base 2
```

JS 实现中 `n` 使用 `BigInt.asUintN(32, BigInt(n))` 按 32 位无符号形式取位，以兼容地表以下负层号。

### 三维码交叉排布

三维码不是把高度码简单追加到二维码末尾，而是按层级插入：

```text
2D segments:
  [hemisphere, level1, level2, level3, ..., level10]

Height segments:
  [a0, a1a2, a3, a4, a5, a6, a7, a8, a9, a10, a11]

3D BGC:
  hemisphere + a0
  + level1 + a1a2
  + level2 + a3
  + level3 + a4
  + ...
  + level10 + a11
```

按指定 `level` 截断即可。例如 4 级三维码只输出到 `level4 + a5`。

## iBEST-DB 验证结果

已用 iBEST-DB 函数做对照验证：

```sql
SELECT
  ST_asBGC(116.315222, 39.910278, 4),
  ST_asBGC3D(116.315222, 39.910278, 0, 4),
  ST_asBGC3D(116.315222, 39.910278, 100, 10);
```

结果：

```text
N50J47534
N050J0047050340
N050J0047050340D9011345100403410
```

JS 输出与上述结果一致。另用东西南北半球和赤道附近边界样本验证，JS 与 iBEST-DB 输出一致。

## 当前实现边界

- 已实现非极区 BGC：`-88 < lat < 88`。
- 未实现南北极特殊网格编码。标准第 5.3 节对 `88 deg` 至 `90 deg` 极区有单独合并与剖分规则。
- BGC 标准层级只到 10 级。若需要 iBEST `gridcell` 1-32 级连续编码，应使用 GeoSOT / `gridcell` 逻辑，而不是 BGC 1-10 级接口。

## JS API

```js
const BeidouGridCode = require("./js/BeidouGridCode");
const BeidouGridBounds = require("./js/BeidouGridBounds");

BeidouGridCode.encode2D(116.315222, 39.910278, 4);
// "N50J47534"

BeidouGridCode.encode3D(116.315222, 39.910278, 100, 10);
// "N050J0047050340D9011345100403410"
```

### 网格边界辅助 API

`js/BeidouGridBounds.js` 是 UMD 模块，可在 Node.js 中通过 `require` 使用，也可在浏览器中通过 `window.BeidouGridBounds` 使用。它不生成 BGC 文本码，而是根据输入点反算该点所在 BGC 单元的二维地理边界、三维高度层边界，以及近似距离。

#### 二维单元边界

```js
const bounds = BeidouGridBounds.getCellBounds(116.315222, 39.910278, 4);
```

返回值：

```js
{
    level: 4,
    west: 116.3,
    south: 39.900000000000006,
    east: 116.31666666666666,
    north: 39.91666666666667,
    centerLon: 116.30833333333334,
    centerLat: 39.90833333333334,
    widthDegrees: 0.016666666666666666,
    heightDegrees: 0.016666666666666666,
    widthMeters: 1421.5769271663594,
    heightMeters: 1853.251337225443
}
```

含义：

- `west/south/east/north`：当前点所在 BGC 二维网格单元的经纬度四至。
- `centerLon/centerLat`：该单元中心点。中心点重新编码后应得到与原始点相同层级的 BGC 二维码。
- `widthDegrees/heightDegrees`：单元经纬度跨度。
- `widthMeters/heightMeters`：用球面距离近似计算的米制宽高，适合 AR 可视化和 UI 展示。

限制与编码实现一致：当前仅支持非极区，即 `-88 < latitude < 88`，层级范围为 `1..10`。

#### 三维高度层边界

```js
const heightBounds = BeidouGridBounds.getHeightBounds(0, 10);
```

返回值：

```js
{
    level: 10,
    layer: 0,
    minLayer: 0,
    maxLayerExclusive: 1,
    minHeight: 0,
    maxHeight: 0.014968424904921118,
    centerHeight: 0.007484212452460559,
    heightMeters: 0.014968424904921118
}
```

含义：

- `layer`：输入高度对应的高度方向整数层号。
- `minLayer/maxLayerExclusive`：按目标 BGC 层级截断后的高度层号范围。
- `minHeight/maxHeight`：该高度单元覆盖的高度范围，满足 `minHeight <= height < maxHeight`。
- `centerHeight`：高度单元中心高度。用它重新编码三维 BGC 时，应得到与原始高度相同层级的三维码。
- `heightMeters`：该层级下高度单元厚度。例如近地面 level 8 约 `0.958 m`，level 10 约 `0.015 m`。

#### 距离辅助函数

```js
BeidouGridBounds.distanceMeters(lon1, lat1, lon2, lat2);
```

使用平均地球半径计算两经纬度点之间的球面距离，返回单位为米的近似值。

自动测试：

```bash
npm test
```
