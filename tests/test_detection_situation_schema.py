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
            "detection_method",
            "detection_method_mapping",
            "detection_method_mapping_history",
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
        self.assertIn("p_observation->>'detectionmethodcode'", self.lower)
        self.assertIn("p_observation->>'sourceproducerassetid'", self.lower)
        self.assertIn("detection_method_code", self.lower)
        self.assertIn("p_observation->>'sourceobservationid'", self.lower)
        self.assertNotIn("jsonb_array_elements(v_items)", self.lower)
        self.assertIn("p_observation#>>'{remotepilotlocation,longitude}'", self.lower)
        self.assertIn("p_observation#>>'{remotepilotlocation,latitude}'", self.lower)
        self.assertIn("pilot_geom", self.lower)
        self.assertIn("raw_payload->>'pilotgps'", self.lower)
        self.assertIn("update situation.target_observation", self.lower)

    def test_remote_pilot_capability_is_registered_for_verified_device(self):
        self.assertIn("'remote_pilot_localization'", self.lower)
        self.assertIn("'coordinate_system','wgs84'", self.lower)


    def test_write_functions_are_private_and_idempotent(self):
        for function in (
            "situation.ingest_target_observation",
            "situation.update_detection_connector_status",
            "situation.reconcile_detection_targets",
            "situation.sync_detection_source_asset",
            "situation.ingest_detection_config_status",
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
        self.assertIn("insert into equipment.asset_status_current", self.lower)
        self.assertIn("update equipment.asset", self.lower)
        self.assertIn("grant execute on function situation.sync_detection_source_asset", self.lower)
        self.assertNotIn("v_raw->>'stationcode'", self.lower)
        self.assertNotIn("p_asset->>'onlinestatus'", self.lower)

    def test_read_rpcs_have_bounded_parameters_and_documented_json(self):
        for function in (
            "api.get_detection_situation_snapshot",
            "api.get_detection_live_tracks",
            "api.get_detection_situation_changes",
            "api.list_detection_target_tracks",
            "api.get_target_track_detail",
        ):
            self.assertIn(f"create or replace function {function}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(function)}\([^;]+?is '[^']*返回 json",
            )
        self.assertIn("p_limit integer default 1000", self.lower)
        self.assertIn("p_limit integer default 500", self.lower)
        self.assertIn("p_trail_seconds integer default 300", self.lower)
        self.assertIn("p_max_points_per_track integer default 300", self.lower)
        self.assertIn("'position',case when r.geom is null then null else st_asgeojson", self.lower)
        self.assertIn("grant execute on function api.get_detection_live_tracks", self.lower)
        self.assertIn("create or replace function api.get_detection_live_tracks_v2", self.lower)
        self.assertIn("p_detection_method_codes text[] default null", self.lower)
        self.assertIn("grant execute on function api.get_detection_live_tracks_v2", self.lower)
        self.assertIn("create or replace function api.get_detection_live_tracks_v3", self.lower)
        self.assertIn("grant execute on function api.get_detection_live_tracks_v3", self.lower)
        self.assertIn("'target_location'", self.lower)
        self.assertIn("'remote_pilot_location'", self.lower)
        self.assertIn("'observations'", self.lower)
        self.assertIn("'observation',case when", self.lower)
        self.assertIn("'observation_methods'", self.lower)
        self.assertIn("p_max_points integer default 2000", self.lower)
        self.assertIn("p_end_at-p_start_at>interval '7 days'", self.lower)
        self.assertNotIn("track detail window cannot exceed 24 hours", self.lower)
        self.assertIn("'spatial_point_count',spatial_point_count", self.lower)
        self.assertIn("grant execute on function api.list_detection_target_tracks", self.lower)
        self.assertIn("grant execute on function api.get_detection_situation_snapshot", self.lower)
        self.assertIn("to admin", self.lower)

    def test_api_facade_is_read_only(self):
        for view in (
            "detection_source_types",
            "detection_methods",
            "detection_method_mappings",
            "detection_method_mapping_history",
            "detection_observation_sources",
            "counter_uas_telemetry_current",
            "counter_uas_status_events",
            "counter_uas_telemetry_samples",
        ):
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
        self.assertIn("capability_codes", self.lower)

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

    def test_detection_method_admin_contract_is_bounded(self):
        for function in (
            "api.create_detection_method",
            "api.update_detection_method",
            "api.upsert_detection_method_mapping",
        ):
            self.assertIn(f"create or replace function {function}", self.lower)
            self.assertIn(f"grant execute on function {function}", self.lower)
        self.assertIn("detection method code is immutable", self.lower)
        self.assertIn("accept_ingest", self.lower)
        self.assertIn("audit_detection_method_mapping", self.lower)
        self.assertIn("request.jwt.claims", self.lower)
        self.assertNotIn("grant update on situation.detection_method", self.lower)

    def test_source_90_seed_registers_and_binds_the_verified_asset(self):
        self.assertIn("'radar_cloud'", self.lower)
        self.assertIn("'90'", self.lower)
        self.assertIn("'b260705174118582'", self.lower)
        self.assertIn("'radar-cloud-box-90'", self.lower)
        self.assertIn("'counter_uas'", self.lower)
        self.assertIn("('microwave_detection'),('radio_detection')", self.lower)
        self.assertIn("'range_pending'", self.lower)
        self.assertIn("st_makepoint(119.1929320,34.5919520)", self.lower)
        self.assertIn("is_simulated", self.lower)
        self.assertIn("from equipment.asset", self.lower)
        self.assertIn("source_system = 'radar_cloud' and source_asset_id = 'b260705174118582'", self.lower)

    def test_config_status_updates_current_state_and_bounded_history(self):
        for table in (
            "counter_uas_telemetry_current",
            "counter_uas_status_event",
            "counter_uas_telemetry_sample",
        ):
            self.assertIn(f"create table if not exists equipment.{table}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on table equipment\.{table} is '[^']*[\u4e00-\u9fff]",
            )
        self.assertIn("p_status->>'boxonline'", self.lower)
        self.assertIn("p_status->'activefrequenciesmhz'", self.lower)
        self.assertIn("missing_source_time", self.lower)
        self.assertIn("'status_changed'", self.lower)
        self.assertIn("interval '60 seconds'", self.lower)
        self.assertIn("on conflict(asset_id) do update", self.lower)
        self.assertIn("grant execute on function situation.ingest_detection_config_status", self.lower)
        self.assertIn("api.counter_uas_telemetry_current,api.counter_uas_status_events", self.lower)
        self.assertIn("asset_connectivity_status", self.lower)
        self.assertIn("connector_state", self.lower)
        self.assertIn("telemetry_stale_after_seconds", self.lower)
        self.assertIn("t.received_at < now()-interval '15 seconds' as telemetry_stale", self.lower)
        telemetry_columns = (
            "asset_id", "observed_at", "received_at", "unattended",
            "detection_device_online", "countermeasure_device_online",
            "counter_voltage_v", "counter_current_a", "counter_power_w",
            "counter_temperature_c", "detection_azimuth_deg", "detection_rotating",
            "counter_azimuth_deg", "counter_rotating", "active_frequencies_mhz",
            "radar_device_sn", "radar_asset_id", "radar_online", "radar_geom",
            "radar_altitude_amsl_m", "radar_heading_deg", "radar_base_heading_deg",
            "radar_gps_update_enabled", "quality_flags", "raw_payload", "updated_at",
        )
        for column in telemetry_columns:
            self.assertRegex(
                self.lower,
                rf"comment on column equipment\.counter_uas_telemetry_current\.{column} is '[^']+';",
            )


if __name__ == "__main__":
    unittest.main()
