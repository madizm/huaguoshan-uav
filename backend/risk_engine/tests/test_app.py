import asyncio
from datetime import datetime, timezone

import httpx

import backend.risk_engine.app as app_module
from backend.risk_engine.domain import RiskAssessment


def _post(path: str) -> httpx.Response:
    async def request():
        transport = httpx.ASGITransport(app=app_module.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            return await client.post(path)

    return asyncio.run(request())


def test_assessment_endpoint_uses_database_configuration(monkeypatch):
    async def fake_assess_observation(database_url: str, observation_id: int):
        assert database_url == "postgresql://risk-engine"
        assert observation_id == 2
        return RiskAssessment(
            status="assessed", risk_level="critical", risk_score=90,
            track_id=1, observation_id=2,
            observed_at=datetime(2026, 9, 25, tzinfo=timezone.utc),
            assessed_at=datetime(2026, 9, 25, tzinfo=timezone.utc),
            protected_object_id=1, protected_object_version=2,
            ring_id=1, ring_code="core", ring_level=5, ring_version=2,
            rule_set_id=3, rule_version=3,
        )

    monkeypatch.setenv("DATABASE_URL", "postgresql://risk-engine")
    monkeypatch.setattr(app_module, "assess_observation", fake_assess_observation)
    response = _post("/v1/assessments/2")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "assessed"
    assert body["ringVersion"] == 2
    assert body["ruleSetId"] == 3


def test_assessment_endpoint_requires_database_configuration(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    response = _post("/v1/assessments/2")
    assert response.status_code == 503


def test_assessment_endpoint_rejects_non_positive_observation_id(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://risk-engine")
    response = _post("/v1/assessments/0")
    assert response.status_code == 422
