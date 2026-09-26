from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from unittest.mock import AsyncMock, MagicMock, Mock, patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "lizheng_connector.py"
SPEC = importlib.util.spec_from_file_location("lizheng_connector", SCRIPT)
assert SPEC and SPEC.loader
connector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = connector
SPEC.loader.exec_module(connector)


class LizhengConnectorTests(unittest.TestCase):
    def test_normalizes_sentinel_position_and_preserves_upstream_payload(self):
        received_at = connector.datetime(
            2026, 9, 26, 4, 0, 49, tzinfo=connector.timezone.utc
        )
        upstream = {
            "id": "60601f08afe4",
            "name": "DJI Mavic(O4)",
            "longitude": 210,
            "latitude": 210,
            "direction": 365,
            "lastseen_time": "2026-09-26T12:00:48.177290441+08:00",
            "created_time": "2026-09-26T12:00:45.201558601+08:00",
            "initial_location": {"lat": 210, "lng": 210},
            "rc_location": {"lat": 210, "lng": 210},
            "seen_sensor": [
                {"sensor_id": "1", "detected_freq_khz": 5816500}
            ],
        }

        normalized = connector.normalize_drone(upstream, "station-7", received_at)

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized["stationId"], "station-7")
        self.assertIsNone(normalized["longitude"])
        self.assertEqual(
            normalized["sourceSessionId"],
            "60601f08afe4:2026-09-26T12:00:45.201558601+08:00",
        )
        self.assertIsNone(normalized["latitude"])
        self.assertIsNone(normalized["azimuthDeg"])
        self.assertEqual(normalized["frequencyMhz"], 5816.5)
        self.assertEqual(normalized["qualityFlags"], ["missing_position"])
        self.assertIs(normalized["rawPayload"], upstream)
        self.assertNotIn("_normalized", upstream)

    def test_normalizes_controller_with_configured_station(self):
        received_at = connector.datetime(
            2026, 9, 26, tzinfo=connector.timezone.utc
        )
        normalized = connector.normalize_device(
            {
                "id": "",
                "class": "controller",
                "state": "",
                "config": '{"geo_location":{"lng":119.19292,"lat":34.592045}}',
            },
            "station-7",
            received_at,
        )

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized["stationId"], "station-7")
        self.assertEqual(normalized["sourceAssetId"], "controller")
        self.assertEqual(normalized["longitude"], 119.19292)
        self.assertEqual(normalized["latitude"], 34.592045)

    def test_uses_documented_add_subscription_protocol(self):
        instance = connector.Connector(
            connector.Config(
                database_dsn="postgresql://unused",
                database_role="detection_ingest",
                base_url="https://device.example",
                station_id="station-7",
                username="user",
                password="password",
                reconcile_seconds=30,
                device_sync_seconds=300,
                http_timeout_seconds=10,
                verify_ssl=False,
            )
        )

        message = instance._subscription_message()

        self.assertEqual(message["type"], "add")
        self.assertEqual(message["id"], "1")
        self.assertEqual(message["payload"]["query"], connector.DRONE_SUBSCRIPTION_QUERY)
        self.assertEqual(message["payload"]["extensions"], {})
        self.assertIsNone(message["payload"]["operationName"])

    def test_reconciled_absence_is_a_normal_close_event(self):
        received_at = connector.datetime(
            2026, 9, 26, 4, 1, tzinfo=connector.timezone.utc
        )

        observation = connector.reconciled_offline_observation(
            "60601f08afe4", "station-7", received_at
        )

        self.assertEqual(observation["stationId"], "station-7")
        self.assertEqual(observation["eventType"], "offline_remove")
        self.assertEqual(observation["endReason"], "reconciled_absent")
        self.assertEqual(observation["qualityFlags"], [])
        self.assertEqual(observation["rawPayload"], {})

    def test_logs_when_http_transport_recovers_after_retry(self):
        class TransportError(Exception):
            pass

        class HTTPStatusError(Exception):
            pass

        response = MagicMock()
        response.raise_for_status.return_value = None
        response.json.return_value = {"data": {}}
        client = MagicMock()
        client.post.side_effect = [TransportError("timed out"), response]
        graphql = connector.GraphQLClient("https://device.example", verify_ssl=False)
        graphql._http_client = client
        fake_httpx = types.SimpleNamespace(
            TransportError=TransportError,
            HTTPStatusError=HTTPStatusError,
        )

        with (
            patch.dict(sys.modules, {"httpx": fake_httpx}),
            patch.object(connector.time, "sleep"),
            self.assertLogs(level="INFO") as logs,
        ):
            body = graphql._request_json("/rf/graphql", {}, 10, "lizheng graphql query")

        self.assertEqual(body, {"data": {}})
        self.assertIn(
            "lizheng graphql query recovered on attempt 2/3",
            "\n".join(logs.output),
        )

    def test_http_reconciliation_queries_all_preserved_drone_fields(self):
        for field in (
            "localization { lat lng }",
            "noise_dbm",
            "tracing { lastlen origin { lat lng } points }",
            "tracking_video",
        ):
            self.assertIn(field, connector.DRONE_QUERY)


class LizhengWebSocketTests(unittest.IsolatedAsyncioTestCase):
    async def test_stop_closes_active_websocket(self):
        instance = connector.Connector(
            connector.Config(
                database_dsn="postgresql://unused",
                database_role="detection_ingest",
                base_url="https://device.example",
                station_id="station-7",
                username="user",
                password="password",
                reconcile_seconds=30,
                device_sync_seconds=300,
                http_timeout_seconds=10,
                verify_ssl=False,
            )
        )
        websocket = MagicMock()
        websocket.close = AsyncMock()
        instance._ws_connection = websocket

        await instance.stop()

        self.assertTrue(instance.stop_event.is_set())
        websocket.close.assert_awaited_once()

    async def test_startup_failure_is_handled_by_retry_loop(self):
        instance = connector.Connector(
            connector.Config(
                database_dsn="postgresql://unused",
                database_role="detection_ingest",
                base_url="https://device.example",
                station_id="station-7",
                username="user",
                password="password",
                reconcile_seconds=30,
                device_sync_seconds=300,
                http_timeout_seconds=10,
                verify_ssl=False,
            )
        )

        async def fail_and_stop():
            instance.stop_event.set()
            raise OSError("transient TLS failure")

        instance._connected_session = fail_and_stop
        instance.store.connector_status = AsyncMock(return_value={})
        instance.store.close = AsyncMock()
        instance.graphql.login = Mock(side_effect=AssertionError("login outside retry loop"))

        await instance.run()

        instance.graphql.login.assert_not_called()
        instance.store.close.assert_awaited_once()

    async def test_ack_subscribes_once_and_application_ping_gets_pong(self):
        instance = connector.Connector(
            connector.Config(
                database_dsn="postgresql://unused",
                database_role="detection_ingest",
                base_url="https://device.example",
                station_id="station-7",
                username="user",
                password="password",
                reconcile_seconds=30,
                device_sync_seconds=300,
                http_timeout_seconds=10,
                verify_ssl=False,
            )
        )

        class FakeWebSocket:
            def __init__(self):
                self.messages = []

            async def send(self, raw):
                self.messages.append(connector.json.loads(raw))

        websocket = FakeWebSocket()
        instance._ws_connection = websocket

        await instance._handle_ws_message('{"type":"connection_ack"}')
        await instance._handle_ws_message('{"type":"connection_ack"}')
        await instance._handle_ws_message('{"type":"ping"}')

        self.assertEqual([message["type"] for message in websocket.messages], ["add", "pong"])


if __name__ == "__main__":
    unittest.main()
