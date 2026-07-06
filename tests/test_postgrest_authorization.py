from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "backend" / "migrate_postgrest_api_roles.sql"


class PostgrestAuthorizationMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION_PATH.read_text(encoding="utf-8").lower()

    def test_flight_path_rpc_authorization_is_migrated_to_single_admin_role(self):
        self.assertIn("create or replace function flight_path.require_planning_actor()", self.sql)
        self.assertIn("if v_role <> 'admin' then", self.sql)
        self.assertIn("raise exception 'role % cannot manage flight path plans'", self.sql)
        self.assertNotIn("v_role not in ('flight_planner', 'airspace_admin')", self.sql)

    def test_admin_can_manage_and_list_all_flight_path_plans(self):
        self.assertIn("create or replace function flight_path.assert_plan_access(p_plan_id bigint)", self.sql)
        self.assertIn("create or replace function flight_path.assert_plan_ownership(p_plan_id bigint, p_operation text)", self.sql)
        self.assertIn("perform flight_path.require_planning_actor();", self.sql)
        self.assertIn("return p_plan_id;", self.sql)

        list_plans_match = re.search(
            r"create or replace function flight_path\.list_plans\([\s\S]*?\n\$\$;",
            self.sql,
        )
        self.assertIsNotNone(list_plans_match)
        list_plans_sql = list_plans_match.group(0)
        self.assertIn("with actor as (", list_plans_sql)
        self.assertIn("select flight_path.require_planning_actor() as subject", list_plans_sql)
        self.assertNotIn("created_by =", list_plans_sql)
        self.assertNotIn("airspace_admin", list_plans_sql)

    def test_flight_path_search_rpcs_no_longer_filter_by_obsolete_planner_roles(self):
        for function_name in ["search_results_by_time", "search_results_by_bbox"]:
            match = re.search(
                rf"create or replace function flight_path\.{function_name}\([\s\S]*?\n\$\$;",
                self.sql,
            )
            self.assertIsNotNone(match, function_name)
            function_sql = match.group(0)
            self.assertIn("select flight_path.require_planning_actor() as subject", function_sql)
            self.assertNotIn("created_by =", function_sql)
            self.assertNotIn("airspace_admin", function_sql)

    def test_flight_path_internal_tables_are_not_exposed_as_postgrest_views(self):
        for view_name in [
            "flight_path_plans",
            "flight_path_plan_points",
            "flight_path_plan_results",
        ]:
            self.assertNotIn(f"create or replace view api.{view_name}", self.sql)
            self.assertNotIn(f"grant select on api.{view_name}", self.sql)
        self.assertIn("drop view if exists api.flight_path_plan_results;", self.sql)
        self.assertIn("drop view if exists api.flight_path_plan_points;", self.sql)
        self.assertIn("drop view if exists api.flight_path_plans;", self.sql)


class FlightPathCreatedByAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.migration_sql = MIGRATION_PATH.read_text(encoding="utf-8").lower()
        cls.base_sql = (ROOT / "backend" / "create_flight_path_planning_rpc.sql").read_text(encoding="utf-8").lower()

    def test_create_plan_audit_actor_comes_from_jwt_claims_not_rpc_input(self):
        for sql in [self.migration_sql, self.base_sql]:
            self.assertIn("create or replace function flight_path.current_actor_name()", sql)
            self.assertIn("->> 'username'", sql)
            self.assertIn("->> 'sub'", sql)
            create_plan_match = re.search(
                r"create or replace function flight_path\.create_plan\([\s\S]*?\n\$\$;",
                sql,
            )
            self.assertIsNotNone(create_plan_match)
            create_plan_sql = create_plan_match.group(0)
            self.assertNotIn("p_created_by", create_plan_sql)
            self.assertIn("flight_path.current_actor_name()", create_plan_sql)

    def test_http_create_flight_path_plan_no_longer_accepts_created_by(self):
        for function_schema, sql in [("api", self.migration_sql), ("citydb", self.base_sql)]:
            wrapper_match = re.search(
                rf"create or replace function {function_schema}\.create_flight_path_plan\([\s\S]*?\n\$\$;",
                sql,
            )
            self.assertIsNotNone(wrapper_match)
            wrapper_sql = wrapper_match.group(0)
            self.assertNotIn("p_created_by", wrapper_sql)
            self.assertIn("select flight_path.create_plan(", wrapper_sql)


if __name__ == "__main__":
    unittest.main()
