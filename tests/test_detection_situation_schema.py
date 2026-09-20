from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "backend" / "create_detection_situation_schema.sql"


class DetectionSituationSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.lower = cls.sql.lower()

    def test_creates_detection_domain_tables(self):
        for table in (
            "detection_source_type",
            "observation_source",
            "observation_source_status_current",
            "target_observation",
            "source_target_session",
            "airspace_target",
            "target_track",
            "track_observation",
            "change_event",
        ):
            self.assertIn(f"create table if not exists situation.{table}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on table situation\.{table} is '[^']*[\u4e00-\u9fff]",
            )

    def test_reuses_append_only_equipment_observations(self):
        self.assertIn("insert into equipment.raw_observation", self.lower)
        self.assertIn("references equipment.raw_observation(id)", self.lower)
        self.assertNotIn("create table if not exists situation.raw_observation", self.lower)
        self.assertIn("height_datum", self.lower)
        self.assertIn("'amsl'", self.lower)

    def test_normalized_contract_and_source_mapping_are_explicit(self):
        self.assertIn("(10, 'radar', '雷达'", self.lower)
        self.assertIn("(20, 'radio_detection', '电侦'", self.lower)
        self.assertIn("p_observation->>'stationid'", self.lower)
        self.assertIn("p_observation->>'sourcetypecode'", self.lower)
        self.assertIn("p_observation->>'sourceobservationid'", self.lower)
        self.assertNotIn("jsonb_array_elements(v_items)", self.lower)

    def test_write_functions_are_private_and_idempotent(self):
        for function in (
            "situation.ingest_target_observation",
            "situation.update_detection_connector_status",
            "situation.reconcile_detection_targets",
        ):
            self.assertIn(f"create or replace function {function}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(function)}\([^;]+?is '[^']*[\u4e00-\u9fff]",
            )
        self.assertIn("on conflict(source_system,source_observation_id) do nothing", self.lower)
        self.assertIn("p_observation->>'schemaversion'", self.lower)
        self.assertIn("pg_advisory_xact_lock", self.lower)
        self.assertIn("revoke all on function situation.ingest_target_observation", self.lower)
        self.assertIn("grant execute on function situation.ingest_target_observation", self.lower)
        self.assertIn("to detection_ingest", self.lower)
        self.assertNotIn("grant detection_ingest to authenticator", self.lower)

    def test_read_rpcs_have_bounded_parameters_and_documented_json(self):
        for function in (
            "api.get_detection_situation_snapshot",
            "api.get_detection_situation_changes",
            "api.get_target_track_detail",
        ):
            self.assertIn(f"create or replace function {function}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(function)}\([^;]+?is '[^']*返回 json",
            )
        self.assertIn("p_limit integer default 1000", self.lower)
        self.assertIn("p_limit integer default 500", self.lower)
        self.assertIn("p_max_points integer default 2000", self.lower)
        self.assertIn("grant execute on function api.get_detection_situation_snapshot", self.lower)
        self.assertIn("to admin", self.lower)

    def test_api_facade_is_read_only(self):
        for view in ("detection_source_types", "detection_observation_sources"):
            self.assertIn(f"create or replace view api.{view}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on view api\.{view} is '[^']*[\u4e00-\u9fff]",
            )
        self.assertIn("grant select on api.detection_source_types", self.lower)
        self.assertNotIn("grant insert on api.detection_source_types", self.lower)
        self.assertIn("asset_lifecycle_status", self.lower)
        self.assertIn("last_error_code", self.lower)
        self.assertIn("lost_timeout_seconds", self.lower)

    def test_admin_can_update_observation_source_through_bounded_rpc(self):
        function = "api.update_detection_observation_source"
        self.assertIn(f"create or replace function {function}", self.lower)
        self.assertRegex(
            self.lower,
            rf"comment on function {re.escape(function)}\([^;]+?is '[^']*返回 json",
        )
        self.assertIn("lost timeout must be between 5 and 3600 seconds", self.lower)
        self.assertIn("from pg_timezone_names", self.lower)
        self.assertIn("lifecycle_status='active'", self.lower)
        self.assertIn("grant execute on function api.update_detection_observation_source", self.lower)
        self.assertIn("revoke all on function api.update_detection_observation_source", self.lower)
        self.assertNotIn("grant update on situation.observation_source", self.lower)

    def test_source_90_seed_registers_and_binds_the_verified_asset(self):
        self.assertIn("'radar_cloud'", self.lower)
        self.assertIn("'90'", self.lower)
        self.assertIn("'b260705174118582'", self.lower)
        self.assertIn("'radar-cloud-box-90'", self.lower)
        self.assertIn("'counter_uas'", self.lower)
        self.assertIn("st_makepoint(119.1929320,34.5919520)", self.lower)
        self.assertIn("is_simulated", self.lower)
        self.assertIn("from equipment.asset", self.lower)
        self.assertIn("source_system = 'radar_cloud' and source_asset_id = 'b260705174118582'", self.lower)


if __name__ == "__main__":
    unittest.main()
