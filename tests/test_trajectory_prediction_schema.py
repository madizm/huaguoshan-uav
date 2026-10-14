from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "backend" / "create_trajectory_prediction.sql"


class TrajectoryPredictionSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.lower = cls.sql.lower()

    def test_creates_prediction_table_with_chinese_comment(self):
        self.assertIn("create table if not exists situation.trajectory_prediction", self.lower)
        self.assertRegex(
            self.lower,
            r"comment on table situation\.trajectory_prediction is '[^']*[\u4e00-\u9fff]",
        )

    def test_column_comments_are_chinese(self):
        for column in (
            "subject_kind", "subject_id", "base_observed_at", "predicted_at",
            "model_code", "model_version", "quality", "reason",
            "horizon_seconds", "step_seconds", "speed_mps", "heading_deg",
            "turn_rate_dps", "window_seconds", "window_point_count",
            "fit_residual_m", "points", "geom",
        ):
            self.assertRegex(
                self.lower,
                rf"comment on column situation\.trajectory_prediction\.{column} is '[^']*[\u4e00-\u9fff]",
            )

    def test_subject_kind_constraint(self):
        self.assertIn("subject_kind in ('airspace_target','aircraft_asset')", self.lower)

    def test_model_code_constraint(self):
        self.assertIn("model_code in ('cv','ct','hover')", self.lower)

    def test_indexes_exist(self):
        self.assertIn("trajectory_prediction_subject_time_idx", self.lower)
        self.assertIn("trajectory_prediction_geom_gix", self.lower)

    def test_rpc_documented_with_return_shape(self):
        self.assertIn(
            "create or replace function api.get_trajectory_predictions(", self.lower,
        )
        self.assertRegex(
            self.lower,
            r"comment on function api\.get_trajectory_predictions\([^)]*\) is '[^']*[\u4e00-\u9fff]",
        )
        comment_start = self.lower.index("comment on function api.get_trajectory_predictions")
        comment = self.lower[comment_start:]
        for field in ("subject_kind", "points", "uncertainty_m", "eta_seconds"):
            self.assertIn(field, comment)

    def test_worker_runtime_table_with_chinese_comment(self):
        self.assertIn("create table if not exists situation.prediction_worker_runtime", self.lower)
        self.assertRegex(
            self.lower,
            r"comment on table situation\.prediction_worker_runtime is '[^']*[\u4e00-\u9fff]",
        )
        self.assertIn("values('trajectory-prediction')", self.lower)
    def test_admin_rpcs_documented(self):
        for signature in (
            "api.get_prediction_engine_status(integer)",
            "api.list_trajectory_predictions(integer,text[])",
        ):
            self.assertIn(f"grant execute on function {signature} to admin", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(signature)} is '[^']*[\u4e00-\u9fff]",
            )
    def test_grants_follow_role_boundaries(self):
        self.assertIn("create role prediction_engine", self.lower)
        self.assertIn("grant select on situation.trajectory_prediction to admin", self.lower)
        self.assertIn(
            "grant select, insert, delete on situation.trajectory_prediction to prediction_engine",
            self.lower,
        )
        self.assertIn(
            "grant execute on function api.get_trajectory_predictions(text[],integer,integer) to admin",
            self.lower,
        )
        self.assertIn("revoke all on situation.trajectory_prediction from public", self.lower)


if __name__ == "__main__":
    unittest.main()
