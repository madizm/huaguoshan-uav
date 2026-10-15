"""Offline-only synthetic IMM contracts; no production data or fitted constants."""
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from itertools import permutations
from math import cos, degrees, hypot, isfinite, radians, sin, sqrt

import pytest

from backend.prediction.domain import ObservationPoint, PredictionConfig, _local_xy, _lon_lat
from backend.prediction.imm import (
    Component, IMMState, INITIAL_TURN_STD_RAD_S, INITIAL_VELOCITY_STD_MPS,
    MODEL_TIME_CONSTANT_SECONDS, TURN_DIFFUSION_STD_RAD_S_SQRT_S,
    _update, ct_motion, interaction, predict_imm_trajectory, propagate, replay_imm,
    transition_matrix, uncertainty_radius_m,
)
from backend.prediction.kalman import replay_cv

BASE_TIME = datetime(2026, 1, 1, tzinfo=timezone.utc)
CONFIG = PredictionConfig(window_seconds=90)


def turn_samples(rate=3, times=range(0, 91, 2), speed=20):
    w = radians(rate)
    return [(float(t), speed * t if w == 0 else speed * sin(w * t) / w,
             0.0 if w == 0 else speed * (1 - cos(w * t)) / w) for t in times]


def points_for(samples):
    return [ObservationPoint(observation_id=i + 1, observed_at=BASE_TIME + timedelta(seconds=t),
                             longitude=_lon_lat(x, y, 119, 34)[0], latitude=_lon_lat(x, y, 119, 34)[1],
                             height_amsl_m=100 + t)
            for i, (t, x, y) in enumerate(samples)]


def predict(points, config=CONFIG, at=90):
    return predict_imm_trajectory("airspace_target", 42, points, BASE_TIME + timedelta(seconds=at), config)


def assert_psd(p):
    """Cholesky test of the complete 5x5 covariance, not only its diagonal."""
    l = [[0.0] * 5 for _ in range(5)]
    for i in range(5):
        for j in range(5):
            assert isfinite(p[i][j])
            assert p[i][j] == pytest.approx(p[j][i], abs=1e-9)
        for j in range(i + 1):
            value = p[i][j] - sum(l[i][k] * l[j][k] for k in range(j))
            if i == j:
                assert value > 0
                l[i][j] = sqrt(value)
            else:
                l[i][j] = value / l[j][j]


def test_constants_are_fixed_and_initial_observation_consumed_once():
    assert MODEL_TIME_CONSTANT_SECONDS == 60
    assert degrees(INITIAL_TURN_STD_RAD_S) == pytest.approx(3)
    assert degrees(TURN_DIFFUSION_STD_RAD_S_SQRT_S) == pytest.approx(0.5)
    state = replay_imm([(17, 12, -4)], 5, 2)
    assert state.probabilities == (0.5, 0.5)
    for component in state.components:
        assert component.mean == [12, -4, 0, 0, 0]
        assert component.covariance[0][0] == 25
        assert component.covariance[2][2] == INITIAL_VELOCITY_STD_MPS**2
        assert component.covariance[4][4] == INITIAL_TURN_STD_RAD_S**2
        assert_psd(component.covariance)


def test_continuous_time_transition_is_stochastic_and_obeys_semigroup():
    assert transition_matrix(0) == [[1, 0], [0, 1]]
    for a, b in ((0.001, 0.03), (2, 5), (29, 61), (0, 8), (1000, 500)):
        p, q, total = transition_matrix(a), transition_matrix(b), transition_matrix(a + b)
        for i in range(2):
            assert sum(p[i]) == pytest.approx(1)
            assert all(0 <= x <= 1 for x in p[i])
            for j in range(2):
                assert sum(p[i][k] * q[k][j] for k in range(2)) == pytest.approx(total[i][j])
    assert transition_matrix(1e-12)[0][1] > 0
    assert transition_matrix(1e9) == [[0.5, 0.5], [0.5, 0.5]]


def test_interaction_contains_between_component_covariance():
    p = [[float(i == j) for j in range(5)] for i in range(5)]
    components = (Component([0, 0, 0, 0, 0], p), Component([10, -4, 0, 0, 0], p))
    original = IMMState(components, (0.8, 0.2))
    mixed, weights = interaction(original, 7)
    assert sum(mixed.probabilities) == pytest.approx(1)
    for j in range(2):
        assert sum(weights[i][j] for i in range(2)) == pytest.approx(1)
        w = weights[1][j]
        assert mixed.components[j].mean[0] == pytest.approx(10 * w)
        assert mixed.components[j].covariance[0][0] == pytest.approx(1 + 100 * w * (1 - w))
        assert mixed.components[j].covariance[0][1] == pytest.approx(-40 * w * (1 - w))
        assert_psd(mixed.components[j].covariance)
    assert original.components[0].covariance[0][0] == 1
    # dt=0 and a zero-probability destination remain well-defined.
    unmixed, conditional = interaction(IMMState(components, (1.0, 0.0)), 0)
    assert unmixed.components == components
    assert conditional == [[1, 0], [0, 1]]


@pytest.mark.parametrize("omega", [0, 1e-10, radians(3), radians(-12)])
def test_analytic_ct_jacobian_matches_central_differences(omega):
    mean, dt = [4.0, -3.0, 18.0, 7.0, omega], 2.7
    result, jacobian = ct_motion(mean, dt)
    for col in range(5):
        epsilon = 1e-6
        plus, minus = mean[:], mean[:]
        plus[col] += epsilon
        minus[col] -= epsilon
        high, _ = ct_motion(plus, dt)
        low, _ = ct_motion(minus, dt)
        for row in range(5):
            assert jacobian[row][col] == pytest.approx((high[row] - low[row]) / (2 * epsilon), abs=2e-6)
    assert hypot(result[2], result[3]) == pytest.approx(hypot(mean[2], mean[3]))
    assert ct_motion(mean, 0)[0] == mean


def test_cv_propagation_matches_existing_white_acceleration_kalman():
    state = replay_imm([(0, 5, -8)], 4, 0.7)
    c = propagate(state.components[0], 0, 7.5, 0.7)
    cv = replay_cv([(0, 5, -8)], 4, 0.7).propagate(7.5)
    assert c.covariance[0][0] == pytest.approx(cv.east.position_variance)
    assert c.covariance[0][2] == pytest.approx(cv.east.position_velocity_covariance)
    assert c.covariance[2][2] == pytest.approx(cv.east.velocity_variance)
    assert c.mean[4] == 0
    assert c.covariance[4][4] == INITIAL_TURN_STD_RAD_S**2
    assert all(c.covariance[i][4] == 0 for i in range(4))
    assert_psd(c.covariance)


def test_joseph_measurement_update_has_exact_scalar_closed_form():
    p = [[0.0] * 5 for _ in range(5)]
    for i, value in enumerate((100, 100, 9, 9, 1)):
        p[i][i] = value
    p[0][2] = p[2][0] = 12
    c, loglik = _update(Component([5, 0, 2, 0, 0], p), 15, 0, 25)
    assert c.mean[:3] == pytest.approx([13, 0, 2.96])
    assert c.covariance[0][0] == pytest.approx(20)
    assert c.covariance[0][2] == pytest.approx(2.4)
    assert c.covariance[2][2] == pytest.approx(9 - 144 / 125)
    assert isfinite(loglik)
    assert_psd(c.covariance)


@pytest.mark.parametrize("rate", [3, -3])
def test_synthetic_turn_evidence_and_future_error_versus_cv(rate):
    samples = turn_samples(rate)
    state = replay_imm(samples)
    assert state.probabilities[1] > state.probabilities[0]
    assert sum(state.probabilities) == pytest.approx(1)
    assert degrees(state.components[1].mean[4]) == pytest.approx(rate, abs=0.2)
    actual = turn_samples(rate, [120])[0][1:]
    forecast = propagate(state.components[1], 1, 30, 1)
    cv = replay_cv(samples).propagate(30)
    ct_error = hypot(forecast.mean[0] - actual[0], forecast.mean[1] - actual[1])
    cv_error = hypot(cv.east.position - actual[0], cv.north.position - actual[1])
    assert ct_error < cv_error
    assert replay_imm(samples) == state
    prediction = predict(points_for(samples))
    assert prediction.model_code == "ct"
    assert prediction.model_version == 3
    # Public clockwise convention is the opposite of internal Cartesian omega.
    assert prediction.turn_rate_dps == pytest.approx(-rate, abs=0.2)
    assert prediction.points[-1].height_amsl_m == 310


def test_straight_and_hover_behavior():
    state = replay_imm(turn_samples(0))
    assert state.probabilities[0] > state.probabilities[1]
    prediction = predict(points_for(turn_samples(0)))
    assert prediction.model_code == "cv"
    assert prediction.speed_mps == pytest.approx(20, abs=0.01)
    assert prediction.heading_deg == 90
    assert [p.eta_seconds for p in prediction.points] == list(range(5, 121, 5))
    end = prediction.points[-1]
    assert _local_xy(end.longitude, end.latitude, 119, 34) == pytest.approx((4200, 0), abs=0.02)
    hover = predict(points_for([(t, 5, 8) for t in range(0, 91, 5)]))
    assert hover.model_code == "hover"
    assert len({(p.longitude, p.latitude) for p in hover.points}) == 1
    assert hover.points[-1].uncertainty_m > hover.points[0].uncertainty_m


def test_dominant_component_future_not_probability_weighted_midpoint():
    samples = turn_samples()
    points = points_for(samples)
    result = predict(points)
    base = points[-1]
    local = [((p.observed_at - base.observed_at).total_seconds(),
              *_local_xy(p.longitude, p.latitude, base.longitude, base.latitude)) for p in points]
    state = replay_imm(local)
    cv, ct = [propagate(c, i, 30, 1) for i, c in enumerate(state.components)]
    eta30 = next(p for p in result.points if p.eta_seconds == 30)
    expected = _lon_lat(ct.mean[0], ct.mean[1], base.longitude, base.latitude)
    assert (eta30.longitude, eta30.latitude) == tuple(round(v, 7) for v in expected)
    center = [state.probabilities[0] * cv.mean[i] + state.probabilities[1] * ct.mean[i] for i in range(2)]
    actual = _local_xy(eta30.longitude, eta30.latitude, base.longitude, base.latitude)
    assert hypot(actual[0] - center[0], actual[1] - center[1]) > 1


def test_uncertainty_includes_disagreement_about_chosen_component_without_cap():
    p = [[float(i == j) for j in range(5)] for i in range(5)]
    left = Component([0, 0, 0, 0, 0], p)
    right = Component([10000, 0, 0, 0, 0], p)
    state = IMMState((left, right), (0.75, 0.25))
    radius = uncertainty_radius_m(state, left.mean)
    assert radius > 2000
    assert radius > uncertainty_radius_m(IMMState((left, left), (0.75, 0.25)), left.mean)
    assert radius > uncertainty_radius_m(state, [2500, 0, 0, 0, 0])


def test_window_highest_id_dedup_future_exclusion_and_input_order_independence():
    points = points_for([(0, 0, 0), (5, 100, 0), (10, 200, 0)])
    loser = points[1].model_copy(update={"observation_id": 0, "longitude": 120})
    future = points_for([(1000, 1e5, 1e5)])[0]
    expected = predict(points, at=10)
    for ordered in permutations(points + [loser]):
        assert predict(list(ordered) + [future], at=10) == expected
    assert expected.window_point_count == 3
    assert expected.base_observed_at == BASE_TIME + timedelta(seconds=10)
    assert predict([future], at=10).reason == "not_enough_points"
    # Missing/equal IDs use deterministic coordinate tie-breakers.
    equal_id = points[1].model_copy(update={"longitude": points[1].longitude + 0.00001})
    assert predict(points + [equal_id], at=10) == predict([equal_id] + points, at=10)
    long_points = points_for(turn_samples(0, range(0, 101, 5)))
    short = predict(long_points, replace(CONFIG, window_seconds=20), at=100)
    assert short == predict(long_points[-5:], replace(CONFIG, window_seconds=20), at=100)
    assert short.window_point_count == 5
    assert predict(long_points, at=100).window_point_count == 19


def test_covariances_remain_positive_finite_with_irregular_and_sparse_times():
    times, current = [0.0], 0.0
    for i in range(120):
        current += (0.01, 0.5, 3, 9)[i % 4]
        times.append(current)
    for rate in (0, 3):
        samples = turn_samples(rate, times)
        state = replay_imm(samples)
        assert sum(state.probabilities) == pytest.approx(1)
        assert all(isfinite(p) and 0 <= p <= 1 for p in state.probabilities)
        for i, component in enumerate(state.components):
            assert_psd(component.covariance)
            assert_psd(propagate(component, i, 120, 1).covariance)
    # Extreme finite innovation underflows one ordinary likelihood, but the
    # log-domain normalization must still leave a valid posterior distribution.
    outlier = replay_imm([(0, 0, 0), (1, 1e6, -1e6), (2, 0, 0)])
    assert sum(outlier.probabilities) == pytest.approx(1)
    assert all(isfinite(p) for p in outlier.probabilities)


@pytest.mark.parametrize("samples", [[], [(0, 1, 2), (0, 3, 4)], [(1, 0, 0), (0, 0, 0)],
                                    [(float("nan"), 0, 0)], [(0, float("inf"), 0)], [(0, 1)]])
def test_invalid_samples(samples):
    with pytest.raises(ValueError):
        replay_imm(samples)


@pytest.mark.parametrize("dt", [-1, float("nan"), float("inf")])
def test_invalid_dt(dt):
    with pytest.raises(ValueError):
        transition_matrix(dt)
    with pytest.raises(ValueError):
        ct_motion([0] * 5, dt)
    with pytest.raises(ValueError):
        propagate(replay_imm([(0, 0, 0)]).components[0], 1, dt, 1)


@pytest.mark.parametrize("noise", [0, -1, float("nan"), float("inf")])
def test_invalid_noise(noise):
    with pytest.raises(ValueError):
        replay_imm([(0, 0, 0)], noise, 1)
    with pytest.raises(ValueError):
        replay_imm([(0, 0, 0)], 1, noise)


@pytest.mark.parametrize("field,value", [("window_seconds", 0), ("window_seconds", float("nan")),
    ("step_seconds", 0), ("step_seconds", 1.5), ("horizon_seconds", -1), ("min_points", 0),
    ("hover_speed_mps", -1), ("min_window_span_seconds", -1), ("max_speed_mps", 0),
    ("max_vertical_speed_mps", float("inf"))])
def test_invalid_config(field, value):
    with pytest.raises(ValueError):
        predict([], replace(CONFIG, **{field: value}))


def test_insufficient_span_and_unrealistic_speed():
    assert predict([]).quality == "insufficient_data"
    assert predict(points_for([(0, 0, 0), (1, 1, 0), (2, 2, 0)]), at=2).reason == "window_span_too_short"
    fast = points_for([(t, 200 * t, 0) for t in range(0, 91, 5)])
    assert predict(fast).reason == "unrealistic_speed"


def test_offline_entrypoint_is_independent_of_production_estimator_selector():
    points = points_for(turn_samples())
    assert predict(points, replace(CONFIG, estimator="kalman_cv")) == predict(points, CONFIG)


def test_invalid_component_propagation_arguments():
    component = replay_imm([(0, 0, 0)]).components[0]
    for model, q in ((2, 1), (-1, 1), (0, 0), (1, float("nan"))):
        with pytest.raises(ValueError):
            propagate(component, model, 5, q)
    with pytest.raises(ValueError):
        ct_motion([0, 0, float("nan"), 0, 0], 1)


def test_straight_to_turn_transition_requires_new_evidence():
    # Noise-free synthetic maneuver, not evidence about sparse field data.
    omega = radians(3)
    samples = [(t, 20 * t, 0.0) for t in range(31)]
    for t in range(31, 61):
        elapsed = t - 30
        samples.append((t, 600 + 20 * sin(omega * elapsed) / omega,
                        20 * (1 - cos(omega * elapsed)) / omega))
    before = replay_imm(samples[:31])
    after = replay_imm(samples)
    assert before.probabilities[0] > 0.8
    assert after.probabilities[1] > 0.8
    assert degrees(after.components[1].mean[4]) == pytest.approx(3, abs=0.2)
    # The model does not predict a turn before receiving maneuver evidence.
    assert before.components[1].mean[4] == pytest.approx(0)
