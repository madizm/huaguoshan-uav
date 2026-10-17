"""Trajectory prediction domain models and deterministic short-term extrapolator.

纯函数模块：输入一段观测窗口，输出恒定速度（CV）/恒定转向（CT）/悬停（hover）
三种模型之一的短期预测点序列。所有常数集中在 PredictionConfig，保证结果可解释、可复现。
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from math import atan2, cos, degrees, hypot, isfinite, pi, radians, sin, sqrt
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .kalman import replay_cv, validate_noise

EARTH_RADIUS_M = 6_371_008.8
MODEL_VERSION = 1

SubjectKind = Literal["airspace_target", "aircraft_asset"]
ModelCode = Literal["cv", "ct", "hover"]
PredictionQuality = Literal["ok", "insufficient_data"]


class ObservationPoint(BaseModel):
    """参与预测拟合的单个历史观测点。"""

    model_config = ConfigDict(extra="forbid")

    observation_id: int | None = None
    observed_at: datetime
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)
    height_amsl_m: float | None = None


@dataclass(frozen=True)
class PredictionConfig:
    """预测算法参数；默认值面向 1~5 秒采样、速度 0~40 m/s 的低空目标。"""

    window_seconds: float = 20
    min_points: int = 3
    min_window_span_seconds: float = 4
    hover_speed_mps: float = 1.0
    max_speed_mps: float = 120
    horizon_seconds: int = 120
    step_seconds: int = 5
    ct_min_turn_rate_dps: float = 3.0
    ct_max_turn_rate_dps: float = 30.0
    ct_min_heading_samples: int = 2
    ct_min_sign_agreement: float = 0.7
    max_vertical_speed_mps: float = 15.0
    uncertainty_base_m: float = 10.0
    uncertainty_per_residual_m: float = 2.0
    uncertainty_ratio: float = 0.25
    uncertainty_growth_speed_mps: float = 2.0
    uncertainty_max_m: float = 2000.0
    estimator: Literal["least_squares", "kalman_cv"] = "least_squares"
    measurement_noise_std_m: float = 10.0
    acceleration_noise_density_m2_s3: float = 1.0
    adaptive_horizon: bool = False
    adaptive_max_uncertainty_m: float = 250.0
    adaptive_max_observation_age_seconds: float = 30.0
    adaptive_max_turn_degrees: float | None = None

    def __post_init__(self) -> None:
        for name in ("horizon_seconds", "step_seconds"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise ValueError(f"{name} must be a positive integer")
        if self.step_seconds > self.horizon_seconds:
            raise ValueError("step_seconds must not exceed horizon_seconds")
        if not isfinite(self.window_seconds) or self.window_seconds <= 0:
            raise ValueError("window_seconds must be finite and > 0")
        for name in ("adaptive_max_uncertainty_m", "adaptive_max_observation_age_seconds"):
            value = getattr(self, name)
            if not isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and > 0")
        if self.adaptive_max_turn_degrees is not None and (
            not isfinite(self.adaptive_max_turn_degrees) or self.adaptive_max_turn_degrees <= 0
        ):
            raise ValueError("adaptive_max_turn_degrees must be None or finite and > 0")
        if self.estimator not in ("least_squares", "kalman_cv"):
            raise ValueError("estimator must be least_squares or kalman_cv")
        validate_noise(self.measurement_noise_std_m, self.acceleration_noise_density_m2_s3)


class PredictedPoint(BaseModel):
    """单个预测点；eta_seconds 从预测基准时刻起算。"""

    model_config = ConfigDict(extra="forbid")

    eta_seconds: float = Field(ge=0)
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)
    height_amsl_m: float | None = None
    uncertainty_m: float = Field(ge=0)


class Prediction(BaseModel):
    """一次轨迹预测结果；quality 为 insufficient_data 时 points 为空。"""

    model_config = ConfigDict(extra="forbid")

    subject_kind: SubjectKind
    subject_id: int
    base_observed_at: datetime
    predicted_at: datetime
    model_code: ModelCode
    model_version: int = MODEL_VERSION
    quality: PredictionQuality
    reason: str | None = None
    horizon_seconds: int
    step_seconds: int
    speed_mps: float | None = None
    heading_deg: float | None = None
    turn_rate_dps: float | None = None
    window_seconds: int
    window_point_count: int = 0
    fit_residual_m: float | None = None
    points: list[PredictedPoint] = Field(default_factory=list)
    horizon_policy: dict = Field(default_factory=dict)


def _local_xy(longitude: float, latitude: float, origin_longitude: float, origin_latitude: float) -> tuple[float, float]:
    """以原点为中心的局部切平面等距圆柱投影，返回东向、北向米数。"""
    x = EARTH_RADIUS_M * radians(longitude - origin_longitude) * cos(radians(origin_latitude))
    y = EARTH_RADIUS_M * radians(latitude - origin_latitude)
    return x, y


def _lon_lat(x: float, y: float, origin_longitude: float, origin_latitude: float) -> tuple[float, float]:
    """_local_xy 的反变换。"""
    latitude = origin_latitude + degrees(y / EARTH_RADIUS_M)
    denominator = EARTH_RADIUS_M * cos(radians(origin_latitude))
    longitude = origin_longitude if abs(denominator) < 1e-9 else origin_longitude + degrees(x / denominator)
    return max(-180.0, min(180.0, longitude)), max(-90.0, min(90.0, latitude))


def _heading_deg(velocity_east: float, velocity_north: float) -> float:
    """由东向、北向速度求真北顺时针航向角（度）。"""
    return (degrees(atan2(velocity_east, velocity_north)) + 360.0) % 360.0


def prepare_window(points: list[ObservationPoint], config: PredictionConfig) -> list[ObservationPoint]:
    """去重、排序并截取最近 window_seconds 的窗口；返回按时间升序的点列。"""
    if config.estimator == "kalman_cv":
        # One measurement per instant. Highest intake ID wins; coordinate/height
        # tie-breakers also make missing/equal IDs independent of input order.
        def winner_key(point: ObservationPoint) -> tuple:
            return (
                point.observation_id is not None, point.observation_id or 0,
                point.longitude, point.latitude,
                point.height_amsl_m is not None, point.height_amsl_m or 0.0,
            )

        by_time: dict[datetime, ObservationPoint] = {}
        for point in points:
            previous = by_time.get(point.observed_at)
            if previous is None or winner_key(point) > winner_key(previous):
                by_time[point.observed_at] = point
        ordered = sorted(by_time.values(), key=lambda point: point.observed_at)
        if not ordered:
            return []
        cutoff = ordered[-1].observed_at - timedelta(seconds=config.window_seconds)
        return [point for point in ordered if point.observed_at >= cutoff]
    keyed: dict[tuple[object, ...], ObservationPoint] = {}
    for point in points:
        # New intake IDs do not make a repeated physical measurement independent.
        key = (point.observed_at, point.longitude, point.latitude, point.height_amsl_m)
        keyed[key] = point
    ordered = sorted(keyed.values(), key=lambda point: (point.observed_at, point.observation_id or 0))
    if not ordered:
        return []
    cutoff = ordered[-1].observed_at - timedelta(seconds=config.window_seconds)
    return [point for point in ordered if point.observed_at >= cutoff]


def _least_squares(times: list[float], values: list[float]) -> tuple[float, float, float]:
    """一元最小二乘拟合，返回 (t=0 处取值, 斜率, 残差均方根)。times 相对基准时刻。"""
    count = len(times)
    mean_t = sum(times) / count
    mean_v = sum(values) / count
    variance_t = sum((t - mean_t) ** 2 for t in times)
    if variance_t <= 0:
        return mean_v, 0.0, 0.0
    covariance = sum((t - mean_t) * (v - mean_v) for t, v in zip(times, values))
    slope = covariance / variance_t
    intercept = mean_v - slope * mean_t
    residual = sqrt(sum((v - (intercept + slope * t)) ** 2 for t, v in zip(times, values)) / count)
    return intercept, slope, residual


@dataclass(frozen=True)
class _WindowFit:
    base_east: float
    base_north: float
    velocity_east: float
    velocity_north: float
    vertical_speed_mps: float | None
    base_height_amsl_m: float | None
    residual_m: float
    speed_mps: float
    heading_deg: float | None


def _fit_window(window: list[ObservationPoint], config: PredictionConfig) -> _WindowFit:
    """在局部切平面上对窗口点做二维线性拟合，并单独拟合高度。"""
    base = window[-1]
    origin_lon, origin_lat = base.longitude, base.latitude
    times = [(point.observed_at - base.observed_at).total_seconds() for point in window]
    easts, norths = [], []
    for point in window:
        east, north = _local_xy(point.longitude, point.latitude, origin_lon, origin_lat)
        easts.append(east)
        norths.append(north)
    base_east, velocity_east, residual_east = _least_squares(times, easts)
    base_north, velocity_north, residual_north = _least_squares(times, norths)
    residual_m = hypot(residual_east, residual_north)
    speed = hypot(velocity_east, velocity_north)
    heading = _heading_deg(velocity_east, velocity_north) if speed > 0.1 else None

    heights = [(t, point.height_amsl_m) for t, point in zip(times, window) if point.height_amsl_m is not None]
    base_height, vertical_speed = None, None
    if len(heights) >= 2:
        base_height, raw_vertical_speed, _ = _least_squares([h[0] for h in heights], [h[1] for h in heights])
        vertical_speed = max(-config.max_vertical_speed_mps, min(config.max_vertical_speed_mps, raw_vertical_speed))
    elif len(heights) == 1:
        base_height = heights[0][1]
        vertical_speed = 0.0
    return _WindowFit(
        base_east=base_east, base_north=base_north,
        velocity_east=velocity_east, velocity_north=velocity_north,
        vertical_speed_mps=vertical_speed, base_height_amsl_m=base_height,
        residual_m=residual_m, speed_mps=speed, heading_deg=heading,
    )


def _estimate_turn_rate_dps(window: list[ObservationPoint], config: PredictionConfig) -> float | None:
    """由相邻观测段的航向变化估计转向率；样本不足或方向不一致时返回 None。"""
    headings: list[tuple[float, float]] = []
    base = window[-1]
    for previous, following in zip(window, window[1:]):
        elapsed = (following.observed_at - previous.observed_at).total_seconds()
        if elapsed <= 0.5:
            continue
        prev_east, prev_north = _local_xy(previous.longitude, previous.latitude, base.longitude, base.latitude)
        next_east, next_north = _local_xy(following.longitude, following.latitude, base.longitude, base.latitude)
        segment_length = hypot(next_east - prev_east, next_north - prev_north)
        if segment_length < 2.0:
            continue
        mid_time = (previous.observed_at + (following.observed_at - previous.observed_at) / 2 - base.observed_at).total_seconds()
        headings.append((mid_time, atan2(next_east - prev_east, next_north - prev_north)))
    rates: list[float] = []
    for (time_a, heading_a), (time_b, heading_b) in zip(headings, headings[1:]):
        elapsed = time_b - time_a
        if elapsed <= 0:
            continue
        delta = (heading_b - heading_a + pi) % (2 * pi) - pi
        rates.append(degrees(delta) / elapsed)
    if len(rates) < config.ct_min_heading_samples:
        return None
    mean_rate = sum(rates) / len(rates)
    if abs(mean_rate) < config.ct_min_turn_rate_dps:
        return None
    agreement = sum(1 for rate in rates if rate * mean_rate > 0) / len(rates)
    if agreement < config.ct_min_sign_agreement:
        return None
    return max(-config.ct_max_turn_rate_dps, min(config.ct_max_turn_rate_dps, mean_rate))


def _uncertainty_m(speed_mps: float, residual_m: float, eta_seconds: float, config: PredictionConfig) -> float:
    """水平不确定半径：基础值 + 拟合残差项 + 随时间线性增长的速度比例项。"""
    growth_speed = max(speed_mps, config.uncertainty_growth_speed_mps)
    value = (
        config.uncertainty_base_m
        + config.uncertainty_per_residual_m * residual_m
        + growth_speed * eta_seconds * config.uncertainty_ratio
    )
    return round(min(config.uncertainty_max_m, value), 1)


@dataclass(frozen=True)
class _SegmentState:
    """末段观测的弦速度、弦航向与时长，用于恒定转向模型的瞬时状态估计。"""
    speed_mps: float
    chord_heading_rad: float
    elapsed_seconds: float


def _last_segment(window: list[ObservationPoint]) -> _SegmentState | None:
    base = window[-1]
    for previous in reversed(window[:-1]):
        elapsed = (base.observed_at - previous.observed_at).total_seconds()
        if elapsed <= 0:
            continue
        prev_east, prev_north = _local_xy(previous.longitude, previous.latitude, base.longitude, base.latitude)
        segment_length = hypot(prev_east, prev_north)
        if segment_length < 1e-6:
            continue
        return _SegmentState(
            speed_mps=segment_length / elapsed,
            chord_heading_rad=atan2(-prev_east, -prev_north),
            elapsed_seconds=elapsed,
        )
    return None


def _mean_segment_speed(window: list[ObservationPoint], omega_rad_per_s: float) -> float | None:
    """各相邻观测段弦速度修正为切向速率后的平均；修正因子 x/sin(x)，x 为半段转向角。"""
    speeds: list[float] = []
    base = window[-1]
    for previous, following in zip(window, window[1:]):
        elapsed = (following.observed_at - previous.observed_at).total_seconds()
        if elapsed <= 0:
            continue
        prev_east, prev_north = _local_xy(previous.longitude, previous.latitude, base.longitude, base.latitude)
        next_east, next_north = _local_xy(following.longitude, following.latitude, base.longitude, base.latitude)
        chord_speed = hypot(next_east - prev_east, next_north - prev_north) / elapsed
        half_turn = abs(omega_rad_per_s) * elapsed / 2
        if half_turn >= 1.0:
            continue
        correction = half_turn / sin(half_turn) if half_turn > 1e-9 else 1.0
        speeds.append(chord_speed * correction)
    return None if not speeds else sum(speeds) / len(speeds)


def _predict_trajectory(
    subject_kind: SubjectKind,
    subject_id: int,
    points: list[ObservationPoint],
    predicted_at: datetime,
    config: PredictionConfig | None = None,
) -> Prediction:
    """对单个对象的一段观测窗口做短期外推；数据不足时返回空预测并注明原因。"""
    config = config or PredictionConfig()
    model_version = 2 if config.estimator == "kalman_cv" else MODEL_VERSION
    window = prepare_window([point for point in points if point.observed_at <= predicted_at], config)

    def insufficient(reason: str) -> Prediction:
        return Prediction(
            subject_kind=subject_kind, subject_id=subject_id,
            base_observed_at=window[-1].observed_at if window else predicted_at,
            predicted_at=predicted_at, model_code="cv", model_version=model_version, quality="insufficient_data",
            reason=reason, horizon_seconds=config.horizon_seconds, step_seconds=config.step_seconds,
            window_seconds=int(config.window_seconds), window_point_count=len(window),
        )

    if len(window) < config.min_points:
        return insufficient("not_enough_points")
    base = window[-1]
    span = (base.observed_at - window[0].observed_at).total_seconds()
    if span < config.min_window_span_seconds:
        return insufficient("window_span_too_short")

    fit = _fit_window(window, config)
    if fit.speed_mps > config.max_speed_mps:
        return insufficient("unrealistic_speed")

    # Keep the existing CT selector and instantaneous CT fit. Only non-CT
    # horizontal state is replaced; height and fit_residual_m remain LS values.
    turn_rate = None
    speed = fit.speed_mps
    heading_rad = radians(fit.heading_deg or 0.0)
    if fit.speed_mps >= config.hover_speed_mps and fit.heading_deg is not None:
        turn_rate = _estimate_turn_rate_dps(window, config)
        if turn_rate is not None:
            segment = _last_segment(window)
            segment_speed = _mean_segment_speed(window, radians(turn_rate))
            if segment is not None and segment_speed is not None:
                if segment_speed > config.max_speed_mps:
                    return insufficient("unrealistic_speed")
                speed = segment_speed
                heading_rad = segment.chord_heading_rad + radians(turn_rate) * (segment.elapsed_seconds / 2)
            else:
                turn_rate = None

    kalman_state = None
    if config.estimator == "kalman_cv" and turn_rate is None:
        samples = [
            ((point.observed_at - window[0].observed_at).total_seconds(),
             *_local_xy(point.longitude, point.latitude, base.longitude, base.latitude))
            for point in window
        ]
        kalman_state = replay_cv(samples, config.measurement_noise_std_m, config.acceleration_noise_density_m2_s3)
        east, north = kalman_state.east, kalman_state.north
        speed = hypot(east.velocity, north.velocity)
        if speed > config.max_speed_mps:
            return insufficient("unrealistic_speed")
        fit = replace(
            fit, base_east=east.position, base_north=north.position,
            velocity_east=east.velocity, velocity_north=north.velocity,
            speed_mps=speed, heading_deg=_heading_deg(east.velocity, north.velocity) if speed > 0.1 else None,
        )
        heading_rad = radians(fit.heading_deg or 0.0)

    common = dict(
        subject_kind=subject_kind, subject_id=subject_id,
        base_observed_at=base.observed_at, predicted_at=predicted_at, model_version=model_version,
        quality="ok", horizon_seconds=config.horizon_seconds, step_seconds=config.step_seconds,
        speed_mps=round(fit.speed_mps, 2), window_seconds=int(config.window_seconds),
        window_point_count=len(window), fit_residual_m=round(fit.residual_m, 2),
    )

    steps = [t for t in range(config.step_seconds, config.horizon_seconds + 1, config.step_seconds)]

    if fit.speed_mps < config.hover_speed_mps or fit.heading_deg is None:
        hover_lon, hover_lat = (
            _lon_lat(fit.base_east, fit.base_north, base.longitude, base.latitude)
            if kalman_state is not None else (base.longitude, base.latitude)
        )
        points_out = [
            PredictedPoint(
                eta_seconds=float(eta), longitude=hover_lon, latitude=hover_lat,
                height_amsl_m=None if fit.base_height_amsl_m is None else round(fit.base_height_amsl_m, 1),
                uncertainty_m=_uncertainty_m(fit.speed_mps, fit.residual_m, eta, config),
            )
            for eta in steps
        ]
        return Prediction(model_code="hover", **common, points=points_out)

    origin_lon, origin_lat = base.longitude, base.latitude
    model_code: ModelCode = "ct" if turn_rate is not None else "cv"
    alpha0 = pi / 2 - heading_rad
    omega = radians(turn_rate) if turn_rate is not None else 0.0
    common["speed_mps"] = round(speed, 2)

    points_out = []
    for eta in steps:
        if model_code == "ct" and abs(omega) > 1e-9:
            east = (speed / omega) * (sin(alpha0) - sin(alpha0 - omega * eta))
            north = (speed / omega) * (cos(alpha0 - omega * eta) - cos(alpha0))
        else:
            east = fit.base_east + fit.velocity_east * eta
            north = fit.base_north + fit.velocity_north * eta
        longitude, latitude = _lon_lat(east, north, origin_lon, origin_lat)
        height = None
        if fit.base_height_amsl_m is not None and fit.vertical_speed_mps is not None:
            height = round(fit.base_height_amsl_m + fit.vertical_speed_mps * eta, 1)
        points_out.append(PredictedPoint(
            eta_seconds=float(eta), longitude=round(longitude, 7), latitude=round(latitude, 7),
            height_amsl_m=height,
            uncertainty_m=(kalman_state.radius_95_m(eta) if kalman_state is not None
                           else _uncertainty_m(speed, fit.residual_m, eta, config)),
        ))
    heading_deg = degrees(heading_rad) % 360.0
    return Prediction(
        model_code=model_code, heading_deg=round(heading_deg, 1),
        turn_rate_dps=None if turn_rate is None else round(turn_rate, 2),
        **common, points=points_out,
    )


def predict_trajectory(
    subject_kind: SubjectKind,
    subject_id: int,
    points: list[ObservationPoint],
    predicted_at: datetime,
    config: PredictionConfig | None = None,
) -> Prediction:
    """生成候选轨迹；可选可信边界截断，ETA 始终相对最新观测。"""
    config = config or PredictionConfig()
    prediction = _predict_trajectory(subject_kind, subject_id, points, predicted_at, config)
    if not config.adaptive_horizon:
        return prediction
    from .adaptive import apply_adaptive_horizon

    window = prepare_window([p for p in points if p.observed_at <= predicted_at], config)
    return apply_adaptive_horizon(prediction, window, config)
