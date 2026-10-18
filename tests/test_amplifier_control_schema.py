from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "backend" / "create_countermeasure_amplifier_schema.sql"


class AmplifierControlSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION.read_text(encoding="utf-8")
        cls.lower = cls.sql.lower()

    def test_creates_control_state_audit_and_outbox_tables(self):
        for table in (
            "control_authorization",
            "amplifier_operation",
            "command_outbox",
            "amplifier_state_current",
            "amplifier_status_event",
            "operation_event",
            "alert",
        ):
            self.assertIn(f"create table if not exists countermeasure.{table}", self.lower)
            self.assertRegex(
                self.lower,
                rf"comment on table countermeasure\.{table} is '[^']*[\u4e00-\u9fff]",
            )

    def test_only_box_and_countermeasure_online_are_device_state_gates(self):
        start = re.search(
            r"create or replace function api\.start_amplifier_operation\(p_request jsonb\).*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("connectivity_status", start)
        self.assertIn("is distinct from 'online'", start)
        self.assertIn("countermeasure_device_online", start)
        self.assertIn(") is not true", start)
        self.assertNotIn("unattended", start)
        self.assertNotIn("telemetry_stale", start)
        self.assertNotIn("active_frequencies_mhz", start)

    def test_start_is_idempotent_and_serialized_per_asset(self):
        self.assertIn("unique(requested_by_sub,idempotency_key)", self.lower.replace(" ", ""))
        self.assertIn("where terminal_at is null", self.lower)
        self.assertIn("pg_advisory_xact_lock", self.lower)
        self.assertIn("idempotency_conflict", self.lower)
        self.assertIn("insert into countermeasure.command_outbox", self.lower)

    def test_modes_frequencies_and_deadlines_are_bounded(self):
        self.assertIn("omnidirectional_frequency", self.lower)
        self.assertIn("target_coordinate", self.lower)
        self.assertIn("requested_duration_seconds between 1 and 60", self.lower)
        for frequency in ("2400", "5200", "5800"):
            self.assertIn(frequency, self.lower)
        self.assertIn("target_coordinate_system='wgs84'", self.lower.replace(" ", ""))
        self.assertIn("device_hard_protection_seconds", self.lower)
        self.assertIn("120", self.lower)

    def test_amp_stop_never_claims_to_stop_strike(self):
        stop = re.search(
            r"create or replace function api\.stop_amplifier_operation\(.*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("unsupported_operation_mode", stop)
        self.assertIn("omnidirectional_frequency", stop)
        self.assertNotIn("command_kind,'strike'", stop.replace(" ", ""))

    def test_http_dispatch_and_websocket_confirmation_are_separate(self):
        self.assertIn("complete_amplifier_command", self.lower)
        self.assertIn("awaiting_on_confirmation", self.lower)
        self.assertIn("awaiting_off_confirmation", self.lower)
        ingest = re.search(
            r"create or replace function countermeasure\.ingest_amplifier_status\(p_status jsonb\).*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("amplifier_status_event", ingest)
        self.assertIn("amplifier_state_current", ingest)
        self.assertIn("ampstatus", self.lower)

    def test_worker_claim_uses_lease_and_skip_locked(self):
        self.assertIn("for update skip locked", self.lower)
        self.assertIn("lease_token", self.lower)
        self.assertIn("lease_expires_at", self.lower)
        self.assertIn("claim_next_amplifier_command", self.lower)
        self.assertIn("fail_amplifier_command", self.lower)

    def test_sensitive_access_guard_uses_authorization_not_asset_id(self):
        guard = re.search(
            r"create or replace function equipment\.limit_sensitive_device_access\(\).*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("countermeasure.control_authorization", guard)
        self.assertIn("radio_jamming", guard)
        self.assertNotIn("82", guard)

    def test_asset_82_is_seeded_by_stable_source_identity(self):
        self.assertIn("b260705174118582", self.lower)
        self.assertIn("radio_jamming", self.lower)
        self.assertIn("'controllable'", self.lower)
        self.assertNotRegex(self.lower, r"where\s+(?:a\.)?id\s*=\s*82")

    def test_authenticated_users_ingest_and_worker_interfaces_are_separate(self):
        self.assertIn("create role countermeasure_worker", self.lower)
        self.assertIn("grant execute on function api.start_amplifier_operation(jsonb) to admin", self.lower)
        self.assertIn("grant execute on function api.stop_amplifier_operation(bigint,uuid,text,text) to admin", self.lower)
        self.assertIn("grant execute on function api.emergency_stop_amplifier(bigint,text,text) to admin", self.lower)
        self.assertIn("grant execute on function countermeasure.ingest_amplifier_status(jsonb) to detection_ingest", self.lower)
        self.assertIn("grant execute on function countermeasure.claim_next_amplifier_command(text,integer) to countermeasure_worker", self.lower)
        self.assertIn("revoke all on all tables in schema countermeasure from public,anonymous,admin", self.lower)
        self.assertIn("revoke all on function api.start_amplifier_operation(jsonb) from public,anonymous", self.lower)

    def test_opening_commands_are_not_reclaimed_after_max_attempts(self):
        claim = re.search(
            r"create or replace function countermeasure\.claim_next_amplifier_command\(.*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("attempt_count>=max_attempts", claim.replace(" ", ""))
        self.assertIn("attempt_count<c.max_attempts", claim.replace(" ", ""))
        self.assertIn("worker_lease_expired", claim)

    def test_status_correlation_rejects_stale_and_predispatch_events(self):
        ingest = re.search(
            r"create or replace function countermeasure\.ingest_amplifier_status\(p_status jsonb\).*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("v_is_stale", ingest)
        self.assertIn("start_dispatch_attempted_at is not null", ingest)
        self.assertIn("returning asset_id into v_current_asset_id", ingest)

    def test_queued_start_can_be_cancelled_before_dispatch(self):
        stop = re.search(
            r"create or replace function api\.stop_amplifier_operation\(.*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("cancelled_before_dispatch", stop)
        self.assertIn("stop_idempotency_key", stop)

    def test_strike_timeout_stays_nonterminal_and_marks_actual_state_unknown(self):
        advance = re.search(
            r"create or replace function countermeasure\.advance_due_amplifier_operations\(\).*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("amplifier_state_current", advance)
        self.assertIn("duration_expiry_not_confirmed", advance)
        unknown_update = re.search(r"update countermeasure\.amplifier_operation set state='unknown'.*?;", advance, re.S).group()
        self.assertNotIn("terminal_at=", unknown_update.replace(" ", ""))

    def test_strike_persists_actual_dispatched_duration_and_expiry(self):
        self.assertIn("dispatched_duration_seconds", self.lower)
        self.assertIn("expected_expiry_at", self.lower)
        self.assertIn("jsonb_set(canonical_request,'{durationseconds}'", self.lower)

    def test_emergency_stop_validates_routing_and_true_idempotency(self):
        emergency = re.search(
            r"create or replace function api\.emergency_stop_amplifier\(.*?\n\$\$;",
            self.lower,
            re.S,
        ).group()
        self.assertIn("exactly one enabled radar_cloud source mapping", emergency)
        self.assertIn("idempotency_conflict", emergency)
        self.assertIn("requested_by_sub", emergency)

    def test_api_schema_has_documented_read_views_and_json_rpcs(self):
        for view in (
            "amplifier_state_current",
            "amplifier_operations",
            "amplifier_operation_events",
        ):
            self.assertIn(f"create or replace view api.{view}", self.lower)
            self.assertRegex(self.lower, rf"comment on view api\.{view} is '[^']*[\u4e00-\u9fff]")
        for function in (
            "api.start_amplifier_operation",
            "api.stop_amplifier_operation",
            "api.emergency_stop_amplifier",
        ):
            self.assertRegex(
                self.lower,
                rf"comment on function {re.escape(function)}\([^;]+?is '[^']*返回 json",
            )


if __name__ == "__main__":
    unittest.main()
