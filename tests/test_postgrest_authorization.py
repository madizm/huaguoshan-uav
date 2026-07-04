from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SQL_PATH = ROOT / "backend" / "create_postgrest_authorization.sql"
PGREST_CONF_PATH = ROOT / "pgrest.conf"
SEED_PATH = ROOT / "scripts" / "seed_platform_identity.py"

spec = importlib.util.spec_from_file_location("seed_platform_identity", SEED_PATH)
seed_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = seed_module
assert spec.loader is not None
spec.loader.exec_module(seed_module)


def normalized_sql(path: Path) -> str:
    return " ".join(path.read_text(encoding="utf-8").split())


class PostgrestAuthorizationDeploymentTests(unittest.TestCase):
    def test_authorization_sql_converges_roles_and_tightens_prototype_grants(self):
        sql = normalized_sql(SQL_PATH)

        for role in ["web_anon", "airspace_reader", "flight_planner", "airspace_admin"]:
            self.assertIn(f"create role {role} nologin", sql)
        self.assertIn("create role postgrest_authenticator login noinherit", sql)
        self.assertIn("grant web_anon, airspace_reader, flight_planner, airspace_admin to postgrest_authenticator", sql)
        self.assertIn("grant airspace_reader to flight_planner", sql)
        self.assertIn("grant flight_planner to airspace_admin", sql)
        self.assertIn("revoke insert, update, delete on airspace.no_fly_zone", sql)
        self.assertIn("grant insert, update on airspace.no_fly_zone to airspace_admin", sql)
        self.assertNotIn("grant delete on airspace.no_fly_zone", sql)
        self.assertIn("revoke execute on function citydb.create_flight_path_plan", sql)
        self.assertIn("from public, web_anon, airspace_reader", sql)
        self.assertIn("to flight_planner", sql)
        self.assertIn("revoke execute on function citydb.delete_flight_path_plan(bigint) from public, web_anon, airspace_reader, flight_planner, airspace_admin", sql)

    def test_authorization_sql_creates_argon2id_identity_store(self):
        sql = normalized_sql(SQL_PATH)

        self.assertIn("create schema if not exists auth", sql)
        self.assertIn("create table if not exists auth.platform_identity", sql)
        self.assertIn("password_hash text not null", sql)
        self.assertIn("password_hash like '$argon2id$%'", sql)
        self.assertIn("enabled boolean not null default true", sql)
        self.assertIn("permission_level in ('airspace_reader', 'flight_planner', 'airspace_admin')", sql)

    def test_postgrest_config_does_not_commit_superuser_connection_or_jwt_secret(self):
        conf = PGREST_CONF_PATH.read_text(encoding="utf-8")

        self.assertNotIn("postgres:postgres", conf)
        self.assertNotIn("db-uri =", conf)
        self.assertNotIn("jwt-secret =", conf)
        self.assertIn("PGRST_DB_URI=postgres://postgrest_authenticator", conf)
        self.assertIn("PGRST_JWT_SECRET", conf)


class PlatformIdentitySeedTests(unittest.TestCase):
    def test_seed_sql_is_idempotent_and_uses_argon2id_hash(self):
        seed = seed_module.PlatformIdentitySeed(
            username="admin",
            display_name="值班管理员",
            permission_level="airspace_admin",
            password_hash="$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$YWJjZA",
        )

        sql = seed.sql()

        self.assertIn("insert into auth.platform_identity", sql)
        self.assertIn("on conflict (username) do update", sql)
        self.assertIn("'admin'", sql)
        self.assertIn("'值班管理员'", sql)
        self.assertIn("'$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$YWJjZA'", sql)
        self.assertNotIn("password", sql.lower().replace("password_hash", ""))

    def test_rejects_non_argon2id_hashes(self):
        args = seed_module.parse_args([
            "--username",
            "admin",
            "--display-name",
            "值班管理员",
            "--password-hash",
            "plaintext",
        ])

        with self.assertRaises(SystemExit):
            seed_module.build_seed(args)


if __name__ == "__main__":
    unittest.main()
