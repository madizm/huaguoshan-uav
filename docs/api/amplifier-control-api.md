# 云平台功放控制接口

## 1. 实现文件

- 数据库迁移：`backend/create_countermeasure_amplifier_schema.sql`
- 指令 worker：`scripts/amplifier_command_worker.py`
- WebSocket 状态接入：`scripts/radar_cloud_connector.py`
- 管理端控制界面：`frontend/admin/src/components/AmplifierControlDrawer.vue`
- 详细设计：`docs/雷达云平台/云平台功放接入设计.md`

迁移为来源设备 `radar_cloud / b260705174118582` 动态登记 `radio_jamming` 可控能力。当前开发库中该设备对应 `equipment.asset.id=82`，实现代码不硬编码该 ID。

## 2. 权限

| JWT / 数据库角色 | 权限 |
|---|---|
| `admin` | 任一已登录用户均可查询状态、开启、手动关闭和紧急关闭 |
| `anonymous` | 无功放查询和控制权限 |
| `detection_ingest` | 仅写入 WebSocket 功放状态、断线时标记 unknown |
| `countermeasure_worker` | 仅领取、完成、失败和推进指令 |

功放控制不要求额外的操作员或主管角色。当前认证入口为所有登录用户签发 `role=admin` 的 JWT。数据库仍通过设备能力和 `countermeasure.control_authorization` 限制哪些资产可以真实控制。

## 3. 开启功放

```http
POST /postgrest/rpc/start_amplifier_operation
Authorization: Bearer <login-jwt>
Content-Type: application/json
```

### 3.1 全向频段

```json
{
  "p_request": {
    "assetId": 82,
    "mode": "omnidirectional_frequency",
    "frequenciesMhz": [2400, 5200, 5800],
    "durationSeconds": 5,
    "reason": "人工确认的反制处置",
    "idempotencyKey": "start-018f..."
  }
}
```

### 3.2 目标坐标

```json
{
  "p_request": {
    "assetId": 82,
    "mode": "target_coordinate",
    "frequenciesMhz": [2400, 5200, 5800],
    "durationSeconds": 60,
    "target": {
      "longitude": 119.196054,
      "latitude": 34.591989,
      "coordinateSystem": "WGS84",
      "observedAt": null,
      "trackId": null
    },
    "reason": "人工确认的目标处置",
    "idempotencyKey": "strike-0190..."
  }
}
```

返回 JSON：

```json
{
  "operationId": "0190...",
  "assetId": 82,
  "state": "queued",
  "requestedDurationSeconds": 60,
  "requestedAt": "2026-10-17T13:00:00Z",
  "hardDeadlineAt": "2026-10-17T13:01:00Z"
}
```

设备状态门禁只有两个：

1. 盒子在线。
2. 处置子系统在线。

RPC 还会校验调用权限、能力授权、并发操作、频率、时长和 WGS84 坐标。它不使用 `unattended`、遥测新鲜度或当前功放状态作为开启门禁。

同一操作人使用相同 `idempotencyKey` 和相同规范请求时返回原操作。相同 key 对应不同请求时返回 `idempotency_conflict`。

## 4. 手动关闭全向功放

```http
POST /postgrest/rpc/stop_amplifier_operation
```

```json
{
  "p_asset_id": 82,
  "p_operation_id": "0190...",
  "p_reason": "操作员手动关闭",
  "p_idempotency_key": "stop-0191..."
}
```

该接口只适用于 `omnidirectional_frequency`。目标坐标模式由 `strike.duration` 在设备侧计时结束；调用本接口会返回 `unsupported_operation_mode`。

## 5. 紧急关闭全向功放

```http
POST /postgrest/rpc/emergency_stop_amplifier
```

```json
{
  "p_asset_id": 82,
  "p_reason": "紧急关闭",
  "p_idempotency_key": "emergency-0192..."
}
```

任一已登录用户均可执行。该接口发送全部支持频段的 `amp action=0`，不要求设备在线，也不要求存在活动操作。它不能中止已经下发的 `strike`。返回 JSON 中的 `strikeInterruptSupported` 固定为 `false`。

## 6. 查询接口

```http
GET /postgrest/amplifier_state_current?asset_id=eq.82
GET /postgrest/amplifier_operations?asset_id=eq.82&order=requested_at.desc
GET /postgrest/amplifier_operation_events?operation_id=eq.<uuid>&order=created_at.asc
```

`amplifier_state_current.actual_state`：

- `on`：WebSocket 或 `config_status.freqsOn` 确认开启。
- `off`：WebSocket 或周期对账确认关闭。
- `unknown`：WebSocket 已断开或到期后未收到确认。

HTTP 指令成功只把操作推进到等待确认状态，不能把设备实际状态直接改为 `on` 或 `off`。

## 7. Worker

创建独立登录角色，不要把密码写入迁移：

```sql
create role amplifier_worker login password '<由密钥系统提供>';
grant countermeasure_worker to amplifier_worker;
```

启动：

```bash
export AMPLIFIER_DATABASE_DSN='postgresql://amplifier_worker:<password>@<db-host>:5432/huaguoshan_projd'
export AMPLIFIER_DATABASE_ROLE='countermeasure_worker'
export RADAR_CLOUD_BASE_URL='http://47.110.44.5:8003'
export AMPLIFIER_WORKER_ID='amplifier-worker-1'

uv run scripts/amplifier_command_worker.py
```

worker 的处理规则：

1. 使用租约和 `FOR UPDATE SKIP LOCKED` 领取指令。
2. 全向开启在 HTTP 调用前持久化关闭指令。
3. HTTP 状态码和响应体 `status` 都为 `200` 时记录“已下发”。
4. 开启或 strike 投递不确定时不自动重试。
5. 全向关闭可以最多重试 7 次。
6. 日志和数据库只保存脱敏响应字段。

## 8. WebSocket 状态

现有 `radar_cloud_connector.py` 在同一地址按 `type` 分流：

```text
uav_amp_status -> countermeasure.ingest_amplifier_status(jsonb)
```

支持频率固定转换：

| 厂商值 | 平台值 |
|---|---:|
| `2.4` | `2400` MHz |
| `5.2` | `5200` MHz |
| `5.8` | `5800` MHz |

WebSocket 断开时，连接器调用 `countermeasure.mark_amplifier_source_unknown`。重连后状态保持 `unknown`，直到收到厂商补发状态或新的 `config_status` 对账状态。

## 9. 60 秒限制

- 全向模式由 worker 在持久化截止时间发送 `amp action=0`。
- 管理端允许输入 `1..60` 秒。
- 目标模式把 `1..60` 秒直接写入 `strike.duration`。
- 设备还有 120 秒硬保护。

120 秒硬保护不能证明全向模式满足 60 秒业务上限。如果平台、网络和设备通信同时失效，全向模式可能持续到 120 秒。不可突破的 60 秒要求仍需要设备侧 60 秒保护或独立边缘 watchdog。

## 10. 验证

单元和静态契约测试：

```bash
uv run pytest -q \
  tests/test_amplifier_control_schema.py \
  tests/test_amplifier_command_worker.py \
  tests/test_radar_cloud_connector.py
```

数据库集成测试：

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f tests/amplifier_control_integration.sql
```

集成测试验证权限隔离、请求幂等、HTTP 前关闭计划、WebSocket 状态确认和 strike 不可手动关闭。测试事务最后回滚。
