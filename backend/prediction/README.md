# 轨迹预测与自适应时长

默认算法仍为最小二乘 + CV/CT/悬停规则选择。默认固定预测上限 120 秒，步长 5 秒，历史窗口 20 秒。预测仅用于展示，不参与风险研判或设备控制。

## 启用与回退

先在目标环境按既有迁移流程执行更新后的 `backend/create_trajectory_prediction.sql`。新增列 `horizon_policy` 使用幂等 `ADD COLUMN IF NOT EXISTS`，旧记录默认为 `{}`。**新 worker（即使固定模式）写入也依赖新列，须先更新 schema 再部署 worker。** 开发库已在用户授权后完成首版 schema 更新及回滚式写入验证；v2 不增加数据库字段，无需额外迁移。

配置 `DATABASE_URL` 后启动：

```bash
uv run python -m backend.prediction.worker \
  --adaptive-horizon \
  --horizon-seconds 120 --step-seconds 5 \
  --adaptive-max-uncertainty-m 250 \
  --adaptive-max-observation-age-seconds 30
```

阈值都是未校准的固定先验，不代表准确率或 95% 覆盖保证。先只读回放，再决定是否启用。删除 `--adaptive-horizon` 即回到固定模式，无须删除新列。卡尔曼估计器仍通过 `--estimator kalman_cv` 单独开启。

可显式使用 `--window-seconds 90` 做稀疏数据诊断。不会自动扩大历史窗口。扩大窗口会混入更早的运动状态，不能视为精度必然提升。默认 20 秒窗口凑不齐 3 个点时，自适应时长仍返回 `not_enough_points`。

## 策略规则 v2

入口 `domain.predict_trajectory` 先生成原算法的候选轨迹，再调用 `adaptive.apply_adaptive_horizon`。规则不改变候选位置、高度或模型选择，不跨批次保存状态。

1. 原始点数、跨度、速度检查失败时，保留原失败原因。
2. 观测年龄达到或超过 30 秒时，不输出未来预测。
3. 丢弃 ETA 小于或等于计算时观测年龄的候选点；ETA 不平移。
4. 按时间顺序检查候选点，首个越界点及后续点全部删除：
   - 仅显式配置 `--adaptive-max-turn-degrees` 时，累计转角超限才截断。默认无此硬限制。
   - 未截顶不确定半径超过 `max_uncertainty_m`：不确定半径超限。
   - `未截顶不确定半径 + 0.5 * a * ETA² > max_uncertainty_m`：运动不稳定。
5. 不强保最短预测时间。如果没有剩余点，质量为 `insufficient_data`，原因是 `no_reliable_future`。

`a` 改为窗口整体二次位置趋势中，超出测量噪声门槛的加速度幅值。不再用原始相邻段最大速度差，避免短间隔定位抖动被二次差分放大。

至少需要 5 个独立观测时刻。CT 先从历史位置中减去模型对应的圆弧运动。将 `t²` 对常数和 `t` 正交化后，分别拟合东西、南北加速度。时间布局退化时不宣称有趋势证据。

在独立、同方差、各向同性位置噪声假设下，单轴加速度标准差为 `2 * measurement_noise_std_m / sqrt(sum(z²))`，其中 z 是正交化的二次项。二维零趋势噪声门槛使用 `sqrt(-2*log(0.05))` 倍标准差。`a = max(拟合加速度幅值 - 噪声门槛, 0)`。默认测量标准差为 10 米，未在本次数据上调优。

这是持续趋势的**证据检测启发式**，不是加速度或未来误差的保守置信上界。少于 5 点、时间布局不足或趋势低于噪声门槛，不等于运动稳定；只表示本规则没有足够趋势证据。这些情况下仍应用半径与观测年龄限制，但可能放行更多预测，必须通过覆盖率检验。

指标新增 `motion_evidence`（`insufficient_samples`、`insufficient_time_geometry`、`below_noise_floor`、`supported_trend`）、独立点数、拟合加速度和噪声门槛。阈值元数据也保存检测所用的测量标准差、最少点数和噪声门槛概率。原 `unexplained_acceleration_mps2` 在 v2 中表示扣除噪声门槛后的值；其语义必须结合 `rule_version` 解读。

默认半径按基础值、残差和时间增长项重算，不采用显示用的 2000 米截顶。卡尔曼 CV 使用原协方差半径；卡尔曼 CT 和悬停仍使用启发式半径。运动误差预算仅控制截断，不修改预测点中的 `uncertainty_m`。这不是统计置信度检验，也没有实现异常点门限。

## 返回与存储

保留 `horizon_seconds` 的原含义：配置上限，必须大于零。它不是自适应实际时长。固定模式新增 `horizon_policy={}`，自适应模式示例：

```json
{
  "mode": "adaptive",
  "rule_version": 2,
  "actual_horizon_seconds": 45,
  "remaining_horizon_seconds": 33,
  "stop_reason": "uncertainty_limit",
  "thresholds": {
    "max_uncertainty_m": 250,
    "max_observation_age_seconds": 30,
    "max_turn_degrees": null,
    "motion_min_samples": 5,
    "motion_measurement_noise_std_m": 10,
    "motion_noise_gate_probability": 0.95
  },
  "metrics": {
    "observation_age_seconds": 12,
    "unexplained_acceleration_mps2": 0,
    "motion_sample_count": 5,
    "motion_evidence": "below_noise_floor",
    "fitted_acceleration_mps2": 0,
    "acceleration_noise_floor_mps2": 0.5
  }
}
```

以上仅为结构示例。`actual_horizon_seconds` 是末个输出点相对最新观测的 ETA，无点时为 0。`remaining_horizon_seconds` 是计算时的剩余秒数，前端须随时钟继续扣减，不能当作实时剩余时间直接显示。

截断原因：`configured_horizon`、`stale_observation`、`no_future_points`、`uncertainty_limit`、`motion_instability`、`turn_angle_limit`；输入失败时保留原原因，例如 `not_enough_points`。

实时 RPC 的 `predictions` 和 `states`、管理端列表及历史预测 RPC 均返回元数据。大屏摘要显示实际末点 ETA，并在详情及选中状态显示截断原因。质量枚举和算法估计器版本不变，策略由 `rule_version` 单独标识。

## 只读回放

```bash
uv run python -m backend.prediction.replay \
  --hours 24 --adaptive-horizon \
  --adaptive-max-uncertainty-m 250 \
  --output /tmp/prediction-adaptive-replay.json
```

`horizon_stops` 汇总截断原因；`actual_horizons` 汇总所有预测起点的实际时长，失败起点计 0。回放仅在保留的检查点上计算误差。**缩短预测会改变评估样本集合，不能仅用误差均值降低证明效果改善。** 验收时应同时检查有效预测比例、各检查点样本覆盖、截断原因和剩余时长。

当前不对离线 IMM 应用此策略；`--include-imm --adaptive-horizon` 会被拒绝。

## 与首版比较

首版已保存在提交 `bd9aee1`。可只读比较两版与固定时长：

```bash
uv run python -m scripts.prediction.compare_adaptive_horizons \
  --hours 24 --window-seconds 20 --horizon-seconds 90 \
  --output /tmp/adaptive-comparison.json
```

工具从本地 Git 提交读取可信的首版代码。不要将 `--legacy-ref` 指向未经审查的代码。所有数据库连接由 `fetch_observations` 强制只读，不运行 worker，不保存原始坐标。

2026-10-17 的诊断报告见 `docs/reports/trajectory-adaptive-v2-validation-2026-10-17.md`。短时截断明显减少，但 CT 和悬停的半径覆盖仍不足，**不能据此声称长时预测可靠或直接完成线上验收**。修订代码尚未部署。

## 本地验证

```bash
uv run pytest backend/prediction/tests tests/test_trajectory_prediction_schema.py tests/test_trajectory_prediction_adapter.py -q
node tests/test_trajectory_prediction_module.js
node tests/test_prediction_timeline.js
```

测试覆盖固定模式回归、LS/卡尔曼截断、陈旧与延迟观测、显式转角限制、运动变化、悬停、空结果、未截顶边界、未来点过滤、不规则采样、短间隔噪声、参数检查、CLI、回放、存储绑定和 RPC schema。开发库 SQL 已验证，真实历史只读诊断已执行；独立数据覆盖校准与部署验收尚未完成。
