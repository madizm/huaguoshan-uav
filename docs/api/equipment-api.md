# 设施设备 API 调用文档

- **更新日期：2026-07-13**
- API 形式：PostgREST REST API
- 数据格式：JSON
- 坐标系：WGS84（EPSG:4326）
- 设备相关高度基准：AMSL

## 1. 访问地址与认证

推荐通过 Nginx 统一入口访问：

```text
http://<host>:20000/postgrest
```

开发环境也可以直接访问 PostgREST：

```text
http://<host>:13000
```

除 OpenAPI 描述外，设施设备接口不允许匿名访问。先通过统一入口登录：

```bash
curl -X POST 'http://<host>:20000/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "<username>",
    "password": "<password>"
  }'
```

从响应中取得 `access_token`，后续请求携带：

```http
Authorization: Bearer <access_token>
```

下文使用以下环境变量简化示例：

```bash
export API_BASE='http://<host>:20000/postgrest'
export TOKEN='<access_token>'
```

## 2. 通用编码和规则

### 2.1 设备类别

| `category_code` | 类别 |
|---|---|
| `base_station_6g` | 6G 基站 |
| `counter_uas` | 反无设备 |
| `video_surveillance` | 视频监控 |
| `uav` | 无人机 |
| `unmanned_vehicle` | 无人车 |
| `vehicle_surveillance` | 车载监控 |
| `sensor` | 传感设备 |

设备创建后不能直接修改 `category_code`；如需改变类别，应重新创建设备，避免分类属性、能力和应急资源关系失配。

### 2.2 连接状态

`connectivity_status` 可取：

- `online`：在线
- `offline`：离线
- `unknown`：未知

### 2.3 调度状态

`dispatch_status` 可取：

- `available`：可用
- `assigned`：已分配
- `maintenance`：维护中
- `unavailable`：不可用
- `unknown`：未知

### 2.4 在线率

`online_rate` 是百分比数值，范围为 `0.00`–`100.00`，保留两位小数。连接状态缺失、`offline` 或 `unknown` 的设备均不计入在线设备数，但计入设备总数。

## 3. 统一设备资产

### 3.1 查询设备列表

```http
GET /equipment_assets
```

主要字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | bigint | 设备资产主键 |
| `asset_code` | text | 唯一资产编码 |
| `category_code` | text | 设备类别编码 |
| `type_code` | text | 类别内设备类型编码 |
| `name` | text | 设备名称 |
| `source_system` | text | 来源系统编码 |
| `source_asset_id` | text | 来源系统设备 ID |
| `managing_unit_name` | text | 管理单位名称 |
| `deployment_mode` | text | 部署方式，如 `fixed`、`mobile` |
| `lifecycle_status` | text | 生命周期状态 |
| `geom` | GeoJSON Point | WGS84 登记位置 |
| `elevation_amsl_m` | numeric | AMSL 高度，单位米 |
| `height_datum` | text | 固定为 `AMSL` |
| `manufacturer` | text | 制造商 |
| `model` | text | 型号 |
| `serial_no` | text | 序列号 |
| `is_simulated` | boolean | 是否为模拟数据 |
| `metadata` | jsonb | 扩展属性 |
| `created_at` | timestamptz | 创建时间 |
| `updated_at` | timestamptz | 更新时间 |

按类别和名称查询：

```bash
curl -G "$API_BASE/equipment_assets" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'category_code=eq.uav' \
  --data-urlencode 'name=like.*花果山*' \
  --data-urlencode 'select=id,asset_code,category_code,name,geom,elevation_amsl_m,height_datum' \
  --data-urlencode 'order=id.asc'
```

### 3.2 新建设备

```http
POST /equipment_assets
```

```bash
curl -X POST "$API_BASE/equipment_assets" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "asset_code": "HGS-SENSOR-002",
    "category_code": "sensor",
    "type_code": "weather_station",
    "name": "东侧气象传感设备",
    "source_system": "operations_console",
    "source_asset_id": "SENSOR-002",
    "managing_unit_name": "花果山景区管理处",
    "deployment_mode": "fixed",
    "lifecycle_status": "active",
    "geom": {"type": "Point", "coordinates": [119.275, 34.650]},
    "elevation_amsl_m": 180,
    "height_datum": "AMSL",
    "is_simulated": false,
    "metadata": {}
  }'
```

`asset_code` 唯一；`source_system` 与 `source_asset_id` 共同组成来源幂等键。

### 3.3 更新和删除设备

```bash
# 更新名称和管理单位
curl -X PATCH "$API_BASE/equipment_assets?id=eq.<asset_id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "更新后的设备名称",
    "managing_unit_name": "更新后的管理单位"
  }'

# 删除设备
curl -X DELETE "$API_BASE/equipment_assets?id=eq.<asset_id>" \
  -H "Authorization: Bearer $TOKEN"
```

已有原始观测的设备不能直接删除，以免破坏观测来源追溯。

## 4. 设备当前状态

### 4.1 查询状态

```http
GET /equipment_asset_status
```

主要字段：`asset_id`、`connectivity_status`、`dispatch_status`、`position_geom`、`position_height_amsl_m`、`height_datum`、`last_heartbeat_at`、`observed_at`、`payload`、`updated_at`。

查询在线且可调度的设备：

```bash
curl -G "$API_BASE/equipment_asset_status" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'connectivity_status=eq.online' \
  --data-urlencode 'dispatch_status=eq.available'
```

### 4.2 写入或更新状态

首次写入：

```bash
curl -X POST "$API_BASE/equipment_asset_status" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "asset_id": <asset_id>,
    "connectivity_status": "online",
    "dispatch_status": "available",
    "position_geom": {"type": "Point", "coordinates": [119.275, 34.650]},
    "position_height_amsl_m": 185,
    "height_datum": "AMSL",
    "last_heartbeat_at": "2026-07-13T15:00:00Z",
    "observed_at": "2026-07-13T15:00:00Z",
    "payload": {}
  }'
```

更新已有状态：

```bash
curl -X PATCH "$API_BASE/equipment_asset_status?asset_id=eq.<asset_id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "connectivity_status": "offline",
    "observed_at": "2026-07-13T15:10:00Z"
  }'
```

每次新增或更新当前状态都会在底层追加状态历史。

## 5. 设备原始观测

### 5.1 查询原始观测

```http
GET /equipment_raw_observations
```

```bash
curl -G "$API_BASE/equipment_raw_observations" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'asset_id=eq.<asset_id>' \
  --data-urlencode 'observed_at=gte.2026-07-13T00:00:00Z' \
  --data-urlencode 'order=observed_at.desc' \
  --data-urlencode 'limit=100'
```

### 5.2 追加原始观测

```http
POST /equipment_raw_observations
```

```bash
curl -X POST "$API_BASE/equipment_raw_observations" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "asset_id": <asset_id>,
    "source_system": "sensor_gateway",
    "source_observation_id": "OBS-20260713-0001",
    "observation_type": "weather_sample",
    "observed_at": "2026-07-13T15:00:00Z",
    "received_at": "2026-07-13T15:00:02Z",
    "geom": {"type": "Point", "coordinates": [119.275, 34.650]},
    "height_amsl_m": 180,
    "height_datum": "AMSL",
    "confidence": 0.95,
    "processing_status": "received",
    "raw_payload": {"temperature_c": 31.2, "humidity_percent": 65},
    "is_simulated": false
  }'
```

`source_system` 与 `source_observation_id` 唯一。`confidence` 范围为 0–1。原始观测采用追加写入，接口不允许 `PATCH`、`PUT` 或 `DELETE`。

## 6. 设备能力

```http
GET /equipment_asset_capabilities
```

返回字段：`id`、`asset_id`、`asset_code`、`category_code`、`capability_code`、`capability_name`、`capability_type`、`access_level`、`enabled`、`parameters`。

```bash
curl -G "$API_BASE/equipment_asset_capabilities" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'category_code=eq.counter_uas' \
  --data-urlencode 'enabled=eq.true'
```

反无设备最高只允许 `recommendable`，平台不提供反无设备直接控制 RPC。

## 7. 能力覆盖范围

```http
GET /equipment_asset_coverages
```

返回字段：`id`、`asset_id`、`capability_code`、`asset_capability_id`、`coverage_geom`、`min_height_amsl_m`、`max_height_amsl_m`、`height_datum`、`valid_from`、`valid_to`、`metadata`。

按设备和 AMSL 高度查询：

```bash
curl -G "$API_BASE/equipment_asset_coverages" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'asset_id=eq.<asset_id>' \
  --data-urlencode 'min_height_amsl_m=lte.300' \
  --data-urlencode 'max_height_amsl_m=gte.300'
```

## 8. 设备分类与状态统计

```http
GET /equipment_statistics
```

按 `category_code`、`connectivity_status` 和 `dispatch_status` 分组，返回 `asset_count`。

```bash
curl -G "$API_BASE/equipment_statistics" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'order=category_code.asc'
```

## 9. 设备在线状态统计

```http
GET /equipment_online_statistics
```

返回字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `category_code` | text | 设备类别编码 |
| `total_count` | bigint | 该类别设备总数 |
| `online_count` | bigint | 连接状态为 `online` 的设备数 |
| `online_rate` | numeric | 在线率百分比，0–100，保留两位小数 |

```bash
curl -G "$API_BASE/equipment_online_statistics" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'select=category_code,total_count,online_count,online_rate' \
  --data-urlencode 'order=category_code.asc'
```

响应示例：

```json
[
  {
    "category_code": "base_station_6g",
    "total_count": 4,
    "online_count": 3,
    "online_rate": 75.00
  },
  {
    "category_code": "uav",
    "total_count": 10,
    "online_count": 8,
    "online_rate": 80.00
  }
]
```

## 10. 既有无人机兼容查询

```http
GET /aircraft_assets
```

该只读接口保留既有无人机展示字段，包括 `source_aircraft_id`、`asset_code`、`name`、`model`、`serial_no`、`owner_unit_name` 和 `availability_status`。新功能建议优先使用统一设备接口。

## 11. 常见 PostgREST 查询参数

| 表达式 | 含义 |
|---|---|
| `field=eq.value` | 等于 |
| `field=neq.value` | 不等于 |
| `field=gt.value` / `gte.value` | 大于 / 大于等于 |
| `field=lt.value` / `lte.value` | 小于 / 小于等于 |
| `field=in.(a,b)` | 位于集合中 |
| `field=like.*keyword*` | 模糊匹配 |
| `select=a,b,c` | 选择返回字段 |
| `order=field.asc` | 排序 |
| `limit=100&offset=0` | 分页 |

## 12. 常见错误

| HTTP 状态 | 典型原因 |
|---|---|
| `400` | 字段约束不满足、使用非 AMSL 高度基准、尝试修改追加式记录 |
| `401` | 未携带 JWT、JWT 无效或已过期 |
| `403` | 当前角色无接口权限 |
| `404` | 接口不存在，例如调用未提供的反无设备控制 RPC |
| `409` | 资产编码、来源幂等键或观测来源键冲突 |
