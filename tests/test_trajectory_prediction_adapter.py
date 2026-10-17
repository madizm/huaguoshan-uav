"""Persistence contract tests; no live database required."""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest

from backend.prediction.adapter import _prediction_params, persist_predictions
from backend.prediction.domain import PredictedPoint, Prediction


def make_prediction(**kwargs):
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    return Prediction(
        subject_kind="airspace_target", subject_id=1,
        base_observed_at=now, predicted_at=now, model_code="cv", quality="ok",
        horizon_seconds=120, step_seconds=5, window_seconds=30, **kwargs,
    )


@pytest.mark.parametrize("policy,points", [
    ({}, []),
    ({"mode": "adaptive", "actual_horizon_seconds": 10, "remaining_horizon_seconds": 8,
      "stop_reason": "uncertainty_limit", "rule_version": 1,
      "thresholds": {"max_uncertainty_m": 100}, "metrics": {"residual_m": 2.5}},
     [PredictedPoint(eta_seconds=10, longitude=119, latitude=34, uncertainty_m=20)]),
    ({"mode": "adaptive", "actual_horizon_seconds": 0, "remaining_horizon_seconds": 0,
      "stop_reason": "insufficient_data", "rule_version": 1,
      "thresholds": {}, "metrics": {}}, []),
])
def test_policy_round_trips_as_json_without_changing_horizon_or_points(policy, points):
    prediction = make_prediction(horizon_policy=policy, points=points)
    params = _prediction_params(prediction)
    assert params[8] == 120
    assert json.loads(params[-3]) == [point.model_dump() for point in points]
    assert json.loads(params[-2]) == policy
    assert params[-1] is None  # fewer than two points have no LineString


def test_fixed_mode_defaults_to_empty_policy():
    prediction = make_prediction()
    assert prediction.horizon_policy == {}
    assert json.loads(_prediction_params(prediction)[-2]) == {}


def test_persistence_sql_binds_policy_as_jsonb_and_keeps_geometry_last():
    async def exercise():
        cursor = AsyncMock()
        cursor.fetchall.return_value = []
        conn = AsyncMock()
        conn.execute.return_value = cursor
        prediction = make_prediction(points=[
            PredictedPoint(eta_seconds=5, longitude=119, latitude=34, uncertainty_m=10),
            PredictedPoint(eta_seconds=10, longitude=119.1, latitude=34.1, uncertainty_m=20),
        ])
        assert await persist_predictions(conn, [prediction], 1, 24) == 1
        query, params = conn.execute.call_args_list[1].args
        assert "points,horizon_policy,geom" in query
        assert "%s::jsonb,%s::jsonb,%s::geometry" in query
        assert query.count("%s") == len(params)
        assert json.loads(params[-2]) == {}
        assert params[-1] == "SRID=4326;LINESTRING(119.0 34.0,119.1 34.1)"

    asyncio.run(exercise())
