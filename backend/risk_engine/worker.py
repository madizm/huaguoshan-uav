"""Continuous worker for evaluating new detection observations."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import socket
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import psycopg
from psycopg.rows import dict_row

from .detection_adapter import (
    fetch_pending_observations,
    fetch_published_configuration,
    lock_worker_cursor,
    record_batch_started,
    record_batch_success,
    record_worker_failure,
    record_worker_idle,
    record_worker_stopped,
    register_worker_runtime,
    target_from_row,
    update_worker_cursor,
)
from .domain import RiskAssessment, RuleSet, assess_target
from .persistence import persist_assessment
from .uav_model import UavModelMatcher

LOGGER = logging.getLogger(__name__)
DEFAULT_WORKER_NAME = "defense-assessment"
ENGINE_VERSION = os.environ.get("RISK_ENGINE_VERSION", "1")


def _json_value(value: Any) -> Any:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Decimal):
        return float(value)
    return value


def _input_snapshot(row: dict[str, Any], weight_class: str | None = None) -> dict[str, Any]:
    trajectory = row.get("trajectory") or []
    return {
        "longitude": _json_value(row.get("longitude")),
        "latitude": _json_value(row.get("latitude")),
        "speedMps": _json_value(row.get("speed_mps")),
        "identityStatus": _json_value(row.get("identity_status")),
        "model": _json_value(row.get("model")),
        "weightClass": weight_class,
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


async def process_batch(conn, worker_name: str, batch_size: int, matcher: UavModelMatcher | None = None) -> int:
    """Process one transactionally guarded batch and return the row count."""
    after_id = await lock_worker_cursor(conn, worker_name)
    rows = await fetch_pending_observations(conn, after_id, batch_size)
    if not rows:
        await record_worker_idle(conn, worker_name)
        return 0
    started = time.monotonic()
    await record_batch_started(conn, worker_name)
    protected_objects, rules = await fetch_published_configuration(conn)
    failed_count = 0
    for row in rows:
        assessed_at = datetime.now(timezone.utc)
        # Match model to weight_class
        weight_class = None
        if matcher is not None:
            spec = matcher.match(row.get("model"))
            if spec is not None:
                weight_class = spec.weight_class
        snapshot = _input_snapshot(row, weight_class)
        try:
            target = target_from_row(row, weight_class)
            result = assess_target(target, protected_objects, rules, assessed_at)
        except Exception as exc:
            LOGGER.exception(
                "assessment failed for observation %s: %s",
                row.get("observation_id"),
                type(exc).__name__,
            )
            snapshot["errorType"] = type(exc).__name__
            result = _failed_assessment(row, rules, assessed_at)
        if result.status == "failed":
            failed_count += 1
        await persist_assessment(conn, result, snapshot)
    await update_worker_cursor(
        conn,
        worker_name,
        max(int(row["observation_id"]) for row in rows),
    )
    await record_batch_success(
        conn, worker_name, len(rows), failed_count,
        max(0, round((time.monotonic() - started) * 1000)),
    )
    return len(rows)


async def run_once(database_url: str, worker_name: str, batch_size: int) -> int:
    async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
        async with conn.transaction():
            await register_worker_runtime(conn, worker_name, _instance_id(), ENGINE_VERSION)
            matcher = await UavModelMatcher.from_database(conn)
            return await process_batch(conn, worker_name, batch_size, matcher)


def _instance_id() -> str:
    return f"{socket.gethostname()}:{os.getpid()}:{uuid.uuid4().hex[:8]}"


async def _runtime_update(database_url: str, operation, *args) -> None:
    async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
        async with conn.transaction():
            await operation(conn, *args)


async def run_forever(database_url: str, worker_name: str, batch_size: int, poll_interval: float) -> None:
    instance_id = _instance_id()
    await _runtime_update(database_url, register_worker_runtime, worker_name, instance_id, ENGINE_VERSION)
    # Load matcher once at startup
    matcher = None
    try:
        async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
            matcher = await UavModelMatcher.from_database(conn)
            LOGGER.info("loaded UAV model matcher with %d rules and %d specs", len(matcher.rules), len(matcher.specs))
    except Exception:
        LOGGER.exception("failed to load UAV model matcher, weight class factor will be unavailable")
    try:
        while True:
            try:
                async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
                    async with conn.transaction():
                        count = await process_batch(conn, worker_name, batch_size, matcher)
                if count:
                    LOGGER.info("assessed %s observations", count)
                    continue
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOGGER.exception("risk assessment batch failed")
                try:
                    await _runtime_update(
                        database_url, record_worker_failure, worker_name,
                        type(exc).__name__, str(exc) or type(exc).__name__,
                    )
                except Exception:
                    LOGGER.exception("failed to persist risk worker error state")
            await asyncio.sleep(poll_interval)
    finally:
        try:
            await _runtime_update(database_url, record_worker_stopped, worker_name)
        except Exception:
            LOGGER.exception("failed to persist risk worker stopped state")


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
    logging.basicConfig(level=os.environ.get("RISK_ENGINE_LOG_LEVEL", os.environ.get("LOG_LEVEL", "INFO")))
    if args.once:
        print(asyncio.run(run_once(args.database_url, args.worker_name, args.batch_size)))
    else:
        asyncio.run(run_forever(args.database_url, args.worker_name, args.batch_size, args.poll_interval))


if __name__ == "__main__":
    main()
