"""Continuous worker for evaluating new detection observations."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import psycopg
from psycopg.rows import dict_row

from .detection_adapter import (
    fetch_pending_observations,
    fetch_published_configuration,
    lock_worker_cursor,
    target_from_row,
    update_worker_cursor,
)
from .domain import RiskAssessment, RuleSet, assess_target
from .persistence import persist_assessment

LOGGER = logging.getLogger(__name__)
DEFAULT_WORKER_NAME = "defense-assessment"


def _json_value(value: Any) -> Any:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Decimal):
        return float(value)
    return value


def _input_snapshot(row: dict[str, Any]) -> dict[str, Any]:
    trajectory = row.get("trajectory") or []
    return {
        "longitude": _json_value(row.get("longitude")),
        "latitude": _json_value(row.get("latitude")),
        "speedMps": _json_value(row.get("speed_mps")),
        "identityStatus": _json_value(row.get("identity_status")),
        "trajectoryObservationIds": [
            point.get("observation_id") or point.get("observationId")
            for point in trajectory if isinstance(point, dict)
        ],
    }


def _failed_assessment(row: dict[str, Any], rules: RuleSet, assessed_at: datetime) -> RiskAssessment:
    observed_at = row.get("observed_at")
    if not isinstance(observed_at, datetime):
        observed_at = assessed_at
    return RiskAssessment(
        status="failed",
        track_id=int(row["track_id"]),
        observation_id=int(row["observation_id"]),
        observed_at=observed_at,
        assessed_at=assessed_at,
        rule_set_id=rules.id,
        rule_version=rules.version,
        reason="assessment_error",
    )


async def process_batch(conn, worker_name: str, batch_size: int) -> int:
    """Process one transactionally guarded batch and return the row count."""
    after_id = await lock_worker_cursor(conn, worker_name)
    rows = await fetch_pending_observations(conn, after_id, batch_size)
    if not rows:
        return 0
    protected_objects, rules = await fetch_published_configuration(conn)
    for row in rows:
        assessed_at = datetime.now(timezone.utc)
        snapshot = _input_snapshot(row)
        try:
            target = target_from_row(row)
            result = assess_target(target, protected_objects, rules, assessed_at)
        except Exception as exc:
            LOGGER.exception(
                "assessment failed for observation %s: %s",
                row.get("observation_id"),
                type(exc).__name__,
            )
            snapshot["errorType"] = type(exc).__name__
            result = _failed_assessment(row, rules, assessed_at)
        await persist_assessment(conn, result, snapshot)
    await update_worker_cursor(
        conn,
        worker_name,
        max(int(row["observation_id"]) for row in rows),
    )
    return len(rows)


async def run_once(database_url: str, worker_name: str, batch_size: int) -> int:
    async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
        async with conn.transaction():
            return await process_batch(conn, worker_name, batch_size)


async def run_forever(database_url: str, worker_name: str, batch_size: int, poll_interval: float) -> None:
    while True:
        try:
            count = await run_once(database_url, worker_name, batch_size)
            if count:
                LOGGER.info("assessed %s observations", count)
                continue
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("risk assessment batch failed")
        await asyncio.sleep(poll_interval)


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate new detection observations")
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL"))
    parser.add_argument("--worker-name", default=DEFAULT_WORKER_NAME)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--poll-interval", type=float, default=1.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if not args.database_url:
        parser.error("--database-url or DATABASE_URL is required")
    if args.batch_size < 1 or args.batch_size > 1000:
        parser.error("--batch-size must be between 1 and 1000")
    if args.poll_interval < 0.1:
        parser.error("--poll-interval must be at least 0.1 seconds")
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    if args.once:
        print(asyncio.run(run_once(args.database_url, args.worker_name, args.batch_size)))
    else:
        asyncio.run(run_forever(args.database_url, args.worker_name, args.batch_size, args.poll_interval))


if __name__ == "__main__":
    main()
