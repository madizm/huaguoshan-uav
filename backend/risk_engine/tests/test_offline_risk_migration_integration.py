"""Opt-in PostgreSQL regressions. Every migration and fixture write is rolled back."""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
from uuid import uuid4

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
import pytest

from backend.risk_engine.domain import RiskAssessment
from backend.risk_engine.detection_adapter import fetch_observation, fetch_pending_observations
from backend.risk_engine.worker import process_batch
from backend.risk_engine.persistence import persist_assessment

ROOT = Path(__file__).resolve().parents[3]
MIGRATION = (ROOT / "backend/migrate_target_risk_offline_events.sql").read_text()
DATABASE_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DATABASE_URL, reason="TEST_DATABASE_URL is not configured")


@pytest.fixture
def db():
    # Never use autocommit: execute the actual migration body in this outer transaction.
    with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:
        try:
            yield conn
        finally:
            conn.rollback()


def migrate(db):
    lines = MIGRATION.splitlines()
    assert sum(line == "begin;" for line in lines) == 1
    assert sum(line == "commit;" for line in lines) == 1
    db.execute("\n".join(line for line in lines if line not in {"begin;", "commit;"}))


def ingest(db, target, at, event="snapshot", coords=False):
    payload = {
        "schemaVersion": 1, "sourceSystem": "radar_cloud", "stationId": "90",
        "sourceObservationId": f"offline-risk-{uuid4().hex}", "sourceTargetId": target,
        "sourceTypeCode": 20, "detectionMethodCode": "radio_detection",
        "eventType": event, "observedAt": at.isoformat(), "receivedAt": at.isoformat(),
        "qualityFlags": ["integration_test"], "rawPayload": {"test": "offline_risk"},
    }
    if coords:
        payload.update(longitude=119.19, latitude=34.59)
    return db.execute("select situation.ingest_target_observation(%s) result", (Jsonb(payload),)).fetchone()["result"]


class SyncDatabase:
    """Use the production async persistence SQL within the rollback connection."""
    def __init__(self, conn):
        self.conn = conn

    async def execute(self, query, params=()):
        return AsyncCursor(self.conn.execute(query, params))


class AsyncCursor:
    def __init__(self, cursor):
        self.cursor = cursor

    async def fetchone(self):
        return self.cursor.fetchone()

    async def fetchall(self):
        return self.cursor.fetchall()


def assess(db, observation, at, status="target_location_unavailable", risk_level="none", risk_score=0):
    asyncio.run(persist_assessment(SyncDatabase(db), RiskAssessment(
        track_id=observation["trackId"], observation_id=observation["observationId"],
        observed_at=at, assessed_at=at, status=status, risk_level=risk_level, risk_score=risk_score,
    ), {"test": "offline-risk"}))


def risk(db, track):
    return db.execute("select event_response.risk_assessment_json(%s) risk", (track,)).fetchone()["risk"]


def snapshot(db, table):
    # All evidence is compared, not just counts; immutable history must remain byte-for-byte equal.
    return db.execute(f"select jsonb_agg(to_jsonb(t) order by id) as data from {table} t").fetchone()["data"]


@pytest.mark.parametrize("latest_has_location", [False, True])
def test_repair_latest_real_observation_pending_idempotency_and_late_guard(db, latest_has_location):
    at = datetime.now(timezone.utc) - timedelta(minutes=5)
    target = f"offline-repair-{uuid4().hex}"
    late = ingest(db, target, at - timedelta(seconds=10))
    old = ingest(db, target, at, coords=True)
    assess(db, old, at, "outside_protected_objects")
    # Tie on observed_at: the larger observation ID wins, even without coordinates.
    latest = ingest(db, target, at, coords=latest_has_location)
    if latest_has_location:
        assess(db, latest, at, "assessed", "high", 75)
    else:
        assess(db, latest, at)
    offline = ingest(db, target, at + timedelta(seconds=30), "offline_remove")
    assess(db, offline, at + timedelta(seconds=30))
    track = latest["trackId"]
    assert risk(db, track)["observationId"] == offline["observationId"]

    pending_target = f"offline-pending-{uuid4().hex}"
    ingest(db, pending_target, at)
    pending_offline = ingest(db, pending_target, at + timedelta(seconds=30), "offline_remove")
    assess(db, pending_offline, at + timedelta(seconds=30))
    pending_track = pending_offline["trackId"]

    untouched_target = f"offline-untouched-{uuid4().hex}"
    untouched = ingest(db, untouched_target, at)
    assess(db, untouched, at)
    late_offline = ingest(db, untouched_target, at - timedelta(seconds=1), "offline_remove")
    assess(db, late_offline, at - timedelta(seconds=1))
    untouched_before = risk(db, untouched["trackId"])
    history_before = snapshot(db, "event_response.target_risk_assessment")
    raw_before = snapshot(db, "equipment.raw_observation")
    cursor = db.execute("select coalesce(max(id),0) id from situation.change_event").fetchone()["id"]

    migrate(db)
    repaired = risk(db, track)
    assert repaired["observationId"] == latest["observationId"]
    if latest_has_location:
        assert (repaired["status"], repaired["riskLevel"], repaired["riskScore"]) == ("assessed", "high", 75)
    else:
        assert repaired["status"] == "target_location_unavailable"
    assert risk(db, pending_track) == {"status": "pending"}
    assert risk(db, untouched["trackId"]) == untouched_before
    detail = db.execute("select api.get_target_track_detail(%s,%s,%s,100) result",
                        (track, at - timedelta(seconds=11), at + timedelta(seconds=31))).fetchone()["result"]
    assert detail["track"]["riskAssessment"] == repaired
    assert detail["track"]["status"] == "closed"
    assert detail["evidence"]["returned_count"] == 4
    assert detail["observations"][-1]["observation_id"] == offline["observationId"]
    assert detail["observations"][-1]["target_location"] is None
    assert snapshot(db, "event_response.target_risk_assessment") == history_before
    assert snapshot(db, "equipment.raw_observation") == raw_before
    events = db.execute("""select * from situation.change_event
        where id>%s and event_type='risk_changed' and aggregate_id=any(%s) order by id""",
        (cursor, [track, pending_track])).fetchall()
    assert len(events) == 2
    changes = db.execute("select api.get_detection_situation_changes(%s,null,1000) result",
                         (cursor,)).fetchone()["result"]["changes"]
    repaired_changes = [change for change in changes
                        if change["type"] == "risk_changed" and change["aggregate_id"] in {track, pending_track}]
    assert len(repaired_changes) == 2
    for change in repaired_changes:
        assert change["riskAssessment"] == risk(db, change["aggregate_id"])
    assert events[0]["occurred_at"] == events[1]["occurred_at"]
    for event in events:
        payload = event["payload"]
        assert payload["risk_assessment"] == risk(db, event["aggregate_id"])
        assert payload["previous_status"] == "target_location_unavailable"
        assert payload["status"] == payload["risk_assessment"]["status"]
        if event["aggregate_id"] == pending_track:
            assert payload["observation_id"] is None
            assert payload["assessment_id"] is None
            assert payload["risk_level"] is None
        else:
            assert payload["observation_id"] == latest["observationId"]
            assert payload["risk_level"] == repaired["riskLevel"]
    current_before = db.execute("select to_jsonb(c) as data from event_response.target_risk_current c order by track_id").fetchall()
    changes_before = snapshot(db, "situation.change_event")
    migrate(db)
    assert snapshot(db, "situation.change_event") == changes_before
    assert db.execute("select to_jsonb(c) as data from event_response.target_risk_current c order by track_id").fetchall() == current_before

    # Evaluating an older real observation after repair must not overwrite that repair.
    assess(db, late, at - timedelta(seconds=10), "outside_protected_objects")
    assert risk(db, track) == repaired
    assert db.execute("select count(*) n from event_response.target_risk_assessment where track_id=%s",
                      (track,)).fetchone()["n"] == 4
    assert snapshot(db, "situation.change_event") == changes_before


def test_monitoring_excludes_offline_for_cursor_and_missing_assessment(db):
    migrate(db)
    at = datetime.now(timezone.utc) - timedelta(minutes=1)
    worker = f"offline-monitor-{uuid4().hex}"
    start = db.execute("select coalesce(max(id),0) id from equipment.raw_observation").fetchone()["id"]
    db.execute("insert into event_response.risk_worker_cursor(worker_name,last_observation_id) values(%s,%s)", (worker, start))
    target = f"offline-backlog-{uuid4().hex}"
    real = ingest(db, target, at)
    offline = ingest(db, target, at + timedelta(seconds=1), "offline_remove")

    def check(cursor):
        db.execute("update event_response.risk_worker_cursor set last_observation_id=%s where worker_name=%s", (cursor, worker))
        result = db.execute("select api.get_risk_engine_status(%s) result", (worker,)).fetchone()["result"]["backlog"]
        expected = db.execute("""select r.id, r.id>%s cursor_pending, a.id assessment_id
            from situation.track_observation tr
            join equipment.raw_observation r on r.id=tr.observation_id
            join situation.target_observation o on o.observation_id=r.id
            left join event_response.target_risk_assessment a on a.observation_id=r.id
            where r.observation_type <> 'detection_offline_remove' and (r.id>%s or a.id is null)
            order by r.id limit 10001""", (cursor, cursor)).fetchall()
        assert result["pendingCount"] == min(len(expected), 10000)
        assert result["cursorPendingCount"] == sum(row["cursor_pending"] for row in expected)
        assert result["repairPendingCount"] == sum(not row["cursor_pending"] and row["assessment_id"] is None for row in expected)
        assert all(row["id"] != offline["observationId"] for row in expected)

    check(start)  # offline above cursor, without an assessment
    check(offline["observationId"])  # offline below cursor, still without assessment
    assess(db, real, at)
    assess(db, offline, at + timedelta(seconds=1))
    check(start)  # offline above cursor, with an immutable legacy assessment


@pytest.mark.parametrize("offline_has_location", [False, True])
def test_worker_ignores_offline_above_and_below_cursor_but_assesses_real_missing_location(db, offline_has_location):
    at = datetime.now(timezone.utc) - timedelta(minutes=1)
    target = f"offline-worker-{uuid4().hex}"
    real = ingest(db, target, at, coords=True)
    asyncio.run(persist_assessment(SyncDatabase(db), RiskAssessment(
        track_id=real["trackId"], observation_id=real["observationId"],
        observed_at=at, assessed_at=at, status="assessed", risk_level="high", risk_score=75,
    ), {}))
    offline = ingest(db, target, at + timedelta(seconds=1), "offline_remove", coords=offline_has_location)
    conn = SyncDatabase(db)
    offline_row = asyncio.run(fetch_observation(conn, offline["observationId"]))
    assert offline_row is None  # Lifecycle events are excluded at the read boundary.
    rows = asyncio.run(fetch_pending_observations(conn, real["observationId"], 5000))
    assert offline["observationId"] not in {row["observation_id"] for row in rows}
    # The missing-history OR branch must not bring this lifecycle event back.
    rows = asyncio.run(fetch_pending_observations(conn, offline["observationId"], 5000))
    assert offline["observationId"] not in {row["observation_id"] for row in rows}

    worker = f"offline-worker-{uuid4().hex}"
    db.execute("insert into event_response.risk_worker_cursor(worker_name,last_observation_id) values(%s,%s)",
               (worker, real["observationId"]))
    assert asyncio.run(process_batch(conn, worker, 100)) == 0
    assert risk(db, real["trackId"])["riskScore"] == 75
    assert risk(db, real["trackId"])["observationId"] == real["observationId"]

    other_target = f"missing-worker-{uuid4().hex}"
    positioned = ingest(db, other_target, at + timedelta(seconds=2), coords=True)
    assess(db, positioned, at + timedelta(seconds=2), "assessed", "high", 75)
    db.execute("update event_response.risk_worker_cursor set last_observation_id=%s where worker_name=%s",
               (positioned["observationId"], worker))
    missing = ingest(db, other_target, at + timedelta(seconds=3))
    assert missing["trackId"] == positioned["trackId"]
    assert risk(db, missing["trackId"])["riskScore"] == 75
    assert asyncio.run(process_batch(conn, worker, 100)) == 1
    assert risk(db, missing["trackId"])["status"] == "target_location_unavailable"
    assert risk(db, real["trackId"])["riskScore"] == 75
    assert db.execute("select count(*) n from event_response.target_risk_assessment where observation_id=%s",
                      (offline["observationId"],)).fetchone()["n"] == 0
    assert asyncio.run(process_batch(conn, worker, 100)) == 0


def test_coordinate_bearing_stale_offline_event_is_not_trajectory_evidence(db):
    at = datetime.now(timezone.utc) - timedelta(minutes=1)
    target = f"offline-trajectory-{uuid4().hex}"
    first = ingest(db, target, at, coords=True)
    assess(db, first, at, "assessed", "high", 75)
    second = ingest(db, target, at + timedelta(seconds=10), coords=True)
    assess(db, second, at + timedelta(seconds=10), "assessed", "high", 75)
    # A stale removal is linked to the active track but must not become scoring evidence.
    offline = ingest(db, target, at + timedelta(seconds=5), "offline_remove", coords=True)
    latest = ingest(db, target, at + timedelta(seconds=20), coords=True)
    assert first["trackId"] == second["trackId"] == offline["trackId"] == latest["trackId"]
    conn = SyncDatabase(db)
    row = asyncio.run(fetch_observation(conn, latest["observationId"]))
    expected_ids = [first["observationId"], second["observationId"], latest["observationId"]]
    assert [point["observation_id"] for point in row["trajectory"]] == expected_ids
    pending = asyncio.run(fetch_pending_observations(conn, offline["observationId"], 5000))
    latest_row = next(row for row in pending if row["observation_id"] == latest["observationId"])
    assert [point["observation_id"] for point in latest_row["trajectory"]] == expected_ids
