from datetime import datetime, timedelta, timezone
from math import cos, pi, radians

import pytest

from backend.risk_engine.domain import (
    ProtectedObjectInput,
    RingInput,
    RuleSet,
    TargetInput,
    TrajectoryPoint,
    assess_target,
    distance_m,
    select_ring,
)


@pytest.fixture
def protected_object():
    return ProtectedObjectInput(
        id=1, name="测试保护对象", longitude=119.25, latitude=34.65, version=3,
        rings=[
            RingInput(id=11, code="sensing", name="感知圈", ring_level=1, radius_m=5000, priority=100, version=3),
            RingInput(id=12, code="tracking", name="跟踪圈", ring_level=2, radius_m=4000, priority=200, version=3),
            RingInput(id=13, code="core", name="核心圈", ring_level=5, radius_m=1000, priority=500, version=3),
        ],
    )


def test_distance_is_zero_at_same_point():
    assert distance_m(119.25, 34.65, 119.25, 34.65) == pytest.approx(0)


def test_select_ring_prefers_priority_then_level(protected_object):
    target = TargetInput(track_id=1, observed_at=datetime.now(timezone.utc), longitude=119.25, latitude=34.65)
    ring, distance = select_ring(target, protected_object)
    assert ring.code == "core"
    assert distance == pytest.approx(0)


def test_assessment_keeps_configuration_versions(protected_object):
    target = TargetInput(track_id=1, observation_id=99, observed_at=datetime.now(timezone.utc), longitude=119.25, latitude=34.65)
    result = assess_target(target, [protected_object], RuleSet(7, {"zone_core": 85, "identity_unverified": 5}), datetime.now(timezone.utc))
    assert result.status == "assessed"
    assert result.ring_version == 3
    assert result.rule_version == 7
    assert result.risk_score == 90
    assert result.risk_level == "critical"


def test_missing_location_is_not_zero_risk(protected_object):
    target = TargetInput(track_id=1, observed_at=datetime.now(timezone.utc))
    result = assess_target(target, [protected_object], RuleSet(1, {}), datetime.now(timezone.utc))
    assert result.status == "target_location_unavailable"
    assert result.risk_score == 0


def test_outside_protected_objects_is_distinct(protected_object):
    target = TargetInput(track_id=1, observed_at=datetime.now(timezone.utc), longitude=120, latitude=35)
    result = assess_target(target, [protected_object], RuleSet(1, {}), datetime.now(timezone.utc))
    assert result.status == "outside_protected_objects"


def test_trajectory_scores_continuous_approach_and_exclusive_eta(protected_object):
    start = datetime(2026, 9, 25, 0, 0, tzinfo=timezone.utc)

    def longitude_at_east_distance(distance):
        return 119.25 + distance / (6_371_008.8 * cos(radians(34.65))) * 180 / pi

    points = [
        TrajectoryPoint(
            observation_id=index + 1, observed_at=start + timedelta(seconds=index * 4),
            longitude=longitude_at_east_distance(distance), latitude=34.65,
        )
        for index, distance in enumerate((3000, 2800, 2600, 2400))
    ]
    target = TargetInput(
        track_id=1, observation_id=4, observed_at=points[-1].observed_at,
        longitude=points[-1].longitude, latitude=points[-1].latitude, trajectory=points,
    )
    rules = RuleSet(
        version=2,
        scores={
            "zone_tracking": 35, "continuous_approach": 10, "fast_approach": 5,
            "next_ring_eta_60": 10, "next_ring_eta_30": 20, "identity_unverified": 5,
        },
        thresholds={
            "continuous_approach": 2, "fast_approach": 10,
            "next_ring_eta_60": 60, "next_ring_eta_30": 30,
        },
        parameters={"approach_window_seconds": 10, "approach_min_points": 4},
    )
    result = assess_target(target, [protected_object], rules, points[-1].observed_at)
    factors = {factor.code: factor for factor in result.factors}
    assert result.risk_score == 75
    assert result.risk_level == "high"
    assert factors["continuous_approach"].matched
    assert factors["fast_approach"].matched
    assert factors["next_ring_eta_30"].matched
    assert not factors["next_ring_eta_60"].matched
    assert factors["next_ring_eta_30"].value == pytest.approx(28, abs=1)


def test_trajectory_factors_remain_unavailable_without_enough_points(protected_object):
    observed_at = datetime(2026, 9, 25, tzinfo=timezone.utc)
    target = TargetInput(
        track_id=1, observation_id=1, observed_at=observed_at,
        longitude=119.27, latitude=34.65,
    )
    result = assess_target(
        target, [protected_object],
        RuleSet(1, {"zone_tracking": 35, "continuous_approach": 10}), observed_at,
    )
    factor = next(item for item in result.factors if item.code == "continuous_approach")
    assert not factor.available
    assert not factor.matched


def test_risk_levels_use_published_parameters(protected_object):
    observed_at = datetime(2026, 9, 25, tzinfo=timezone.utc)
    target = TargetInput(
        track_id=1, observed_at=observed_at, longitude=119.25, latitude=34.65,
    )
    result = assess_target(
        target, [protected_object],
        RuleSet(
            3, {"zone_core": 85, "identity_unverified": 5},
            parameters={"score_critical": 95, "score_high": 60},
        ),
        observed_at,
    )
    assert result.risk_score == 90
    assert result.risk_level == "high"
