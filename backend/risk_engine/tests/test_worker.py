import asyncio
from datetime import datetime, timezone

import backend.risk_engine.worker as worker
from backend.risk_engine.domain import RuleSet


def test_batch_persists_failed_observation_and_advances_cursor(monkeypatch):
    rows = [{
        "track_id": 7,
        "observation_id": 42,
        "observed_at": datetime(2026, 9, 25, tzinfo=timezone.utc),
        "longitude": 119.2,
        "latitude": 34.6,
        "speed_mps": 1,
        "identity_status": b"unsupported",
    }]
    persisted = []
    cursors = []
    runtime_events = []

    async def fake_lock(conn, worker_name):
        return 10

    async def fake_fetch(conn, after_id, batch_size):
        return rows

    async def fake_config(conn):
        return [], RuleSet(id=9, version=2, scores={})

    async def fake_persist(conn, result, snapshot):
        persisted.append((result, snapshot))

    async def fake_update(conn, worker_name, observation_id):
        cursors.append(observation_id)

    async def fake_started(conn, worker_name):
        runtime_events.append(("started", worker_name))

    async def fake_success(conn, worker_name, batch_size, failed_count, duration_ms):
        runtime_events.append(("success", worker_name, batch_size, failed_count, duration_ms))

    monkeypatch.setattr(worker, "lock_worker_cursor", fake_lock)
    monkeypatch.setattr(worker, "fetch_pending_observations", fake_fetch)
    monkeypatch.setattr(worker, "fetch_published_configuration", fake_config)
    monkeypatch.setattr(worker, "persist_assessment", fake_persist)
    monkeypatch.setattr(worker, "update_worker_cursor", fake_update)
    monkeypatch.setattr(worker, "record_batch_started", fake_started)
    monkeypatch.setattr(worker, "record_batch_success", fake_success)

    count = asyncio.run(worker.process_batch(object(), "defense-assessment", 100))
    result, snapshot = persisted[0]
    assert count == 1
    assert result.status == "failed"
    assert result.reason == "assessment_error"
    assert result.rule_set_id == 9
    assert snapshot["errorType"] == "ValidationError"
    assert cursors == [42]
    assert runtime_events[0] == ("started", "defense-assessment")
    assert runtime_events[1][:4] == ("success", "defense-assessment", 1, 1)


def test_empty_batch_records_idle_heartbeat(monkeypatch):
    events = []

    async def fake_lock(conn, worker_name):
        return 42

    async def fake_fetch(conn, after_id, batch_size):
        return []

    async def fake_idle(conn, worker_name):
        events.append(worker_name)

    monkeypatch.setattr(worker, "lock_worker_cursor", fake_lock)
    monkeypatch.setattr(worker, "fetch_pending_observations", fake_fetch)
    monkeypatch.setattr(worker, "record_worker_idle", fake_idle)

    count = asyncio.run(worker.process_batch(object(), "defense-assessment", 100))
    assert count == 0
    assert events == ["defense-assessment"]
