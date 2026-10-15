"""Dependency-free, finite-window constant-velocity Kalman state estimation.

Horizontal axes are independent. R is position measurement variance (m²); q is
continuous white-acceleration spectral density (m²/s³), NOT acceleration std.
Covariance is model-based, not an empirically calibrated coverage guarantee.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import ceil, isfinite, log, sqrt


def validate_noise(measurement_noise_std_m: float, acceleration_noise_density_m2_s3: float) -> None:
    for name, value in (
        ("measurement_noise_std_m", measurement_noise_std_m),
        ("acceleration_noise_density_m2_s3", acceleration_noise_density_m2_s3),
    ):
        if not isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be finite and > 0")


@dataclass(frozen=True)
class AxisState:
    """Position/velocity posterior with symmetric 2×2 covariance."""

    position: float
    velocity: float
    position_variance: float
    position_velocity_covariance: float
    velocity_variance: float

    def propagate(self, dt: float, acceleration_noise_density_m2_s3: float) -> AxisState:
        """F P Fᵀ + q [[dt³/3, dt²/2], [dt²/2, dt]]."""
        if not isfinite(dt) or dt < 0:
            raise ValueError("dt must be finite and >= 0")
        q = acceleration_noise_density_m2_s3
        if not isfinite(q) or q <= 0:
            raise ValueError("acceleration_noise_density_m2_s3 must be finite and > 0")
        return AxisState(
            self.position + self.velocity * dt,
            self.velocity,
            self.position_variance + 2 * dt * self.position_velocity_covariance
            + dt * dt * self.velocity_variance + q * dt**3 / 3,
            self.position_velocity_covariance + dt * self.velocity_variance + q * dt * dt / 2,
            self.velocity_variance + q * dt,
        )

    def update(self, measurement: float, measurement_variance: float) -> AxisState:
        """Scalar position measurement, Joseph-form covariance update."""
        if not isfinite(measurement) or not isfinite(measurement_variance) or measurement_variance <= 0:
            raise ValueError("measurement must be finite; measurement_variance must be finite and > 0")
        p, c, v = self.position_variance, self.position_velocity_covariance, self.velocity_variance
        r = measurement_variance
        kp, kv = p / (p + r), c / (p + r)
        a = 1 - kp
        innovation = measurement - self.position
        return AxisState(
            self.position + kp * innovation,
            self.velocity + kv * innovation,
            a * a * p + kp * kp * r,
            a * (c - kv * p) + kp * kv * r,
            v - 2 * kv * c + kv * kv * p + kv * kv * r,
        )


@dataclass(frozen=True)
class HorizontalState:
    east: AxisState
    north: AxisState
    acceleration_noise_density_m2_s3: float

    def propagate(self, dt: float) -> HorizontalState:
        return HorizontalState(
            self.east.propagate(dt, self.acceleration_noise_density_m2_s3),
            self.north.propagate(dt, self.acceleration_noise_density_m2_s3),
            self.acceleration_noise_density_m2_s3,
        )

    def radius_95_m(self, eta_seconds: float) -> float:
        """Conservative enclosing circle of the model's 95% horizontal ellipse.

        Uses sqrt(chi²(2, .95) * largest axis variance), rounded UP to 0.1 m.
        No display heuristic cap: truncating this radius would not be conservative.
        """
        future = self.propagate(eta_seconds)
        variance = max(future.east.position_variance, future.north.position_variance)
        return ceil(sqrt(-2 * log(0.05) * variance) * 10) / 10


def replay_cv(
    samples: list[tuple[float, float, float]],
    measurement_noise_std_m: float = 10.0,
    acceleration_noise_density_m2_s3: float = 1.0,
) -> HorizontalState:
    """Replay (seconds, east_m, north_m), returning state at the final sample.

    Caller supplies a sorted, unique-time finite window. No persistent state is
    retained. First measurement initializes position once (Ppp=R), with zero
    velocity and a diffuse 120 m/s velocity standard deviation (Pvv=14400).
    Remaining measurements each receive one predict/update at their actual dt.
    """
    validate_noise(measurement_noise_std_m, acceleration_noise_density_m2_s3)
    if not samples:
        raise ValueError("samples must not be empty")
    for index, sample in enumerate(samples):
        if not all(isfinite(value) for value in sample):
            raise ValueError("samples must be finite")
        if index and sample[0] <= samples[index - 1][0]:
            raise ValueError("sample times must be strictly increasing")
    r = measurement_noise_std_m**2
    time, east, north = samples[0]
    state = HorizontalState(
        AxisState(east, 0.0, r, 0.0, 120.0**2),
        AxisState(north, 0.0, r, 0.0, 120.0**2),
        acceleration_noise_density_m2_s3,
    )
    for next_time, east, north in samples[1:]:
        prior = state.propagate(next_time - time)
        state = HorizontalState(prior.east.update(east, r), prior.north.update(north, r), acceleration_noise_density_m2_s3)
        time = next_time
    return state
