# 轨迹预测 API

轨迹预测由 `backend/prediction/worker.py` 预计算：每 2 秒读取最近 30 秒内活跃的空域目标和无人机资产观测，做运动学外推（恒定速度 cv、恒定转向 ct、悬停 hover），结果追加写入 `situation.trajectory_prediction`，同一对象写入节流 5 秒，保留 24 小时。

预测越过检查点时刻（10/30/60/120 秒）后，worker 自动将预测点与实际观测比对，追加评估记录到 `situation.trajectory_prediction_evaluation`。评估记录不随预测清理删除，用于模型效果审计。

两个表都在 `situation` 内部层，前端只通过以下 `api` RPC 访问。所有接口需要 admin 角色 JWT。

## 状态估计版本

- 默认 `least_squares`：原最小二乘状态估计，`model_version=1`。
- 可选 `kalman_cv`：CV/悬停使用有限窗口卡尔曼水平状态估计，`model_version=2`；CT 外推和高度拟合保留原算法。版本 2 不代表每条记录都使用了卡尔曼（CT 仍沿用原模型）。
- 版本 2 的 CV `uncertainty_m` 是模型协方差对应的 95% 水平误差椭圆外接圆半径，未做经验覆盖率校准，不受原启发式半径上限约束。CT/悬停仍用启发式半径，不能将所有模型的半径都解释为 95% 置信范围。
- `fit_residual_m` 仍为最小二乘窗口位置残差，不是卡尔曼创新残差。接口返回结构不变。
- 现有准确度 RPC 不按 `model_version` 分桶，不能用它直接比较两版效果。请先用只读回放，见 [实施与验证报告](../reports/trajectory-kalman-validation-2026-10-15.md)。
- IMM CV/CT 仅作为 `replay --include-imm` 的离线实验，实验版本号 3，不可通过 worker 选择，也未写入线上预测表。见 [IMM 历史验证报告](../reports/trajectory-imm-validation-2026-10-15.md)。

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
- 观测与接收时差包含快照陈旧、传输延迟与时钟差，不能单独证明源时钟偏差。连接器、worker 和数据库均应校时；worker 的 `predicted_at` 使用 worker 本机时间，并非数据库时间。
- 平均观测至预测时差为 `predicted_at - base_observed_at`，包含位置陈旧和等待，不是算法耗时。新预测窗口与准确度匹配排除离线、缺失/非法位置时间与未来样本，重复物理观测不增加拟合权重。既有预测和评估不重建，未标记的旧错误时间不能由过滤器自动纠正。
