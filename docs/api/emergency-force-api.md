# 应急力量 API 调用文档

- **更新日期：2026-07-14**
- API 形式：PostgREST REST API
- 数据格式：JSON
- 坐标系：WGS84（EPSG:4326）
- 当前数据范围：花果山景区模拟数据

## 1. 访问地址与认证

推荐通过 Nginx 统一入口访问：

```text
http://<host>:20000/postgrest
```

开发环境也可以直接访问 PostgREST：

```text
http://<host>:13000
```

除 OpenAPI 描述外，应急力量接口不允许匿名访问。先通过统一入口登录：

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

## 2. 接口总览

| 资源 | 接口路径 | 用途 | 权限 |
|---|---|---|---|
| 救援力量 | `/emergency_rescue_forces` | 救援队伍、消防队伍和巡护力量 | CRUD |
| 医疗资源 | `/emergency_medical_resources` | 医疗点、急救站和救护车辆 | CRUD |
| 专家力量 | `/emergency_experts` | 应急研判和技术支持专家 | CRUD |
| 避难场所 | `/emergency_shelters` | 人员疏散安置场所 | CRUD |
| 物资仓库 | `/emergency_material_warehouses` | 应急物资储备和调拨仓库 | CRUD |
| 取水点 | `/emergency_water_points` | 消防、救援或生活保障取水点 | CRUD |
| 起降点 | `/emergency_landing_sites` | 无人机、直升机起降保障点 | CRUD |
| 分类统计 | `/emergency_resource_category_statistics` | 各类资源数量统计快照 | 只读 |
| 刷新统计 | `/rpc/refresh_emergency_resource_category_statistics` | 刷新分类统计快照 | RPC |

CRUD 分别对应 `GET`、`POST`、`PATCH` 和 `DELETE`。接口不提供整表无条件更新或删除示例，调用 `PATCH`、`DELETE` 时应始终携带主键或其他明确过滤条件。

## 3. 通用字段与规则

七类资源均包含以下字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | bigint | 资源主键，创建时无需传入 |
| `source_code` | text | 唯一且稳定的来源编码 |
| `name` | text | 资源名称 |
| `availability_status` | text | 可用状态，各类资源的取值不同 |
| `is_simulated` | boolean | 是否为模拟数据 |
| `metadata` | jsonb | 扩展属性，默认为 `{}` |
| `geom` | GeoJSON Point | WGS84 点坐标，经度在前、纬度在后 |
| `created_at` | timestamptz | 创建时间，由服务端生成 |
| `updated_at` | timestamptz | 更新时间，由服务端维护 |

通用规则：

- `source_code` 在对应资源内唯一，重复创建返回 `409`。
- 数量、容量和供给能力不能为负；部分容量字段必须大于 0。
- 写入坐标时使用 GeoJSON Point，例如 `{"type":"Point","coordinates":[119.275,34.650]}`。
- 当前种子数据均为模拟数据；录入真实资源时应显式设置 `is_simulated: false`。
- 新增、更新或删除资源后，分类统计不会自动变化，需调用统计刷新 RPC。

### 3.1 控制 GeoJSON 返回格式

默认响应的 `Content-Type` 为 `application/json`，每条记录的 `geom` 字段是 GeoJSON Point。若需要标准 GeoJSON `FeatureCollection`，可通过 HTTP 内容协商将请求头 `Accept` 设置为 `application/geo+json`；服务端响应的 `Content-Type` 将变为 `application/geo+json`。

```bash
curl -G "$API_BASE/emergency_rescue_forces" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/geo+json' \
  --data-urlencode 'select=id,name,availability_status,geom' \
  --data-urlencode 'limit=10'
```

响应示例：

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [119.28642, 34.65521]
      },
      "properties": {
        "id": 5,
        "name": "景区志愿救援服务队",
        "availability_status": "available"
      }
    }
  ]
}
```

注意：请求的 `Content-Type` 表示请求体格式，不能控制响应格式；控制返回格式应使用 `Accept`。在 `select` 中包含 `geom` 后，该字段会成为 Feature 的 `geometry`，其他字段会进入 `properties`。

## 4. 救援力量

### 4.1 查询救援力量

```http
GET /emergency_rescue_forces
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `force_type` | text | 力量类型，如 `forest_fire`、`rescue`、`ranger`、`volunteer` |
| `unit_name` | text | 所属单位 |
| `commander_name` | text | 负责人姓名，可为空 |
| `contact_phone` | text | 联系电话，可为空 |
| `personnel_count` | integer | 人员数量，不小于 0 |

`availability_status` 可取 `available`、`deployed`、`standby`、`unavailable`。

查询可调度的森林消防力量：

```bash
curl -G "$API_BASE/emergency_rescue_forces" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'force_type=eq.forest_fire' \
  --data-urlencode 'availability_status=eq.available' \
  --data-urlencode 'select=id,source_code,name,unit_name,personnel_count,geom' \
  --data-urlencode 'order=personnel_count.desc'
```

### 4.2 新增救援力量

```bash
curl -X POST "$API_BASE/emergency_rescue_forces" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "source_code": "RESCUE-2026-001",
    "name": "东部山地救援组",
    "force_type": "rescue",
    "unit_name": "花果山景区应急管理中心",
    "commander_name": "张三",
    "contact_phone": "13800000000",
    "personnel_count": 20,
    "availability_status": "available",
    "is_simulated": false,
    "metadata": {},
    "geom": {"type": "Point", "coordinates": [119.275, 34.650]}
  }'
```

## 5. 医疗资源

```http
GET /emergency_medical_resources
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `resource_type` | text | 类型，如 `clinic`、`first_aid_station`、`ambulance_station` |
| `unit_name` | text | 所属单位 |
| `contact_phone` | text | 联系电话，可为空 |
| `service_capacity` | integer | 单次服务或接纳人数，不小于 0 |
| `ambulance_count` | integer | 救护车数量，不小于 0 |

`availability_status` 可取 `available`、`busy`、`standby`、`unavailable`。

查询有救护车且当前可用的医疗资源：

```bash
curl -G "$API_BASE/emergency_medical_resources" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'availability_status=eq.available' \
  --data-urlencode 'ambulance_count=gt.0' \
  --data-urlencode 'order=service_capacity.desc'
```

新增医疗资源时的请求体示例：

```json
{
  "source_code": "MEDICAL-2026-001",
  "name": "东入口急救站",
  "resource_type": "first_aid_station",
  "unit_name": "花果山景区医疗保障组",
  "contact_phone": "13800000001",
  "service_capacity": 15,
  "ambulance_count": 1,
  "availability_status": "available",
  "is_simulated": false,
  "metadata": {"equipment": "AED、急救包"},
  "geom": {"type": "Point", "coordinates": [119.280, 34.650]}
}
```

将该 JSON 作为 `POST /emergency_medical_resources` 的请求体即可创建资源。

## 6. 专家力量

```http
GET /emergency_experts
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `expertise` | text | 专业方向，如森林防火、地质灾害、医疗救援、无人机巡查 |
| `organization_name` | text | 所属机构 |
| `professional_title` | text | 专业职称，可为空 |
| `contact_phone` | text | 联系电话，可为空 |

`availability_status` 可取 `available`、`consulting`、`standby`、`unavailable`。

```bash
curl -G "$API_BASE/emergency_experts" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'expertise=eq.森林防火' \
  --data-urlencode 'availability_status=in.(available,standby)' \
  --data-urlencode 'select=id,name,expertise,organization_name,professional_title,contact_phone,geom'
```

## 7. 避难场所

```http
GET /emergency_shelters
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `venue_type` | text | 类型，如 `square`、`parking_area`、`visitor_center`、`school` |
| `managing_unit_name` | text | 管理单位 |
| `contact_phone` | text | 联系电话，可为空 |
| `capacity` | integer | 最大安置人数，必须大于 0 |
| `current_occupancy` | integer | 当前安置人数，范围为 0 至 `capacity` |

`availability_status` 可取 `available`、`preparing`、`occupied`、`unavailable`。

查询当前可用避难场所：

```bash
curl -G "$API_BASE/emergency_shelters" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'availability_status=eq.available' \
  --data-urlencode 'select=id,name,venue_type,capacity,current_occupancy,geom' \
  --data-urlencode 'order=capacity.desc'
```

更新当前安置人数：

```bash
curl -X PATCH "$API_BASE/emergency_shelters?id=eq.<shelter_id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{"current_occupancy": 180}'
```

## 8. 物资仓库

```http
GET /emergency_material_warehouses
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `warehouse_type` | text | 类型，如 `comprehensive`、`firefighting`、`medical`、`daily_necessities` |
| `managing_unit_name` | text | 管理单位 |
| `contact_phone` | text | 联系电话，可为空 |
| `storage_capacity_t` | numeric | 仓储能力，单位吨，不小于 0 |
| `inventory_summary` | jsonb | 库存摘要 JSON |

`availability_status` 可取 `available`、`dispatching`、`restocking`、`unavailable`。

```bash
curl -G "$API_BASE/emergency_material_warehouses" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'availability_status=in.(available,dispatching)' \
  --data-urlencode 'select=id,name,warehouse_type,storage_capacity_t,inventory_summary,geom' \
  --data-urlencode 'order=storage_capacity_t.desc'
```

`inventory_summary` 的结构由业务方约定，例如：

```json
{
  "饮用水": 1200,
  "应急照明": 180,
  "帐篷": 90,
  "食品包": 600
}
```

## 9. 取水点

```http
GET /emergency_water_points
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `water_source_type` | text | 水源类型，如 `reservoir`、`pond`、`hydrant`、`stream` |
| `managing_unit_name` | text | 管理单位，可为空 |
| `contact_phone` | text | 联系电话，可为空 |
| `estimated_supply_m3_h` | numeric | 估算供水能力，单位立方米/小时，不小于 0 |

`availability_status` 可取 `available`、`limited`、`maintenance`、`unavailable`。

```bash
curl -G "$API_BASE/emergency_water_points" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'availability_status=eq.available' \
  --data-urlencode 'estimated_supply_m3_h=gte.30' \
  --data-urlencode 'order=estimated_supply_m3_h.desc'
```

## 10. 起降点

```http
GET /emergency_landing_sites
```

专有字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `site_type` | text | 类型，如 `uav_pad`、`helicopter_pad`、`temporary_landing_zone` |
| `managing_unit_name` | text | 管理单位 |
| `contact_phone` | text | 联系电话，可为空 |
| `max_aircraft_count` | integer | 可同时保障的飞行器数量，必须大于 0 |

`availability_status` 可取 `available`、`occupied`、`standby`、`maintenance`、`unavailable`。

查询可用的无人机起降点：

```bash
curl -G "$API_BASE/emergency_landing_sites" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'site_type=eq.uav_pad' \
  --data-urlencode 'availability_status=eq.available' \
  --data-urlencode 'select=id,name,max_aircraft_count,managing_unit_name,geom'
```

## 11. 通用更新和删除

七类 CRUD 接口采用相同调用方式。以下以救援力量为例。

更新资源：

```bash
curl -X PATCH "$API_BASE/emergency_rescue_forces?id=eq.<resource_id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "personnel_count": 24,
    "availability_status": "deployed"
  }'
```

删除资源：

```bash
curl -X DELETE "$API_BASE/emergency_rescue_forces?id=eq.<resource_id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Prefer: return=representation'
```

成功但未指定 `Prefer: return=representation` 时，PostgREST 通常返回空响应体。

## 12. 分类统计与刷新

### 12.1 查询统计快照

```http
GET /emergency_resource_category_statistics
```

返回字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `category_code` | text | 类别编码 |
| `category_name` | text | 类别中文名称 |
| `resource_count` | bigint | 该类别资源数量 |
| `refreshed_at` | timestamptz | 当前快照刷新时间 |

`category_code` 可取：`rescue_force`、`medical_resource`、`expert_force`、`shelter`、`material_warehouse`、`water_point`、`landing_site`。

```bash
curl -G "$API_BASE/emergency_resource_category_statistics" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'select=category_code,category_name,resource_count,refreshed_at' \
  --data-urlencode 'order=category_code.asc'
```

响应示例：

```json
[
  {
    "category_code": "rescue_force",
    "category_name": "救援力量",
    "resource_count": 5,
    "refreshed_at": "2026-07-14T16:38:10.001838+08:00"
  }
]
```

### 12.2 刷新统计快照

新增、更新或删除资源后调用：

```http
POST /rpc/refresh_emergency_resource_category_statistics
```

```bash
curl -X POST "$API_BASE/rpc/refresh_emergency_resource_category_statistics" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{}'
```

RPC 返回本次刷新时间，格式为 JSON 字符串：

```json
"2026-07-14T16:38:10.001838+08:00"
```

推荐写入流程：

1. 调用资源 CRUD 接口完成写入；
2. 调用刷新统计 RPC；
3. 重新查询分类统计接口。

## 13. 常见 PostgREST 查询参数

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

## 14. 常见错误

| HTTP 状态 | 典型原因 |
|---|---|
| `400` | 状态值不合法、数量或容量越界、坐标格式错误、避难人数超过容量 |
| `401` | 未携带 JWT、JWT 无效或已过期 |
| `403` | 当前角色无接口权限 |
| `404` | 接口路径不存在 |
| `409` | `source_code` 重复 |
