#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Contract checks for the 今日飞行运营看板 backend API surface.

These tests intentionally stay at the repository's current SQL-contract seam:
they verify the migration exposes one high-level PostgREST RPC through the api
schema and encodes the product-visible counting rules without coupling to a
specific query plan.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_PATH = ROOT / "backend" / "create_flight_operation_api.sql"
ROLE_MIGRATION_PATH = ROOT / "backend" / "migrate_postgrest_api_roles.sql"


class FlightOperationSchemaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = SQL_PATH.read_text(encoding="utf-8").lower()

    def test_core_tables_and_vocabularies_exist(self):
        self.assertIn("create extension if not exists best_geomgrid cascade", self.sql)

        for table in ["flight_plan", "execution_route", "uav_asset", "flight_sortie"]:
            self.assertIn(f"create table if not exists flight_operation.{table}", self.sql)

        self.assertIn("plan_type in ('approval_reported', 'patrol_task')", self.sql)
        self.assertIn("plan_source in ('third_party', 'platform')", self.sql)
        self.assertIn("status in ('pending', 'in_progress', 'completed', 'cancelled', 'abnormal', 'expired')", self.sql)
        self.assertIn("approval_status in ('reported', 'approved', 'rejected', 'revoked', 'unknown')", self.sql)
        self.assertIn("availability_status in ('available', 'unavailable', 'maintenance')", self.sql)
        self.assertIn("status in ('scheduled', 'in_progress', 'completed', 'aborted')", self.sql)

    def test_execution_route_constraints_and_active_route_contract_exist(self):
        self.assertIn("active_execution_route_id bigint", self.sql)
        self.assertIn("flight_operation_plan_active_execution_route_fk", self.sql)
        self.assertIn("flight_operation_execution_route_plan_active_uniq", self.sql)
        self.assertIn("source in ('platform_path_planning_result', 'third_party', 'manual')", self.sql)
        self.assertIn("route_grid_codes gridcell[] not null", self.sql)
        self.assertIn("cardinality(route_grid_codes) > 0", self.sql)
        self.assertIn("platform_path_planning_result_id bigint references flight_path.plan_result(id) on delete restrict", self.sql)
        self.assertIn("platform_validated boolean not null default false", self.sql)
        self.assertIn("external_source is not null", self.sql)
        self.assertIn("external_id is not null", self.sql)
        self.assertIn("external_raw_payload is not null", self.sql)
        self.assertIn("route_geometry is not null", self.sql)
        self.assertIn("comment on column flight_operation.execution_route.route_grid_codes", self.sql)

    def test_execution_route_rpcs_preserve_immutable_gger_evidence(self):
        self.assertIn("create or replace function api.create_third_party_execution_route", self.sql)
        self.assertIn("create or replace function api.create_manual_execution_route", self.sql)
        self.assertIn("create or replace function api.select_platform_path_planning_execution_route", self.sql)
        self.assertIn("drop function if exists api.create_third_party_execution_route(bigint, text, text, jsonb, jsonb, jsonb, jsonb)", self.sql)
        self.assertIn("p_route_grid_codes gridcell[]", self.sql)
        self.assertIn("cardinality(p_route_grid_codes) = 0", self.sql)
        self.assertIn("p_platform_path_planning_result_id", self.sql)
        self.assertIn("result_status <> 'success'", self.sql)
        self.assertIn("'platform_path_planning_result', true", self.sql)
        self.assertIn("active_execution_route_id = v_route.id", self.sql)
        self.assertNotIn("update flight_operation.execution_route\n  set route_grid_codes", self.sql)

    def test_constraints_and_indexes_cover_prd_slice(self):
        for name in [
            "flight_operation_plan_interval_chk",
            "flight_operation_plan_type_fields_chk",
            "flight_operation_sortie_timestamps_chk",
            "flight_operation_sortie_plan_one_to_one_uniq",
            "flight_operation_plan_external_identity_uniq",
            "flight_operation_plan_today_window_idx",
            "flight_operation_plan_type_status_idx",
            "flight_operation_sortie_uav_status_idx",
            "flight_operation_sortie_actual_start_idx",
            "flight_operation_sortie_actual_end_idx",
        ]:
            self.assertIn(name, self.sql)

        self.assertIn("flight_plan_id bigint not null references flight_operation.flight_plan(id) on delete restrict", self.sql)
        self.assertNotIn("flight_path_plan_id", self.sql)

    def test_today_dashboard_rpc_encodes_business_window_and_statistics(self):
        self.assertIn("create or replace function api.get_today_flight_operation_dashboard", self.sql)
        self.assertIn("asia/shanghai", self.sql)
        self.assertIn("planned_start_at < w.end_at", self.sql)
        self.assertIn("planned_end_at > w.start_at", self.sql)
        self.assertIn("approval_status not in ('rejected', 'revoked')", self.sql)
        self.assertIn("actual_start_at >= w.start_at", self.sql)
        self.assertIn("actual_end_at >= w.start_at", self.sql)
        self.assertIn("nullif((select planned_sortie_count from summary), 0)", self.sql)
        self.assertIn("count(distinct uav_asset_id)", self.sql)

    def test_today_dashboard_uses_one_plan_one_sortie_statistics(self):
        self.assertIn("count(*)::integer as value\n  from actionable_plans", self.sql)
        self.assertIn("where plan_type = 'patrol_task'", self.sql)
        self.assertIn("status not in ('completed', 'cancelled')", self.sql)
        self.assertIn("join actionable_plans p on p.id = s.flight_plan_id", self.sql)
        self.assertNotIn("sum(normalized_planned_sortie_count)", self.sql)
        self.assertNotIn("coalesce(planned_sortie_count, 1)", self.sql)
        self.assertNotIn("normalized_planned_sortie_count", self.sql)

    def test_dashboard_returns_active_execution_route_contract(self):
        self.assertIn("active_execution_route", self.sql)
        self.assertIn("route_grid_codes", self.sql)
        self.assertIn("platform_validated", self.sql)
        self.assertIn("platform_validation_label", self.sql)
        self.assertIn("未复核可飞", self.sql)
        self.assertIn("route_geometry", self.sql)

    def test_import_rpc_preserves_third_party_provenance(self):
        self.assertIn("create or replace function api.import_approval_reported_flight", self.sql)
        self.assertIn("external_source", self.sql)
        self.assertIn("external_id", self.sql)
        self.assertIn("external_raw_payload", self.sql)
        self.assertIn("on conflict (external_source, external_id) do update", self.sql)


class FlightOperationAuthorizationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = SQL_PATH.read_text(encoding="utf-8").lower()
        cls.role_sql = ROLE_MIGRATION_PATH.read_text(encoding="utf-8").lower()

    def test_api_rpc_requires_admin_and_is_granted_only_to_admin(self):
        self.assertIn("create or replace function flight_operation.require_admin()", self.sql)
        self.assertIn("if v_role <> 'admin' then", self.sql)
        self.assertIn("grant execute on function api.get_today_flight_operation_dashboard", self.sql)
        self.assertIn("grant execute on function api.import_approval_reported_flight", self.sql)
        self.assertIn("grant execute on function api.create_third_party_execution_route", self.sql)
        self.assertIn("grant execute on function api.create_manual_execution_route", self.sql)
        self.assertIn("grant execute on function api.select_platform_path_planning_execution_route", self.sql)
        self.assertNotRegex(self.sql, re.compile(r"grant execute .* to anonymous"))

    def test_role_migration_includes_flight_operation_business_schema(self):
        self.assertIn("flight_operation", self.role_sql)
        self.assertRegex(self.role_sql, re.compile(r"grant usage on schema[\s\S]*flight_operation[\s\S]*to admin"))
        self.assertRegex(self.role_sql, re.compile(r"alter default privileges[\s\S]*flight_operation[\s\S]*grant execute on functions to admin"))


if __name__ == "__main__":
    unittest.main()
