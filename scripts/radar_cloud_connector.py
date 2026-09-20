#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2,<4",
#   "websockets>=15,<17",
# ]
# ///
"""Consume radar-cloud HTTP/WebSocket data into the detection situation schema."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import os
import signal
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from zoneinfo import ZoneInfo

SOURCE_SYSTEM = "radar_cloud"
SUPPORTED_MESSAGE_TYPES = {
    "config_status",
    "uav_dashboard_snapshot",
    "uav_online_remove",
    "uav_online_upsert",
}
SOURCE_TIMEZONE = ZoneInfo("Asia/Shanghai")


def safe_number(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def source_time(value: Any, fallback: datetime) -> tuple[datetime, bool]:
    if not isinstance(value, str) or not value.strip():
        return fallback, True
    try:
        parsed = datetime.fromisoformat(value.strip().replace(" ", "T").replace("Z", "+00:00"))
    except ValueError:
        return fallback, True
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=SOURCE_TIMEZONE)
    return parsed.astimezone(timezone.utc), False


def normalize_vendor_item(message_type: str, item: dict[str, Any], station_id: str,
                          received_at: datetime) -> dict[str, Any] | None:
    item_station = str(item.get("stationId", station_id))
    serial = item.get("serial")
    if item_station != station_id or not isinstance(serial, str) or not serial.strip():
        return None
    serial = serial.strip()
    event_type = {"uav_online_remove": "offline_remove", "uav_online_upsert": "online_upsert"}.get(
        message_type, "snapshot"
    )
    observed_at, missing_time = source_time(item.get("currentTime", item.get("lastTime")), received_at)
    longitude, latitude = safe_number(item.get("lng")), safe_number(item.get("lat"))
    if (longitude is None or latitude is None) and isinstance(item.get("gps"), str):
        parts = item["gps"].split("/", 1)
        if len(parts) == 2:
            longitude, latitude = safe_number(parts[0]), safe_number(parts[1])
    if not (longitude is not None and latitude is not None and -180 <= longitude <= 180
            and -90 <= latitude <= 90 and (longitude != 0 or latitude != 0)):
        longitude = latitude = None
    source_type = safe_number(item.get("sourceType"))
    source_type_code = int(source_type) if source_type in {10.0, 20.0} else None
    quality_flags = []
    if source_type_code is None:
        quality_flags.append("missing_source_type")
    if longitude is None and event_type != "offline_remove":
        quality_flags.append("missing_position")
    if missing_time:
        quality_flags.append("missing_source_time")
    canonical = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    fingerprint = "|".join((SOURCE_SYSTEM, item_station, str(source_type_code), serial, event_type,
                             observed_at.isoformat(), canonical))
    distance_km = safe_number(item.get("distance"))
    return {
        "schemaVersion": 1, "sourceSystem": SOURCE_SYSTEM, "stationId": item_station,
        "sourceObservationId": hashlib.sha256(fingerprint.encode()).hexdigest(),
        "sourceTargetId": serial, "sourceSessionId": item.get("sessionId") or None,
        "sourceTypeCode": source_type_code, "eventType": event_type,
        "observedAt": observed_at.isoformat(), "receivedAt": received_at.isoformat(),
        "longitude": longitude, "latitude": latitude,
        "altitudeAmslM": safe_number(item.get("altitude")),
        "relativeHeightM": safe_number(item.get("height")),
        "horizontalDistanceM": distance_km * 1000 if distance_km is not None else None,
        "azimuthDeg": safe_number(item.get("azimuth")),
        "elevationDeg": safe_number(item.get("elevation")),
        "speedMps": safe_number(item.get("directSpeed")),
        "frequencyMhz": safe_number(item.get("freq")),
        "listType": safe_number(item.get("listType")), "model": item.get("model") or None,
        "endReason": item.get("reason") or None, "qualityFlags": quality_flags, "rawPayload": item,
    }


def normalize_vendor_payload(message_type: str, payload: dict[str, Any], station_id: str,
                             received_at: datetime) -> list[dict[str, Any]]:
    if message_type == "config_status":
        return []
    items = payload.get("list", []) if message_type in {"uav_dashboard_snapshot", "online_list_snapshot"} else [payload]
    if not isinstance(items, list):
        raise ValueError(f"{message_type} payload.list must be an array")
    return [normalized for item in items if isinstance(item, dict)
            if (normalized := normalize_vendor_item(message_type, item, station_id, received_at)) is not None]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def online_list_url(base_url: str, station_id: str) -> str:
    query = urllib.parse.urlencode({"stationId": station_id})
    return f"{base_url.rstrip('/')}/uav/onlineList?{query}"


def parse_vendor_message(raw: str) -> tuple[str, dict[str, Any]] | None:
    message = json.loads(raw)
    if not isinstance(message, dict):
        raise ValueError("WebSocket message must be a JSON object")
    message_type = message.get("type")
    payload = message.get("payload")
    if message_type not in SUPPORTED_MESSAGE_TYPES:
        return None
    if not isinstance(payload, dict):
        raise ValueError(f"{message_type} payload must be a JSON object")
    return message_type, payload


def present_target_ids(items: list[Any], station_id: str) -> list[str]:
    result: set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        if str(item.get("stationId", station_id)) != station_id:
            continue
        serial = item.get("serial")
        if isinstance(serial, str) and serial.strip():
            result.add(serial.strip())
    return sorted(result)


def fetch_online_list(base_url: str, station_id: str, timeout: float) -> list[dict[str, Any]]:
    request = urllib.request.Request(
        online_list_url(base_url, station_id),
        headers={"Accept": "application/json", "User-Agent": "huaguoshan-detection-connector/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.load(response)
    if not isinstance(body, dict) or body.get("status") != 200 or not isinstance(body.get("data"), list):
        raise ValueError("online list response does not contain status=200 and a data array")
    return [item for item in body["data"] if isinstance(item, dict)]


@dataclass(frozen=True)
class Config:
    database_dsn: str
    database_role: str
    base_url: str
    websocket_url: str
    station_id: str
    reconcile_seconds: float
    http_timeout_seconds: float


class DetectionStore:
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

    async def _execute_value(self, query: str, parameters: tuple[Any, ...]) -> dict[str, Any]:
        if self.connection is None or self.connection.closed:
            await self.close()
            await self.connect()
        async with self.connection.cursor() as cursor:
            await cursor.execute(query, parameters)
            row = await cursor.fetchone()
        if not row or not isinstance(row[0], dict):
            raise RuntimeError("detection database function returned an invalid result")
        return row[0]

    async def ingest(self, observation: dict[str, Any]) -> dict[str, Any]:
        return await self._execute_value(
            "select situation.ingest_target_observation(%s::jsonb)",
            (json.dumps(observation, ensure_ascii=False, separators=(",", ":")),),
        )

    async def ingest_vendor_payload(self, message_type: str,
                                    payload: dict[str, Any]) -> list[dict[str, Any]]:
        observations = normalize_vendor_payload(message_type, payload, self.config.station_id, utc_now())
        results = []
        for observation in observations:
            try:
                results.append(await self.ingest(observation))
            except Exception as error:
                logging.exception(
                    "normalized observation rejected source_target_id=%s",
                    observation.get("sourceTargetId"),
                )
                results.append({
                    "status": "rejected",
                    "sourceTargetId": observation.get("sourceTargetId"),
                    "errorCode": type(error).__name__,
                })
        return results

    async def connector_status(self, state: str, error_code: str | None = None) -> dict[str, Any]:
        return await self._execute_value(
            "select situation.update_detection_connector_status(%s,%s,%s,%s,%s,%s,%s::jsonb)",
            (
                SOURCE_SYSTEM,
                self.config.station_id,
                state,
                utc_now(),
                utc_now() if state == "connected" else None,
                error_code,
                json.dumps({"websocketUrl": self.config.websocket_url}, separators=(",", ":")),
            ),
        )

    async def reconcile(self, target_ids: list[str]) -> dict[str, Any]:
        return await self._execute_value(
            "select situation.reconcile_detection_targets(%s,%s,%s,%s)",
            (SOURCE_SYSTEM, self.config.station_id, utc_now(), target_ids),
        )


class Connector:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.store = DetectionStore(config)
        self.stop_event = asyncio.Event()

    async def stop(self) -> None:
        self.stop_event.set()

    async def synchronize_online_list(self) -> None:
        items = await asyncio.to_thread(
            fetch_online_list,
            self.config.base_url,
            self.config.station_id,
            self.config.http_timeout_seconds,
        )
        payload = {"stationId": int(self.config.station_id), "list": items, "count": len(items)}
        ingest_result = await self.store.ingest_vendor_payload("online_list_snapshot", payload)
        reconcile_result = await self.store.reconcile(present_target_ids(items, self.config.station_id))
        logging.info("online list synchronized ingest=%s reconcile=%s", ingest_result, reconcile_result)

    async def reconciliation_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(self.stop_event.wait(), timeout=self.config.reconcile_seconds)
            except TimeoutError:
                try:
                    await self.synchronize_online_list()
                except Exception:
                    logging.exception("online list reconciliation failed")

    async def connected_session(self) -> None:
        from websockets.asyncio.client import connect

        async with connect(
            self.config.websocket_url,
            open_timeout=10,
            ping_interval=20,
            ping_timeout=20,
            max_size=2 * 1024 * 1024,
        ) as websocket:
            await self.store.connector_status("connected")
            await self.synchronize_online_list()
            reconcile_task = asyncio.create_task(self.reconciliation_loop())
            try:
                while not self.stop_event.is_set():
                    raw = await asyncio.wait_for(websocket.recv(), timeout=30)
                    parsed = parse_vendor_message(raw)
                    if parsed is None:
                        continue
                    message_type, payload = parsed
                    result = await self.store.ingest_vendor_payload(message_type, payload)
                    logging.debug("message ingested type=%s result=%s", message_type, result)
            finally:
                reconcile_task.cancel()
                await asyncio.gather(reconcile_task, return_exceptions=True)

    async def run(self) -> None:
        await self.store.connect()
        delay = 1.0
        try:
            while not self.stop_event.is_set():
                try:
                    await self.connected_session()
                    delay = 1.0
                except asyncio.CancelledError:
                    raise
                except Exception as error:
                    logging.exception("radar-cloud connection failed; retrying in %.1fs", delay)
                    try:
                        await self.store.connector_status("disconnected", type(error).__name__)
                    except Exception:
                        logging.exception("failed to persist disconnected status")
                    try:
                        await asyncio.wait_for(self.stop_event.wait(), timeout=delay)
                    except TimeoutError:
                        pass
                    delay = min(delay * 2, 60.0)
        finally:
            try:
                await self.store.connector_status("disconnected", "connector_stopped")
            except Exception:
                logging.exception("failed to persist shutdown status")
            await self.store.close()


def parse_args() -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-dsn", default=os.getenv("DETECTION_DATABASE_DSN"))
    parser.add_argument("--database-role", default=os.getenv("DETECTION_DATABASE_ROLE", "detection_ingest"))
    parser.add_argument("--base-url", default=os.getenv("RADAR_CLOUD_BASE_URL", "http://47.110.44.5:8003"))
    parser.add_argument(
        "--websocket-url",
        default=os.getenv("RADAR_CLOUD_WEBSOCKET_URL", "ws://47.110.44.5:8003/realTimeAlarmWebSocket"),
    )
    parser.add_argument("--station-id", default=os.getenv("RADAR_CLOUD_STATION_ID", "90"))
    parser.add_argument("--reconcile-seconds", type=float, default=30.0)
    parser.add_argument("--http-timeout-seconds", type=float, default=10.0)
    args = parser.parse_args()
    if not args.database_dsn:
        parser.error("--database-dsn or DETECTION_DATABASE_DSN is required")
    if not args.station_id.isdigit():
        parser.error("station ID must be numeric")
    if args.reconcile_seconds < 5:
        parser.error("reconcile interval must be at least 5 seconds")
    return Config(
        database_dsn=args.database_dsn,
        database_role=args.database_role,
        base_url=args.base_url,
        websocket_url=args.websocket_url,
        station_id=args.station_id,
        reconcile_seconds=args.reconcile_seconds,
        http_timeout_seconds=args.http_timeout_seconds,
    )


async def async_main() -> None:
    config = parse_args()
    connector = Connector(config)
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, lambda: asyncio.create_task(connector.stop()))
    await connector.run()


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
