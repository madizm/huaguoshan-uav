from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "backend" / "migrate_equipment_detection_devices.sql"


class DetectionEquipmentMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION.read_text(encoding="utf-8").lower()

    def test_keeps_6g_on_existing_profile_and_adds_six_requested_categories(self):
        self.assertIn("base_station_6g_profile", self.sql)
        for category in (
            "jamming_device", "aoa_direction_finder", "microwave_radar",
            "remote_id_receiver", "directed_energy_device", "electro_optical_device",
        ):
            self.assertIn(f"'{category}'", self.sql)
            self.assertIn(f"create table if not exists equipment.{category}_profile", self.sql)

    def test_profile_tables_have_category_guards_and_chinese_comments(self):
        profiles = re.findall(r"create table if not exists (equipment\.[a-z0-9_]+_profile)", self.sql)
        self.assertEqual(len(profiles), 6)
        self.assertIn("equipment.require_profile_category", self.sql)
        for profile in profiles:
            self.assertRegex(self.sql, rf"comment on table {re.escape(profile)} is '[^']*[\u4e00-\u9fff]")

    def test_adds_capabilities_for_observation_and_response(self):
        for capability in (
            "network_sensing_6g", "radio_jamming", "aoa_measurement", "radio_detection", "microwave_detection",
            "range_measurement", "velocity_measurement", "remote_id_identification",
            "electro_optical_observation", "electro_optical_tracking", "directed_energy_response",
        ):
            self.assertIn(f"'{capability}'", self.sql)

    def test_sensitive_devices_cannot_become_controllable(self):
        self.assertIn("limit_sensitive_device_access", self.sql)
        self.assertIn("'counter_uas', 'jamming_device', 'directed_energy_device'", self.sql)
        self.assertIn("cannot exceed recommendable", self.sql)
        self.assertNotIn("jamming_control", self.sql)
        self.assertNotIn("laser_fire", self.sql)

    def test_has_asset_category_dictionary_and_catalog_name_statistics(self):
        self.assertIn("create table if not exists equipment.asset_category", self.sql)
        self.assertIn("foreign key (category_code) references equipment.asset_category(code)", self.sql)
        self.assertIn("create or replace view api.equipment_asset_categories", self.sql)
        self.assertIn("c.name as catalog_name", self.sql)
        self.assertIn("group by a.category_code, c.name", self.sql)
        self.assertIn("comment on column api.equipment_online_statistics.catalog_name", self.sql)

    def test_exposes_profile_views_with_chinese_comments_and_admin_grants(self):
        for resource in (
            "equipment_jamming_device_profiles", "equipment_aoa_direction_finder_profiles",
            "equipment_microwave_radar_profiles", "equipment_remote_id_receiver_profiles",
            "equipment_directed_energy_device_profiles", "equipment_electro_optical_device_profiles",
        ):
            self.assertIn(f"create or replace view api.{resource}", self.sql)
            self.assertRegex(self.sql, rf"comment on view api\.{resource} is '[^']*[\u4e00-\u9fff]")
        self.assertIn("grant select on api.equipment_asset_categories", self.sql)
        self.assertIn("api.equipment_jamming_device_profiles", self.sql)


class DetectionEquipmentSeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = (ROOT / "scripts/seed_detection_equipment.py").read_text(encoding="utf-8").lower()

    def test_generates_five_to_ten_assets_per_category_in_the_requested_area(self):
        self.assertIn("rng.randint(5, 10)", self.sql)
        self.assertIn("point_in_polygon", self.sql)
        self.assertIn("random_point", self.sql)
        self.assertIn("st_intersection", self.sql)
        self.assertIn("user_feature_collection", self.sql)

    def test_seed_is_idempotent_and_marks_all_data_simulated(self):
        self.assertIn("seed_detection_equipment", self.sql)
        self.assertIn("is_simulated", self.sql)
        self.assertIn("on conflict (source_system, source_asset_id) do update", self.sql)
        self.assertIn("on conflict (source_system, source_observation_id) do nothing", self.sql)
        self.assertIn("simulated_linkage_only", self.sql)
        self.assertIn('client_encoding="utf8"', self.sql)


if __name__ == "__main__":
    unittest.main()
