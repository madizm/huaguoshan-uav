from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "backend" / "create_police_team_schema.sql"


class PoliceTeamSchemaMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION_PATH.read_text(encoding="utf-8")
        cls.sql_lower = cls.sql.lower()

    def test_creates_normalized_officer_team_and_membership_tables(self):
        for table in ["police_officer", "police_team", "police_team_member"]:
            self.assertIn(
                f"create table if not exists emergency_resource.{table}",
                self.sql_lower,
            )
            self.assertRegex(
                self.sql,
                rf"comment on table emergency_resource\.{table} is '[^']*[\u4e00-\u9fff]",
            )

        self.assertIn("officer_no text not null unique", self.sql_lower)
        self.assertIn(
            "station_id bigint references emergency_resource.police_station(id)",
            self.sql_lower,
        )
        self.assertIn("on update cascade on delete set null", self.sql_lower)
        self.assertIn(
            "team_id bigint not null references emergency_resource.police_team(id)",
            self.sql_lower,
        )
        self.assertIn(
            "officer_id bigint not null references emergency_resource.police_officer(id)",
            self.sql_lower,
        )

    def test_preserves_membership_history_and_current_membership_integrity(self):
        self.assertIn("joined_at timestamptz not null default now()", self.sql_lower)
        self.assertIn("left_at timestamptz", self.sql_lower)
        self.assertIn("left_at is null or left_at >= joined_at", self.sql_lower)
        self.assertRegex(
            self.sql_lower,
            r"create unique index if not exists police_team_one_active_leader_uq[\s\S]*?"
            r"where member_role = 'leader' and left_at is null",
        )
        self.assertRegex(
            self.sql_lower,
            r"create unique index if not exists police_team_one_active_membership_uq[\s\S]*?"
            r"where left_at is null",
        )
        self.assertNotIn("police_officer_one_active_team_uq", self.sql_lower)

    def test_leader_assignment_is_atomic_and_rejects_inactive_officers(self):
        match = re.search(
            r"create or replace function emergency_resource\.assign_police_team_leader\([\s\S]*?\n\$\$;",
            self.sql_lower,
        )
        self.assertIsNotNone(match)
        function_sql = match.group(0)
        self.assertIn("for update", function_sql)
        self.assertIn("where id = p_officer_id and is_active", function_sql)
        self.assertIn("set member_role = 'member'", function_sql)
        self.assertIn("set member_role = 'leader'", function_sql)
        self.assertIn("insert into emergency_resource.police_team_member", function_sql)

    def test_exposes_authenticated_crud_roster_and_leader_rpc(self):
        for resource in [
            "emergency_police_officers",
            "emergency_police_teams",
            "emergency_police_team_members",
        ]:
            self.assertIn(f"create or replace view api.{resource}", self.sql_lower)

        self.assertIn(
            "create or replace view api.emergency_police_team_roster",
            self.sql_lower,
        )
        self.assertIn(
            "create or replace function api.assign_police_team_leader(",
            self.sql_lower,
        )
        self.assertIn("from public, anonymous", self.sql_lower)
        self.assertIn("grant select on api.emergency_police_team_roster", self.sql_lower)
        self.assertIn(
            "grant execute on function api.assign_police_team_leader(bigint, bigint) to admin",
            self.sql_lower,
        )
        self.assertIn("notify pgrst, 'reload schema'", self.sql_lower)

    def test_api_objects_have_chinese_comments_and_rpc_return_description(self):
        for view in [
            "emergency_police_officers",
            "emergency_police_teams",
            "emergency_police_team_members",
            "emergency_police_team_roster",
            "emergency_police_team_details",
            "emergency_police_team_member_history",
        ]:
            self.assertRegex(
                self.sql,
                rf"comment on view api\.{view} is '[^']*[\u4e00-\u9fff]",
            )
        self.assertRegex(
            self.sql,
            r"comment on function api\.assign_police_team_leader\(bigint, bigint\) "
            r"is '[^']*返回[^']*id、team_id[^']*'",
        )

    def test_supports_admin_workflows_without_partial_team_or_deleted_history(self):
        self.assertGreaterEqual(self.sql_lower.count("is_simulated boolean not null default false"), 2)
        self.assertIn("create or replace view api.emergency_police_team_details", self.sql_lower)
        self.assertIn("active_member_count", self.sql_lower)
        self.assertIn("create or replace function emergency_resource.create_police_team(", self.sql_lower)
        self.assertIn("perform emergency_resource.assign_police_team_leader", self.sql_lower)
        self.assertIn("create or replace function emergency_resource.remove_police_team_member(", self.sql_lower)
        self.assertIn("current team leader must be replaced before leaving the team", self.sql_lower)
        self.assertIn("create or replace function api.create_police_team(", self.sql_lower)
        self.assertIn("create or replace function api.remove_police_team_member(", self.sql_lower)
        self.assertRegex(
            self.sql,
            r"comment on function api\.create_police_team\([^)]*\) is '[^']*返回[^']*'",
        )
        self.assertRegex(
            self.sql,
            r"comment on function api\.remove_police_team_member\([^)]*\) is '[^']*返回[^']*'",
        )


if __name__ == "__main__":
    unittest.main()
