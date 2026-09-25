# 来源架次统计 API

## 1. 统计口径

一条 `situation.source_target_session` 计为一个来源架次。来源架次表示单一侦测来源对一个 `source_target_id` 的连续发现会话，不等同于跨来源融合后的真实物理飞行架次。

统计投影 `situation.source_sortie_statistics` 只读且可重建，不修改来源会话、航迹、观测或风险历史。管理端只能通过 `api` schema 的受限 RPC 查询，不能直接读取该投影。

迁移顺序：

1. `backend/create_detection_situation_schema.sql`
2. `backend/create_defense_ring_admin.sql`
3. `backend/create_target_risk_assessment.sql`
4. `backend/create_source_sortie_statistics.sql`
5. `backend/migrate_postgrest_api_roles.sql`

## 2. 数据质量语义

每条来源架次包含以下质量字段：

- `timestampSuspect`：接收时间晚于观测时间超过 1 小时，或观测时间超前接收时间超过 5 分钟；
- `singleTimestamp`：架次内所有观测只有一个不同的观测时间；
- `nonSpatial`：架次没有任何空间坐标；
- `lifecycleOverlap`：本架次开始时间早于同来源同目标上一架次的结束时间。

异常架次不会被删除或自动排除。调用方应明确展示异常数量，并通过质量过滤器决定分析范围。

`maxRiskLevel` 只在架次至少存在一条 `status=assessed` 的评估时返回。只有 `target_location_unavailable` 或 `outside_protected_objects` 的架次返回空值，前端展示为“不可评估”，不能归入正常或低风险。

## 3. 获取总览

```http
POST /postgrest/rpc/get_source_sortie_statistics
Authorization: Bearer <admin-jwt>
Content-Type: application/json
```

```json
{
  "p_start_at": "2026-09-18T00:00:00+08:00",
  "p_end_at": "2026-09-24T00:00:00+08:00",
  "p_source_ids": null,
  "p_detection_method_codes": null
}
```

窗口采用半开区间，按 `started_at` 统计，最大 90 天。返回：

- `summary`：来源架次、活动架次、空间架次、高风险架次、核心圈架次、平均持续时间和观测量；
- `riskDistribution`：架次最大有效风险分布；
- `quality`：四类质量问题数量。

## 4. 获取时间序列

```http
POST /postgrest/rpc/get_source_sortie_series
```

```json
{
  "p_start_at": "2026-09-18T00:00:00+08:00",
  "p_end_at": "2026-09-24T00:00:00+08:00",
  "p_bucket": "day",
  "p_source_ids": null,
  "p_detection_method_codes": null
}
```

`p_bucket` 仅允许 `hour` 或 `day`，按 `Asia/Shanghai` 分桶。窗口最大 90 天。每个点包含来源架次、空间架次、高/严重风险架次和时间戳异常架次数量。

## 5. 查询架次列表

```http
POST /postgrest/rpc/list_source_sorties
```

```json
{
  "p_start_at": "2026-09-18T00:00:00+08:00",
  "p_end_at": "2026-09-24T00:00:00+08:00",
  "p_source_ids": null,
  "p_detection_method_codes": null,
  "p_risk_levels": ["high", "critical"],
  "p_quality_issue": null,
  "p_limit": 100,
  "p_offset": 0
}
```

明细窗口最大 31 天，单页最多 500 条，偏移最大 10000。`p_quality_issue` 可选值：

- `timestamp_suspect`
- `single_timestamp`
- `non_spatial`
- `lifecycle_overlap`

返回 `total` 和 `sorties`。每条架次包含来源目标、航迹、起止时间、观测与空间点数量、风险、防御圈和质量属性。
