# 云平台侦测接入接口

## 1. 实现范围

当前实现由以下文件组成：

- 数据库迁移：`backend/create_detection_situation_schema.sql`
- 云平台连接器：`scripts/radar_cloud_connector.py`
- 数据库设计：`docs/雷达云平台/云平台侦测接入设计.md`

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
  "qualityFlags": [],
  "rawPayload": {}
}
```

返回 `status`、`observationId`、`targetId`、`trackId` 和 `changeCursor`。重复幂等键返回 `status=duplicate`，不会重复写入航迹和增量事件。

### 3.2 更新连接器状态

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

### 3.3 在线目标对账

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

三个写函数只授权给 `detection_ingest` 组角色。该角色：

- 可以使用 `situation` schema；
- 可以执行三个内部写函数；
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
3. 拉取 `/uav/onlineList?stationId=90` 初始化目标。
4. 持续接收 WebSocket 消息并按每条记录的 `stationId` 过滤。
5. 每 30 秒重新拉取在线列表并对账。
6. 断线后按 1、2、4 秒递增，最长 60 秒重连。
7. 收到 `SIGINT` 或 `SIGTERM` 后记录断开状态并退出。

## 6. 系统读接口

以下接口通过现有 PostgREST `api` schema 暴露，仅授权 `admin` JWT：

```http
GET  /postgrest/detection_source_types
GET  /postgrest/detection_observation_sources
POST /postgrest/rpc/get_detection_situation_snapshot
POST /postgrest/rpc/get_detection_situation_changes
POST /postgrest/rpc/get_target_track_detail
```

快照请求示例：

```json
{
  "p_station_ids": ["90"],
  "p_source_type_codes": [10, 20],
  "p_active_within_seconds": 30,
  "p_limit": 1000
}
```

增量请求示例：

```json
{
  "p_after_cursor": 0,
  "p_station_ids": ["90"],
  "p_limit": 500
}
```

航迹详情使用半开时间区间，单次窗口最大 24 小时：

```json
{
  "p_track_id": 1,
  "p_start_at": "2026-09-20T00:00:00Z",
  "p_end_at": "2026-09-21T00:00:00Z",
  "p_max_points": 2000
}
```

### 6.1 管理侦测来源

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
