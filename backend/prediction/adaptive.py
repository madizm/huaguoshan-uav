"""可选的展示可信边界：有限窗口运动稳定性与未截顶半径共同限制外推。

规则阈值是固定先验，不是校准后的准确率保证。不改变候选模型或历史窗口。
"""
from __future__ import annotations

from dataclasses import replace

from math import cos, hypot, log, pi, radians, sin, sqrt

from .domain import ObservationPoint, Prediction, PredictionConfig, _least_squares, _local_xy, prepare_window


def _motion_metrics(window: list[ObservationPoint], prediction: Prediction, config: PredictionConfig) -> dict:
    """用整个窗口的二次位置趋势检测持续偏离，而非放大单段差分。

    将 t² 对常数与 t 正交化，避免对极短段求导。CT 先减去模型圆弧。
    从加速度幅值扣除测量噪声模型下的二维 95% 零趋势噪声门槛。
    这是“是否有趋势证据”的启发式检测，不是未来误差的置信上界。
    少于 5 个独立时刻不宣称具有加速度证据；仍检查半径和观测年龄。
    """
    # Repeated timestamp measurements are not independent evidence for a trend.
    window = prepare_window(window, replace(config, estimator="kalman_cv"))
    metrics = {
        "motion_evidence": "insufficient_samples",
        "motion_sample_count": len({p.observed_at for p in window}),
        "unexplained_acceleration_mps2": 0.0,
        "fitted_acceleration_mps2": None,
        "acceleration_noise_floor_mps2": None,
    }
    if metrics["motion_sample_count"] < 5 or prediction.quality != "ok":
        return metrics
    origin = window[-1]
    times = [(p.observed_at - origin.observed_at).total_seconds() for p in window]
    squares = [t*t for t in times]
    intercept, slope, _ = _least_squares(times, squares)
    quadratic_basis = [square - intercept - slope*t for t, square in zip(times, squares)]
    information = sum(z*z for z in quadratic_basis)
    if information < 1e-9:
        metrics["motion_evidence"] = "insufficient_time_geometry"
        return metrics

    values = []
    omega = radians(prediction.turn_rate_dps or 0.0)
    alpha = pi/2 - radians(prediction.heading_deg or 0.0)
    for point, t in zip(window, times):
        east, north = _local_xy(point.longitude, point.latitude, origin.longitude, origin.latitude)
        if prediction.model_code == "ct" and abs(omega) > 1e-9:
            speed = prediction.speed_mps or 0.0
            east -= speed/omega * (sin(alpha) - sin(alpha - omega*t))
            north -= speed/omega * (cos(alpha - omega*t) - cos(alpha))
        values.append((east, north))
    ae = 2 * sum(z*value[0] for z, value in zip(quadratic_basis, values)) / information
    an = 2 * sum(z*value[1] for z, value in zip(quadratic_basis, values)) / information
    fitted = hypot(ae, an)
    noise_floor = sqrt(-2*log(0.05)) * 2*config.measurement_noise_std_m / sqrt(information)
    effective = max(0.0, fitted - noise_floor)
    metrics.update(
        motion_evidence="supported_trend" if effective > 0 else "below_noise_floor",
        unexplained_acceleration_mps2=effective,
        fitted_acceleration_mps2=fitted,
        acceleration_noise_floor_mps2=noise_floor,
    )
    return metrics


def apply_adaptive_horizon(
    prediction: Prediction, window: list[ObservationPoint], config: PredictionConfig,
) -> Prediction:
    """截断首个越界点及后续点；不强保最短时长，不输出已经过去的点。

    horizon_seconds 仍为配置上限。实际末点 ETA 和距计算时刻剩余时长写入元数据。
    运动误差预算为 0.5*a*t²，与未截顶水平半径相加后比较阈值。
    """
    age = max(0.0, (prediction.predicted_at - prediction.base_observed_at).total_seconds())
    motion = _motion_metrics(window, prediction, config)
    acceleration = motion["unexplained_acceleration_mps2"]
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
                if (config.adaptive_max_turn_degrees is not None
                        and abs(prediction.turn_rate_dps or 0.0) * eta > config.adaptive_max_turn_degrees):
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
        "mode": "adaptive", "rule_version": 2,
        "actual_horizon_seconds": actual,
        "remaining_horizon_seconds": max(0.0, actual - age),
        "stop_reason": reason,
        "thresholds": {
            "max_uncertainty_m": config.adaptive_max_uncertainty_m,
            "max_observation_age_seconds": config.adaptive_max_observation_age_seconds,
            "max_turn_degrees": config.adaptive_max_turn_degrees,
            "motion_min_samples": 5,
            "motion_measurement_noise_std_m": config.measurement_noise_std_m,
            "motion_noise_gate_probability": 0.95,
        },
        "metrics": {"observation_age_seconds": age, **motion},
    }
    updates = {"points": kept, "horizon_policy": policy}
    if prediction.quality == "ok" and not kept:
        updates.update(quality="insufficient_data", reason="no_reliable_future")
    return prediction.model_copy(update=updates)
