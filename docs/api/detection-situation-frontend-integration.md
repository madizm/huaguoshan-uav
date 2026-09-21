# 侦测态势前端对接指南

## 1. 文档目标

本文面向低空空域三维工作台前端，说明如何通过 PostgREST 接入雷达、电侦目标的：

- 当前态势；
- 最近一段实时尾迹；
- 持久化游标增量；
- 历史航迹摘要与详情；
- 观测来源健康状态。

数据库表、连接器写入协议和部署方式见 [`detection-situation-api.md`](./detection-situation-api.md)。前端不得直接访问 `situation` schema，只能调用 `api` schema 暴露的视图和 RPC。

## 2. 推荐对接流程

实时模式采用“批量初始化 + 游标增量”，不要周期性重复下载每条航迹的完整历史。

```text
登录取得 admin JWT
        │
        ▼
get_detection_live_tracks_v2
初始化活动目标、最近 5 分钟尾迹、来源状态和 cursor
        │
        ▼
每 2 秒调用 get_detection_situation_changes(after_cursor)
        │
        ├─ target_upsert：更新目标并追加空间点
        ├─ target_remove：标记目标丢失
        └─ source_status：提示来源状态变化
        │
        ▼
更新 cursor；has_more=true 时立即读取下一页
```

历史模式独立使用：

```text
list_detection_target_tracks
        │
        ▼
用户选择 track_id
        │
        ▼
get_target_track_detail
```

## 3. 认证与请求约定

### 3.1 同源入口

生产部署应通过同一个 Nginx 入口访问前端、认证服务和 PostgREST：

```text
POST /auth/login
POST /postgrest/rpc/<function_name>
GET  /postgrest/<resource_name>
```

前端不应硬编码数据库地址或直接连接 PostgreSQL。

### 3.2 登录

```http
POST /auth/login
Content-Type: application/json
```

```json
{
  "username": "<用户名>",
  "password": "<密码>"
}
```

后续请求携带：

```http
Authorization: Bearer <access_token>
Content-Type: application/json
Accept: application/json
```

侦测态势读接口仅授权 `admin` JWT。收到 `401` 时应停止轮询并切换到未登录状态，不应持续重试。

### 3.3 PostgREST RPC

所有 RPC 使用 `POST`，参数放在 JSON 请求体中。参数名必须与文档完全一致，包括 `p_` 前缀。

```js
async function rpc(name, payload, token) {
  const response = await fetch(`/postgrest/rpc/${name}`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) throw new Error(`RPC ${name} HTTP ${response.status}`);
  return response.json();
}
```

## 4. 稳定枚举与基本类型

### 4.1 来源类型

| `source_type_code` | 含义 | 建议颜色 |
|---:|---|---|
| `10` | 雷达 | `#f6c85f` |
| `20` | 电侦 | `#5eead4` |
| `null` | 来源类型待确认 | 中性灰 |

不要根据中文名称执行逻辑判断，应使用数值编码。

### 4.2 航迹状态

| 状态 | 含义 | 前端行为 |
|---|---|---|
| `tracking` | 正在跟踪 | 正常显示当前位置和尾迹 |
| `lost` | 暂时丢失 | 降低透明度，短暂保留后移除 |
| `closed` | 会话已明确结束 | 历史模式展示，实时模式移除 |

### 4.3 增量类型

| 类型 | 含义 |
|---|---|
| `target_upsert` | 目标新增或更新，可能带空间位置 |
| `target_remove` | 目标丢失或来源明确移除 |
| `source_status` | 来源连接或配置状态变化 |

### 4.4 坐标和高度

- `position` 是 WGS84 GeoJSON `Point`，坐标顺序为 `[longitude, latitude]`。
- `altitude_amsl_m` 是平均海平面高度，单位米。
- `relative_height_m` 是来源相对高度，不能当作 AMSL 使用。
- 高度缺失时，可以使用固定视觉抬升绘制，但必须标注“高度未知”。
- 无坐标侦测不得使用站点坐标或 `(0, 0)` 代替目标位置。

## 5. 实时航迹初始化

### 5.1 请求

```http
POST /postgrest/rpc/get_detection_live_tracks_v2
```

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

参数说明：

| 参数 | 范围 | 说明 |
|---|---:|---|
| `p_observation_source_ids` | 可空 | 观测来源 ID 过滤；`null` 表示全部来源 |
| `p_producer_asset_ids` | 可空 | 实际生产观测的设备资产 ID；`null` 表示不过滤 |
| `p_detection_method_codes` | 可空 | 平台稳定侦测方式过滤；`null` 表示不过滤，`[]` 表示空集 |
| `p_active_within_seconds` | 5–3600 | 最近多久有观测才视为活动航迹 |
| `p_trail_seconds` | 30–1800 | 每条航迹返回的尾迹时间窗口 |
| `p_max_tracks` | 1–5000 | 最大活动航迹数 |
| `p_max_points_per_track` | 2–1000 | 每条航迹最大空间点数 |

推荐值是 120 秒活动窗口、300 秒尾迹窗口、每条航迹最多 300 点。

### 5.2 响应结构

```json
{
  "generated_at": "2026-09-21T10:31:07.885948+08:00",
  "cursor": 3070,
  "trail_seconds": 300,
  "sources": [
    {
      "id": 1,
      "station_id": "90",
      "name": "连云港雷达云平台站点 90",
      "enabled": true,
      "connector_state": "connected",
      "last_message_at": "2026-09-21T10:30:31+08:00",
      "last_snapshot_at": "2026-09-21T10:30:40+08:00",
      "lost_timeout_seconds": 60
    }
  ],
  "tracks": [
    {
      "track_id": 177,
      "track_code": "TRK-178",
      "target_id": 177,
      "status": "tracking",
      "station_id": "90",
      "source_target_id": "F6Q8D249V00GLEL3",
      "observation_methods": [{"code": "radio_detection", "name": "电侦"}],
      "latest_observation_method_code": "radio_detection",
      "latest_observation_method_name": "电侦",
      "model": "DJI-Matrice 3D/3TD",
      "last_observed_at": "2026-09-21T10:30:31+08:00",
      "quality_flags": [],
      "points": [
        {
          "observation_id": 3135,
          "observed_at": "2026-09-21T10:30:31+08:00",
          "position": {
            "type": "Point",
            "coordinates": [119.179627433, 34.597603822]
          },
          "altitude_amsl_m": 116.0,
          "detection_method_code": "radio_detection",
          "detection_method_name": "电侦",
          "quality_flags": []
        }
      ]
    }
  ]
}
```

前端应保存：

- `cursor`：下一次增量请求的起点；
- `trail_seconds`：本地尾迹裁剪窗口；
- 以 `track_id` 为键的航迹映射；
- 来源状态列表。

## 6. 游标增量

### 6.1 轮询请求

```http
POST /postgrest/rpc/get_detection_situation_changes
```

```json
{
  "p_after_cursor": 3070,
  "p_station_ids": ["90"],
  "p_limit": 500
}
```

推荐每 2 秒调用一次。上一次请求尚未结束时，不要并发发起下一次请求。

### 6.2 响应结构

```json
{
  "from_cursor": 3070,
  "next_cursor": 3072,
  "has_more": false,
  "changes": [
    {
      "cursor": 3071,
      "type": "target_upsert",
      "occurred_at": "2026-09-21T10:30:32+08:00",
      "payload": {
        "track_id": 177,
        "target_id": 177,
        "track_code": "TRK-178",
        "source_target_id": "F6Q8D249V00GLEL3",
        "source_type_code": 20,
        "model": "DJI-Matrice 3D/3TD",
        "observation_id": 3136,
        "observed_at": "2026-09-21T10:30:32+08:00",
        "position": {
          "type": "Point",
          "coordinates": [119.1797, 34.5975]
        },
        "altitude_amsl_m": 115.0,
        "quality_flags": []
      }
    }
  ]
}
```

### 6.3 游标规则

1. 成功处理当前页后，将本地游标更新为 `next_cursor`。
2. `has_more=true` 时立即继续请求下一页，不等待下一个轮询周期。
3. 不要使用数组下标或时间戳替代游标。
4. 重复收到同一 `observation_id` 时忽略该空间点。
5. 页面重新加载或增量失败无法恢复时，重新调用实时初始化接口取得新快照和游标。

### 6.4 增量合并

`target_upsert` 可能没有 `position`。这种消息表示目标仍被侦测到，但不能更新地图坐标。增量中的 `detection_method_code` 使用平台稳定编码，与初始化响应一致。

建议的合并逻辑：

```js
function applyTargetUpsert(track, payload) {
  track.status = 'tracking';
  track.lastObservedAt = payload.observed_at;

  if (!payload.position) return;
  if (track.observationIds.has(payload.observation_id)) return;

  track.observationIds.add(payload.observation_id);
  track.points.push(payload);
  track.points.sort((a, b) =>
    Date.parse(a.observed_at) - Date.parse(b.observed_at) ||
    Number(a.observation_id) - Number(b.observation_id)
  );
}
```

收到 `target_remove` 后：

- 将状态改为 `lost`；
- 保存 `occurred_at` 作为丢失时间；
- 尾迹和末次位置降低透明度；
- 建议保留 60 秒后从实时图层移除。

## 7. 前端尾迹缓冲区

每条航迹应使用有界缓冲区，避免页面长时间运行后内存持续增长。

推荐规则：

- 只保留最近 5 分钟空间点；
- 每条航迹最多保留 300 点；
- 使用 `observation_id` 去重；
- 按 `observed_at`、`observation_id` 排序；
- 删除窗口外点时同步删除其去重集合记录；
- 切换来源过滤条件时重新初始化，不要仅隐藏旧数据后继续接收全部增量。

增量可能迟到，因此不能假设后收到的点一定具有更晚的 `observed_at`。

## 8. Cesium 渲染建议

### 8.1 当前位置

每条活动航迹显示一个当前位置实体：

- 位置取该航迹时间最新的有效空间点；
- 雷达、电侦使用不同颜色；
- 标签优先使用 `model`，其次使用来源类型名称；
- 描述面板展示来源目标 ID、观测时间和高度基准。

```js
const [longitude, latitude] = point.position.coordinates;
const height = point.altitude_amsl_m ?? 100;
const position = Cesium.Cartesian3.fromDegrees(longitude, latitude, height);
```

当 `altitude_amsl_m` 缺失时，上例中的 `100` 仅是视觉抬升，不是业务高度。

### 8.2 尾迹切段

来源快照可能在极短时间内发生明显位置跳变。前端不应把所有点直接连接为一条折线。

相邻点推算水平速度超过 `100 m/s` 时，应结束当前线段并从下一个点开始新线段：

```text
正常点 ─ 正常点    异常跳变    正常点 ─ 正常点
       第一段      不连线             第二段
```

同时满足以下条件的重复快照不应计为跳变：

- 时间相同；
- 坐标距离不超过 1 米。

### 8.3 不做无限外推

当前界面应以真实观测点为准。可以在两个已收到的有效点之间做短时插值改善视觉连续性，但不得：

- 在只有一个点时根据速度无限外推；
- 把方位角当作目标航向；
- 把站点到目标的距离当作目标累计航程；
- 把缺失高度显示为 `0 m AMSL`。

### 8.4 图层更新

目标数量较少时，可以在每批增量后重建侦测 `CustomDataSource`。目标数量增大后，应改为按 `track_id` 更新实体，减少闪烁和对象分配。

## 9. 来源状态展示

来源状态来自初始化响应的 `sources`：

| 判断 | 建议展示 |
|---|---|
| `enabled=false` | 已停用 |
| `connector_state!=connected` | 连接异常 |
| 最近消息超过 `max(120 秒, 2 × lost_timeout_seconds)` | 数据已延迟 |
| 其他情况 | 接入正常 |

`connector_state=connected` 只代表连接器链路状态，不等同于物理雷达健康状态。

收到 `source_status` 增量后，可以重新调用实时初始化接口，以取得完整的最新来源状态。

## 10. 当前态势快照

不需要尾迹的轻量页面可以调用：

```http
POST /postgrest/rpc/get_detection_situation_snapshot
```

```json
{
  "p_station_ids": ["90"],
  "p_source_type_codes": [10, 20],
  "p_active_within_seconds": 120,
  "p_limit": 1000
}
```

返回字段：

- `targets`：有有效位置的活动目标；
- `non_spatial_detections`：没有有效位置的活动侦测；
- `sources`：来源状态；
- `cursor`：当前增量游标。

实时尾迹页面使用 `get_detection_live_tracks_v2`，不应再同时调用旧版 `get_detection_live_tracks`。旧版只保留给尚未迁移的调用方。

## 11. 历史航迹

### 11.1 查询摘要

```http
POST /postgrest/rpc/list_detection_target_tracks
```

```json
{
  "p_start_at": "2026-09-21T00:00:00+08:00",
  "p_end_at": "2026-09-22T00:00:00+08:00",
  "p_station_ids": ["90"],
  "p_source_type_codes": [20],
  "p_limit": 200
}
```

时间区间采用 `[p_start_at, p_end_at)` 半开语义，单次窗口最大 7 天。

每条摘要包括：

- `track_id`、`track_code`；
- 来源目标、型号和来源类型；
- 航迹状态及起止时间；
- 观测数量和空间点数量；
- 质量标记数量；
- 高度范围和空间范围。

### 11.2 查询详情

```http
POST /postgrest/rpc/get_target_track_detail
```

```json
{
  "p_track_id": 177,
  "p_start_at": "2026-09-21T00:00:00+08:00",
  "p_end_at": "2026-09-22T00:00:00+08:00",
  "p_max_points": 5000
}
```

响应包含：

- `track`：航迹基本信息；
- `points`：有坐标的观测点；
- `non_spatial_observations`：无坐标观测；
- `evidence`：原始数量、返回数量和是否抽样。

历史轨迹同样必须执行异常跳变切段。

## 12. 错误处理与恢复

| 场景 | 前端处理 |
|---|---|
| `401 Unauthorized` | 停止轮询，清除失效 JWT，提示重新登录 |
| `403 Forbidden` | 停止轮询，提示账号无侦测态势权限 |
| 网络超时或 `5xx` | 保留当前地图内容，指数退避后重试 |
| 增量游标处理失败 | 重新调用实时初始化接口 |
| 单页 `has_more=true` | 立即读取下一页 |
| 页面切换到历史模式 | 停止实时轮询 |
| 页面销毁 | 清除定时器和 Cesium 数据源 |

建议退避间隔为 2、4、8、16 秒，最长不超过 30 秒。恢复成功后重置退避。

避免每 2 秒重复记录相同错误；界面保留一个当前错误状态即可。

## 13. 性能边界

- 实时初始化最多 5000 条航迹，前端推荐限制为 1000 条。
- 每条实时尾迹最多返回 1000 点，前端推荐 300 点。
- 单次增量最多 1000 条，前端推荐每页 500 条。
- 历史摘要最多 1000 条。
- 航迹详情最多返回 5000 个抽样点。
- 历史查询窗口最大 7 天。

目标数量较多时，应优先缩小站点、来源类型、活动窗口和尾迹窗口，而不是提高所有上限。

## 14. 对接验收清单

- [ ] 未登录时不请求受保护接口。
- [ ] 实时初始化后保存返回游标。
- [ ] 增量轮询不会并发重入。
- [ ] `has_more=true` 时能够连续翻页。
- [ ] 使用 `observation_id` 去重。
- [ ] 能处理迟到、乱序和相同时间观测。
- [ ] 无坐标侦测不会出现在地图虚假位置。
- [ ] 缺失高度不会显示为 `0 m AMSL`。
- [ ] 异常跳变不会被连成跨越线。
- [ ] 丢失目标会淡出并最终移除。
- [ ] 来源过滤变化后重新初始化。
- [ ] 切换历史模式或销毁页面时停止轮询。
- [ ] 401、网络中断和游标恢复路径经过验证。
- [ ] 桌面与移动端均无面板横向溢出。

## 15. 仓库实现参考

当前三维工作台实现位于：

- `frontend/src/features/source-situation/source-situation-module.js`
- `frontend/tianditu-3d.html`
- `frontend/src/styles/controls.css`
- `frontend/src/api/postgrest-client.js`

对应测试：

- `tests/test_source_situation_module.js`
- `tests/test_detection_situation_schema.py`
