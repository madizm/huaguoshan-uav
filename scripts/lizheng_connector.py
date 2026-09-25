#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2,<4",
#   "websockets>=15,<17",
# ]
# ///
"""Consume Lizheng RF detection device data into the detection situation schema.

Authentication: POST /login → JWT token (refreshed before expiry).
Real-time:      GraphQL subscription over WebSocket at /sub/subscriptions.
Reconciliation: Periodic drone query to detect disappeared drones.
Device sync:    Periodic devices/sensor query for asset health and position.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import ssl
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

SOURCE_SYSTEM = "lizheng"
DETECTION_METHOD_CODE = "radio_detection"
SOURCE_TIMEZONE_NAME = "Asia/Shanghai"
# Token refresh when less than this many seconds remain before expiry.
TOKEN_REFRESH_MARGIN_SECONDS = 300
# Drone subscription query — selects the same fields as the HTTP drone query.
DRONE_SUBSCRIPTION_QUERY = """subscription {
  drone {
    id name description image state direction distance speed
    altitude height latitude longitude
    created_time deleted_time lastseen_time
    confirmed reliability
    rc_location { lat lng }
    initial_location { lat lng }
    localization { lat lng }
    seen_sensor { sensor_id detected_freq_khz signal_dbm snr_dB bandwidth_khz noise_dbm port }
    attack_bands attack_type attacking attacking_ttl
    in_ada blacklisted whitelisted has_duplicate
    tracing { lastlen origin { lat lng } points }
    link_id jamming_conflicts directional_attack_state
    has_screenshot tracking_video
  }
}"""
DRONE_QUERY = """query {
  drone {
    id name description state direction distance speed
    altitude height latitude longitude
    created_time deleted_time lastseen_time
    confirmed reliability
    rc_location { lat lng }
    initial_location { lat lng }
    seen_sensor { sensor_id detected_freq_khz signal_dbm snr_dB bandwidth_khz port }
    attack_bands attack_type attacking
    in_ada blacklisted whitelisted
  }
}"""
DEVICES_QUERY = """query {
  devices {
    id class node state gps_fixed faults toc
    config status
  }
}"""
SENSOR_QUERY = """query {
  sensor {
    id name mac node state faults ttl
    config sensor_status { version temperature ip_address first_seen last_seen }
  }
}"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def safe_number(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def is_valid_position(lng: float | None, lat: float | None) -> bool:
    return (
        lng is not None
        and lat is not None
        and -180 <= lng <= 180
        and -90 <= lat <= 90
        and (lng != 0 or lat != 0)
    )


def is_sentinel_position(lng: float | None, lat: float | None) -> bool:
    """Lizheng uses 210 as sentinel for invalid coordinates."""
    return (lng is not None and abs(lng - 210) < 0.01) or (
        lat is not None and abs(lat - 210) < 0.01
    )


def parse_source_time(value: Any, fallback: datetime) -> tuple[datetime, bool]:
    if not isinstance(value, str) or not value.strip():
        return fallback, True
    raw = value.strip().replace(" ", "T")
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return fallback, True
    if parsed.tzinfo is None:
        from zoneinfo import ZoneInfo

        parsed = parsed.replace(tzinfo=ZoneInfo(SOURCE_TIMEZONE_NAME))
    return parsed.astimezone(timezone.utc), False


def is_deleted(drone: dict[str, Any]) -> bool:
    deleted = drone.get("deleted_time")
    if not isinstance(deleted, str):
        return False
    return not deleted.startswith("0001-01-01")


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def normalize_drone(drone: dict[str, Any], received_at: datetime) -> dict[str, Any] | None:
    drone_id = drone.get("id")
    if not isinstance(drone_id, str) or not drone_id.strip():
        return None
    drone_id = drone_id.strip()

    if is_deleted(drone):
        event_type = "offline_remove"
    else:
        event_type = "online_upsert"

    observed_at, missing_time = parse_source_time(
        drone.get("lastseen_time") or drone.get("created_time"), received_at
    )

    lng = safe_number(drone.get("longitude"))
    lat = safe_number(drone.get("latitude"))
    if is_sentinel_position(lng, lat):
        lng = lat = None
    if not is_valid_position(lng, lat):
        lng = lat = None

    rc_lat_raw = drone.get("rc_location", {})
    if isinstance(rc_lat_raw, dict):
        rc_lng = safe_number(rc_lat_raw.get("lng"))
        rc_lat = safe_number(rc_lat_raw.get("lat"))
    else:
        rc_lng = rc_lat = None
    if is_sentinel_position(rc_lng, rc_lat):
        rc_lng = rc_lat = None
    if not is_valid_position(rc_lng, rc_lat):
        rc_lng = rc_lat = None

    direction = safe_number(drone.get("direction"))
    if direction is not None and abs(direction - 365) < 0.01:
        direction = None

    seen_sensors = drone.get("seen_sensor")
    frequency_mhz = None
    if isinstance(seen_sensors, list) and seen_sensors:
        first = seen_sensors[0]
        if isinstance(first, dict):
            freq_khz = safe_number(first.get("detected_freq_khz"))
            if freq_khz is not None and freq_khz > 0:
                frequency_mhz = freq_khz / 1000.0

    quality_flags: list[str] = []
    if missing_time:
        quality_flags.append("missing_source_time")
    if lng is None and event_type != "offline_remove":
        quality_flags.append("missing_position")

    return {
        "schemaVersion": 1,
        "sourceSystem": SOURCE_SYSTEM,
        "stationId": "1",
        "sourceObservationId": f"lizheng:{drone_id}:{observed_at.isoformat()}",
        "sourceTargetId": drone_id,
        "sourceSessionId": drone_id,
        "sourceTypeCode": None,
        "detectionMethodCode": DETECTION_METHOD_CODE,
        "eventType": event_type,
        "observedAt": observed_at.isoformat(),
        "receivedAt": received_at.isoformat(),
        "longitude": lng,
        "latitude": lat,
        "altitudeAmslM": safe_number(drone.get("altitude")),
        "relativeHeightM": safe_number(drone.get("height")),
        "horizontalDistanceM": safe_number(drone.get("distance")),
        "azimuthDeg": direction,
        "elevationDeg": None,
        "speedMps": safe_number(drone.get("speed")),
        "frequencyMhz": frequency_mhz,
        "listType": None,
        "model": drone.get("name") or None,
        "remotePilotLocation": (
            {"longitude": rc_lng, "latitude": rc_lat}
            if is_valid_position(rc_lng, rc_lat)
            else None
        ),
        "endReason": None,
        "qualityFlags": quality_flags,
        "rawPayload": drone,
    }


def normalize_device(device: dict[str, Any], received_at: datetime) -> dict[str, Any] | None:
    device_class = device.get("class") or "unknown"
    device_id = device.get("id")
    # For controller, use 'controller' as default id if empty.
    if device_class == "controller" and (not isinstance(device_id, str) or not device_id.strip()):
        device_id = "controller"
    elif not isinstance(device_id, str) or not device_id.strip():
        return None
    else:
        device_id = device_id.strip()

    config_str = device.get("config")
    config: dict[str, Any] = {}
    if isinstance(config_str, str) and config_str.strip():
        try:
            config = json.loads(config_str)
        except json.JSONDecodeError:
            pass

    status_str = device.get("status")
    status: dict[str, Any] = {}
    if isinstance(status_str, str) and status_str.strip():
        try:
            status = json.loads(status_str)
        except json.JSONDecodeError:
            pass

    geo = config.get("geo_location", {}) if isinstance(config, dict) else {}
    lng = safe_number(geo.get("lng")) if isinstance(geo, dict) else None
    lat = safe_number(geo.get("lat")) if isinstance(geo, dict) else None
    if not is_valid_position(lng, lat):
        lng = lat = None

    state = device.get("state") or ""
    connectivity = "online" if state == "operational" else "offline" if state else "unknown"

    gps_fixed = device.get("gps_fixed")
    heartbeat_at = None
    if isinstance(gps_fixed, bool) and gps_fixed:
        heartbeat_at = received_at

    toc_ms = safe_number(device.get("toc"))
    metadata: dict[str, Any] = {
        "device_class": device_class,
        "node": device.get("node"),
        "faults": device.get("faults") or None,
        "gps_fixed": gps_fixed,
    }
    if isinstance(config, dict):
        for key in ("sn", "pid", "hardware_version", "bands", "range"):
            if key in config:
                metadata[key] = config[key]
    if isinstance(status, dict) and "heading" in status:
        metadata["heading"] = status["heading"]

    return {
        "schemaVersion": 1,
        "sourceSystem": SOURCE_SYSTEM,
        "stationId": "1",
        "sourceAssetId": device_id,
        "name": f"历正{device_class} #{device_id}",
        "manufacturer": "历正科技",
        "model": config.get("pid") if isinstance(config, dict) else None,
        "longitude": lng,
        "latitude": lat,
        "connectivityStatus": connectivity,
        "heartbeatAt": heartbeat_at.isoformat() if heartbeat_at else None,
        "observedAt": received_at.isoformat(),
        "metadata": metadata,
        "statusPayload": device,
    }


# ---------------------------------------------------------------------------
# GraphQL HTTP client
# ---------------------------------------------------------------------------


class GraphQLClient:
    def __init__(self, base_url: str, verify_ssl: bool = True) -> None:
        self.base_url = base_url.rstrip("/")
        self.token: str | None = None
        self.token_exp: float = 0.0
        self.verify_ssl = verify_ssl

    def login(self, username: str, password: str, timeout: float) -> None:
        data = json.dumps(
            {"username": username, "password": password}
        ).encode()
        request = urllib.request.Request(
            f"{self.base_url}/login",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "huaguoshan-lizheng-connector/1",
            },
            method="POST",
        )
        ssl_ctx = self._ssl_context()
        with urllib.request.urlopen(request, timeout=timeout, context=ssl_ctx) as response:
            body = json.load(response)
        token = body.get("token")
        if not isinstance(token, str) or not token:
            raise RuntimeError("login response missing token")
        self.token = token
        exp_len = safe_number(body.get("expLen"))
        # expLen is in milliseconds from login time.
        self.token_exp = time.time() + (exp_len / 1000 if exp_len else 3600)
        logging.info("lizheng login successful, token expires in %.0fs", exp_len / 1000 if exp_len else 3600)

    def query(self, graphql: str, timeout: float) -> dict[str, Any]:
        if self.token is None:
            raise RuntimeError("not logged in")
        data = json.dumps({"query": graphql}).encode()
        request = urllib.request.Request(
            f"{self.base_url}/rf/graphql",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "huaguoshan-lizheng-connector/1",
            },
            method="POST",
        )
        ssl_ctx = self._ssl_context()
        with urllib.request.urlopen(request, timeout=timeout, context=ssl_ctx) as response:
            body = json.load(response)
        if "errors" in body and body["errors"]:
            messages = [e.get("message", "") for e in body["errors"] if isinstance(e, dict)]
            logging.warning("graphql errors: %s", messages)
        return body.get("data") or {}

    def ensure_token(self, username: str, password: str, timeout: float) -> None:
        if self.token is None or time.time() > self.token_exp - TOKEN_REFRESH_MARGIN_SECONDS:
            logging.info("refreshing lizheng token")
            self.login(username, password, timeout)

    def ws_url(self) -> str:
        parsed = urllib.parse.urlparse(self.base_url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        return f"{scheme}://{parsed.netloc}/sub/subscriptions"

    def _ssl_context(self) -> ssl.SSLContext | None:
        if self.verify_ssl:
            return None
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx


# ---------------------------------------------------------------------------
# Database store
# ---------------------------------------------------------------------------


class DetectionStore:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.connection: Any = None

    async def connect(self) -> None:
        import psycopg
        from psycopg import sql

        self.connection = await psycopg.AsyncConnection.connect(
            self.config.database_dsn, autocommit=True
        )
        await self.connection.execute(
            sql.SQL("set role {}").format(sql.Identifier(self.config.database_role))
        )

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

    async def sync_box(self, box: dict[str, Any]) -> dict[str, Any]:
        return await self._execute_value(
            "select situation.sync_detection_source_asset(%s::jsonb)",
            (json.dumps(box, ensure_ascii=False, separators=(",", ":")),),
        )

    async def ingest_telemetry(self, sensor_status: dict[str, Any], observed_at: datetime) -> dict[str, Any]:
        """Write device telemetry via situation.ingest_lizheng_telemetry function."""
        return await self._execute_value(
            "select situation.ingest_lizheng_telemetry(%s, %s::jsonb)",
            (observed_at, json.dumps(sensor_status, ensure_ascii=False, separators=(",", ":"))),
        )

    async def connector_status(
        self, state: str, error_code: str | None = None
    ) -> dict[str, Any]:
        from datetime import datetime as _dt

        now = _dt.now(timezone.utc)
        return await self._execute_value(
            "select situation.update_detection_connector_status(%s,%s,%s,%s,%s,%s,%s::jsonb)",
            (
                SOURCE_SYSTEM,
                "1",
                state,
                now,
                now if state == "connected" else None,
                error_code,
                json.dumps(
                    {"websocketUrl": f"lizheng-device", "sourceSystem": SOURCE_SYSTEM},
                    separators=(",", ":"),
                ),
            ),
        )

    async def reconcile(self, target_ids: list[str]) -> dict[str, Any]:
        from datetime import datetime as _dt

        return await self._execute_value(
            "select situation.reconcile_detection_targets(%s,%s,%s,%s)",
            (SOURCE_SYSTEM, "1", _dt.now(timezone.utc), target_ids),
        )


# ---------------------------------------------------------------------------
# Connector
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Config:
    database_dsn: str
    database_role: str
    base_url: str
    station_id: str
    username: str
    password: str
    reconcile_seconds: float
    device_sync_seconds: float
    http_timeout_seconds: float
    verify_ssl: bool


class Connector:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.store = DetectionStore(config)
        self.graphql = GraphQLClient(config.base_url, verify_ssl=config.verify_ssl)
        self.stop_event = asyncio.Event()
        self.active_drones: dict[str, datetime] = {}  # drone_id → last_seen
        self._protocol_use_add = False  # False = standard graphql-ws, True = "add"

    async def stop(self) -> None:
        self.stop_event.set()

    # -- Drone subscription (WebSocket) ------------------------------------

    def _subscription_message(self) -> dict[str, Any]:
        if self._protocol_use_add:
            return {
                "id": "1",
                "type": "add",
                "payload": {
                    "query": DRONE_SUBSCRIPTION_QUERY,
                    "extensions": {},
                    "operationName": None,
                    "variables": {},
                },
            }
        # Standard graphql-ws protocol.
        return {
            "id": "1",
            "type": "subscribe",
            "payload": {
                "query": DRONE_SUBSCRIPTION_QUERY,
                "variables": {},
            },
        }

    async def _handle_ws_message(self, raw: str) -> None:
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            logging.warning("non-JSON websocket message: %.200s", raw)
            return
        if not isinstance(message, dict):
            return

        msg_type = message.get("type")

        # Standard graphql-ws: server sends connection_ack after connection_init.
        if msg_type == "connection_ack":
            logging.info("graphql-ws connection acknowledged")
            await self._ws_send(self._subscription_message())
            return

        # Standard graphql-ws keepalive.
        if msg_type in ("ka", "ping"):
            return

        # Data delivery — both protocols use "data" / "next".
        if msg_type in ("data", "next"):
            await self._process_subscription_data(message.get("payload", {}))
            return

        # Error from server.
        if msg_type in ("error", "complete"):
            logging.info("subscription ended: type=%s", msg_type)
            return

        logging.debug("unhandled websocket message type=%s", msg_type)

    async def _process_subscription_data(self, payload: dict[str, Any]) -> None:
        data = payload.get("data", payload)
        drone_data = data.get("drone")
        if drone_data is None:
            return
        if not isinstance(drone_data, list):
            drone_data = [drone_data]

        received_at = datetime.now(timezone.utc)
        present_ids: list[str] = []

        for drone in drone_data:
            if not isinstance(drone, dict):
                continue
            drone_id = drone.get("id")
            if not isinstance(drone_id, str) or not drone_id.strip():
                continue
            drone_id = drone_id.strip()

            if is_deleted(drone):
                # Drone removed — emit offline_remove if we were tracking it.
                if drone_id in self.active_drones:
                    normalized = normalize_drone(drone, received_at)
                    if normalized is not None:
                        try:
                            await self.store.ingest(normalized)
                        except Exception:
                            logging.exception(
                                "offline_remove rejected drone_id=%s", drone_id
                            )
                    self.active_drones.pop(drone_id, None)
                continue

            # Drone present — track and ingest.
            present_ids.append(drone_id)
            is_new = drone_id not in self.active_drones
            self.active_drones[drone_id] = received_at

            normalized = normalize_drone(drone, received_at)
            if normalized is None:
                continue
            if is_new:
                normalized["eventType"] = "online_upsert"
            else:
                normalized["eventType"] = "snapshot"
            try:
                await self.store.ingest(normalized)
            except Exception:
                logging.exception("observation rejected drone_id=%s", drone_id)

    async def _ws_send(self, message: dict[str, Any]) -> None:
        raw = json.dumps(message)
        await self._ws_connection.send(raw)

    async def _connected_session(self) -> None:
        from websockets.asyncio.client import connect

        self.graphql.ensure_token(
            self.config.username, self.config.password, self.config.http_timeout_seconds
        )

        ws_url = self.graphql.ws_url()
        ssl_ctx = None if self.config.verify_ssl else self.graphql._ssl_context()
        headers = {"Authorization": f"Bearer {self.graphql.token}"}

        logging.info("connecting websocket %s", ws_url)

        async with connect(
            ws_url,
            additional_headers=headers,
            ssl=ssl_ctx,
            open_timeout=10,
            ping_interval=20,
            ping_timeout=20,
            max_size=2 * 1024 * 1024,
        ) as websocket:
            self._ws_connection = websocket
            await self.store.connector_status("connected")

            # Send connection_init for standard graphql-ws protocol.
            # The server may respond with connection_ack, triggering the
            # subscription request in _handle_ws_message.
            await self._ws_send({"type": "connection_init"})
            # Also send the subscription directly for servers that accept
            # the documented "add" protocol without connection_init.
            await self._ws_send(self._subscription_message())

            # Perform initial device sync and reconciliation immediately.
            try:
                await self._sync_devices()
            except Exception:
                logging.exception("initial device sync failed")
            try:
                await self._reconcile_drones()
            except Exception:
                logging.exception("initial reconciliation failed")

            # Start background reconciliation and device sync.
            reconcile_task = asyncio.create_task(self._reconciliation_loop())
            device_sync_task = asyncio.create_task(self._device_sync_loop())

            try:
                while not self.stop_event.is_set():
                    raw = await asyncio.wait_for(websocket.recv(), timeout=30)
                    await self._handle_ws_message(raw)
            except asyncio.TimeoutError:
                logging.info("websocket receive timeout, reconnecting")
            finally:
                reconcile_task.cancel()
                device_sync_task.cancel()
                await asyncio.gather(
                    reconcile_task, device_sync_task, return_exceptions=True
                )

    # -- Reconciliation (periodic drone query) ------------------------------

    async def _reconciliation_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(
                    self.stop_event.wait(), timeout=self.config.reconcile_seconds
                )
            except asyncio.TimeoutError:
                try:
                    await self._reconcile_drones()
                except Exception:
                    logging.exception("drone reconciliation failed")

    async def _reconcile_drones(self) -> None:
        self.graphql.ensure_token(
            self.config.username, self.config.password, self.config.http_timeout_seconds
        )
        data = await asyncio.to_thread(
            self.graphql.query, DRONE_QUERY, self.config.http_timeout_seconds
        )
        drones = data.get("drone", [])
        if not isinstance(drones, list):
            drones = [drones] if drones else []

        received_at = datetime.now(timezone.utc)
        present_ids: set[str] = set()

        for drone in drones:
            if not isinstance(drone, dict):
                continue
            drone_id = drone.get("id")
            if not isinstance(drone_id, str) or not drone_id.strip():
                continue
            drone_id = drone_id.strip()

            if is_deleted(drone):
                continue

            present_ids.add(drone_id)
            is_new = drone_id not in self.active_drones
            self.active_drones[drone_id] = received_at

            normalized = normalize_drone(drone, received_at)
            if normalized is None:
                continue
            normalized["eventType"] = "online_upsert" if is_new else "snapshot"
            try:
                await self.store.ingest(normalized)
            except Exception:
                logging.exception("reconciliation ingest rejected drone_id=%s", drone_id)

        # Emit offline_remove for tracked drones no longer present.
        disappeared = set(self.active_drones.keys()) - present_ids
        for drone_id in disappeared:
            offline = {
                "schemaVersion": 1,
                "sourceSystem": SOURCE_SYSTEM,
                "stationId": "1",
                "sourceObservationId": f"lizheng:{drone_id}:{received_at.isoformat()}",
                "sourceTargetId": drone_id,
                "sourceSessionId": drone_id,
                "sourceTypeCode": None,
                "detectionMethodCode": DETECTION_METHOD_CODE,
                "eventType": "offline_remove",
                "observedAt": received_at.isoformat(),
                "receivedAt": received_at.isoformat(),
                "longitude": None,
                "latitude": None,
                "altitudeAmslM": None,
                "relativeHeightM": None,
                "horizontalDistanceM": None,
                "azimuthDeg": None,
                "elevationDeg": None,
                "speedMps": None,
                "frequencyMhz": None,
                "listType": None,
                "model": None,
                "remotePilotLocation": None,
                "endReason": "reconciled_absent",
                "qualityFlags": ["reconciled_absent"],
                "rawPayload": {},
            }
            try:
                await self.store.ingest(offline)
            except Exception:
                logging.exception("reconciliation offline_remove rejected drone_id=%s", drone_id)
            self.active_drones.pop(drone_id, None)

        # Also call the server-side reconcile for timeout-based cleanup.
        try:
            await self.store.reconcile(sorted(present_ids))
        except Exception:
            logging.exception("server-side reconcile failed")

        logging.debug("reconciliation complete active=%d present=%d", len(self.active_drones), len(present_ids))

    # -- Device sync (periodic devices/sensor query) ------------------------

    async def _device_sync_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(
                    self.stop_event.wait(), timeout=self.config.device_sync_seconds
                )
            except asyncio.TimeoutError:
                try:
                    await self._sync_devices()
                except Exception:
                    logging.exception("device sync failed")

    async def _sync_devices(self) -> None:
        self.graphql.ensure_token(
            self.config.username, self.config.password, self.config.http_timeout_seconds
        )
        data = await asyncio.to_thread(
            self.graphql.query, DEVICES_QUERY, self.config.http_timeout_seconds
        )
        devices = data.get("devices", [])
        if not isinstance(devices, list):
            devices = [devices] if devices else []

        received_at = datetime.now(timezone.utc)
        results = []
        for device in devices:
            # Only sync the main controller device; sub-devices (engine, sensor, jammer)
            # are components of the integrated system and share the same observation source.
            if device.get("class") != "controller":
                continue
            normalized = normalize_device(device, received_at)
            if normalized is None:
                continue
            try:
                results.append(await self.store.sync_box(normalized))
            except Exception:
                logging.exception(
                    "device sync rejected device_id=%s", normalized["sourceAssetId"]
                )
                results.append(
                    {
                        "status": "rejected",
                        "sourceAssetId": normalized["sourceAssetId"],
                    }
                )

        # Query sensor status and write telemetry
        await self._sync_sensor_telemetry(received_at)

        logging.info("device sync complete count=%d", len(results))

    async def _sync_sensor_telemetry(self, received_at: datetime) -> None:
        """Query sensor status and write telemetry to counter_uas_telemetry_current."""
        try:
            data = await asyncio.to_thread(
                self.graphql.query, SENSOR_QUERY, self.config.http_timeout_seconds
            )
        except Exception:
            logging.exception("sensor query failed")
            return

        sensors = data.get("sensor", [])
        if not isinstance(sensors, list):
            sensors = [sensors] if sensors else []

        # Aggregate sensor status for the main asset
        operational_count = sum(1 for s in sensors if s.get("state") == "operational")
        total_count = len(sensors)
        temperatures = [
            s.get("sensor_status", {}).get("temperature")
            for s in sensors
            if isinstance(s.get("sensor_status"), dict)
            and s["sensor_status"].get("temperature") is not None
        ]
        avg_temp = sum(temperatures) / len(temperatures) if temperatures else None

        sensor_status = {
            "sensor_count": total_count,
            "operational_count": operational_count,
            "avg_temperature_c": avg_temp,
            "sensors": [
                {
                    "id": s.get("id"),
                    "state": s.get("state"),
                    "temperature": s.get("sensor_status", {}).get("temperature")
                    if isinstance(s.get("sensor_status"), dict)
                    else None,
                }
                for s in sensors
            ],
        }

        try:
            result = await self.store.ingest_telemetry(sensor_status, received_at)
            logging.info(
                "sensor telemetry written sensors=%d operational=%d temp=%s",
                result.get("sensor_count", total_count),
                result.get("operational_count", operational_count),
                avg_temp,
            )
        except Exception:
            logging.exception("sensor telemetry write failed")

    # -- Main loop ----------------------------------------------------------

    async def run(self) -> None:
        await self.store.connect()
        # Initial login.
        await asyncio.to_thread(
            self.graphql.login,
            self.config.username,
            self.config.password,
            self.config.http_timeout_seconds,
        )

        delay = 1.0
        try:
            while not self.stop_event.is_set():
                try:
                    await self._connected_session()
                    delay = 1.0
                except asyncio.CancelledError:
                    raise
                except Exception as error:
                    logging.exception(
                        "lizheng connection failed; retrying in %.1fs", delay
                    )
                    try:
                        await self.store.connector_status(
                            "disconnected", type(error).__name__
                        )
                    except Exception:
                        logging.exception("failed to persist disconnected status")
                    try:
                        await asyncio.wait_for(self.stop_event.wait(), timeout=delay)
                    except asyncio.TimeoutError:
                        pass
                    delay = min(delay * 2, 60.0)
        finally:
            try:
                await self.store.connector_status("disconnected", "connector_stopped")
            except Exception:
                logging.exception("failed to persist shutdown status")
            await self.store.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args() -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--database-dsn", default=os.getenv("DETECTION_DATABASE_DSN")
    )
    parser.add_argument(
        "--database-role",
        default=os.getenv("DETECTION_DATABASE_ROLE", "detection_ingest"),
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("LIZHENG_BASE_URL", "https://10.10.0.93"),
    )
    parser.add_argument(
        "--station-id",
        default=os.getenv("LIZHENG_STATION_ID", "1"),
    )
    parser.add_argument(
        "--username",
        default=os.getenv("LIZHENG_USERNAME", "admin"),
    )
    parser.add_argument(
        "--password",
        default=os.getenv("LIZHENG_PASSWORD", "admin"),
    )
    parser.add_argument(
        "--reconcile-seconds", type=float, default=30.0
    )
    parser.add_argument(
        "--device-sync-seconds", type=float, default=300.0
    )
    parser.add_argument(
        "--http-timeout-seconds", type=float, default=10.0
    )
    parser.add_argument(
        "--no-verify-ssl",
        action="store_true",
        default=os.getenv("LIZHENG_NO_VERIFY_SSL", "1") == "1",
        help="Skip TLS certificate verification (default for self-signed device certs).",
    )
    args = parser.parse_args()
    if not args.database_dsn:
        parser.error("--database-dsn or DETECTION_DATABASE_DSN is required")
    if args.reconcile_seconds < 5:
        parser.error("reconcile interval must be at least 5 seconds")
    if args.device_sync_seconds < 30:
        parser.error("device sync interval must be at least 30 seconds")
    return Config(
        database_dsn=args.database_dsn,
        database_role=args.database_role,
        base_url=args.base_url,
        station_id=args.station_id,
        username=args.username,
        password=args.password,
        reconcile_seconds=args.reconcile_seconds,
        device_sync_seconds=args.device_sync_seconds,
        http_timeout_seconds=args.http_timeout_seconds,
        verify_ssl=not args.no_verify_ssl,
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
