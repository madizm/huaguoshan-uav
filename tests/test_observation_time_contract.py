"""Future-intake time contract. DB test uses only an explicitly supplied test DB."""
from __future__ import annotations

import asyncio
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import psycopg
import pytest
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from scripts.radar_cloud_connector import normalize_vendor_item
from backend.prediction.adapter import fetch_target_windows, fetch_asset_windows, evaluate_due_predictions
from backend.prediction.domain import ObservationPoint, PredictionConfig, prepare_window, predict_trajectory
from backend.risk_engine.detection_adapter import fetch_pending_observations, fetch_observation

NOW = datetime(2026, 9, 20, 10, tzinfo=timezone.utc)


def normalize(**fields):
    return normalize_vendor_item("uav_dashboard_snapshot", {
        "serial": "A", "stationId": 90, "sourceType": 10,
        "currentTime": "2026-09-20 17:59:58.123", "lastTime": "2026-09-20 17:00:00",
        "lng": 119.2, "lat": 34.6, **fields,
    }, "90", NOW)


def test_current_time_is_coordinate_time_and_takes_precedence_over_last_time():
    result = normalize()
    assert result["observedAt"] == "2026-09-20T09:59:58.123000+00:00"
    assert result["detectedAt"] == result["observedAt"]
    assert result["receivedAt"] == NOW.isoformat()
    assert result["positionTimeValid"] is True
    later = normalize_vendor_item("uav_online_upsert", result["rawPayload"], "90", NOW + timedelta(seconds=30))
    assert later["observedAt"] == result["observedAt"]
    assert later["qualityFlags"] == ["late_observation"]


@pytest.mark.parametrize("current_time", [None, "", "bad", 1719123456789, "0001-01-01T00:00:00"])
def test_explicit_invalid_current_time_does_not_fall_back_to_valid_last_time(current_time):
    result = normalize(currentTime=current_time)
    assert result["positionTimeValid"] is False
    assert "invalid_position_time" in result["qualityFlags"]
    assert result["rawPayload"]["currentTime"] == current_time
    # Required raw timestamp is only a storage fallback, not a motion timestamp.
    assert result["observedAt"] == result["receivedAt"]


@pytest.mark.parametrize("last_time", [None, "bad", "2026-09-20T10:00:01Z"])
def test_valid_current_time_is_not_rejected_by_invalid_or_future_last_time(last_time):
    result = normalize(lastTime=last_time)
    assert result["positionTimeValid"] is True
    assert result["observedAt"] == "2026-09-20T09:59:58.123000+00:00"
    assert result["qualityFlags"] == []


def test_snapshot_with_only_current_time_is_a_valid_position():
    item = normalize()["rawPayload"].copy()
    del item["lastTime"]
    result = normalize_vendor_item("uav_dashboard_snapshot", item, "90", NOW)
    assert result["positionTimeValid"] is True
    assert result["observedAt"] == "2026-09-20T09:59:58.123000+00:00"
    assert result["qualityFlags"] == []


@pytest.mark.parametrize("message_type", ["uav_online_upsert", "online_list_snapshot"])
@pytest.mark.parametrize("last_time", ["2026-09-20 17:59:58.123", None, "bad"])
def test_last_time_compatibility_when_current_time_is_absent(message_type, last_time):
    item = normalize(lastTime=last_time)["rawPayload"].copy()
    del item["currentTime"]
    result = normalize_vendor_item(message_type, item, "90", NOW)
    assert result["positionTimeValid"] is (last_time == "2026-09-20 17:59:58.123")
    assert result["detectedAt"] is None
    assert result["observedAt"] == (
        "2026-09-20T09:59:58.123000+00:00" if result["positionTimeValid"] else NOW.isoformat()
    )


def test_future_is_not_lateness_and_offline_is_not_motion():
    result = normalize(currentTime="2026-09-20T10:00:00.001Z")
    assert result["qualityFlags"] == ["future_source_time"]
    assert not result["positionTimeValid"]
    result = normalize_vendor_item("uav_online_remove", normalize()["rawPayload"], "90", NOW)
    assert result["observedAt"] == NOW.isoformat()
    assert result["longitude"] is None
    assert result["latitude"] is None
    assert not result["positionTimeValid"]
    assert "lifecycle_event" in result["qualityFlags"]


def test_prediction_deduplicates_physical_measurements_not_ingestion_ids():
    points = [ObservationPoint(observation_id=i, observed_at=NOW, longitude=119.2, latitude=34.6)
              for i in range(1, 5)]
    assert len(prepare_window(points, PredictionConfig())) == 1
    future = ObservationPoint(observation_id=5, observed_at=NOW + timedelta(days=1), longitude=120, latitude=35)
    prediction = predict_trajectory("airspace_target", 1, points + [future], NOW)
    assert prediction.window_point_count == 1
    assert prediction.base_observed_at == NOW
    assert prediction.quality == "insufficient_data"


def test_risk_confirmation_does_not_count_snapshot_copies_as_independent_evidence():
    from backend.risk_engine.domain import (
        ProtectedObjectInput, RuleSet, TargetInput, TrajectoryPoint, _trajectory_state,
    )
    copies = [TrajectoryPoint(observation_id=i, observed_at=NOW - timedelta(seconds=10),
                              longitude=119.201, latitude=34.6) for i in range(1, 5)]
    target = TargetInput(track_id=1, observation_id=5, observed_at=NOW,
                         longitude=119.2, latitude=34.6, trajectory=copies)
    obj = ProtectedObjectInput(id=1, name="test", longitude=119.19, latitude=34.6, version=1, rings=[])
    assert not _trajectory_state(target, obj, RuleSet(version=1, scores={})).available


class FakeConnection:
    def __init__(self):
        self.queries = []

    async def execute(self, query, params=()):
        self.queries.append(query)
        return self

    async def fetchall(self):
        return []

    async def fetchone(self):
        return None


def test_all_motion_read_paths_share_validity_filter_including_evaluation():
    async def exercise():
        conn = FakeConnection()
        await fetch_target_windows(conn, 30, 120, 100, 100)
        await fetch_asset_windows(conn, 30, 120, 100, 100)
        await evaluate_due_predictions(conn, 24)
        await fetch_pending_observations(conn, 0)
        await fetch_observation(conn, 1)
        for query in conn.queries:
            assert "situation.position_time_valid(" in query
            assert "observed_at<=now()" in query
        assert "distinct on (r.observed_at)" in conn.queries[0]
        assert "dr.asset_id=r.asset_id and dr.geom is not distinct from r.geom" in conn.queries[3]
    asyncio.run(exercise())


@pytest.mark.skipif(not os.environ.get("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL is not configured")
def test_ingestion_watermarks_liveness_and_adapters_in_database():
    async def exercise():
        async with await psycopg.AsyncConnection.connect(os.environ["TEST_DATABASE_URL"], row_factory=dict_row) as conn:
            try:
                now = datetime.now(timezone.utc)
                observed = now - timedelta(seconds=10)
                serial = "time-contract-" + uuid4().hex

                async def ingest(key, **changes):
                    payload = {
                        "schemaVersion": 1, "sourceSystem": "radar_cloud", "stationId": "90",
                        "sourceObservationId": serial + key, "sourceTargetId": serial,
                        "sourceTypeCode": 10, "eventType": "snapshot", "rawPayload": {},
                        "observedAt": observed.isoformat(), "receivedAt": now.isoformat(),
                        "longitude": 119.2, "latitude": 34.6, "qualityFlags": [], **changes,
                    }
                    cursor = await conn.execute("select situation.ingest_target_observation(%s) result", (Jsonb(payload),))
                    return (await cursor.fetchone())["result"]

                first = await ingest("first")
                track_id = first["trackId"]
                await conn.execute("insert into event_response.risk_worker_cursor(worker_name,last_observation_id) values(%s,0)", (serial,))
                cursor = await conn.execute("select api.get_risk_engine_status(%s) status", (serial,))
                pending_before = (await cursor.fetchone())["status"]["backlog"]["pendingCount"]
                duplicate = await ingest("repeat")  # Different intake ID, same physical sample.
                cursor = await conn.execute("select api.get_risk_engine_status(%s) status", (serial,))
                assert (await cursor.fetchone())["status"]["backlog"]["pendingCount"] == pending_before
                await ingest("first", receivedAt=(now + timedelta(seconds=1)).isoformat())
                missing = await ingest("missing", observedAt=(observed + timedelta(seconds=2)).isoformat(),
                                       positionTimeValid=False, qualityFlags=["invalid_position_time"])
                future = await ingest("future", observedAt=(now + timedelta(days=1)).isoformat())
                assert missing["trackId"] is None and future["trackId"] is None
                cursor = await conn.execute("select * from situation.target_track where id=%s", (track_id,))
                track = await cursor.fetchone()
                assert track["last_observed_at"] == observed
                assert track["current_observation_id"] == first["observationId"]
                cursor = await conn.execute("select * from situation.source_target_session where id=%s", (track["source_session_id"],))
                session = await cursor.fetchone()
                assert session["last_received_at"] > observed
                windows = dict(await fetch_target_windows(conn, 30, 120, 100, 10000))
                assert len(windows[track_id]) == 1
                assert await fetch_observation(conn, duplicate["observationId"]) is None
                assert (await fetch_observation(conn, first["observationId"]))["observed_at"] == observed
                # A non-spatial update must not move the position watermark.
                await ingest("nonspatial", observedAt=(observed + timedelta(seconds=1)).isoformat(), longitude=None, latitude=None)
                cursor = await conn.execute("select last_observed_at from situation.target_track where id=%s", (track_id,))
                assert (await cursor.fetchone())["last_observed_at"] == observed
                await ingest("offline", eventType="offline_remove", observedAt=now.isoformat())
                cursor = await conn.execute("select status,last_observed_at from situation.target_track where id=%s", (track_id,))
                assert await cursor.fetchone() == {"status": "closed", "last_observed_at": observed}
                # Emulate previously linked invalid-time evidence. It is closer to
                # the checkpoint than the real position, but must not be matched.
                await conn.execute("insert into situation.track_observation(track_id,observation_id,association_method) values(%s,%s,'source_session')",
                                   (track_id, missing["observationId"]))
                cursor = await conn.execute("select asset_id from equipment.raw_observation where id=%s", (first["observationId"],))
                asset_id = (await cursor.fetchone())["asset_id"]
                for kind, subject_id in [("airspace_target", track_id), ("aircraft_asset", asset_id)]:
                    cursor = await conn.execute("""
                        insert into situation.trajectory_prediction(
                          subject_kind,subject_id,base_observed_at,predicted_at,model_code,model_version,
                          quality,horizon_seconds,step_seconds,window_seconds,window_point_count,points
                        ) values(%s,%s,%s,%s,'cv',1,'ok',10,10,20,3,%s) returning id
                    """, (kind, subject_id, observed - timedelta(seconds=8), now,
                          Jsonb([{"eta_seconds": 10, "longitude": 119.2, "latitude": 34.6, "uncertainty_m": 10}])))
                    prediction_id = (await cursor.fetchone())["id"]
                    await evaluate_due_predictions(conn, 24)
                    cursor = await conn.execute("select actual_observed_at from situation.trajectory_prediction_evaluation where prediction_id=%s", (prediction_id,))
                    assert (await cursor.fetchone())["actual_observed_at"] == observed
                assert await evaluate_due_predictions(conn, 24) == 0
                # Legacy normal payloads (without positionTimeValid) are supported.
                cursor = await conn.execute("select situation.position_time_valid(%s,%s,'detection_snapshot','{}') valid", (observed, now))
                assert (await cursor.fetchone())["valid"] is True
            finally:
                await conn.rollback()
    asyncio.run(exercise())


@pytest.mark.skipif(not os.environ.get("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL is not configured")
@pytest.mark.parametrize("apply_migration", [False, True], ids=["source", "migration"])
@pytest.mark.parametrize("nonspatial_first", [False, True], ids=["spatial", "nonspatial-then-spatial"])
def test_legacy_future_watermarks_recover_only_on_valid_intake(apply_migration, nonspatial_first):
    async def exercise():
        async with await psycopg.AsyncConnection.connect(os.environ["TEST_DATABASE_URL"], row_factory=dict_row) as conn:
            try:
                now = datetime.now(timezone.utc)
                observed = now - timedelta(seconds=10)
                future = now + timedelta(days=1)
                serial = "future-recovery-" + uuid4().hex

                async def ingest(key, at=observed, **changes):
                    payload = {
                        "schemaVersion": 1, "sourceSystem": "radar_cloud", "stationId": "90",
                        "sourceObservationId": serial + key, "sourceTargetId": serial,
                        "sourceTypeCode": 10, "eventType": "snapshot", "rawPayload": {"test": key},
                        "observedAt": at.isoformat(), "receivedAt": now.isoformat(),
                        "longitude": 119.2, "latitude": 34.6, "qualityFlags": [], **changes,
                    }
                    cursor = await conn.execute("select situation.ingest_target_observation(%s) result", (Jsonb(payload),))
                    return (await cursor.fetchone())["result"]

                first = await ingest("first", observed - timedelta(seconds=1))
                bad = await ingest("legacy-future", future)
                track_id, target_id = first["trackId"], first["targetId"]
                cursor = await conn.execute("select source_session_id from situation.target_track where id=%s", (track_id,))
                session_id = (await cursor.fetchone())["source_session_id"]
                # Emulate state left by the old intake; immutable evidence stays untouched.
                for table, row_id in [("source_target_session", session_id), ("target_track", track_id)]:
                    await conn.execute(f"update situation.{table} set last_observed_at=%s,current_observation_id=%s where id=%s",
                                       (future, bad["observationId"], row_id))
                await conn.execute("update situation.airspace_target set last_observed_at=%s where id=%s", (future, target_id))

                async def state(table, row_id):
                    cursor = await conn.execute(f"select * from situation.{table} where id=%s", (row_id,))
                    return await cursor.fetchone()

                async def evidence():
                    cursor = await conn.execute("""
                        select to_jsonb(r) evidence from equipment.raw_observation r
                        where id=any(%s) order by id
                    """, ([first["observationId"], bad["observationId"]],))
                    return await cursor.fetchall()

                raw_before = await evidence()
                if apply_migration:
                    migration = (Path(__file__).resolve().parents[1] / "backend/migrate_detection_observation_time.sql").read_text()
                    # Keep migration DDL and all fixtures in the rollback transaction.
                    await conn.execute("\n".join(line for line in migration.splitlines() if line not in {"begin;", "commit;"}))
                for table, row_id in [("source_target_session", session_id), ("target_track", track_id), ("airspace_target", target_id)]:
                    assert (await state(table, row_id))["last_observed_at"] == future

                # Invalid-time intake cannot repair state, even when it has coordinates.
                invalid = await ingest("invalid", positionTimeValid=False, qualityFlags=["invalid_position_time"])
                assert invalid["trackId"] is None
                assert (await state("target_track", track_id))["current_observation_id"] == bad["observationId"]
                if nonspatial_first:
                    nonspatial = await ingest("nonspatial", observed + timedelta(seconds=1), longitude=None, latitude=None)
                    session = await state("source_target_session", session_id)
                    assert session["last_observed_at"] == observed + timedelta(seconds=1)
                    assert session["current_observation_id"] == nonspatial["observationId"]
                    assert (await state("airspace_target", target_id))["last_observed_at"] == observed + timedelta(seconds=1)
                    track = await state("target_track", track_id)
                    assert track["last_observed_at"] == future
                    assert track["current_observation_id"] == bad["observationId"]

                # Arrival order need not be physical-time order. The next real
                # position can precede the non-spatial sample and must still
                # replace the old future position, without rewinding the session.
                position_at = observed if nonspatial_first else observed + timedelta(seconds=2)
                valid = await ingest("valid", position_at)
                assert valid["trackId"] == track_id and valid["targetId"] == target_id
                track = await state("target_track", track_id)
                assert track["last_observed_at"] == position_at
                assert track["current_observation_id"] == valid["observationId"]
                session_at = observed + timedelta(seconds=1) if nonspatial_first else position_at
                session_pointer = nonspatial["observationId"] if nonspatial_first else valid["observationId"]
                session = await state("source_target_session", session_id)
                assert session["last_observed_at"] == session_at
                assert session["current_observation_id"] == session_pointer
                assert (await state("airspace_target", target_id))["last_observed_at"] == session_at
                # Recovery does not weaken the ordinary late-arrival guard.
                await ingest("late", observed - timedelta(seconds=1))
                assert (await state("target_track", track_id))["current_observation_id"] == valid["observationId"]
                assert (await state("source_target_session", session_id))["current_observation_id"] == session_pointer
                assert await evidence() == raw_before
            finally:
                await conn.rollback()
    asyncio.run(exercise())
