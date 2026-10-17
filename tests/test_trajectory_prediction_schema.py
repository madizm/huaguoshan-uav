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
            "horizon_seconds", "horizon_policy", "step_seconds", "speed_mps", "heading_deg",
            "turn_rate_dps", "window_seconds", "window_point_count",
            "fit_residual_m", "points", "geom",
        ):
            self.assertRegex(
                self.lower,
                rf"comment on column situation\.trajectory_prediction\.{column} is '[^']*[\u4e00-\u9fff]",
            )

    def test_horizon_policy_has_idempotent_upgrade_and_preserves_positive_configured_horizon(self):
        declaration = "horizon_policy jsonb not null default '{}'::jsonb"
        self.assertIn(declaration, self.lower)
        self.assertRegex(
            self.lower,
            r"alter table situation\.trajectory_prediction\s+add column if not exists "
            + re.escape(declaration),
        )
        self.assertIn("horizon_seconds integer not null check (horizon_seconds > 0)", self.lower)
        comment = self.lower.split(
            "comment on column situation.trajectory_prediction.horizon_policy is '", 1,
        )[1].split("';", 1)[0]
        for field in (
            "horizon_seconds", "mode", "actual_horizon_seconds", "remaining_horizon_seconds",
            "stop_reason", "rule_version", "thresholds", "metrics",
        ):
            self.assertIn(field, comment)

    def test_horizon_policy_exposed_in_realtime_and_admin_queries(self):
        predictions, states = self.realtime_rpc().split("'predictions',", 1)[1].split("'states',", 1)
        for section in (predictions, states):
            self.assertIn("'horizon_policy', latest.horizon_policy", section)
        for name, alias in (("list_trajectory_predictions", "p"), ("get_track_prediction_history", "t")):
            rpc = self.lower.split(f"create or replace function api.{name}(", 1)[1].split("$$;", 1)[0]
            self.assertIn(f"'horizon_policy', {alias}.horizon_policy", rpc)
        comment = self.lower.split("comment on function api.get_trajectory_predictions", 1)[1].split("';", 1)[0]
        self.assertEqual(comment.count('"horizon_policy"'), 2)

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

    def realtime_rpc(self):
        return self.lower.split(
            "create or replace function api.get_trajectory_predictions(", 1,
        )[1].split("$$;", 1)[0]

    def test_realtime_rpc_signature_is_unchanged(self):
        self.assertIn(
            "p_subject_kinds text[] default null,\n"
            "  p_max_subjects integer default 200,\n"
            "  p_max_prediction_age_seconds integer default 30\n"
            ") returns jsonb", self.realtime_rpc(),
        )

    def test_realtime_predictions_keep_latest_valid_contract_and_include_id(self):
        predictions = self.realtime_rpc().split("'predictions',", 1)[1].split("'states',", 1)[0]
        self.assertIn("'id', latest.id", predictions)
        self.assertIn("where p.quality = 'ok'", predictions)
        self.assertIn("make_interval(secs => p_max_prediction_age_seconds)", predictions)
        self.assertIn("'points', latest.points", predictions)

    def test_realtime_states_are_latest_regardless_of_quality_without_points(self):
        states = self.realtime_rpc().split("'states',", 1)[1]
        fields = re.findall(r"'([a-z_]+)', latest\.([a-z_]+)", states)
        expected = (
            "id", "subject_kind", "subject_id", "quality", "reason",
            "base_observed_at", "predicted_at", "horizon_seconds", "horizon_policy",
            "model_code", "model_version", "step_seconds",
        )
        self.assertEqual(fields, [(field, field) for field in expected])
        self.assertIn("from selected_subjects latest", states)
        self.assertNotIn("p_max_prediction_age_seconds", states)
        # No quality predicate or join to valid predictions: a newer insufficient
        # record must remain visible even when predictions contains an older OK row.
        self.assertNotRegex(states, r"(?:p|latest)\.quality\s*=")
        self.assertNotIn("join", states)
        self.assertNotIn("'points'", states)

    def test_realtime_common_pool_filters_and_deduplicates_before_recency_limit(self):
        # Static SQL contract checks only; these do not execute PostgreSQL.
        rpc = self.realtime_rpc()
        pool = rpc.split("with latest_states as (", 1)[1].split("select jsonb_build_object", 1)[0]
        latest_states, selected = pool.split("), selected_subjects as (", 1)
        self.assertIn("select distinct on (p.subject_kind, p.subject_id) p.*", latest_states)
        self.assertIn("p.predicted_at >= now() - interval '10 minutes'", latest_states)
        self.assertIn("p_subject_kinds is null or p.subject_kind = any(p_subject_kinds)", latest_states)
        self.assertIn(
            "order by p.subject_kind, p.subject_id, p.predicted_at desc, p.id desc",
            latest_states,
        )
        self.assertNotRegex(latest_states, r"p\.quality\s*=")
        self.assertNotIn("limit", latest_states)
        self.assertRegex(
            selected,
            r"select \* from latest_states\s+order by predicted_at desc, id desc"
            r"\s+limit p_max_subjects",
        )
        self.assertEqual(rpc.count("limit p_max_subjects"), 1)

    def test_realtime_every_prediction_has_its_latest_state_even_at_subject_limit(self):
        rpc = self.realtime_rpc()
        predictions, states = rpc.split("'predictions',", 1)[1].split("'states',", 1)
        # A newer failed state cannot be displaced by an independent prediction limit.
        self.assertIn("join selected_subjects s", predictions)
        self.assertIn(
            "on s.subject_kind = p.subject_kind and s.subject_id = p.subject_id",
            predictions,
        )
        self.assertIn("select distinct on (p.subject_kind, p.subject_id) p.*", predictions)
        self.assertIn(
            "order by p.subject_kind, p.subject_id, p.predicted_at desc, p.id desc",
            predictions,
        )
        self.assertIn("from selected_subjects latest", states)
        for array in (predictions, states):
            self.assertNotIn("limit", array)
            self.assertIn("order by latest.subject_kind, latest.subject_id", array)
            self.assertIn("'[]'::jsonb", array)

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
    def test_evaluation_table_with_chinese_comment(self):
        self.assertIn(
            "create table if not exists situation.trajectory_prediction_evaluation", self.lower,
        )
        self.assertRegex(
            self.lower,
            r"comment on table situation\.trajectory_prediction_evaluation is '[^']*[\u4e00-\u9fff]",
        )
        self.assertIn("unique (prediction_id, eta_seconds)", self.lower)
        self.assertIn("within_uncertainty boolean not null", self.lower)
        self.assertIn("trajectory_prediction_evaluation_subject_idx", self.lower)

    def test_accuracy_rpcs_documented(self):
        for signature in (
            "api.get_prediction_accuracy_stats(integer)",
            "api.get_prediction_evaluation_detail(bigint)",
            "api.get_track_prediction_history(bigint,timestamptz,timestamptz,integer)",
        ):
            self.assertIn(f"grant execute on function {signature} to admin", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(signature)} is '[^']*[\u4e00-\u9fff]",
            )

    def test_track_prediction_history_is_thinned_and_bounded(self):
        self.assertIn(
            "create or replace function api.get_track_prediction_history(", self.lower,
        )
        self.assertIn("distinct on (floor(extract(epoch from p.base_observed_at)/p_thin_seconds))", self.lower)
        self.assertIn("time window must not exceed 7 days", self.lower)
        self.assertIn("p.quality='ok'", self.lower)

    def test_grants_follow_role_boundaries(self):
        self.assertIn("create role prediction_engine", self.lower)
        self.assertIn(
            "grant select, insert on situation.trajectory_prediction_evaluation to prediction_engine",
            self.lower,
        )
        self.assertIn(
            "revoke all on situation.trajectory_prediction_evaluation from public", self.lower,
        )
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
