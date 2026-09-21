from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "backend" / "create_equipment_admin_api.sql"


class EquipmentAdminApiMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.lower = cls.sql.lower()

    def test_exposes_asset_admin_read_model_with_coordinates(self):
        self.assertIn("create or replace view api.equipment_asset_admin_details as", self.lower)
        self.assertIn("st_x(a.geom) as longitude", self.lower)
        self.assertIn("st_y(a.geom) as latitude", self.lower)
        self.assertIn("grant select on api.equipment_asset_admin_details to admin", self.lower)

    def test_maps_every_equipment_category_to_a_profile_table(self):
        for category in (
            "base_station_6g", "counter_uas", "video_surveillance", "uav",
            "unmanned_vehicle", "vehicle_surveillance", "sensor", "jamming_device",
            "aoa_direction_finder", "microwave_radar", "remote_id_receiver",
            "directed_energy_device", "electro_optical_device",
        ):
            self.assertIn(f"when '{category}' then '{category}_profile'", self.lower)

    def test_reads_and_saves_asset_with_category_profile(self):
        self.assertIn("create or replace function api.get_equipment_configuration(", self.lower)
        self.assertIn("create or replace function api.save_equipment_configuration(", self.lower)
        self.assertIn("insert into equipment.asset(", self.lower)
        self.assertIn("jsonb_populate_record", self.lower)
        self.assertIn("unknown profile field", self.lower)
        self.assertIn("grant execute on function api.save_equipment_configuration", self.lower)

    def test_reads_and_saves_related_configuration(self):
        self.assertIn("create or replace view api.equipment_capability_catalog as", self.lower)
        self.assertIn("'capabilities', v_capabilities", self.lower)
        self.assertIn("'sensor_channels', v_sensor_channels", self.lower)
        self.assertIn("'dispatch_resource', v_dispatch_resource", self.lower)
        self.assertIn("'coverages', v_coverages", self.lower)
        self.assertIn("insert into equipment.asset_capability", self.lower)
        self.assertIn("insert into equipment.asset_coverage", self.lower)
        self.assertIn("insert into equipment.sensor_channel", self.lower)
        self.assertIn("insert into emergency_resource.equipment_resource", self.lower)
        self.assertIn("grant select on api.equipment_capability_catalog to admin", self.lower)

    def test_rpc_enforces_category_and_optimistic_locking(self):
        self.assertIn("equipment category is immutable", self.lower)
        self.assertIn("equipment configuration has been modified", self.lower)
        self.assertIn("p_expected_updated_at", self.lower)
        self.assertIn("where code = v_category_code and enabled", self.lower)

    def test_keeps_radar_rpc_as_compatibility_wrapper(self):
        self.assertIn("create or replace function api.save_microwave_radar_configuration(", self.lower)
        self.assertIn("select api.save_equipment_configuration(", self.lower)
        self.assertIn("jsonb_build_object('category_code', 'microwave_radar')", self.lower)

    def test_api_objects_have_chinese_comments_and_fixed_search_path(self):
        for signature in (
            "api.get_equipment_configuration(bigint)",
            "api.save_equipment_configuration(jsonb, jsonb, timestamptz)",
            "api.save_microwave_radar_configuration(jsonb, jsonb, timestamptz)",
        ):
            self.assertIn(f"comment on function {signature} is", self.lower)
        self.assertIn("返回单个设备的资产、专业属性、能力", self.sql)
        self.assertIn("在单个事务中保存设备资产、专业属性、能力", self.sql)
        self.assertIn("set search_path = api, equipment, public, pg_temp", self.lower)


if __name__ == "__main__":
    unittest.main()
