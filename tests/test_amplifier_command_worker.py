from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "amplifier_command_worker.py"
SPEC = importlib.util.spec_from_file_location("amplifier_command_worker", SCRIPT)
assert SPEC and SPEC.loader
worker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


class AmplifierCommandWorkerTests(unittest.TestCase):
    def test_builds_omnidirectional_start_from_canonical_command(self):
        request = worker.build_vendor_request({
            "commandKind": "amp_start",
            "stationId": 90,
            "boxCode": "BOX-1",
            "frequenciesMhz": [2400, 5200, 5800],
        })
        self.assertEqual(request, {
            "stationId": 90,
            "boxCode": "BOX-1",
            "cmd": "amp",
            "data": {"action": 1, "freqs": "2.4,5.2,5.8"},
        })

    def test_builds_normal_and_emergency_stop_with_action_zero(self):
        for kind in ("amp_stop", "emergency_amp_stop"):
            request = worker.build_vendor_request({
                "commandKind": kind,
                "stationId": "90",
                "boxCode": "BOX-1",
                "frequenciesMhz": [5800, 2400],
            })
            self.assertEqual(request["cmd"], "amp")
            self.assertEqual(request["data"], {"action": 0, "freqs": "2.4,5.8"})
            self.assertEqual(request["stationId"], 90)

    def test_builds_target_strike_in_wgs84_longitude_latitude_order(self):
        request = worker.build_vendor_request({
            "commandKind": "strike",
            "stationId": 90,
            "boxCode": "BOX-1",
            "frequenciesMhz": [2400],
            "durationSeconds": 60,
            "targetLongitude": 119.196054,
            "targetLatitude": 34.591989,
            "targetCoordinateSystem": "WGS84",
        })
        self.assertEqual(request, {
            "stationId": 90,
            "boxCode": "BOX-1",
            "cmd": "strike",
            "data": {
                "gps": "119.196054/34.591989",
                "duration": 60,
                "freqs": "2.4",
            },
        })

    def test_rejects_unknown_frequency_coordinate_system_and_duration(self):
        base = {
            "commandKind": "strike", "stationId": 90, "boxCode": "BOX-1",
            "frequenciesMhz": [2400], "durationSeconds": 10,
            "targetLongitude": 119.1, "targetLatitude": 34.5,
            "targetCoordinateSystem": "WGS84",
        }
        for change in (
            {"frequenciesMhz": [433]},
            {"targetCoordinateSystem": "GCJ-02"},
            {"durationSeconds": 61},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                worker.build_vendor_request(base | change)

    def test_vendor_acceptance_requires_http_and_body_status_200(self):
        self.assertTrue(worker.vendor_accepted(200, {"status": 200, "msg": "指令已下发"}))
        self.assertFalse(worker.vendor_accepted(202, {"status": 200}))
        self.assertFalse(worker.vendor_accepted(200, {"status": 500}))
        self.assertFalse(worker.vendor_accepted(200, None))

    def test_sanitizes_vendor_response(self):
        self.assertEqual(
            worker.sanitize_vendor_response({
                "status": 200,
                "msg": "指令已下发",
                "data": {"secret": "not persisted"},
                "serverErrorMsg": None,
                "extra": "ignored",
            }),
            {"status": 200, "msg": "指令已下发", "serverErrorMsg": None},
        )

    def test_ambiguous_opening_is_not_retried_but_stop_is_bounded(self):
        self.assertIsNone(worker.retry_delay_seconds("amp_start", 1, ambiguous=True))
        self.assertIsNone(worker.retry_delay_seconds("strike", 1, ambiguous=True))
        self.assertEqual(worker.retry_delay_seconds("amp_stop", 1, ambiguous=True), 1.0)
        self.assertEqual(worker.retry_delay_seconds("emergency_amp_stop", 3, ambiguous=True), 4.0)
        self.assertIsNone(worker.retry_delay_seconds("amp_stop", 7, ambiguous=True))

    def test_command_endpoint_is_exact_and_no_credentials_are_embedded(self):
        self.assertEqual(
            worker.command_url("http://47.110.44.5:8003/"),
            "http://47.110.44.5:8003/api/cloud/command/send",
        )
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("AMPLIFIER_DATABASE_DSN", source)
        self.assertIn("RADAR_CLOUD_BASE_URL", source)
        self.assertNotIn("postgres/postgres", source)
        self.assertNotIn("geovis@", source)


class WorkerDeliveryClassificationTests(unittest.IsolatedAsyncioTestCase):
    def make_worker(self):
        config = worker.Config("dsn", "role", "http://vendor", "worker", 0.1, 15, 5)
        instance = worker.Worker(config)
        return instance

    async def test_accepted_vendor_response_with_database_failure_is_not_marked_deterministic_failure(self):
        instance = self.make_worker()
        calls = []

        class Gateway:
            async def send(self, payload):
                return 200, {"status": 200, "msg": "指令已下发"}

        class Store:
            async def complete(self, *args):
                raise ConnectionError("database unavailable")

            async def fail(self, *args, **kwargs):
                calls.append((args, kwargs))

        instance.gateway = Gateway()
        instance.store = Store()
        await instance.process_one({
            "commandId": "command-1", "commandKind": "amp_start", "stationId": 90,
            "boxCode": "BOX-1", "frequenciesMhz": [2400], "attemptCount": 1,
        })
        self.assertEqual(calls, [])

    async def test_undocumented_opening_rejection_is_conservatively_ambiguous(self):
        instance = self.make_worker()
        calls = []

        class Gateway:
            async def send(self, payload):
                return 500, {"status": 500, "msg": "error"}

        class Store:
            async def fail(self, command, error_code, *, ambiguous):
                calls.append((error_code, ambiguous))

        instance.gateway = Gateway()
        instance.store = Store()
        await instance.process_one({
            "commandId": "command-1", "commandKind": "amp_start", "stationId": 90,
            "boxCode": "BOX-1", "frequenciesMhz": [2400], "attemptCount": 1,
        })
        self.assertEqual(calls, [("vendor_rejected_500_500", True)])

    async def test_failure_after_transmission_starts_is_ambiguous(self):
        instance = self.make_worker()
        calls = []

        class Gateway:
            async def send(self, payload):
                raise ValueError("invalid response body")

        class Store:
            async def fail(self, command, error_code, *, ambiguous):
                calls.append((error_code, ambiguous))

        instance.gateway = Gateway()
        instance.store = Store()
        await instance.process_one({
            "commandId": "command-1", "commandKind": "amp_start", "stationId": 90,
            "boxCode": "BOX-1", "frequenciesMhz": [2400], "attemptCount": 1,
        })
        self.assertEqual(calls, [("ValueError", True)])


if __name__ == "__main__":
    unittest.main()
