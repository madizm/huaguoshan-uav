from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "radar_cloud_connector.py"
SPEC = importlib.util.spec_from_file_location("radar_cloud_connector", SCRIPT)
assert SPEC and SPEC.loader
connector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = connector
SPEC.loader.exec_module(connector)


class RadarCloudConnectorTests(unittest.TestCase):
    def test_builds_the_verified_online_list_path(self):
        self.assertEqual(
            connector.online_list_url("http://47.110.44.5:8003/", "90"),
            "http://47.110.44.5:8003/uav/onlineList?stationId=90",
        )

    def test_builds_the_box_query_path(self):
        self.assertEqual(
            connector.prod_box_query_url("http://47.110.44.5:8003/"),
            "http://47.110.44.5:8003/prodBox/queryAll",
        )

    def test_normalizes_box_asset_and_status(self):
        received_at = connector.datetime(2026, 9, 21, 8, tzinfo=connector.timezone.utc)
        normalized = connector.normalize_vendor_box(
            {
                "boxCode": "b260705174118582",
                "boxName": "边缘盒子",
                "stationCode": "lianyungang",
                "factoryName": "边缘盒子",
                "modelName": "D007-V",
                "longitude": 119.192932,
                "latitude": 34.591952,
                "onlineStatus": 0,
                "heartbeatTime": "2026-09-21 14:23:37",
            },
            "90",
            received_at,
        )
        self.assertEqual(normalized["schemaVersion"], 1)
        self.assertEqual(normalized["stationId"], "90")
        self.assertEqual(normalized["sourceAssetId"], "b260705174118582")
        self.assertEqual(normalized["longitude"], 119.192932)
        self.assertEqual(normalized["latitude"], 34.591952)
        self.assertEqual(normalized["connectivityStatus"], "offline")
        self.assertEqual(normalized["metadata"]["station_code"], "lianyungang")
        self.assertEqual(normalized["heartbeatAt"], "2026-09-21T06:23:37+00:00")

    def test_rejects_box_without_identity_and_discards_invalid_position(self):
        received_at = connector.datetime(2026, 9, 21, tzinfo=connector.timezone.utc)
        self.assertIsNone(connector.normalize_vendor_box({}, "90", received_at))
        normalized = connector.normalize_vendor_box(
            {"boxCode": "BOX-1", "longitude": 0, "latitude": 0}, "90", received_at
        )
        self.assertIsNone(normalized["longitude"])
        self.assertIsNone(normalized["latitude"])

    def test_accepts_supported_messages_and_ignores_unknown_events(self):
        self.assertEqual(
            connector.parse_vendor_message(
                '{"type":"uav_online_upsert","payload":{"serial":"A","stationId":90}}'
            ),
            ("uav_online_upsert", {"serial": "A", "stationId": 90}),
        )
        self.assertIsNone(connector.parse_vendor_message('{"type":"other","payload":{}}'))
        with self.assertRaisesRegex(ValueError, "payload"):
            connector.parse_vendor_message('{"type":"uav_online_upsert","payload":[]}')

    def test_reconciliation_uses_item_station_and_unique_serials(self):
        items = [
            {"serial": "A", "stationId": 90},
            {"serial": "A", "stationId": 90},
            {"serial": "B", "stationId": 30},
            {"serial": " C "},
            {"stationId": 90},
            "invalid",
        ]
        self.assertEqual(connector.present_target_ids(items, "90"), ["A", "C"])

    def test_normalizes_vendor_fields_and_units(self):
        received_at = connector.datetime(2026, 9, 20, 9, 46, 9, tzinfo=connector.timezone.utc)
        normalized = connector.normalize_vendor_item(
            "uav_dashboard_snapshot",
            {
                "serial": "A",
                "stationId": 90,
                "sourceType": 20,
                "currentTime": "2026-09-20 17:46:08",
                "lng": 119.196,
                "lat": 34.592,
                "altitude": 32,
                "height": -26.7,
                "distance": 0.29,
                "directSpeed": "15.5",
                "freq": 5816.5,
            },
            "90",
            received_at,
        )
        self.assertEqual(normalized["schemaVersion"], 1)
        self.assertEqual(normalized["eventType"], "snapshot")
        self.assertEqual(normalized["sourceTypeCode"], 20)
        self.assertEqual(normalized["observedAt"], "2026-09-20T09:46:08+00:00")
        self.assertEqual(normalized["horizontalDistanceM"], 290.0)
        self.assertEqual(normalized["speedMps"], 15.5)
        self.assertEqual(normalized["qualityFlags"], [])
        self.assertEqual(len(normalized["sourceObservationId"]), 64)

    def test_normalization_marks_missing_fields_and_filters_other_stations(self):
        received_at = connector.datetime(2026, 9, 20, tzinfo=connector.timezone.utc)
        self.assertIsNone(connector.normalize_vendor_item(
            "uav_online_upsert", {"serial": "A", "stationId": 30}, "90", received_at
        ))
        normalized = connector.normalize_vendor_item(
            "online_list_snapshot", {"serial": "A", "stationId": 90}, "90", received_at
        )
        self.assertEqual(
            normalized["qualityFlags"],
            ["missing_source_type", "missing_position", "missing_source_time"],
        )

    def test_database_rejections_are_isolated_per_observation(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("for observation in observations:", source)
        self.assertIn('"status": "rejected"', source)
        self.assertIn("results.append(await self.ingest(observation))", source)

    def test_has_inline_runtime_dependencies_and_no_embedded_credentials(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"psycopg[binary]>=3.2,<4"', source)
        self.assertIn('"websockets>=15,<17"', source)
        self.assertIn("DETECTION_DATABASE_DSN", source)
        self.assertNotIn("postgres/postgres", source)
        self.assertNotIn("geovis@", source)
        self.assertIn('"set role {}"', source)


if __name__ == "__main__":
    unittest.main()
