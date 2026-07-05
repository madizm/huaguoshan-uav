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


if __name__ == "__main__":
    unittest.main()
