#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2,<4",
# ]
# ///
"""Dispatch durable amplifier commands to the radar-cloud HTTP endpoint."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

SUPPORTED_FREQUENCIES = {2400: "2.4", 5200: "5.2", 5800: "5.8"}
OPENING_COMMANDS = {"amp_start", "strike"}
STOP_COMMANDS = {"amp_stop", "emergency_amp_stop"}


def normalized_frequencies(values: Any) -> list[int]:
    if not isinstance(values, list) or not values:
        raise ValueError("frequenciesMhz must be a non-empty array")
    result: set[int] = set()
    for value in values:
        if isinstance(value, bool):
            raise ValueError("unsupported amplifier frequency")
        try:
            frequency = int(value)
        except (TypeError, ValueError) as error:
            raise ValueError("unsupported amplifier frequency") from error
        if frequency not in SUPPORTED_FREQUENCIES:
            raise ValueError(f"unsupported amplifier frequency {frequency}")
        result.add(frequency)
    return sorted(result)


def vendor_frequency_text(values: Any) -> str:
    return ",".join(SUPPORTED_FREQUENCIES[value] for value in normalized_frequencies(values))


def _coordinate_text(value: Any, name: str, minimum: float, maximum: float) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{name} is invalid") from error
    if not minimum <= number <= maximum:
        raise ValueError(f"{name} is invalid")
    return format(number, ".12g")


def build_vendor_request(command: dict[str, Any]) -> dict[str, Any]:
    kind = command.get("commandKind")
    try:
        station_id = int(command["stationId"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("stationId is invalid") from error
    box_code = command.get("boxCode")
    if not isinstance(box_code, str) or not box_code.strip():
        raise ValueError("boxCode is required")
    frequencies = vendor_frequency_text(command.get("frequenciesMhz"))
    envelope: dict[str, Any] = {"stationId": station_id, "boxCode": box_code.strip()}

    if kind in {"amp_start", "amp_stop", "emergency_amp_stop"}:
        envelope.update({
            "cmd": "amp",
            "data": {"action": 1 if kind == "amp_start" else 0, "freqs": frequencies},
        })
        return envelope
    if kind != "strike":
        raise ValueError(f"unsupported command kind {kind}")
    if command.get("targetCoordinateSystem") != "WGS84":
        raise ValueError("targetCoordinateSystem must be WGS84")
    try:
        duration = int(command.get("durationSeconds"))
    except (TypeError, ValueError) as error:
        raise ValueError("durationSeconds is invalid") from error
    if not 1 <= duration <= 60:
        raise ValueError("durationSeconds must be between 1 and 60")
    longitude = _coordinate_text(command.get("targetLongitude"), "targetLongitude", -180, 180)
    latitude = _coordinate_text(command.get("targetLatitude"), "targetLatitude", -90, 90)
    envelope.update({
        "cmd": "strike",
        "data": {"gps": f"{longitude}/{latitude}", "duration": duration, "freqs": frequencies},
    })
    return envelope


def vendor_accepted(http_status: int, body: Any) -> bool:
    return http_status == 200 and isinstance(body, dict) and body.get("status") == 200


def sanitize_vendor_response(body: Any) -> dict[str, Any]:
    if not isinstance(body, dict):
        return {}
    return {key: body.get(key) for key in ("status", "msg", "serverErrorMsg")}


def retry_delay_seconds(command_kind: str, attempt_count: int, *, ambiguous: bool) -> float | None:
    del ambiguous  # Opening ambiguity changes policy by command kind, not the delay calculation.
    if command_kind in OPENING_COMMANDS or command_kind not in STOP_COMMANDS:
        return None
    if attempt_count >= 7:
        return None
    return float(min(2 ** max(0, attempt_count - 1), 30))


def command_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/api/cloud/command/send"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, ANN201
        return None


class RadarCloudGateway:
    def __init__(self, base_url: str, timeout_seconds: float) -> None:
        self.url = command_url(base_url)
        self.timeout_seconds = timeout_seconds
        self.opener = urllib.request.build_opener(_NoRedirect())

    def send_sync(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(),
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "huaguoshan-amplifier-worker/1",
            },
            method="POST",
        )
        try:
            response = self.opener.open(request, timeout=self.timeout_seconds)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(64 * 1024 + 1)
            if len(raw) > 64 * 1024:
                raise ValueError("vendor response exceeds 64 KiB")
            try:
                body = json.loads(raw) if raw else {}
            except json.JSONDecodeError as error:
                raise ValueError("vendor response is not valid JSON") from error
            if not isinstance(body, dict):
                raise ValueError("vendor response must be a JSON object")
            return int(response.status), body

    async def send(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return await asyncio.to_thread(self.send_sync, payload)


@dataclass(frozen=True)
class Config:
    database_dsn: str
    database_role: str
    base_url: str
    worker_id: str
    poll_seconds: float
    lease_seconds: int
    http_timeout_seconds: float


class CommandStore:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.connection: Any = None

    async def connect(self) -> None:
        import psycopg
        from psycopg import sql

        self.connection = await psycopg.AsyncConnection.connect(self.config.database_dsn, autocommit=True)
        await self.connection.execute(sql.SQL("set role {}").format(sql.Identifier(self.config.database_role)))

    async def close(self) -> None:
        if self.connection is not None:
            await self.connection.close()
            self.connection = None

    async def _value(self, query: str, parameters: tuple[Any, ...]) -> Any:
        if self.connection is None or self.connection.closed:
            await self.close()
            await self.connect()
        async with self.connection.cursor() as cursor:
            await cursor.execute(query, parameters)
            row = await cursor.fetchone()
        return row[0] if row else None

    async def claim(self) -> dict[str, Any] | None:
        value = await self._value(
            "select countermeasure.claim_next_amplifier_command(%s,%s)",
            (self.config.worker_id, self.config.lease_seconds),
        )
        return value if isinstance(value, dict) else None

    async def complete(self, command: dict[str, Any], http_status: int, body: dict[str, Any]) -> None:
        await self._value(
            "select countermeasure.complete_amplifier_command(%s,%s,%s,%s::jsonb)",
            (
                command["commandId"], command["leaseToken"], http_status,
                json.dumps(sanitize_vendor_response(body), ensure_ascii=False, separators=(",", ":")),
            ),
        )

    async def fail(self, command: dict[str, Any], error_code: str, *, ambiguous: bool) -> None:
        delay = retry_delay_seconds(
            str(command["commandKind"]), int(command.get("attemptCount", 1)), ambiguous=ambiguous
        )
        await self._value(
            "select countermeasure.fail_amplifier_command(%s,%s,%s,%s,%s)",
            (command["commandId"], command["leaseToken"], error_code, ambiguous, delay),
        )

    async def advance_due(self) -> None:
        await self._value("select countermeasure.advance_due_amplifier_operations()", ())


class Worker:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.store = CommandStore(config)
        self.gateway = RadarCloudGateway(config.base_url, config.http_timeout_seconds)
        self.stop_event = asyncio.Event()

    async def stop(self) -> None:
        self.stop_event.set()

    async def process_one(self, command: dict[str, Any]) -> None:
        try:
            vendor_request = build_vendor_request(command)
        except Exception as error:
            logging.exception("amplifier command validation failed id=%s", command.get("commandId"))
            await self._record_failure(command, type(error).__name__, ambiguous=False)
            return

        try:
            http_status, body = await self.gateway.send(vendor_request)
        except Exception as error:
            # Once transmission starts, even response parsing failures are uncertain:
            # the vendor may already have executed the command.
            logging.warning("amplifier command delivery ambiguous id=%s error=%s", command["commandId"], type(error).__name__)
            await self._record_failure(command, type(error).__name__, ambiguous=True)
            return

        if not vendor_accepted(http_status, body):
            # Without a vendor idempotency/non-execution guarantee, an opening
            # response other than the documented success is still conservative.
            await self._record_failure(
                command,
                f"vendor_rejected_{http_status}_{body.get('status')}",
                ambiguous=str(command.get("commandKind")) in OPENING_COMMANDS,
            )
            return

        try:
            await self.store.complete(command, http_status, body)
        except Exception:
            # Do not turn a vendor-accepted opening into a deterministic failure.
            # The lease-expiry path quarantines it as an ambiguous delivery.
            logging.exception("failed to persist accepted amplifier command id=%s", command["commandId"])
            return
        logging.info("amplifier command dispatched id=%s kind=%s", command["commandId"], command["commandKind"])

    async def _record_failure(self, command: dict[str, Any], error_code: str, *, ambiguous: bool) -> None:
        try:
            await self.store.fail(command, error_code, ambiguous=ambiguous)
        except Exception:
            logging.exception("failed to persist amplifier command failure id=%s", command.get("commandId"))

    async def run(self) -> None:
        await self.store.connect()
        try:
            while not self.stop_event.is_set():
                try:
                    await self.store.advance_due()
                    command = await self.store.claim()
                except Exception:
                    logging.exception("amplifier worker database cycle failed")
                    command = None
                if command is not None:
                    await self.process_one(command)
                    continue
                try:
                    await asyncio.wait_for(self.stop_event.wait(), timeout=self.config.poll_seconds)
                except TimeoutError:
                    pass
        finally:
            await self.store.close()


def parse_args() -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-dsn", default=os.getenv("AMPLIFIER_DATABASE_DSN"))
    parser.add_argument("--database-role", default=os.getenv("AMPLIFIER_DATABASE_ROLE", "countermeasure_worker"))
    parser.add_argument("--base-url", default=os.getenv("RADAR_CLOUD_BASE_URL", "http://47.110.44.5:8003"))
    parser.add_argument("--worker-id", default=os.getenv("AMPLIFIER_WORKER_ID", f"amplifier-{uuid4()}"))
    parser.add_argument("--poll-seconds", type=float, default=0.25)
    parser.add_argument("--lease-seconds", type=int, default=15)
    parser.add_argument("--http-timeout-seconds", type=float, default=5.0)
    args = parser.parse_args()
    if not args.database_dsn:
        parser.error("--database-dsn or AMPLIFIER_DATABASE_DSN is required")
    if args.poll_seconds <= 0 or not 5 <= args.lease_seconds <= 30 or args.http_timeout_seconds <= 0:
        parser.error("poll and timeout values must be positive; lease must be between 5 and 30 seconds")
    if args.http_timeout_seconds + 1 >= args.lease_seconds:
        parser.error("HTTP timeout must be at least one second shorter than the command lease")
    return Config(
        database_dsn=args.database_dsn,
        database_role=args.database_role,
        base_url=args.base_url,
        worker_id=args.worker_id,
        poll_seconds=args.poll_seconds,
        lease_seconds=args.lease_seconds,
        http_timeout_seconds=args.http_timeout_seconds,
    )


async def async_main() -> None:
    worker = Worker(parse_args())
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, lambda: asyncio.create_task(worker.stop()))
    await worker.run()


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
