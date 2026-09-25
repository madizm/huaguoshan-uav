from datetime import datetime, timezone

from psycopg.types.json import Jsonb

from backend.risk_engine.detection_adapter import fetch_published_configuration, target_from_row
from backend.risk_engine.domain import RiskAssessment
from backend.risk_engine.persistence import fetch_persisted_assessment, persist_assessment


class FakeCursor:
    def __init__(self, rows):
        self.rows = rows

    async def fetchall(self):
        return self.rows

    async def fetchone(self):
        return self.rows[0] if self.rows else None


class FakeConnection:
    def __init__(self, result_sets=None):
        self.result_sets = list(result_sets or [])
        self.calls = []

    async def execute(self, query, params=()):
        self.calls.append((query, params))
        rows = self.result_sets.pop(0) if self.result_sets else []
        return FakeCursor(rows)


async def _load_empty_objects():
    conn = FakeConnection([[{
        "rule_set_id": 9, "rule_version": 2, "factor_code": b"zone_sensing",
        "threshold_value": 1, "score": 20,
    }], [{"parameter_code": b"score_low", "value_numeric": 20}], []])
    return await fetch_published_configuration(conn)


def test_configuration_keeps_active_rules_when_no_protected_objects():
    import asyncio

    objects, rules = asyncio.run(_load_empty_objects())
    assert objects == []
    assert rules.id == 9
    assert rules.version == 2
    assert rules.scores == {"zone_sensing": 20}
    assert rules.thresholds == {"zone_sensing": 1}
    assert rules.parameters == {"score_low": 20}


def test_target_adapter_decodes_database_text_bytes():
    target = target_from_row({
        "track_id": 1, "observation_id": 2, "observed_at": datetime.now(timezone.utc),
        "longitude": 119.2, "latitude": 34.6, "speed_mps": 3,
        "identity_status": b"unverified",
    })
    assert target.identity_status == "unverified"


def test_persistence_uses_psycopg_parameters_and_version_snapshots():
    import asyncio

    conn = FakeConnection()
    assessment = RiskAssessment(
        status="assessed", risk_level="high", risk_score=75, track_id=1, observation_id=2,
        observed_at=datetime.now(timezone.utc), assessed_at=datetime.now(timezone.utc),
        protected_object_id=3, protected_object_version=4, ring_id=5, ring_code="hard_strike",
        ring_level=4, ring_version=4, distance_m=1234.5, rule_set_id=9, rule_version=2,
    )
    asyncio.run(persist_assessment(conn, assessment, {"longitude": 119.2}))
    query, params = conn.calls[0]
    assert "$1" not in query
    assert "where (excluded.observed_at,coalesce(excluded.observation_id,0)) >" in query.lower()
    assert "risk_changed" in query
    assert "'risk_assessment',jsonb_strip_nulls" in query.lower()
    assert params[9] == 4
    assert params[15] == 9
    assert isinstance(params[17], Jsonb)
    assert isinstance(params[18], Jsonb)


def test_fetch_persisted_assessment_returns_versioned_result():
    import asyncio

    conn = FakeConnection([[{
        "status": "assessed", "risk_level": "high", "risk_score": 75,
        "track_id": 1, "observation_id": 2,
        "observed_at": datetime.now(timezone.utc), "assessed_at": datetime.now(timezone.utc),
        "protected_object_id": 3, "protected_object_version": 4,
        "ring_id": 5, "ring_code": "hard_strike", "ring_level": 4,
        "distance_m": 1234.5, "ring_version": 4,
        "rule_set_id": 9, "rule_version": 2, "factors": [], "reason": None,
    }]])
    result = asyncio.run(fetch_persisted_assessment(conn, 2))
    assert result is not None
    assert result.ring_version == 4
    assert result.rule_set_id == 9
