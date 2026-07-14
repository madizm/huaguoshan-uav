from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "backend" / "create_equipment_asset_schema.sql"
SEED_PATH = ROOT / "backend" / "seed_equipment_demo_data.sql"


class EquipmentAssetSchemaMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION_PATH.read_text(encoding="utf-8")
        cls.sql_lower = cls.sql.lower()
        cls.seed = SEED_PATH.read_text(encoding="utf-8")
        cls.seed_lower = cls.seed.lower()

    def test_creates_unified_asset_and_all_category_profiles(self):
        self.assertIn("create schema if not exists equipment", self.sql_lower)
        self.assertIn("create table if not exists equipment.asset (", self.sql_lower)
        for category in [
            "base_station_6g",
            "counter_uas",
            "video_surveillance",
            "uav",
            "unmanned_vehicle",
            "vehicle_surveillance",
            "sensor",
        ]:
            self.assertIn(f"'{category}'", self.sql_lower)
            self.assertIn(f"create table if not exists equipment.{category}_profile", self.sql_lower)
        self.assertIn("create table if not exists equipment.sensor_channel", self.sql_lower)
        self.assertIn("create index if not exists asset_geom_gix", self.sql_lower)
        self.assertIn("prevent_profile_category_change", self.sql_lower)

    def test_models_current_history_observations_capabilities_and_coverage(self):
        for table in [
            "asset_status_current",
            "asset_status_history",
            "raw_observation",
            "capability",
            "asset_capability",
            "asset_coverage",
        ]:
            self.assertIn(f"create table if not exists equipment.{table}", self.sql_lower)
        self.assertIn("connectivity_status in ('online', 'offline', 'unknown')", self.sql_lower)
        self.assertIn("dispatch_status in ('available', 'assigned', 'maintenance', 'unavailable', 'unknown')", self.sql_lower)
        self.assertGreaterEqual(self.sql_lower.count("height_datum = 'amsl'"), 4)
        self.assertIn("confidence >= 0 and confidence <= 1", self.sql_lower)
        self.assertIn("raise exception 'equipment raw observations are append-only'", self.sql_lower)
        self.assertIn("counter-uas capability access level cannot exceed recommendable", self.sql_lower)

    def test_limits_emergency_resource_link_to_four_dispatchable_categories(self):
        self.assertIn("create table if not exists emergency_resource.equipment_resource", self.sql_lower)
        for category in ["uav", "unmanned_vehicle", "vehicle_surveillance", "video_surveillance"]:
            self.assertIn(f"'{category}'", self.sql_lower)
        self.assertIn("equipment_resource_category_guard", self.sql_lower)

    def test_migrates_aircraft_and_separates_reported_flights(self):
        self.assertIn("from flight_plan.aircraft_asset legacy", self.sql_lower)
        self.assertIn("insert into equipment.uav_profile", self.sql_lower)
        self.assertIn("references equipment.uav_profile(asset_id)", self.sql_lower)
        self.assertIn("update flight_plan.reported_flight rf", self.sql_lower)
        self.assertIn("drop column aircraft_id", self.sql_lower)
        self.assertRegex(
            self.sql_lower,
            r"'reported_flight'::text as activity_type[\s\S]+?null::bigint as aircraft_id",
        )

    def test_exposes_only_api_facade_and_preserves_aircraft_fields(self):
        resources = [
            "equipment_assets",
            "equipment_asset_status",
            "equipment_raw_observations",
            "equipment_asset_capabilities",
            "equipment_asset_coverages",
            "equipment_statistics",
            "aircraft_assets",
        ]
        for resource in resources:
            self.assertIn(f"create or replace view api.{resource}", self.sql_lower)
            self.assertRegex(self.sql_lower, rf"comment on view api\.{resource} is '[^']*[\u4e00-\u9fff]")
        for compatibility_field in [
            "source_aircraft_id",
            "asset_code",
            "owner_unit_name",
            "availability_status",
        ]:
            self.assertIn(compatibility_field, self.sql_lower)
        self.assertIn("revoke all on all tables in schema equipment from anonymous", self.sql_lower)
        self.assertNotIn("counter_uas_control", self.sql_lower)

    def test_exposes_online_statistics_by_category(self):
        self.assertIn("create or replace view api.equipment_online_statistics as", self.sql_lower)
        self.assertIn("count(*)::bigint as total_count", self.sql_lower)
        self.assertIn(
            "count(*) filter (where s.connectivity_status = 'online')::bigint as online_count",
            self.sql_lower,
        )
        self.assertIn("as online_rate", self.sql_lower)
        self.assertIn("comment on view api.equipment_online_statistics", self.sql_lower)
        self.assertIn("grant select on api.equipment_online_statistics to admin", self.sql_lower)

    def test_seed_is_idempotent_and_covers_every_category(self):
        for category in [
            "base_station_6g",
            "counter_uas",
            "video_surveillance",
            "uav",
            "unmanned_vehicle",
            "vehicle_surveillance",
            "sensor",
        ]:
            self.assertIn(f"'{category}'", self.seed_lower)
        self.assertIn("on conflict (source_system, source_asset_id) do update", self.seed_lower)
        self.assertIn("is_simulated", self.seed_lower)
        self.assertIn("on conflict (source_system, source_observation_id) do nothing", self.seed_lower)
        self.assertIn("119.23062143399773", self.seed)
        self.assertIn("34.66401112992460", self.seed)

    def test_new_database_objects_have_chinese_comments(self):
        physical_tables = re.findall(
            r"create table if not exists (equipment\.[a-z0-9_]+|emergency_resource\.equipment_resource)",
            self.sql_lower,
        )
        for table in physical_tables:
            self.assertRegex(self.sql_lower, rf"comment on table {re.escape(table)} is '[^']*[\u4e00-\u9fff]")


if __name__ == "__main__":
    unittest.main()
