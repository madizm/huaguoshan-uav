# 三维模型包络 GGER 网格 RPC

## `grid_convex_hull_3d`

把浏览器提取的模型外壳或计算的凸包交给 iBEST-DB `ST_AsGrids3D`，返回可供 Cesium 绘制的 GGER 三维网格及每个网格的包围盒。模型外壳模式保留内凹结构，是默认模式；凸包模式用于粗略包围。

```http
POST /postgrest/rpc/grid_convex_hull_3d
Authorization: Bearer <admin JWT>
Content-Type: application/json
```

### 请求

```json
{
  "p_wkt": "POLYHEDRALSURFACE Z (((119.268 34.646 10,...)))",
  "p_detail_level": 19,
  "p_is_agg": true,
  "p_max_cells": 5000
}
```

- `p_wkt`：EPSG:4326 `POLYHEDRALSURFACE Z`。X/Y 为经纬度，Z 为椭球高，单位米；最大 1 MiB。
- `p_detail_level`：iBEST-DB 网格层级，范围 6–32，默认 19。
- `p_is_agg`：是否聚合连续子网格，默认 `true`。
- `p_max_cells`：响应允许的最大网格数，范围 1–10000，默认 5000。

页面展示的包络 WKT 是 EPSG:4978 ECEF；调用 RPC 前，前端会使用 Cesium 椭球转换成上述 EPSG:4326 三维 WKT。

### 返回

```json
{
  "dimension": 3,
  "detail_level": 19,
  "is_agg": true,
  "cell_count": 4,
  "height_datum": "ELLIPSOID",
  "source_srid": 4326,
  "gger_grids": "{\"cells\":[\"GZ...\"]}",
  "gger_grids_with_box": "{\"cells\":[{\"code\":\"GZ...\",\"bbox\":\"(119.267... 34.645... 0,119.268... 34.646... 122.62)\"}]}"
}
```

- `gger_grids`：`ST_AsText(grids, 'GGER')` 的文本结果。
- `gger_grids_with_box`：`ST_WithBox(grids, 'GGER')` 的文本结果，前端解析 `cells[].bbox` 后绘制三维网格线框。

### 权限和限制

- 仅 `admin` 可执行；匿名请求返回 401。
- 只接受三维 PolyhedralSurface。
- 经度必须在 `[-180, 180]`，纬度必须在 `[-90, 90]`。
- 高度限制为 `[-12000, 100000]` 米。
- 超过 `p_max_cells` 时返回错误，调用方应降低 detail level。
