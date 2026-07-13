from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "backend" / "create_emergency_force_schema.sql"


class EmergencyForceSchemaMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION_PATH.read_text(encoding="utf-8")
        cls.sql_lower = cls.sql.lower()

    def test_creates_english_physical_identifiers_with_wgs84_points(self):
        self.assertIn("create schema if not exists emergency_resource", self.sql_lower)
        for table in [
            "rescue_force",
            "medical_resource",
            "expert_force",
            "shelter",
            "material_warehouse",
            "water_point",
            "landing_site",
        ]:
            self.assertIn(f"create table if not exists emergency_resource.{table}", self.sql_lower)
            self.assertIn(f"on emergency_resource.{table} using gist (geom)", self.sql_lower)
        self.assertEqual(self.sql_lower.count("geom geometry(point, 4326) not null"), 7)

    def test_seed_data_is_explicitly_simulated_and_scattered_in_scenic_area(self):
        self.assertEqual(self.sql_lower.count("is_simulated boolean not null default true"), 7)
        self.assertIn("所有坐标均随机散落在脚本顶部声明的景区范围内", self.sql)
        self.assertGreaterEqual(self.sql.count("ST_SetSRID(ST_MakePoint("), 30)
        self.assertIn("119.23062143399773", self.sql)
        self.assertIn("34.66401112992460", self.sql)

    def test_exposes_only_api_facade_to_postgrest_admin_role(self):
        api_resources = [
            "emergency_rescue_forces",
            "emergency_medical_resources",
            "emergency_experts",
            "emergency_shelters",
            "emergency_material_warehouses",
            "emergency_water_points",
            "emergency_landing_sites",
        ]
        for resource in api_resources:
            self.assertIn(f"create or replace view api.{resource}", self.sql_lower)
            self.assertIn(f"grant select, insert, update, delete on api.{resource} to admin", self.sql_lower)
        self.assertIn("notify pgrst, 'reload schema'", self.sql_lower)


if __name__ == "__main__":
    unittest.main()
