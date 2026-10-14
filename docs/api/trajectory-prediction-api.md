# 轨迹预测 API

轨迹预测由 `backend/prediction/worker.py` 预计算：每 2 秒读取最近 30 秒内活跃的空域目标和无人机资产观测，做运动学外推（恒定速度 cv、恒定转向 ct、悬停 hover），结果追加写入 `situation.trajectory_prediction`，同一对象写入节流 5 秒，保留 24 小时。

预测越过检查点时刻（10/30/60/120 秒）后，worker 自动将预测点与实际观测比对，追加评估记录到 `situation.trajectory_prediction_evaluation`。评估记录不随预测清理删除，用于模型效果审计。

两个表都在 `situation` 内部层，前端只通过以下 `api` RPC 访问。所有接口需要 admin 角色 JWT。

## 1. 大屏实时预测

```http
POST /postgrest/rpc/get_trajectory_predictions
```

```json
{ "p_subject_kinds": null, "p_max_subjects": 200, "p_max_prediction_age_seconds": 30 }
```

- `p_subject_kinds`：`airspace_target`、`aircraft_asset` 子集或 NULL（全部）。
- `p_max_prediction_age_seconds`：5–600，只返回预测时刻在该秒数内的记录。

返回 `{"generated_at","predictions":[...]}`，每条含 `subject_kind`、`subject_id`、`base_observed_at`、`predicted_at`、`model_code`、`model_version`、`horizon_seconds`、`step_seconds`、`speed_mps`、`heading_deg`、`turn_rate_dps`、`window_point_count`、`fit_residual_m` 和 `points`（`[{"eta_seconds","longitude","latitude","height_amsl_m","uncertainty_m"}]`）。仅含 `quality=ok` 的记录。

## 2. 引擎健康状态

```http
POST /postgrest/rpc/get_prediction_engine_status
```

```json
{ "p_offline_after_seconds": 30 }
```

返回 `{"generated_at","state","worker","throughput","models"}`。`state` 为 `healthy`、`degraded`、`offline` 之一：心跳超过阈值判 `offline`，worker 自报降级或停止判 `degraded`。`throughput` 含最近一分钟/一小时写入量、数据不足条数、活跃对象数和平均预测延迟；`models` 为最近一小时各模型写入条数。

## 3. 最近预测记录

```http
POST /postgrest/rpc/list_trajectory_predictions
```

```json
{ "p_limit": 50, "p_subject_kinds": null }
```

按预测时间倒序返回最近记录（不含预测点几何），每条含 `id`、`subject_kind`、`subject_id`、`base_observed_at`、`predicted_at`、`model_code`、`model_version`、`quality`、`reason`、`horizon_seconds`、`speed_mps`、`heading_deg`、`turn_rate_dps`、`window_point_count`、`fit_residual_m`、`point_count`。用于后台质量核查。

## 4. 准确度汇总

```http
POST /postgrest/rpc/get_prediction_accuracy_stats
```

```json
{ "p_hours": 24 }
```

- `p_hours`：1–720，按预测基准时刻统计该时长窗口内的评估记录。

返回 `{"generated_at","hours","summary","buckets"}`：

- `summary`：`{"evaluatedPredictions","samples","meanErrorM","medianErrorM","withinUncertaintyRate"}`；无样本时各指标为 NULL。
- `buckets`：按 `modelCode`、`subjectKind`、`etaSeconds` 分桶，每桶含 `samples`、`meanErrorM`、`medianErrorM`、`p90ErrorM`、`withinUncertaintyRate`。

误差单位为米，按 WGS84 椭球面距离计算；`withinUncertaintyRate` 为误差落在预测不确定半径内的比例，低于 0.8 说明不确定度口径偏乐观。

## 5. 单条预测评估明细

```http
POST /postgrest/rpc/get_prediction_evaluation_detail
```

```json
{ "p_prediction_id": 12345 }
```

返回 `{"generated_at","prediction_id","evaluations":[{"etaSeconds","errorM","uncertaintyM","withinUncertainty","actualObservedAt","timeOffsetS","evaluatedAt"}]}`。`timeOffsetS` 为实际观测时刻减检查点目标时刻的秒数。预测记录超期清理后明细仍可查；未越过检查点或该时段无实际观测时 `evaluations` 为空数组。

## 6. 航迹历史预测（回放叠加）

```http
POST /postgrest/rpc/get_track_prediction_history
```

```json
{ "p_track_id": 28181, "p_from": "2026-10-14T17:32:00+08:00", "p_to": "2026-10-14T17:53:00+08:00", "p_thin_seconds": 30 }
```

- `p_thin_seconds`：5–600，每个抽稀时间桶取基准时刻最新的一条，默认 30。
- 时间窗最长 7 天；预测仅保留 24 小时，超出窗口返回空数组。

返回 `{"generated_at","track_id","thin_seconds","predictions":[{"id","base_observed_at","predicted_at","model_code","speed_mps","heading_deg","turn_rate_dps","points":[...]}]}`，`points` 结构与实时接口一致。仅含 `quality=ok` 且有预测点的记录。大屏历史回放按帧时刻取基准时刻不晚于该帧的最近一条渲染。

## 关联与口径说明

- 空域目标的 `subject_id` 是 `situation.target_track.id`，目标丢失重建航迹后 ID 变更，跨航迹的长期精度分析需经 `target_id` 二次关联；无人机资产的 `subject_id` 是稳定的 `equipment.asset.id`。
- 实际观测匹配容差为检查点目标时刻前后 3 秒，取最近一条。
- 源时钟偏差会直接污染误差统计：评估前应在管理后台「侦测来源」页确认相关来源的源时钟偏差在阈值内。
