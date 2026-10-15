from dataclasses import astuple
from datetime import timedelta
from itertools import permutations
from math import ceil, cos, isfinite, log, radians, sin, sqrt
import random

import pytest

from backend.prediction.domain import PredictionConfig, predict_trajectory, prepare_window
from backend.prediction.kalman import AxisState, replay_cv
from .test_domain import BASE_TIME, make_points, straight_line, to_east_north


def predict(points, config=None, at=20):
    return predict_trajectory("airspace_target", 1, points, BASE_TIME + timedelta(seconds=at),
                              config or PredictionConfig(estimator="kalman_cv"))


def test_constant_velocity_and_variable_dt():
    for times in ([0, 5, 10, 15, 20], [0, 0.25, 2.5, 8, 13, 20]):
        points = make_points([(t, 12 * t, 6 * t) for t in times])
        result = predict(points)
        assert result.model_version == 2
        assert result.model_code == "cv"
        assert result.speed_mps == pytest.approx(sqrt(180), abs=0.05)
        east, north = to_east_north(result.points[-1].longitude, result.points[-1].latitude)
        assert east == pytest.approx(12 * 140, abs=1)
        assert north == pytest.approx(6 * 140, abs=1)


def test_deterministic_noisy_track_smooths_position_and_velocity():
    rng = random.Random(942)
    samples = [(t, 15 * t + rng.gauss(0, 8), -4 * t + rng.gauss(0, 8)) for t in range(21)]
    state = replay_cv(samples, 8, 0.05)
    # Compare against a raw final-segment extrapolation, not a claim that KF
    # always beats LS: performance depends on the maneuver/noise assumptions.
    future = state.propagate(10)
    error = (future.east.position - 450)**2 + (future.north.position + 120)**2
    raw_east = samples[-1][1] + 10 * (samples[-1][1] - samples[-2][1])
    raw_north = samples[-1][2] + 10 * (samples[-1][2] - samples[-2][2])
    assert error < (raw_east - 450)**2 + (raw_north + 120)**2
    assert state.east.velocity == pytest.approx(15, abs=1)
    assert state.north.velocity == pytest.approx(-4, abs=1)
    assert replay_cv(samples, 8, 0.05) == state


def test_single_timestamp_is_initialized_exactly_once():
    state = replay_cv([(0, 10, -20)], 5, 2)
    assert state.east.position == 10
    assert state.north.position == -20
    assert state.east.position_variance == 25
    assert state.east.velocity_variance == 14400


def test_joseph_update_matches_scalar_closed_form():
    prior = AxisState(5, 2, 100, 12, 9)
    result = prior.update(15, 25)
    assert result.position == pytest.approx(13)
    assert result.velocity == pytest.approx(2.96)
    assert result.position_variance == pytest.approx(20)
    assert result.position_velocity_covariance == pytest.approx(2.4)
    assert result.velocity_variance == pytest.approx(9 - 144 / 125)


def test_continuous_process_noise_and_variable_dt_composition():
    state = AxisState(10, 3, 9, 2, 4)
    whole = state.propagate(7, 2)
    split = state.propagate(2, 2).propagate(5, 2)
    assert whole.position == 31
    assert whole.position_variance == pytest.approx(9 + 28 + 196 + 2 * 343 / 3)
    assert whole.position_velocity_covariance == pytest.approx(2 + 28 + 49)
    assert whole.velocity_variance == 18
    assert astuple(split) == pytest.approx(astuple(whole))
    assert state.propagate(0, 2) == state


def test_covariance_stays_finite_positive_semidefinite_under_many_updates():
    state = AxisState(0, 0, 100, 0, 14400)
    for index in range(2000):
        state = state.propagate([0.001, 0.5, 3, 7][index % 4], 0.02).update(sin(index), 4)
        p, c, v = state.position_variance, state.position_velocity_covariance, state.velocity_variance
        assert all(isfinite(value) for value in (p, c, v))
        assert p > 0 and v > 0
        assert p * v - c * c >= -1e-10


def test_radius_formula_growth_noise_sensitivity_and_no_heuristic_cap():
    samples = [(0, 0, 0), (5, 100, 0), (20, 400, 0)]
    state = replay_cv(samples)
    radii = [state.radius_95_m(t) for t in [0, 5, 20, 120]]
    assert radii == sorted(radii)
    future = state.propagate(20)
    expected = sqrt(-2 * log(0.05) * max(future.east.position_variance, future.north.position_variance))
    assert state.radius_95_m(20) == ceil(expected * 10) / 10
    assert replay_cv(samples, 20).radius_95_m(20) > state.radius_95_m(20)
    assert replay_cv(samples, 10, 5).radius_95_m(120) > state.radius_95_m(120)
    result = predict(straight_line(), PredictionConfig(estimator="kalman_cv", uncertainty_max_m=1))
    assert result.points[-1].uncertainty_m > 1
    expected_state = replay_cv([(0, -400, 0), (5, -300, 0), (10, -200, 0), (15, -100, 0), (20, 0, 0)])
    assert result.points[-1].uncertainty_m == expected_state.radius_95_m(120)


def test_duplicates_reordering_future_and_repeated_calls_do_not_change_result():
    points = straight_line()
    result = predict(points)
    # A later intake of the same physical sample contributes only once.
    dup = points[2].model_copy(update={"observation_id": 999})
    future = make_points([(100, 50000, 0)])
    shuffled = [points[4], points[1], dup, points[0], points[3], points[2], dup] + future
    assert predict(shuffled) == result
    assert predict(shuffled) == result
    assert result.window_point_count == 5


def test_conflicting_same_timestamp_has_deterministic_winner():
    points = straight_line()
    last = points[-1]
    low = last.model_copy(update={"observation_id": 0, "longitude": last.longitude + 0.01})
    tie = last.model_copy(update={"observation_id": last.observation_id, "latitude": last.latitude - 0.01})
    for order in permutations([last, low, tie]):
        assert predict(points[:-1] + list(order)) == predict(points)
    # Missing IDs also have a total coordinate/height tie-breaker.
    no_id = [p.model_copy(update={"observation_id": None}) for p in [last, tie]]
    config = PredictionConfig(estimator="kalman_cv")
    assert prepare_window(no_id, config) == prepare_window(no_id[::-1], config)


def test_duplicate_timestamps_cannot_satisfy_minimum_count():
    points = straight_line(count=2)
    assert predict(points * 5).reason == "not_enough_points"


def test_window_excludes_old_and_future_measurements():
    points = straight_line(count=11, step=2)
    config = PredictionConfig(estimator="kalman_cv", window_seconds=10)
    assert predict(points, config) == predict(points[-6:], config)
    assert predict(points + make_points([(100, 0, 0)]), config) == predict(points, config)


def test_hover_uses_filtered_position_and_existing_heuristic_uncertainty():
    points = make_points([(t, 0 if t < 20 else 2, 0) for t in [0, 5, 10, 15, 20]])
    result = predict(points)
    assert result.model_code == "hover"
    east, north = to_east_north(result.points[0].longitude, result.points[0].latitude)
    assert 0 < east < 2
    assert north == pytest.approx(0)
    assert len({(p.longitude, p.latitude) for p in result.points}) == 1
    assert result.points[0].uncertainty_m < 30  # heuristic, not CV covariance radius


def test_ct_remains_existing_fit_and_uncertainty():
    omega = radians(10)
    radius = 20 / omega
    points = make_points([(t, radius * sin(omega * t), radius * (cos(omega * t) - 1)) for t in [0, 5, 10, 15, 20]])
    old = predict(points, PredictionConfig())
    new = predict(points)
    assert new.model_code == "ct"
    assert new.model_dump(exclude={"model_version"}) == old.model_dump(exclude={"model_version"})


def test_height_remains_ls_and_default_version_is_unchanged():
    points = [p.model_copy(update={"height_amsl_m": 100 + i * 10}) for i, p in enumerate(straight_line())]
    default = predict(points, PredictionConfig())
    explicit = predict(points, PredictionConfig(estimator="least_squares"))
    kalman = predict(points)
    assert default == explicit
    assert default.model_version == 1
    assert [p.height_amsl_m for p in default.points] == [p.height_amsl_m for p in kalman.points]
    assert kalman.fit_residual_m == default.fit_residual_m
    assert predict([]).model_version == 2
    assert predict(make_points([(t, 200 * t, 0) for t in [0, 5, 10]])).reason == "unrealistic_speed"


@pytest.mark.parametrize("field", ["measurement_noise_std_m", "acceleration_noise_density_m2_s3"])
@pytest.mark.parametrize("value", [0, -1, float("nan"), float("inf"), -float("inf")])
def test_invalid_noise_parameters(field, value):
    with pytest.raises(ValueError, match=field):
        PredictionConfig(**{field: value})
    with pytest.raises(ValueError, match=field):
        replay_cv([(0, 0, 0)], **{field: value})


def test_invalid_estimator_and_samples():
    with pytest.raises(ValueError, match="estimator"):
        PredictionConfig(estimator="other")
    for samples in ([], [(0, 0, 0), (0, 1, 1)], [(1, 0, 0), (0, 1, 1)], [(0, float("nan"), 0)]):
        with pytest.raises(ValueError):
            replay_cv(samples)
    for dt in [-1, float("inf"), float("nan")]:
        with pytest.raises(ValueError):
            replay_cv([(0, 0, 0)]).propagate(dt)
