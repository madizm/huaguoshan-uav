from dataclasses import replace
from datetime import timedelta
from math import cos, radians, sin

import pytest

from backend.prediction.domain import PredictionConfig, predict_trajectory
from backend.prediction.tests.test_domain import BASE_TIME, make_points, straight_line


def predict(points=None, age=0, **kwargs):
    return predict_trajectory("airspace_target", 1, points or straight_line(),
                              BASE_TIME + timedelta(seconds=20 + age),
                              PredictionConfig(adaptive_horizon=True, **kwargs))


def test_fixed_mode_unchanged_and_adaptive_maximum_can_be_reached():
    fixed = predict_trajectory("airspace_target", 1, straight_line(), BASE_TIME + timedelta(seconds=20))
    assert fixed.horizon_policy == {}
    adaptive = predict(adaptive_max_uncertainty_m=1000)
    assert adaptive.points == fixed.points
    assert adaptive.horizon_seconds == 120
    assert adaptive.horizon_policy["actual_horizon_seconds"] == 120
    assert adaptive.horizon_policy["stop_reason"] == "configured_horizon"


@pytest.mark.parametrize("estimator", ["least_squares", "kalman_cv"])
def test_uncertainty_truncates_prefix_for_both_estimators(estimator):
    result = predict(estimator=estimator, adaptive_max_uncertainty_m=100)
    assert result.quality == "ok"
    assert 0 < result.horizon_policy["actual_horizon_seconds"] < 120
    assert result.horizon_policy["stop_reason"] == "uncertainty_limit"
    assert result.horizon_policy["actual_horizon_seconds"] == result.points[-1].eta_seconds
    assert all(p.uncertainty_m <= 100 for p in result.points)


def test_age_removes_elapsed_points_without_shifting_eta():
    result = predict(age=12, adaptive_max_uncertainty_m=1000)
    assert result.points[0].eta_seconds == 15
    assert result.base_observed_at == BASE_TIME + timedelta(seconds=20)
    assert result.horizon_policy["remaining_horizon_seconds"] == 108


@pytest.mark.parametrize("age", [30, 31, 200])
def test_stale_observation_produces_explicit_empty_prediction(age):
    result = predict(age=age)
    assert result.quality == "insufficient_data"
    assert result.reason == "no_reliable_future"
    assert result.points == []
    assert result.horizon_policy["stop_reason"] == "stale_observation"
    assert result.horizon_policy["actual_horizon_seconds"] == 0
    assert result.horizon_seconds == 120


def test_no_future_points_and_no_forced_minimum():
    result = predict(age=10, horizon_seconds=10)
    assert result.points == []
    assert result.horizon_policy["stop_reason"] == "no_future_points"
    result = predict(adaptive_max_uncertainty_m=1)
    assert result.points == []
    assert result.horizon_policy["stop_reason"] == "uncertainty_limit"


def test_uncertainty_display_cap_cannot_hide_boundary_violation():
    result = predict(uncertainty_max_m=1, adaptive_max_uncertainty_m=100)
    assert result.horizon_policy["actual_horizon_seconds"] < 120
    assert result.horizon_policy["stop_reason"] == "uncertainty_limit"


def test_turn_angle_limit_and_stable_ct_acceleration():
    omega = radians(10)
    radius = 20 / omega
    points = make_points([(t, radius * sin(omega*t), radius * (cos(omega*t)-1))
                          for t in range(0, 21, 5)])
    result = predict(points, adaptive_max_uncertainty_m=1000)
    assert result.model_code == "ct"
    assert result.horizon_policy["actual_horizon_seconds"] == 5
    assert result.horizon_policy["stop_reason"] == "turn_angle_limit"
    assert result.horizon_policy["metrics"]["unexplained_acceleration_mps2"] < 0.001


def test_accelerating_straight_motion_shortens_forecast():
    points = make_points([(t, 0.5*t*t, 0) for t in range(0, 21, 5)])
    result = predict(points)
    assert result.model_code == "cv"
    assert result.horizon_policy["stop_reason"] == "motion_instability"
    assert result.horizon_policy["metrics"]["unexplained_acceleration_mps2"] == pytest.approx(1)


def test_hover_is_not_automatically_trusted():
    points = make_points([(t, 0, 0) for t in range(0, 21, 5)])
    result = predict(points, adaptive_max_uncertainty_m=20)
    assert result.model_code == "hover"
    assert result.horizon_policy["actual_horizon_seconds"] == 20
    assert result.horizon_policy["stop_reason"] == "uncertainty_limit"


def test_data_failure_reason_and_future_filtering_are_preserved():
    points = straight_line(count=2)
    result = predict(points)
    assert result.reason == "not_enough_points"
    assert result.horizon_policy["stop_reason"] == "not_enough_points"
    future = make_points([(100, 100000, 100000)])
    assert predict(straight_line()+future) == predict()


@pytest.mark.parametrize("field,value", [
    ("horizon_seconds", 0), ("step_seconds", 0), ("horizon_seconds", 1.5),
    ("step_seconds", 121), ("adaptive_max_uncertainty_m", float("nan")),
    ("adaptive_max_observation_age_seconds", float("inf")),
    ("adaptive_max_turn_degrees", -1), ("window_seconds", 0),
])
def test_invalid_config(field, value):
    with pytest.raises(ValueError):
        replace(PredictionConfig(), **{field: value})


@pytest.mark.parametrize("estimator", ["least_squares", "kalman_cv"])
def test_irregular_observations_and_shuffled_input_are_deterministic(estimator):
    points = make_points([(t, 10*t, 0) for t in (0, 3, 8, 14, 20)])
    config = dict(estimator=estimator, adaptive_max_uncertainty_m=1000)
    reference = predict(points, **config)
    assert reference.horizon_policy["metrics"]["unexplained_acceleration_mps2"] < 1e-6
    assert reference == predict(list(reversed(points)) + [points[1]], **config)


def test_imm_refuses_unsupported_policy():
    from backend.prediction.imm import predict_imm_trajectory

    with pytest.raises(ValueError, match="not supported"):
        predict_imm_trajectory("airspace_target", 1, straight_line(),
                               BASE_TIME + timedelta(seconds=20), PredictionConfig(adaptive_horizon=True))
