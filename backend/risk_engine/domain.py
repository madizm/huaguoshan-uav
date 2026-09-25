"""Risk assessment domain models and deterministic evaluator."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from math import asin, cos, radians, sin, sqrt
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

RiskStatus = Literal["assessed", "outside_protected_objects", "target_location_unavailable", "pending", "failed"]
RiskLevel = Literal["none", "low", "medium", "high", "critical"]
EARTH_RADIUS_M = 6_371_008.8


class TrajectoryPoint(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)

    observation_id: int | None = None
    observed_at: datetime
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)


class TargetInput(BaseModel):
    model_config = ConfigDict(extra="forbid", alias_generator=to_camel, populate_by_name=True)

    track_id: int
    observation_id: int | None = None
    observed_at: datetime
    longitude: float | None = Field(default=None, ge=-180, le=180)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    speed_mps: float | None = Field(default=None, ge=0)
    identity_status: Literal["unverified", "identified", "conflicted"] = "unverified"
    weight_class: Literal["micro", "light", "small", "medium", "large"] | None = None
    trajectory: list[TrajectoryPoint] = Field(default_factory=list)


class RingInput(BaseModel):
    id: int
    code: str
    name: str
    ring_level: int
    radius_m: float
    priority: int
    version: int


class ProtectedObjectInput(BaseModel):
    id: int
    name: str
    longitude: float
    latitude: float
    version: int
    enabled: bool = True
    rings: list[RingInput]


class FactorResult(BaseModel):
    code: str
    score: int
    matched: bool
    available: bool = True
    value: float | None = None
    threshold: float | None = None


class RiskAssessment(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)
    status: RiskStatus
    risk_level: RiskLevel = "none"
    risk_score: int = 0
    track_id: int
    observation_id: int | None = None
    observed_at: datetime
    assessed_at: datetime
    protected_object_id: int | None = None
    protected_object_name: str | None = None
    protected_object_version: int | None = None
    ring_id: int | None = None
    ring_code: str | None = None
    ring_name: str | None = None
    ring_level: int | None = None
    distance_m: float | None = None
    ring_version: int | None = None
    rule_set_id: int | None = None
    rule_version: int | None = None
    factors: list[FactorResult] = Field(default_factory=list)
    reason: str | None = None


@dataclass(frozen=True)
class RuleSet:
    version: int
    scores: dict[str, int]
    id: int | None = None
    thresholds: dict[str, float | None] = field(default_factory=dict)
    parameters: dict[str, float] = field(default_factory=dict)


@dataclass(frozen=True)
class _TrajectoryState:
    available: bool
    closing_speed_mps: float | None = None
    velocity_x_mps: float | None = None
    velocity_y_mps: float | None = None
    heading_reliable: bool = False


def distance_m(longitude_a: float, latitude_a: float, longitude_b: float, latitude_b: float) -> float:
    """Return haversine distance in meters for WGS84 coordinates."""
    lat_a, lat_b = radians(latitude_a), radians(latitude_b)
    dlat = lat_b - lat_a
    dlon = radians(longitude_b - longitude_a)
    value = sin(dlat / 2) ** 2 + cos(lat_a) * cos(lat_b) * sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * asin(sqrt(min(1.0, value)))


def select_ring(target: TargetInput, protected_object: ProtectedObjectInput) -> tuple[RingInput, float] | None:
    if not protected_object.enabled or target.longitude is None or target.latitude is None:
        return None
    distance = distance_m(target.longitude, target.latitude, protected_object.longitude, protected_object.latitude)
    matches = [ring for ring in protected_object.rings if distance <= ring.radius_m]
    if not matches:
        return None
    ring = min(matches, key=lambda item: (-item.priority, -item.ring_level, item.id))
    return ring, distance


def _parameter(rules: RuleSet, code: str, default: float) -> float:
    return float(rules.parameters.get(code, default))


def _risk_level(score: int, rules: RuleSet) -> RiskLevel:
    if score >= _parameter(rules, "score_critical", 80):
        return "critical"
    if score >= _parameter(rules, "score_high", 60):
        return "high"
    if score >= _parameter(rules, "score_medium", 40):
        return "medium"
    if score >= _parameter(rules, "score_low", 20):
        return "low"
    return "none"


def _local_xy(longitude: float, latitude: float, center_longitude: float, center_latitude: float) -> tuple[float, float]:
    x = EARTH_RADIUS_M * radians(longitude - center_longitude) * cos(radians(center_latitude))
    y = EARTH_RADIUS_M * radians(latitude - center_latitude)
    return x, y


def _trajectory_state(target: TargetInput, protected_object: ProtectedObjectInput, rules: RuleSet) -> _TrajectoryState:
    if target.longitude is None or target.latitude is None:
        return _TrajectoryState(available=False)
    current = TrajectoryPoint(
        observation_id=target.observation_id, observed_at=target.observed_at,
        longitude=target.longitude, latitude=target.latitude,
    )
    keyed: dict[tuple[object, ...], TrajectoryPoint] = {}
    for point in [*target.trajectory, current]:
        key = ("id", point.observation_id) if point.observation_id is not None else (
            "point", point.observed_at, point.longitude, point.latitude,
        )
        keyed[key] = point
    window_seconds = _parameter(rules, "approach_window_seconds", 10)
    cutoff = target.observed_at - timedelta(seconds=window_seconds)
    ordered = sorted(
        (point for point in keyed.values() if point.observed_at <= target.observed_at),
        key=lambda point: (point.observed_at, point.observation_id or 0),
    )
    points = [point for point in ordered if point.observed_at >= cutoff]
    anchors = [point for point in ordered if point.observed_at < cutoff]
    if anchors:
        points.insert(0, anchors[-1])
    min_points = max(2, int(_parameter(rules, "approach_min_points", 4)))
    if len(points) < min_points:
        return _TrajectoryState(available=False)
    elapsed = (points[-1].observed_at - points[0].observed_at).total_seconds()
    if elapsed < window_seconds or elapsed <= 0:
        return _TrajectoryState(available=False)

    first_distance = distance_m(
        points[0].longitude, points[0].latitude, protected_object.longitude, protected_object.latitude,
    )
    last_distance = distance_m(
        points[-1].longitude, points[-1].latitude, protected_object.longitude, protected_object.latitude,
    )
    first_x, first_y = _local_xy(
        points[0].longitude, points[0].latitude, protected_object.longitude, protected_object.latitude,
    )
    last_x, last_y = _local_xy(
        points[-1].longitude, points[-1].latitude, protected_object.longitude, protected_object.latitude,
    )
    velocity_x = (last_x - first_x) / elapsed
    velocity_y = (last_y - first_y) / elapsed
    velocity_norm = sqrt(velocity_x * velocity_x + velocity_y * velocity_y)
    heading_reliable = velocity_norm > 0.1
    if heading_reliable:
        for previous, following in zip(points, points[1:]):
            segment_seconds = (following.observed_at - previous.observed_at).total_seconds()
            if segment_seconds <= 0:
                continue
            previous_x, previous_y = _local_xy(
                previous.longitude, previous.latitude, protected_object.longitude, protected_object.latitude,
            )
            following_x, following_y = _local_xy(
                following.longitude, following.latitude, protected_object.longitude, protected_object.latitude,
            )
            segment_x = (following_x - previous_x) / segment_seconds
            segment_y = (following_y - previous_y) / segment_seconds
            segment_norm = sqrt(segment_x * segment_x + segment_y * segment_y)
            if segment_norm > 0.1 and segment_x * velocity_x + segment_y * velocity_y <= 0:
                heading_reliable = False
                break
    return _TrajectoryState(
        available=True,
        closing_speed_mps=(first_distance - last_distance) / elapsed,
        velocity_x_mps=velocity_x,
        velocity_y_mps=velocity_y,
        heading_reliable=heading_reliable,
    )


def _next_ring_eta(
    target: TargetInput, protected_object: ProtectedObjectInput, selected_ring: RingInput, state: _TrajectoryState,
) -> float | None:
    if (
        target.longitude is None or target.latitude is None or not state.available or not state.heading_reliable
        or state.velocity_x_mps is None or state.velocity_y_mps is None
    ):
        return None
    deeper = [
        ring for ring in protected_object.rings
        if ring.ring_level > selected_ring.ring_level and ring.radius_m < selected_ring.radius_m
    ]
    if not deeper:
        return None
    next_ring = max(deeper, key=lambda ring: (ring.radius_m, -ring.ring_level, -ring.id))
    x, y = _local_xy(
        target.longitude, target.latitude, protected_object.longitude, protected_object.latitude,
    )
    vx, vy = state.velocity_x_mps, state.velocity_y_mps
    a = vx * vx + vy * vy
    b = 2 * (x * vx + y * vy)
    c = x * x + y * y - next_ring.radius_m * next_ring.radius_m
    discriminant = b * b - 4 * a * c
    if a <= 0 or c <= 0 or discriminant < 0:
        return None
    root = sqrt(discriminant)
    candidates = [value for value in ((-b - root) / (2 * a), (-b + root) / (2 * a)) if value >= 0]
    return min(candidates) if candidates else None


def assess_target(
    target: TargetInput,
    protected_objects: list[ProtectedObjectInput],
    rules: RuleSet,
    assessed_at: datetime,
) -> RiskAssessment:
    base = dict(
        track_id=target.track_id, observation_id=target.observation_id,
        observed_at=target.observed_at, assessed_at=assessed_at,
        rule_set_id=rules.id, rule_version=rules.version,
    )
    if target.longitude is None or target.latitude is None:
        return RiskAssessment(status="target_location_unavailable", reason="target_location_unavailable", **base)

    matches = [(obj, select_ring(target, obj)) for obj in protected_objects]
    matches = [(obj, match) for obj, match in matches if match is not None]
    if not matches:
        return RiskAssessment(status="outside_protected_objects", **base)

    obj, (ring, distance) = min(
        matches, key=lambda item: (-item[1][0].priority, -item[1][0].ring_level, item[1][0].id, item[0].id),
    )
    factors: list[FactorResult] = []
    zone_code = f"zone_{ring.code}"
    factors.append(FactorResult(
        code=zone_code, score=rules.scores.get(zone_code, 0), matched=True,
        value=float(ring.ring_level), threshold=rules.thresholds.get(zone_code),
    ))

    state = _trajectory_state(target, obj, rules)
    continuous_threshold = float(rules.thresholds.get("continuous_approach") or 2)
    continuous_matched = (
        state.available and state.closing_speed_mps is not None
        and state.closing_speed_mps >= continuous_threshold
    )
    factors.append(FactorResult(
        code="continuous_approach", score=rules.scores.get("continuous_approach", 0),
        matched=continuous_matched, available=state.available,
        value=None if state.closing_speed_mps is None else round(state.closing_speed_mps, 3),
        threshold=continuous_threshold,
    ))
    fast_threshold = float(rules.thresholds.get("fast_approach") or 10)
    factors.append(FactorResult(
        code="fast_approach", score=rules.scores.get("fast_approach", 0),
        matched=continuous_matched and state.closing_speed_mps is not None and state.closing_speed_mps >= fast_threshold,
        available=state.available,
        value=None if state.closing_speed_mps is None else round(state.closing_speed_mps, 3),
        threshold=fast_threshold,
    ))

    eta = _next_ring_eta(target, obj, ring, state)
    eta_factors: list[FactorResult] = []
    for code, default_threshold in (("next_ring_eta_60", 60), ("next_ring_eta_30", 30)):
        threshold = float(rules.thresholds.get(code) or default_threshold)
        eta_factors.append(FactorResult(
            code=code, score=rules.scores.get(code, 0), matched=eta is not None and eta <= threshold,
            available=eta is not None, value=None if eta is None else round(eta, 3), threshold=threshold,
        ))
    matched_eta = [factor for factor in eta_factors if factor.matched]
    if len(matched_eta) > 1:
        selected_eta = max(matched_eta, key=lambda factor: (factor.score, -(factor.threshold or 0)))
        for factor in eta_factors:
            factor.matched = factor is selected_eta
    factors.extend(eta_factors)

    factors.append(FactorResult(
        code="identity_unverified", score=rules.scores.get("identity_unverified", 0),
        matched=target.identity_status == "unverified",
    ))

    # Weight class factor
    if target.weight_class is not None:
        weight_factor_code = f"weight_class_{target.weight_class}"
        factors.append(FactorResult(
            code=weight_factor_code,
            score=rules.scores.get(weight_factor_code, 0),
            matched=True,
            available=True,
        ))
    else:
        # Weight class unknown - no factor contributed
        factors.append(FactorResult(
            code="weight_class_unknown",
            score=0,
            matched=False,
            available=False,
        ))

    score = min(100, sum(factor.score for factor in factors if factor.matched))
    return RiskAssessment(
        status="assessed", risk_level=_risk_level(score, rules), risk_score=score,
        protected_object_id=obj.id, protected_object_name=obj.name, protected_object_version=obj.version,
        ring_id=ring.id, ring_code=ring.code, ring_name=ring.name, ring_level=ring.ring_level,
        distance_m=round(distance, 3), ring_version=ring.version, factors=factors, **base,
    )
