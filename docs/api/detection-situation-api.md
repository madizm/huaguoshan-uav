# 云平台侦测接入接口

## 1. 实现范围

当前实现由以下文件组成：

- 数据库迁移：`backend/create_detection_situation_schema.sql`
- 云平台连接器：`scripts/radar_cloud_connector.py`
- 数据库设计：`docs/雷达云平台/云平台侦测接入设计.md`
- 前端对接：`docs/api/detection-situation-frontend-integration.md`

连接器直接调用受限 PostgreSQL 函数。设计文档中的 `/internal/v1/detection/*` 是逻辑内部接口；当前部署没有额外增加 HTTP 转发层，避免无意义的透传服务。

## 2. 部署数据库

迁移依赖：

1. `backend/create_equipment_asset_schema.sql`
2. `backend/migrate_equipment_detection_devices.sql`
3. `backend/create_detection_situation_schema.sql`

执行：

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f backend/create_detection_situation_schema.sql
```

迁移会幂等登记已验证的站点 90 盒子：

```text
asset_code: RADAR-CLOUD-BOX-90
source_system: radar_cloud
source_asset_id: b260705174118582
station_id: 90
coordinate: 119.1929320, 34.5919520 (WGS84)
```

## 3. 内部写函数

### 3.1 写入规范目标观测

```sql
situation.ingest_target_observation(p_observation jsonb) returns jsonb
```

连接器负责拆分厂商批次、过滤站点、转换时区和单位，并逐条提交 `schemaVersion=1` 的规范观测：

```json
{
  "schemaVersion": 1,
  "sourceSystem": "radar_cloud",
  "stationId": "90",
  "sourceObservationId": "<SHA-256>",
  "sourceTargetId": "F9F4X25BR00A025M",
  "sourceSessionId": null,
  "sourceTypeCode": 20,
  "eventType": "snapshot",
  "observedAt": "2026-09-20T09:46:08Z",
  "receivedAt": "2026-09-20T09:46:09Z",
  "longitude": 119.196,
  "latitude": 34.592,
  "altitudeAmslM": 32,
  "horizontalDistanceM": 290,
  "remotePilotLocation": {
    "longitude": 119.1812,
    "latitude": 34.5968
  },
  "qualityFlags": [],
  "rawPayload": {}
}
```

返回 `status`、`observationId`、`targetId`、`trackId` 和 `changeCursor`。重复幂等键返回 `status=duplicate`，不会重复写入航迹和增量事件。

### 3.2 同步盒子台账和状态

```sql
situation.sync_detection_source_asset(p_asset jsonb) returns jsonb
```

连接器将 `prodBox/queryAll` 返回的已配置盒子同步到：

- `equipment.asset`：名称、厂商、型号、WGS84 登记位置和厂商扩展属性；
- `equipment.asset_status_current`：在线状态、最近心跳、最近观测时间和原始状态载荷；
- `equipment.asset_status_history`：由当前状态表触发器自动追加历史记录。

厂家字段解释和枚举转换由 `radar_cloud_connector.py` 完成；数据库函数只接收规范化资产字段。函数只允许更新已通过 `situation.observation_source` 配置并启用的资产，不会根据未受信任的厂家响应自动创建资产。返回 JSON：`status`、`assetId`、`sourceAssetId`、`connectivityStatus`。

### 3.3 写入设备实时状态

```sql
situation.ingest_detection_config_status(p_status jsonb) returns jsonb
```

连接器将 WebSocket `config_status` 规范化后写入。该消息没有厂商采集时间，因此 `observedAt` 使用平台接收时间，并强制携带 `missing_source_time` 质量标记。数据按用途分层保存：

- `equipment.counter_uas_telemetry_current`：每次覆盖的最新遥测；
- `equipment.counter_uas_status_event`：仅无人值守、子系统在线、旋转、启用频段等离散状态变化时追加；
- `equipment.counter_uas_telemetry_sample`：连续电气量、角度等最多每设备每 60 秒采样一条；
- `equipment.asset_status_current`：只同步盒子连通状态与心跳；
- `situation.observation_source_status_current`：只刷新接入链路最近消息时间。

雷达序列号仅在已经登记为 `microwave_radar` 资产时建立 `radar_asset_id` 关联，不根据状态消息自动创建设备。函数返回 `status`、`assetId`、`sourceAssetId`、`eventId` 和 `sampled`。

### 3.4 更新连接器状态

```sql
situation.update_detection_connector_status(
  p_source_system text,
  p_station_id text,
  p_state text,
  p_observed_at timestamptz,
  p_last_message_at timestamptz,
  p_error_code text,
  p_details jsonb
) returns jsonb
```

状态限定为 `connected`、`disconnected`、`degraded`、`unknown`。

### 3.5 在线目标对账

```sql
situation.reconcile_detection_targets(
  p_source_system text,
  p_station_id text,
  p_observed_at timestamptz,
  p_present_target_ids text[]
) returns jsonb
```

目标缺失超过来源配置的宽限时间后，来源会话和航迹变为 `lost`。

## 4. 权限

四个写函数只授权给 `detection_ingest` 组角色。该角色：

- 可以使用 `situation` schema；
- 可以执行四个内部写函数；
- 不能直接查询或修改 `situation` 底层表；
- 没有被授予 PostgREST 的 `authenticator`；
- 不能通过浏览器管理员 JWT 调用。

生产部署应创建独立登录角色并授予组角色：

```sql
create role detection_connector login password '<由密钥系统提供>';
grant detection_ingest to detection_connector;
```

密码不得写入迁移、脚本或服务配置仓库。

## 5. 启动连接器

连接器使用 PEP 723 内联依赖，由 `uv` 自动创建隔离运行环境：

```bash
export DETECTION_DATABASE_DSN='postgresql://detection_connector:<password>@<db-host>:5432/huaguoshan_projd'
export DETECTION_DATABASE_ROLE='detection_ingest'
export RADAR_CLOUD_BASE_URL='http://47.110.44.5:8003'
export RADAR_CLOUD_WEBSOCKET_URL='ws://47.110.44.5:8003/realTimeAlarmWebSocket'
export RADAR_CLOUD_STATION_ID='90'

uv run scripts/radar_cloud_connector.py
```

运行行为：

1. 连接数据库并切换到 `detection_ingest`。
2. 建立厂商 WebSocket。
3. 调用 `POST /prodBox/queryAll` 初始化盒子台账和状态，之后每 300 秒同步一次。
4. 拉取 `/uav/onlineList?stationId=90` 初始化目标。
5. 持续接收 WebSocket 目标消息和 `config_status`，按每条记录的 `stationId` 过滤并分别入库。
6. 每 30 秒重新拉取在线列表并对账。
7. 断线后按 1、2、4 秒递增，最长 60 秒重连。
8. 收到 `SIGINT` 或 `SIGTERM` 后记录断开状态并退出。

## 6. 系统读接口

以下接口通过现有 PostgREST `api` schema 暴露，仅授权 `admin` JWT：

```http
GET  /postgrest/detection_source_types
GET  /postgrest/detection_methods
GET  /postgrest/detection_method_mappings
GET  /postgrest/detection_method_mapping_history
GET  /postgrest/detection_observation_sources
GET  /postgrest/counter_uas_telemetry_current
GET  /postgrest/counter_uas_status_events
GET  /postgrest/counter_uas_telemetry_samples
POST /postgrest/rpc/get_detection_situation_snapshot
POST /postgrest/rpc/get_detection_live_tracks
POST /postgrest/rpc/get_detection_live_tracks_v2
POST /postgrest/rpc/get_detection_live_tracks_v3
POST /postgrest/rpc/get_detection_situation_changes
POST /postgrest/rpc/list_detection_target_tracks
POST /postgrest/rpc/get_target_track_detail
```

### 6.1 当前态势快照

```json
{
  "p_station_ids": ["90"],
  "p_source_type_codes": [10, 20],
  "p_active_within_seconds": 30,
  "p_limit": 1000
}
```

返回活动目标的当前位置、无坐标侦测、来源状态和当前增量游标。

### 6.2 实时航迹初始化

```json
{
  "p_station_ids": ["90"],
  "p_source_type_codes": [10, 20],
  "p_active_within_seconds": 120,
  "p_trail_seconds": 300,
  "p_max_tracks": 1000,
  "p_max_points_per_track": 300
}
```

返回当前活动目标、每条目标最近一段有界空间尾迹、来源状态和增量游标。前端随后使用游标补读增量，避免重复下载完整尾迹。

新接入应使用同时表达目标位置和远程飞手位置的观测版本：

```json
{
  "p_observation_source_ids": null,
  "p_producer_asset_ids": null,
  "p_detection_method_codes": ["radar", "radio_detection"],
  "p_active_within_seconds": 120,
  "p_trail_seconds": 300,
  "p_max_tracks": 1000,
  "p_max_points_per_track": 300
}
```

`get_detection_live_tracks_v3` 沿用 v2 的参数，但将每条航迹的 `points` 升级为 `observations`。每条观测分别包含可空的 `target_location` 和 `remote_pilot_location`，两者通过同一个 `observation_id` 保持关联；没有目标坐标但有飞手坐标的观测也会返回。v2 和更早接口仅用于兼容现有调用方。

`remote_pilot_location.position` 是 WGS84 GeoJSON Point，`source=vendor_reported` 表示位置由厂商设备上报。飞手位置不参与目标航迹位置、速度或跳点计算。

### 6.3 态势增量

```json
{
  "p_after_cursor": 0,
  "p_station_ids": ["90"],
  "p_limit": 500
}
```

`target_upsert` 增量保留原有平铺字段，并增加与 v3 相同结构的 `observation`；其中分别包含 `target_location` 和 `remote_pilot_location`。`target_remove` 用于将目标标记为丢失。

### 6.4 历史航迹摘要

历史查询使用半开时间区间，单次窗口最大 7 天：

```json
{
  "p_start_at": "2026-09-20T16:00:00Z",
  "p_end_at": "2026-09-21T16:00:00Z",
  "p_station_ids": ["90"],
  "p_source_type_codes": [20],
  "p_limit": 200
}
```

返回 `tracks`，每项包含航迹、来源目标、时间范围、空间点数量、质量标记数量、高度范围和空间范围。

### 6.5 航迹详情

航迹详情同样使用半开时间区间，单次窗口最大 7 天：

```json
{
  "p_track_id": 1,
  "p_start_at": "2026-09-20T00:00:00Z",
  "p_end_at": "2026-09-21T00:00:00Z",
  "p_max_points": 2000
}
```

### 6.6 管理侦测来源

管理员通过受约束 RPC 更新来源配置，不直接写入 `situation` 基础表：

```http
POST /postgrest/rpc/update_detection_observation_source
Authorization: Bearer <admin-jwt>
Content-Type: application/json
```

请求：

```json
{
  "p_source_id": 1,
  "p_name": "连云港雷达云平台站点 90",
  "p_asset_id": 2,
  "p_source_timezone": "Asia/Shanghai",
  "p_lost_timeout_seconds": 30,
  "p_enabled": true
}
```

返回 JSON 包含 `id`、`name`、`asset_id`、`source_timezone`、`lost_timeout_seconds` 和 `enabled`。接口约束：

- 名称不能为空，来源时区必须是 PostgreSQL 已知时区。
- 目标丢失宽限必须在 5 至 3600 秒之间。
- 启用来源时，映射设备必须存在且处于 `active` 生命周期。
- `source_system`、站点 ID 和盒子编码不可通过此接口修改。
- 停用后接入函数拒绝该来源的新观测，并将连接器状态重置为 `unknown`。
- 每次配置变更产生一条 `source_status` 增量事件。

`detection_observation_sources` 视图同时返回设备资产映射、来源时区、丢失宽限、连接时间和最近错误，供管理后台诊断使用。

### 6.7 管理侦测方式与厂商映射

```http
GET  /postgrest/detection_methods
GET  /postgrest/detection_method_mappings
GET  /postgrest/detection_method_mapping_history
POST /postgrest/rpc/create_detection_method
POST /postgrest/rpc/update_detection_method
POST /postgrest/rpc/upsert_detection_method_mapping
```

稳定编码如 `radar`、`radio_detection` 创建后不可修改。已使用的方式不删除，只能把 `lifecycle_status` 设置为 `deprecated`。`visible` 只控制管理端和业务筛选器展示；厂商类型是否继续接入由映射上的 `accept_ingest` 独立控制。

映射创建及其侦测方式、接入开关、扩展配置变更会追加写入 `detection_method_mapping_history`，记录变更前后值、时间和可取得的 JWT 主体。

厂商映射以 `(source_system, vendor_code)` 唯一，例如：

```text
radar_cloud + 10 -> radar
radar_cloud + 20 -> radio_detection
```

接入适配器向规范化载荷写入 `detectionMethodCode`。数据库同时校验厂商编码映射，防止适配器把同一个厂商类型解释成不同的平台侦测方式。

能识别实际生产设备时，适配器可同时写入 `sourceProducerAssetId`。接入函数按 `(sourceSystem, sourceProducerAssetId)` 解析 `equipment.asset`，并写入观测的 `producer_asset_id`；无法明确识别时保持为空，不把接入盒子冒充为实际生产设备。

## 7. 验证

```bash
python3 tests/test_detection_situation_schema.py
python3 tests/test_radar_cloud_connector.py
uv run python -m ast scripts/radar_cloud_connector.py
```

开发库已经验证：

- 迁移可完整编译；
- 重复消息不会重复入库；
- 有坐标目标进入态势快照；
- 离线消息关闭来源会话；
- `admin` 不能直接访问 `situation`；
- `detection_ingest` 不能直接查询底层表。
