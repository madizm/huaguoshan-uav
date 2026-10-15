from datetime import datetime, timedelta, timezone
from math import cos, degrees, radians, sin

import pytest

from backend.prediction.domain import (
    EARTH_RADIUS_M,
    ObservationPoint,
    PredictionConfig,
    predict_trajectory,
    prepare_window,
)

ORIGIN_LON = 119.25
ORIGIN_LAT = 34.65
BASE_TIME = datetime(2026, 1, 1, tzinfo=timezone.utc)


def to_lon_lat(east_m: float, north_m: float) -> tuple[float, float]:
    lon = ORIGIN_LON + degrees(east_m / (EARTH_RADIUS_M * cos(radians(ORIGIN_LAT))))
    lat = ORIGIN_LAT + degrees(north_m / EARTH_RADIUS_M)
    return lon, lat


def to_east_north(lon: float, lat: float) -> tuple[float, float]:
    east = EARTH_RADIUS_M * radians(lon - ORIGIN_LON) * cos(radians(ORIGIN_LAT))
    north = EARTH_RADIUS_M * radians(lat - ORIGIN_LAT)
    return east, north


def make_points(positions: list[tuple[float, float, float]], start_id: int = 1, start_offset_s: float = 0) -> list[ObservationPoint]:
    points = []
    for index, (t, east, north) in enumerate(positions):
        lon, lat = to_lon_lat(east, north)
        points.append(ObservationPoint(
            observation_id=start_id + index,
            observed_at=BASE_TIME + timedelta(seconds=start_offset_s + t),
            longitude=lon, latitude=lat,
        ))
    return points


def straight_line(speed: float = 20.0, count: int = 5, step: float = 5.0) -> list[ObservationPoint]:
    return make_points([(i * step, speed * i * step, 0.0) for i in range(count)])


class TestStraightLine:
    def test_cv_extrapolates_constant_velocity(self):
        points = straight_line()
        prediction = predict_trajectory(
            "airspace_target", 1, points, BASE_TIME + timedelta(seconds=20),
        )
        assert prediction.quality == "ok"
        assert prediction.model_code == "cv"
        assert prediction.speed_mps == pytest.approx(20.0, abs=0.1)
        assert prediction.heading_deg == pytest.approx(90.0, abs=0.5)
        eta60 = next(p for p in prediction.points if p.eta_seconds == 60)
        east, north = to_east_north(eta60.longitude, eta60.latitude)
        assert east == pytest.approx(20.0 * 20 + 20.0 * 60, abs=1.0)
        assert north == pytest.approx(0.0, abs=1.0)

    def test_points_cover_horizon_by_step(self):
        prediction = predict_trajectory(
            "airspace_target", 1, straight_line(), BASE_TIME + timedelta(seconds=20),
        )
        assert [p.eta_seconds for p in prediction.points] == [float(t) for t in range(5, 121, 5)]
        assert prediction.base_observed_at == BASE_TIME + timedelta(seconds=20)

    def test_uncertainty_grows_with_eta(self):
        prediction = predict_trajectory(
            "airspace_target", 1, straight_line(), BASE_TIME + timedelta(seconds=20),
        )
        values = [p.uncertainty_m for p in prediction.points]
        assert all(a < b for a, b in zip(values, values[1:]))

    def test_shuffled_and_duplicated_points_give_same_result(self):
        points = straight_line()
        shuffled = [points[3], points[0], points[4], points[1], points[2], points[2]]
        reference = predict_trajectory("airspace_target", 1, points, BASE_TIME + timedelta(seconds=20))
        result = predict_trajectory("airspace_target", 1, shuffled, BASE_TIME + timedelta(seconds=20))
        assert result.quality == "ok"
        assert [ (p.longitude, p.latitude) for p in result.points ] == [
            (p.longitude, p.latitude) for p in reference.points
        ]


class TestHover:
    def test_stationary_subject_predicts_hover(self):
        points = make_points([(i * 5.0, 0.2 * (i % 2), 0.1 * (i % 3)) for i in range(5)])
        prediction = predict_trajectory(
            "aircraft_asset", 7, points, BASE_TIME + timedelta(seconds=20),
        )
        assert prediction.quality == "ok"
        assert prediction.model_code == "hover"
        last = points[-1]
        for point in prediction.points:
            assert point.longitude == pytest.approx(last.longitude)
            assert point.latitude == pytest.approx(last.latitude)


class TestConstantTurn:
    def test_ct_follows_circle(self):
        speed, turn_dps, step = 20.0, 10.0, 5.0
        omega = radians(turn_dps)
        radius = speed / omega
        positions = []
        for i in range(5):
            t = i * step
            positions.append((t, radius * sin(omega * t), radius * (cos(omega * t) - 1)))
        points = make_points(positions)
        prediction = predict_trajectory(
            "airspace_target", 2, points, BASE_TIME + timedelta(seconds=20),
        )
        assert prediction.quality == "ok"
        assert prediction.model_code == "ct"
        assert prediction.turn_rate_dps == pytest.approx(turn_dps, abs=1.0)
        eta10 = next(p for p in prediction.points if p.eta_seconds == 10)
        east, north = to_east_north(eta10.longitude, eta10.latitude)
        expected_t = 20 + 10
        assert east == pytest.approx(radius * sin(omega * expected_t), abs=3.0)
        assert north == pytest.approx(radius * (cos(omega * expected_t) - 1), abs=3.0)


class TestInsufficientData:
    def test_too_few_points(self):
        prediction = predict_trajectory("airspace_target", 3, straight_line(count=2), BASE_TIME)
        assert prediction.quality == "insufficient_data"
        assert prediction.reason == "not_enough_points"
        assert prediction.points == []

    def test_window_span_too_short(self):
        points = make_points([(0.0, 0.0, 0.0), (1.0, 20.0, 0.0), (2.0, 40.0, 0.0)])
        prediction = predict_trajectory("airspace_target", 3, points, BASE_TIME + timedelta(seconds=2))
        assert prediction.quality == "insufficient_data"
        assert prediction.reason == "window_span_too_short"

    def test_unrealistic_speed_rejected(self):
        points = make_points([(0.0, 0.0, 0.0), (5.0, 0.0, 0.0), (10.0, 10000.0, 0.0)])
        prediction = predict_trajectory(
            "airspace_target", 3, points, BASE_TIME + timedelta(seconds=10),
        )
        assert prediction.quality == "insufficient_data"
        assert prediction.reason == "unrealistic_speed"

    def test_empty_input(self):
        prediction = predict_trajectory("airspace_target", 3, [], BASE_TIME)
        assert prediction.quality == "insufficient_data"


class TestWindowAndHeight:
    def test_window_trims_old_points(self):
        config = PredictionConfig(window_seconds=10)
        points = straight_line(count=11, step=2.0)
        window = prepare_window(points, config)
        assert len(window) == 6
        assert window[0].observed_at == BASE_TIME + timedelta(seconds=10)

    def test_height_extrapolated_with_vertical_speed(self):
        base = straight_line()
        points = [
            point.model_copy(update={"height_amsl_m": 100.0 + 2.0 * i * 5.0})
            for i, point in enumerate(base)
        ]
        prediction = predict_trajectory(
            "airspace_target", 4, points, BASE_TIME + timedelta(seconds=20),
        )
        assert prediction.quality == "ok"
        eta60 = next(p for p in prediction.points if p.eta_seconds == 60)
        assert eta60.height_amsl_m == pytest.approx(140.0 + 2.0 * 60, abs=1.0)

    def test_missing_height_keeps_height_empty(self):
        prediction = predict_trajectory(
            "airspace_target", 4, straight_line(), BASE_TIME + timedelta(seconds=20),
        )
        assert all(p.height_amsl_m is None for p in prediction.points)
