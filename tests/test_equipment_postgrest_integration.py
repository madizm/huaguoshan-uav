from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener


@unittest.skipUnless(
    os.environ.get("RUN_EQUIPMENT_INTEGRATION") == "1",
    "set RUN_EQUIPMENT_INTEGRATION=1 to test the migrated PostgREST facade",
)
class EquipmentPostgrestIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.base_url = os.environ.get("EQUIPMENT_API_URL", "http://10.1.109.151:13000").rstrip("/")
        cls.opener = build_opener()
        secret = os.environ["POSTGREST_JWT_SECRET"].encode()

        def encode(payload: dict[str, object]) -> str:
            raw = json.dumps(payload, separators=(",", ":")).encode()
            return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

        header = encode({"alg": "HS256", "typ": "JWT"})
        payload = encode({"role": "admin", "exp": int(time.time()) + 300})
        signature = base64.urlsafe_b64encode(
            hmac.new(secret, f"{header}.{payload}".encode(), hashlib.sha256).digest()
        ).rstrip(b"=").decode()
        cls.authorization = f"Bearer {header}.{payload}.{signature}"

    def request(self, path: str, *, authorization: bool = True, method: str = "GET", body=None):
        headers = {"Content-Type": "application/json"}
        if authorization:
            headers["Authorization"] = self.authorization
        request = Request(
            f"{self.base_url}/{path}",
            headers=headers,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
        )
        for attempt in range(8):
            try:
                with self.opener.open(request, timeout=8) as response:
                    return response.status, json.load(response)
            except HTTPError as error:
                if error.code not in {502, 503, 504} or attempt == 7:
                    raise
                error.close()
                time.sleep(1)
            except URLError:
                if attempt == 7:
                    raise
                time.sleep(1)
        raise AssertionError("unreachable")

    def test_seven_categories_are_queryable_with_explicit_amsl_datum(self):
        _, assets = self.request("equipment_assets?select=category_code,height_datum")
        self.assertEqual(
            {row["category_code"] for row in assets},
            {"base_station_6g", "counter_uas", "video_surveillance", "uav", "unmanned_vehicle", "vehicle_surveillance", "sensor"},
        )
        self.assertEqual({row["height_datum"] for row in assets}, {"AMSL"})

    def test_online_statistics_are_available_by_category(self):
        _, rows = self.request(
            "equipment_online_statistics?select=category_code,total_count,online_count,online_rate"
        )
        self.assertEqual(len(rows), 7)
        self.assertTrue(all(row["total_count"] >= row["online_count"] for row in rows))
        self.assertTrue(all(0 <= float(row["online_rate"]) <= 100 for row in rows))

    def test_reported_flights_never_expose_a_managed_asset_id(self):
        _, rows = self.request("flight_activities?activity_type=eq.reported_flight&select=aircraft_id,aircraft_name")
        self.assertTrue(rows)
        self.assertTrue(all(row["aircraft_id"] is None for row in rows))
        self.assertTrue(all(row["aircraft_name"] for row in rows))

    def test_counter_uas_is_recommendable_but_has_no_control_endpoint(self):
        _, rows = self.request("equipment_asset_capabilities?category_code=eq.counter_uas&select=access_level")
        self.assertTrue(rows)
        self.assertEqual({row["access_level"] for row in rows}, {"recommendable"})
        with self.assertRaises(HTTPError) as raised:
            self.request("rpc/counter_uas_control", method="POST", body={})
        self.assertEqual(raised.exception.code, 404)
        raised.exception.close()

    def test_raw_observations_are_append_only_and_anonymous_is_denied(self):
        with self.assertRaises(HTTPError) as raised:
            self.request("equipment_raw_observations?id=gt.0", method="PATCH", body={"processing_status": "changed"})
        self.assertEqual(raised.exception.code, 400)
        raised.exception.close()
        with self.assertRaises(HTTPError) as raised:
            self.request("equipment_assets?limit=1", authorization=False)
        self.assertIn(raised.exception.code, {401, 403})
        raised.exception.close()


if __name__ == "__main__":
    unittest.main()
