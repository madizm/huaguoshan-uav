"""HTTP service boundary for database-backed risk assessments."""

from __future__ import annotations

import os
from datetime import datetime, timezone

import psycopg
from fastapi import FastAPI, HTTPException
from psycopg.rows import dict_row

from .detection_adapter import fetch_observation, fetch_published_configuration, target_from_row
from .domain import RiskAssessment, assess_target
from .persistence import fetch_persisted_assessment, persist_assessment

app = FastAPI(title="Huaguoshan Risk Assessment Engine", version="0.1.0")


class ObservationNotFoundError(LookupError):
    pass


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


async def assess_observation(database_url: str, observation_id: int) -> RiskAssessment:
    async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
        async with conn.transaction():
            persisted = await fetch_persisted_assessment(conn, observation_id)
            if persisted is not None:
                return persisted
            row = await fetch_observation(conn, observation_id)
            if row is None:
                raise ObservationNotFoundError(observation_id)
            protected_objects, rules = await fetch_published_configuration(conn)
            target = target_from_row(row)
            result = assess_target(target, protected_objects, rules, datetime.now(timezone.utc))
            await persist_assessment(conn, result, {
                "longitude": target.longitude,
                "latitude": target.latitude,
                "speedMps": target.speed_mps,
                "identityStatus": target.identity_status,
                "trigger": "http",
            })
            return result


@app.post("/v1/assessments/{observation_id}", response_model=RiskAssessment, response_model_by_alias=True)
async def create_assessment(observation_id: int) -> RiskAssessment:
    if observation_id < 1:
        raise HTTPException(status_code=422, detail="observation_id must be positive")
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        raise HTTPException(status_code=503, detail="risk assessment database is not configured")
    try:
        return await assess_observation(database_url, observation_id)
    except ObservationNotFoundError as exc:
        raise HTTPException(status_code=404, detail="observation is not associated with a target track") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except psycopg.Error as exc:
        raise HTTPException(status_code=503, detail="risk assessment database is unavailable") from exc
