from __future__ import annotations

import asyncio
import os
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import psycopg
import pytest
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from backend.risk_engine.detection_adapter import fetch_published_configuration
from backend.risk_engine.domain import RiskAssessment, TargetInput, assess_target
from backend.risk_engine.persistence import persist_assessment


DATABASE_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DATABASE_URL, reason="TEST_DATABASE_URL is not configured")


async def _ingest(conn, source_observation_id: str, source_target_id: str, observed_at: datetime):
    payload = {
        "schemaVersion": 1,
        "sourceSystem": "radar_cloud",
        "stationId": "90",
        "sourceObservationId": source_observation_id,
        "sourceTargetId": source_target_id,
        "sourceTypeCode": 20,
        "detectionMethodCode": "radio_detection",
        "eventType": "snapshot",
        "observedAt": observed_at.isoformat(),
        "receivedAt": datetime.now(timezone.utc).isoformat(),
        "qualityFlags": ["integration_test"],
        "rawPayload": {"test": "risk_engine"},
    }
    cursor = await conn.execute(
        "select situation.ingest_target_observation(%s::jsonb) result",
        (Jsonb(payload),),
    )
    return (await cursor.fetchone())["result"]


async def _exercise_database_contract():
    async with await psycopg.AsyncConnection.connect(DATABASE_URL, row_factory=dict_row) as conn:
        try:
            cursor = await conn.execute("select coalesce(max(id),0) change_cursor from situation.change_event")
            change_cursor = (await cursor.fetchone())["change_cursor"]
            suffix = uuid4().hex
            target_id = f"risk-it-{suffix}"
            older_at = datetime.now(timezone.utc) - timedelta(minutes=2)
            newer_at = older_at + timedelta(minutes=1)
            older = await _ingest(conn, f"risk-old-{suffix}", target_id, older_at)
            newer = await _ingest(conn, f"risk-new-{suffix}", target_id, newer_at)
            assert older["trackId"] == newer["trackId"]

            protected_objects, rules = await fetch_published_configuration(conn)
            newer_result = assess_target(TargetInput(
                track_id=newer["trackId"], observation_id=newer["observationId"],
                observed_at=newer_at, longitude=None, latitude=None,
            ), protected_objects, rules, newer_at)
            older_result = assess_target(TargetInput(
                track_id=older["trackId"], observation_id=older["observationId"],
                observed_at=older_at, longitude=None, latitude=None,
            ), protected_objects, rules, older_at)

            await persist_assessment(conn, newer_result, {"integrationTest": True})
            await persist_assessment(conn, newer_result, {"integrationTest": True})
            await persist_assessment(conn, older_result, {"integrationTest": True})

            cursor = await conn.execute(
                """select count(*) history_count,
                  (select observation_id from event_response.target_risk_current where track_id=%s) current_observation_id,
                  (select count(*) from situation.change_event where event_type='risk_changed' and aggregate_id=%s) risk_changes
                from event_response.target_risk_assessment where track_id=%s""",
                (newer["trackId"], newer["trackId"], newer["trackId"]),
            )
            state = await cursor.fetchone()
            assert state == {
                "history_count": 2,
                "current_observation_id": newer["observationId"],
                "risk_changes": 1,
            }

            cursor = await conn.execute(
                "select event_response.risk_assessment_json(%s) risk",
                (newer["trackId"],),
            )
            assert (await cursor.fetchone())["risk"]["status"] == "target_location_unavailable"

            cursor = await conn.execute(
                "select api.list_target_risk_assessments(%s,%s,%s,10) history",
                (newer["trackId"], older_at - timedelta(seconds=1), newer_at + timedelta(seconds=1)),
            )
            history = (await cursor.fetchone())["history"]
            assert [item["observationId"] for item in history["assessments"]] == [
                older["observationId"], newer["observationId"],
            ]

            failed_at = newer_at + timedelta(seconds=30)
            failed_observation = await _ingest(conn, f"risk-failed-{suffix}", target_id, failed_at)
            await persist_assessment(conn, RiskAssessment(
                status="failed", track_id=newer["trackId"],
                observation_id=failed_observation["observationId"], observed_at=failed_at,
                assessed_at=failed_at, rule_set_id=rules.id, rule_version=rules.version,
                reason="integration_test_failure",
            ), {"integrationTest": True})

            cursor = await conn.execute(
                "select api.get_detection_live_tracks_v3(null,null,null,600,300,100,100) result"
            )
            live = (await cursor.fetchone())["result"]
            live_track = next(item for item in live["tracks"] if item["track_id"] == newer["trackId"])
            assert live_track["riskAssessment"]["status"] == "failed"

            cursor = await conn.execute(
                "select api.get_detection_situation_changes(%s,null,100) result",
                (change_cursor,),
            )
            changes = (await cursor.fetchone())["result"]["changes"]
            risk_changes = [item for item in changes if item["type"] == "risk_changed"]
            assert [item["riskAssessment"]["status"] for item in risk_changes] == [
                "target_location_unavailable", "failed",
            ]
            assert all(item["aggregate_id"] == newer["trackId"] for item in risk_changes)

            cursor = await conn.execute(
                "select api.list_detection_target_tracks(%s,%s,null,null,100) result",
                (older_at - timedelta(seconds=1), failed_at + timedelta(seconds=1)),
            )
            tracks = (await cursor.fetchone())["result"]["tracks"]
            summary = next(item for item in tracks if item["track_id"] == newer["trackId"])
            assert summary["riskAssessment"]["status"] == "failed"

            cursor = await conn.execute(
                "select api.get_target_track_detail(%s,%s,%s,100) result",
                (newer["trackId"], older_at - timedelta(seconds=1), failed_at + timedelta(seconds=1)),
            )
            detail = (await cursor.fetchone())["result"]
            assert detail["track"]["riskAssessment"]["status"] == "failed"
            assert detail["track"]["riskAssessment"]["status"] == "failed"
            observation_risks = [item["riskAssessment"] for item in detail["observations"]]
            assert [item["status"] for item in observation_risks] == [
                "target_location_unavailable", "target_location_unavailable", "failed",
            ]
            assert set(observation_risks[-1]) == {"status", "riskLevel", "riskScore"}
            cursor = await conn.execute(
                "select api.get_risk_engine_status('defense-assessment') status"
            )
            monitor = (await cursor.fetchone())["status"]
            assert set(monitor) == {"state", "generatedAt", "worker", "backlog", "throughput", "configuration"}
            assert monitor["backlog"]["pendingCount"] >= 0
            assert monitor["configuration"]["ruleVersion"] == rules.version

            cursor = await conn.execute(
                "select api.list_risk_engine_failures(%s,%s,10) failures",
                (older_at - timedelta(seconds=1), failed_at + timedelta(seconds=1)),
            )
            failures = (await cursor.fetchone())["failures"]["failures"]
            assert failures[0]["observationId"] == failed_observation["observationId"]
        finally:
            await conn.rollback()


def test_database_idempotency_late_observation_and_current_projection():
    asyncio.run(_exercise_database_contract())
