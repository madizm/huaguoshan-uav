"""Experimental OFFLINE CV/CT interacting-multiple-model EKF (version 3).

Not imported by the worker. State is [east, north, ve, vn, omega_rad_s],
with positive omega counterclockwise (reported heading/turn rate is clockwise).
All priors below are fixed a priori, not fitted to production observations.
The symmetric continuous-time model chain has a 60 s probability-relaxation
constant (each direction's jump rate is 1/120 s). CT angular random-walk std
is 0.5 deg/s/sqrt(s); initial angular std is 3 deg/s. CV resets omega to zero
and its cross-covariances to zero, retaining the initial angular variance as
an unused embedding prior for transitions to CT. This is not a third model.

Horizontal white-acceleration density q uses PredictionConfig's existing SI
units. CT propagation uses <=1 s EKF substeps, CV-form Cartesian acceleration
noise and independent angular diffusion at each substep. This is a local
linearization, not an exact nonlinear stochastic discretization. Sparse data,
aliased turns, abrupt maneuvers, long forecasts and the local geographic plane
can invalidate it. Position-only data poorly observes turn at low speed.
Uncertainty includes both modes' covariance and disagreement about the chosen
component, without a display cap; it is NOT empirically calibrated coverage.
Height remains a separate least-squares extrapolation. No persistent state,
map matching, data association, sensor-specific errors, or online tuning.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
from math import ceil, cos, degrees, exp, expm1, hypot, isfinite, log, pi, radians, sin, sqrt

from .domain import (
    ObservationPoint, PredictedPoint, Prediction, PredictionConfig, SubjectKind,
    _fit_window, _heading_deg, _local_xy, _lon_lat, prepare_window,
)
from .kalman import validate_noise

MODEL_VERSION = 3
MODEL_TIME_CONSTANT_SECONDS = 60.0
INITIAL_TURN_STD_RAD_S = radians(3.0)
TURN_DIFFUSION_STD_RAD_S_SQRT_S = radians(0.5)
INITIAL_VELOCITY_STD_MPS = 120.0
MAX_EKF_STEP_SECONDS = 1.0

Vector = list[float]
Matrix = list[list[float]]


def _zeros() -> Matrix:
    return [[0.0] * 5 for _ in range(5)]


def _identity() -> Matrix:
    return [[float(i == j) for j in range(5)] for i in range(5)]


def _transpose(a: Matrix) -> Matrix:
    return [list(row) for row in zip(*a)]


def _multiply(a: Matrix, b: Matrix) -> Matrix:
    return [[sum(x * y for x, y in zip(row, col)) for col in zip(*b)] for row in a]


def _sandwich(f: Matrix, p: Matrix) -> Matrix:
    return _multiply(_multiply(f, p), _transpose(f))


def _symmetrize(p: Matrix) -> Matrix:
    return [[(p[i][j] + p[j][i]) / 2 for j in range(5)] for i in range(5)]


def transition_matrix(dt: float) -> list[list[float]]:
    """Exact exp(Q dt), rows=source, columns=destination; obeys semigroup law."""
    if not isfinite(dt) or dt < 0:
        raise ValueError("dt must be finite and >= 0")
    switch = -expm1(-dt / MODEL_TIME_CONSTANT_SECONDS) / 2
    return [[1 - switch, switch], [switch, 1 - switch]]


@dataclass(frozen=True)
class Component:
    mean: Vector
    covariance: Matrix


@dataclass(frozen=True)
class IMMState:
    """Read-only by convention; component order and probabilities are (CV, CT)."""
    components: tuple[Component, Component]
    probabilities: tuple[float, float]


def interaction(state: IMMState, dt: float) -> tuple[IMMState, Matrix]:
    """Full mean/covariance mixing; conditional weights [source][destination].

    Exposed for diagnostic tests. Zero-prior destinations at dt=0 use their
    own component (the conditional distribution is otherwise undefined).
    """
    transition = transition_matrix(dt)
    prior = [sum(state.probabilities[i] * transition[i][j] for i in range(2)) for j in range(2)]
    weights = [[state.probabilities[i] * transition[i][j] / prior[j] if prior[j] else float(i == j)
                for j in range(2)] for i in range(2)]
    mixed = []
    for j in range(2):
        mean = [sum(weights[i][j] * state.components[i].mean[k] for i in range(2)) for k in range(5)]
        covariance = [[sum(weights[i][j] * (
            state.components[i].covariance[k][l]
            + (state.components[i].mean[k] - mean[k]) * (state.components[i].mean[l] - mean[l])
        ) for i in range(2)) for l in range(5)] for k in range(5)]
        mixed.append(Component(mean, covariance))
    return IMMState(tuple(mixed), tuple(prior)), weights


def ct_motion(mean: Vector, dt: float) -> tuple[Vector, Matrix]:
    """Exact deterministic coordinated turn and analytic EKF Jacobian.

    Taylor series in theta avoids cancellation and gives the correct omega
    derivatives at zero, which are essential for learning a turn from CV.
    """
    if not isfinite(dt) or dt < 0 or len(mean) != 5 or not all(map(isfinite, mean)):
        raise ValueError("finite five-state mean and nonnegative dt required")
    x, y, vx, vy, w = mean
    theta = w * dt
    s, c = sin(theta), cos(theta)
    if abs(theta) < 1e-4:
        a = dt * (1 - theta**2 / 6 + theta**4 / 120)
        b = dt * (theta / 2 - theta**3 / 24 + theta**5 / 720)
        da = dt**2 * (-theta / 3 + theta**3 / 30 - theta**5 / 840)
        db = dt**2 * (0.5 - theta**2 / 8 + theta**4 / 144)
    else:
        a, b = dt * s / theta, dt * (1 - c) / theta
        da = dt**2 * (theta * c - s) / theta**2
        db = dt**2 * (theta * s - (1 - c)) / theta**2
    result = [x + a * vx - b * vy, y + b * vx + a * vy,
              c * vx - s * vy, s * vx + c * vy, w]
    f = _identity()
    f[0][2], f[0][3], f[1][2], f[1][3] = a, -b, b, a
    f[2][2], f[2][3], f[3][2], f[3][3] = c, -s, s, c
    f[0][4], f[1][4] = da * vx - db * vy, db * vx + da * vy
    f[2][4], f[3][4] = dt * (-s * vx - c * vy), dt * (c * vx - s * vy)
    return result, f


def _reset_cv(component: Component) -> Component:
    mean, p = component.mean[:], [row[:] for row in component.covariance]
    mean[4] = 0.0
    for i in range(5):
        p[i][4] = p[4][i] = 0.0
    p[4][4] = INITIAL_TURN_STD_RAD_S**2
    return Component(mean, p)


def propagate(component: Component, model: int, dt: float, q: float) -> Component:
    """Propagate one component, without interaction or measurement update."""
    if model not in (0, 1) or not isfinite(dt) or dt < 0 or not isfinite(q) or q <= 0:
        raise ValueError("model must be 0/1, dt >= 0 and q > 0, all finite")
    current = _reset_cv(component) if model == 0 else component
    count = max(1, ceil(dt / MAX_EKF_STEP_SECONDS)) if model == 1 else 1
    h = dt / count
    for _ in range(count):
        if model == 1:
            mean, f = ct_motion(current.mean, h)
        else:
            mean, f = current.mean[:], _identity()
            mean[0] += h * mean[2]
            mean[1] += h * mean[3]
            f[0][2] = f[1][3] = h
        p = _sandwich(f, current.covariance)
        for pos, vel in ((0, 2), (1, 3)):
            p[pos][pos] += q * h**3 / 3
            p[pos][vel] += q * h**2 / 2
            p[vel][pos] += q * h**2 / 2
            p[vel][vel] += q * h
        if model == 1:
            p[4][4] += TURN_DIFFUSION_STD_RAD_S_SQRT_S**2 * h
        current = Component(mean, _symmetrize(p))
    return _reset_cv(current) if model == 0 else current


def _update(component: Component, east: float, north: float, r: float) -> tuple[Component, float]:
    """2D position update with full innovation covariance and Joseph form."""
    p, mean = component.covariance, component.mean
    a, b, d = p[0][0] + r, p[0][1], p[1][1] + r
    # Cholesky-style Schur complement is more stable than a*d-b*b.
    schur = d - b * b / a
    if a <= 0 or schur <= 0 or not isfinite(schur):
        raise ValueError("innovation covariance is not positive definite")
    inverse = [[1 / a + (b / a)**2 / schur, -b / a / schur],
               [-b / a / schur, 1 / schur]]
    k = [[sum(p[i][j] * inverse[j][l] for j in range(2)) for l in range(2)] for i in range(5)]
    innovation = [east - mean[0], north - mean[1]]
    updated = [mean[i] + sum(k[i][j] * innovation[j] for j in range(2)) for i in range(5)]
    residual = _identity()
    for i in range(5):
        for j in range(2):
            residual[i][j] -= k[i][j]
    covariance = _sandwich(residual, p)
    for i in range(5):
        for j in range(5):
            covariance[i][j] += r * sum(k[i][l] * k[j][l] for l in range(2))
    mahalanobis = innovation[0]**2 / a + (innovation[1] - b / a * innovation[0])**2 / schur
    likelihood = -log(2 * pi) - 0.5 * (log(a) + log(schur) + mahalanobis)
    return Component(updated, _symmetrize(covariance)), likelihood


def replay_imm(samples: list[tuple[float, float, float]], measurement_noise_std_m: float = 10.0,
               acceleration_noise_density_m2_s3: float = 1.0) -> IMMState:
    """Replay strictly increasing (seconds, east, north), no double initialization.

    Starts with equal model probability, Pposition=R and diffuse velocity prior.
    First observation initializes once; each later sample mixes, predicts and
    applies the Bayesian likelihood update. Public diagnostics expose both
    posteriors and normalized probabilities, without changing production APIs.
    """
    validate_noise(measurement_noise_std_m, acceleration_noise_density_m2_s3)
    if not samples:
        raise ValueError("samples must not be empty")
    for i, sample in enumerate(samples):
        if len(sample) != 3 or not all(map(isfinite, sample)):
            raise ValueError("samples must be finite (time, east, north)")
        if i and sample[0] <= samples[i - 1][0]:
            raise ValueError("sample times must be strictly increasing")
    r = measurement_noise_std_m**2
    p = _zeros()
    for i, variance in enumerate((r, r, INITIAL_VELOCITY_STD_MPS**2,
                                  INITIAL_VELOCITY_STD_MPS**2, INITIAL_TURN_STD_RAD_S**2)):
        p[i][i] = variance
    first = Component([samples[0][1], samples[0][2], 0.0, 0.0, 0.0], p)
    state = IMMState((first, first), (0.5, 0.5))
    time = samples[0][0]
    for next_time, east, north in samples[1:]:
        dt = next_time - time
        mixed, _ = interaction(state, dt)
        components, evidence = [], []
        for model in range(2):
            prior = propagate(mixed.components[model], model, dt, acceleration_noise_density_m2_s3)
            posterior, likelihood = _update(prior, east, north, r)
            components.append(_reset_cv(posterior) if model == 0 else posterior)
            evidence.append(log(mixed.probabilities[model]) + likelihood)
        maximum = max(evidence)
        weights = [exp(value - maximum) for value in evidence]
        total = sum(weights)
        state = IMMState(tuple(components), tuple(w / total for w in weights))
        time = next_time
    return state


def uncertainty_radius_m(state: IMMState, chosen_mean: Vector) -> float:
    """Mixture second moment about the displayed mode, NOT mixture centroid.

    Enclosing radius uses chi-square(2,.95) times largest second-moment
    eigenvalue, conservatively including mode disagreement. A Gaussian-mixture
    second moment does not imply actual 95% probability content.
    """
    a = b = d = 0.0
    for probability, component in zip(state.probabilities, state.components):
        dx, dy = component.mean[0] - chosen_mean[0], component.mean[1] - chosen_mean[1]
        a += probability * (component.covariance[0][0] + dx * dx)
        b += probability * (component.covariance[0][1] + dx * dy)
        d += probability * (component.covariance[1][1] + dy * dy)
    largest = (a + d + hypot(a - d, 2 * b)) / 2
    return ceil(sqrt(-2 * log(0.05) * max(0.0, largest)) * 10) / 10


def _validate_config(config: PredictionConfig) -> None:
    validate_noise(config.measurement_noise_std_m, config.acceleration_noise_density_m2_s3)
    for name in ("window_seconds", "max_speed_mps", "max_vertical_speed_mps"):
        value = getattr(config, name)
        if not isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be finite and > 0")
    for name in ("min_window_span_seconds", "hover_speed_mps"):
        value = getattr(config, name)
        if not isfinite(value) or value < 0:
            raise ValueError(f"{name} must be finite and >= 0")
    for name in ("horizon_seconds", "step_seconds", "min_points"):
        value = getattr(config, name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise ValueError(f"{name} must be a positive integer")


def predict_imm_trajectory(kind: SubjectKind, id: int, points: list[ObservationPoint],
                           predicted_at: datetime, config: PredictionConfig) -> Prediction:
    """Offline experimental predictor; ETA is relative to newest eligible sample.

    Deterministic highest-ID timestamp deduplication and inclusive finite window
    match CV replay. Future observations are removed BEFORE choosing the window.
    Forecast follows the dominant posterior component, never a physical midpoint;
    probabilities are held fixed across its open-loop future (no extra mixing).
    Hover is a display decision for that component's speed below the configured
    threshold, with stationary means but the same growing covariance envelope.
    """
    _validate_config(config)
    window = prepare_window([p for p in points if p.observed_at <= predicted_at],
                            replace(config, estimator="kalman_cv"))
    common = dict(subject_kind=kind, subject_id=id,
                  base_observed_at=window[-1].observed_at if window else predicted_at,
                  predicted_at=predicted_at, model_version=MODEL_VERSION,
                  horizon_seconds=config.horizon_seconds, step_seconds=config.step_seconds,
                  window_seconds=int(config.window_seconds), window_point_count=len(window))

    def insufficient(reason: str) -> Prediction:
        return Prediction(**common, model_code="cv", quality="insufficient_data", reason=reason)

    if len(window) < config.min_points:
        return insufficient("not_enough_points")
    base = window[-1]
    if (base.observed_at - window[0].observed_at).total_seconds() < config.min_window_span_seconds:
        return insufficient("window_span_too_short")
    samples = [((p.observed_at - base.observed_at).total_seconds(),
                *_local_xy(p.longitude, p.latitude, base.longitude, base.latitude)) for p in window]
    state = replay_imm(samples, config.measurement_noise_std_m, config.acceleration_noise_density_m2_s3)
    chosen = 0 if state.probabilities[0] >= state.probabilities[1] else 1
    component = state.components[chosen]
    speed = hypot(component.mean[2], component.mean[3])
    if speed > config.max_speed_mps:
        return insufficient("unrealistic_speed")
    hover = speed < config.hover_speed_mps
    fit = _fit_window(window, config)
    output = []
    future, previous_eta = state, 0
    for eta in range(config.step_seconds, config.horizon_seconds + 1, config.step_seconds):
        future = IMMState(tuple(propagate(c, i, eta - previous_eta, config.acceleration_noise_density_m2_s3)
                                for i, c in enumerate(future.components)), state.probabilities)
        previous_eta = eta
        center = component.mean if hover else future.components[chosen].mean
        longitude, latitude = _lon_lat(center[0], center[1], base.longitude, base.latitude)
        height = None if fit.base_height_amsl_m is None else round(
            fit.base_height_amsl_m + (fit.vertical_speed_mps or 0.0) * eta, 1)
        output.append(PredictedPoint(eta_seconds=eta, longitude=round(longitude, 7),
                                     latitude=round(latitude, 7), height_amsl_m=height,
                                     uncertainty_m=uncertainty_radius_m(future, center)))
    return Prediction(**common, model_code="hover" if hover else ("cv" if chosen == 0 else "ct"),
                      quality="ok", speed_mps=round(speed, 2),
                      heading_deg=None if hover else round(_heading_deg(component.mean[2], component.mean[3]), 1),
                      turn_rate_dps=round(-degrees(component.mean[4]), 2) if chosen == 1 and not hover else None,
                      fit_residual_m=round(fit.residual_m, 2), points=output)
