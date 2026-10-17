"""可选的展示可信边界：有限窗口运动稳定性与未截顶半径共同限制外推。

规则阈值是固定先验，不是校准后的准确率保证。不改变候选模型或历史窗口。
"""
from __future__ import annotations

from math import cos, hypot, radians, sin

from .domain import ObservationPoint, Prediction, PredictionConfig, _local_xy


def _unexplained_acceleration(window: list[ObservationPoint], turn_rate_dps: float) -> float:
    """相邻段速度变化扣除模型转向后的最大加速度，单位 m/s²。

    使用段中点时间；CT 将前段速度按已识别转向旋转后再比较。
    不忽略不稳定段，也不将短间隔噪声当作可信的稳定运动。
    """
    segments = []
    if not window:
        return 0.0
    origin = window[-1]
    for a, b in zip(window, window[1:]):
        dt = (b.observed_at - a.observed_at).total_seconds()
        if dt <= 0:
            continue
        ae, an = _local_xy(a.longitude, a.latitude, origin.longitude, origin.latitude)
        be, bn = _local_xy(b.longitude, b.latitude, origin.longitude, origin.latitude)
        east, north = be - ae, bn - an
        midpoint = (a.observed_at - origin.observed_at).total_seconds() + dt / 2
        segments.append((midpoint, east / dt, north / dt))
    acceleration = 0.0
    for a, b in zip(segments, segments[1:]):
        dt = b[0] - a[0]
        angle = radians(turn_rate_dps) * dt
        east = a[1] * cos(angle) + a[2] * sin(angle)
        north = -a[1] * sin(angle) + a[2] * cos(angle)
        acceleration = max(acceleration, hypot(b[1] - east, b[2] - north) / dt)
    return acceleration


def apply_adaptive_horizon(
    prediction: Prediction, window: list[ObservationPoint], config: PredictionConfig,
) -> Prediction:
    """截断首个越界点及后续点；不强保最短时长，不输出已经过去的点。

    horizon_seconds 仍为配置上限。实际末点 ETA 和距计算时刻剩余时长写入元数据。
    运动误差预算为 0.5*a*t²，与未截顶水平半径相加后比较阈值。
    """
    age = max(0.0, (prediction.predicted_at - prediction.base_observed_at).total_seconds())
    acceleration = _unexplained_acceleration(window, prediction.turn_rate_dps or 0.0)
    reason = prediction.reason if prediction.quality != "ok" else "configured_horizon"
    kept = []
    uses_covariance = config.estimator == "kalman_cv" and prediction.model_code == "cv"
    if prediction.quality == "ok":
        if age >= config.adaptive_max_observation_age_seconds:
            reason = "stale_observation"
        else:
            for point in prediction.points:
                eta = point.eta_seconds
                # Already elapsed points must not be presented as future predictions.
                if eta <= age:
                    continue
                if abs(prediction.turn_rate_dps or 0.0) * eta > config.adaptive_max_turn_degrees:
                    reason = "turn_angle_limit"
                    break
                # Reconstruct the UNCLIPPED heuristic: the display cap must never
                # make a long forecast appear to satisfy the adaptive threshold.
                radius = point.uncertainty_m if uses_covariance else (
                    config.uncertainty_base_m
                    + config.uncertainty_per_residual_m * (prediction.fit_residual_m or 0.0)
                    + max(prediction.speed_mps or 0.0, config.uncertainty_growth_speed_mps)
                    * eta * config.uncertainty_ratio
                )
                if radius > config.adaptive_max_uncertainty_m:
                    reason = "uncertainty_limit"
                    break
                if radius + 0.5 * acceleration * eta**2 > config.adaptive_max_uncertainty_m:
                    reason = "motion_instability"
                    break
                kept.append(point)
            if not kept and reason == "configured_horizon":
                reason = "no_future_points"
    actual = kept[-1].eta_seconds if kept else 0.0
    policy = {
        "mode": "adaptive", "rule_version": 1,
        "actual_horizon_seconds": actual,
        "remaining_horizon_seconds": max(0.0, actual - age),
        "stop_reason": reason,
        "thresholds": {
            "max_uncertainty_m": config.adaptive_max_uncertainty_m,
            "max_observation_age_seconds": config.adaptive_max_observation_age_seconds,
            "max_turn_degrees": config.adaptive_max_turn_degrees,
        },
        "metrics": {"observation_age_seconds": age, "unexplained_acceleration_mps2": acceleration},
    }
    updates = {"points": kept, "horizon_policy": policy}
    if prediction.quality == "ok" and not kept:
        updates.update(quality="insufficient_data", reason="no_reliable_future")
    return prediction.model_copy(update=updates)
