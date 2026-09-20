from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "backend" / "create_raw_source_situation_rpc.sql").read_text(encoding="utf-8").lower()


class RawSourceSituationRpcTests(unittest.TestCase):
    def test_reads_all_three_sources_through_one_bounded_rpc(self):
        self.assertIn("raw.eqp_wrj_hf", SQL)
        self.assertIn("raw.eqp_wrj_yh", SQL)
        self.assertIn("raw.eqp_monitor_wyld", SQL)
        self.assertIn("p_end_at - p_start_at > interval '31 days'", SQL)
        self.assertIn("create_time >= p_start_at and create_time < p_end_at", SQL)
        self.assertIn("send_time >= p_start_at and send_time < p_end_at", SQL)

    def test_samples_drone_and_radar_tracks_server_side(self):
        self.assertIn("p_drone_sample_seconds", SQL)
        self.assertIn("distinct on (source_code, sample_bucket)", SQL)
        self.assertIn("distinct on (batch_no)", SQL)
        self.assertIn("latest_per_track_in_window", SQL)
        self.assertIn("jsonb_agg", SQL)

    def test_reports_quality_without_inventing_radar_height(self):
        for field in (
            "missing_position_rows",
            "coordinate_anomaly_rows",
            "altitude_anomaly_rows",
            "speed_anomaly_rows",
            "disappeared_rows",
        ):
            self.assertIn(field, SQL)
        self.assertIn("null::numeric as altitude_m", SQL)
        self.assertIn("'airspace_target'", SQL)

    def test_uses_security_definer_with_fixed_search_path_and_admin_only_grant(self):
        self.assertIn("security definer", SQL)
        self.assertIn("set search_path = pg_catalog, public, raw, api", SQL)
        self.assertIn("revoke all on function api.get_raw_source_situation", SQL)
        self.assertIn("grant execute on function api.get_raw_source_situation", SQL)
        self.assertIn("to admin", SQL)

    def test_function_has_chinese_return_contract_comment(self):
        self.assertIn("comment on function api.get_raw_source_situation", SQL)
        self.assertIn("返回 json 格式", SQL)
        self.assertIn("bounds", SQL)
        self.assertIn("tracks", SQL)


if __name__ == "__main__":
    unittest.main()
