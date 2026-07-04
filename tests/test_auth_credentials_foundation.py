from __future__ import annotations

import importlib.util
import io
import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "backend" / "create_auth_credentials.sql"
MODULE_PATH = ROOT / "scripts" / "create_initial_admin.py"

spec = importlib.util.spec_from_file_location("create_initial_admin", MODULE_PATH)
create_initial_admin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = create_initial_admin
assert spec.loader is not None
spec.loader.exec_module(create_initial_admin)


class AuthCredentialsMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = MIGRATION_PATH.read_text(encoding="utf-8").lower()

    def test_user_account_table_is_narrow_credentials_storage(self):
        self.assertIn("create schema if not exists auth", self.sql)
        self.assertIn("create table if not exists auth.user_account", self.sql)
        self.assertIn("create or replace function auth.generate_uuid_v4()", self.sql)
        for column in [
            "id uuid primary key default auth.generate_uuid_v4()",
            "username text not null",
            "password_hash text not null",
            "enabled boolean not null default true",
            "failed_login_count integer not null default 0",
            "locked_until timestamptz",
            "last_failed_login_at timestamptz",
            "last_successful_login_at timestamptz",
            "created_at timestamptz not null default now()",
            "updated_at timestamptz not null default now()",
        ]:
            self.assertIn(column, self.sql)
        self.assertIn("constraint user_account_username_unique unique (username)", self.sql)
        self.assertIn("constraint user_account_password_hash_argon2id check (password_hash like '$argon2id$%')", self.sql)
        self.assertNotIn("avatar", self.sql)
        self.assertNotIn("organization", self.sql)
        self.assertNotIn("menu", self.sql)

    def test_auth_service_role_can_manage_only_credentials(self):
        self.assertIn("create role auth_service login noinherit", self.sql)
        self.assertIn("grant usage on schema auth to auth_service", self.sql)
        self.assertIn("grant select, insert, update on auth.user_account to auth_service", self.sql)
        self.assertIn("array['api', 'citydb', 'airspace', 'terrain', 'citydb_grid', 'flight_path']", self.sql)
        self.assertIn("revoke all on schema %i from auth_service", self.sql)
        self.assertIn("revoke all on all tables in schema %i from auth_service", self.sql)
        self.assertNotIn("grant admin to auth_service", self.sql)
        self.assertNotIn("grant usage on schema citydb", self.sql)


class FakeCursor:
    def __init__(self) -> None:
        self.executed: list[tuple[str, tuple[object, ...]]] = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def execute(self, statement: str, params: tuple[object, ...]) -> None:
        self.executed.append((" ".join(statement.split()), params))

    def fetchone(self):
        return ("00000000-0000-0000-0000-000000000001",)


class FakeConnection:
    def __init__(self) -> None:
        self.cursor_obj = FakeCursor()
        self.committed = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def cursor(self):
        return self.cursor_obj

    def commit(self) -> None:
        self.committed = True


class CreateInitialAdminTests(unittest.TestCase):
    def test_build_credential_requires_argon2id_hash_and_no_default_password(self):
        args = create_initial_admin.parse_args(["--dsn", "postgresql://example/db", "--username", " admin ", "--password", "long-enough-secret"])

        credential = create_initial_admin.build_credential(args, "long-enough-secret", hasher=lambda password: "$argon2id$v=19$hash")

        self.assertEqual(credential.username, "admin")
        self.assertEqual(credential.password_hash, "$argon2id$v=19$hash")
        self.assertTrue(credential.enabled)
        with self.assertRaises(create_initial_admin.ScriptError):
            create_initial_admin.build_credential(args, "long-enough-secret", hasher=lambda password: "$2b$not-argon2")

    def test_password_can_come_from_stdin_and_must_be_strong_enough(self):
        args = create_initial_admin.parse_args(["--dsn", "postgresql://example/db", "--username", "admin", "--password-stdin"])

        self.assertEqual(create_initial_admin.resolve_password(args, stdin=io.StringIO("long-enough-secret\n")), "long-enough-secret")
        with self.assertRaises(create_initial_admin.ScriptError):
            create_initial_admin.resolve_password(args, stdin=io.StringIO("short\n"))

    def test_create_admin_inserts_argon2id_hash_without_committed_default_secret(self):
        fake_conn = FakeConnection()
        fake_psycopg = types.SimpleNamespace(connect=lambda dsn, connect_timeout: fake_conn)
        original = sys.modules.get("psycopg")
        sys.modules["psycopg"] = fake_psycopg
        try:
            args = create_initial_admin.parse_args(
                ["--dsn", "postgresql://example/db", "--username", "admin", "--password", "long-enough-secret", "--replace"]
            )

            account_id = create_initial_admin.create_admin(args, hasher=lambda password: "$argon2id$v=19$hash")
        finally:
            if original is None:
                sys.modules.pop("psycopg", None)
            else:
                sys.modules["psycopg"] = original

        self.assertEqual(account_id, "00000000-0000-0000-0000-000000000001")
        self.assertTrue(fake_conn.committed)
        statements = fake_conn.cursor_obj.executed
        self.assertEqual(statements[0][0], 'delete from "auth"."user_account" where username = %s')
        self.assertIn('insert into "auth"."user_account" (username, password_hash, enabled)', statements[1][0])
        self.assertEqual(statements[1][1], ("admin", "$argon2id$v=19$hash", True))


if __name__ == "__main__":
    unittest.main()
