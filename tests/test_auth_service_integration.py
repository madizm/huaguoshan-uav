# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "argon2-cffi>=23.1",
#   "fastapi>=0.115",
#   "httpx>=0.27",
#   "psycopg[binary]>=3.2",
#   "PyJWT>=2.8",
# ]
# ///

"""Integration tests for the 认证入口服务 against a real PostgreSQL + Argon2id backend.

These tests complement the unit-level fake tests by verifying the actual:
- Argon2id password verification (PHC format, hash matching, rejection of wrong passwords)
- PostgreSQL repository (SQL correctness, FOR UPDATE locking, connection lifecycle)
- Database schema alignment (UserAccount field mapping)
- Full HTTP round-trip through FastAPI + real PgUserAccountRepository
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "backend" / "auth_service.py"
SCRIPTS = ROOT / "scripts" / "create_initial_admin.py"

spec = importlib.util.spec_from_file_location("auth_service", MODULE_PATH)
auth_service = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = auth_service
assert spec.loader is not None
spec.loader.exec_module(auth_service)

spec_cli = importlib.util.spec_from_file_location("create_initial_admin", SCRIPTS)
create_admin = importlib.util.module_from_spec(spec_cli)
sys.modules[spec_cli.name] = create_admin
assert spec_cli.loader is not None
spec_cli.loader.exec_module(create_admin)


# ── connection helpers ──────────────────────────────────────────────


def _pg_dsn() -> str:
    import os

    return os.getenv("AUTH_DATABASE_DSN", os.getenv("CITYDB_DSN", ""))


_real_dsn = _pg_dsn()
_real_schema = "auth"


def _create_test_account(dsn: str, username: str, password: str) -> str:
    args = create_admin.parse_args(["--dsn", dsn, "--username", username, "--password", password, "--replace"])
    return create_admin.create_admin(args, stdin=sys.stdin)


def _delete_account(dsn: str, username: str) -> None:
    import psycopg

    with psycopg.connect(dsn, connect_timeout=15) as conn:
        qname = create_admin.qname("auth", "user_account")
        with conn.cursor() as cur:
            cur.execute(f"delete from {qname} where username = %s", (username,))
        conn.commit()


TEST_USERNAME = f"_test_auth_{uuid4().hex[:12]}"
TEST_PASSWORD = "integration-test-password-long-enough"


class AuthServiceIntegrationTests(unittest.TestCase):
    """Real database + real Argon2id — one integration test class."""

    @classmethod
    def setUpClass(cls) -> None:
        if not _real_dsn:
            raise unittest.SkipTest("AUTH_DATABASE_DSN or CITYDB_DSN not set")
        _create_test_account(_real_dsn, TEST_USERNAME, TEST_PASSWORD)

    @classmethod
    def tearDownClass(cls) -> None:
        if _real_dsn:
            _delete_account(_real_dsn, TEST_USERNAME)

    def setUp(self) -> None:
        from fastapi.testclient import TestClient

        settings = auth_service.AuthSettings()
        # Point at the real database with the real verifier.
        self._app = auth_service.create_app(
            settings=settings,
            # No fake repository — real PgUserAccountRepository.
            repository_factory=lambda: auth_service.PgUserAccountRepository(_real_dsn, _real_schema),
            # Real Argon2id verifier.
            password_verifier=auth_service.Argon2PasswordVerifier(),
        )
        self._client = TestClient(self._app)
        # Reset lockout state between tests.
        _delete_account(_real_dsn, TEST_USERNAME)
        _create_test_account(_real_dsn, TEST_USERNAME, TEST_PASSWORD)

    # ── health ───────────────────────────────────────────────────────

    def test_healthz_returns_healthy(self):
        response = self._client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "healthy"})

    # ── login success ────────────────────────────────────────────────

    def test_login_with_real_credentials_returns_admin_jwt(self):
        response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": TEST_PASSWORD})

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["token_type"], "bearer")
        self.assertGreater(payload["expires_in"], 0)
        self.assertEqual(payload["user"]["username"], TEST_USERNAME)
        self.assertEqual(payload["user"]["role"], "admin")

        # Verify the JWT was signed by the real secret and carries admin claims.
        settings = auth_service.AuthSettings()
        claims = auth_service.decode_access_token(payload["access_token"], settings)
        self.assertEqual(claims["role"], "admin")
        self.assertEqual(claims["username"], TEST_USERNAME)
        self.assertTrue(str(claims["sub"]).startswith("user_account:"))

    # ── wrong password ───────────────────────────────────────────────

    def test_wrong_password_returns_generic_401(self):
        response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": "absolutely-wrong"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json(), {"detail": "Invalid username or password"})

    # ── unknown user ─────────────────────────────────────────────────

    def test_unknown_user_returns_generic_401(self):
        response = self._client.post("/auth/login", json={"username": "definitely-does-not-exist", "password": "whatever"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json(), {"detail": "Invalid username or password"})

    # ── /auth/me ─────────────────────────────────────────────────────

    def test_me_with_real_token(self):
        login_resp = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": TEST_PASSWORD})
        token = login_resp.json()["access_token"]

        me = self._client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(me.status_code, 200)
        self.assertEqual(me.json()["username"], TEST_USERNAME)
        self.assertEqual(me.json()["role"], "admin")
        self.assertIn("expires_at", me.json())

    def test_me_without_token_returns_401(self):
        response = self._client.get("/auth/me")
        self.assertEqual(response.status_code, 401)

    # ── lockout cycle with real database ─────────────────────────────

    def test_several_wrong_passwords_do_not_lock_under_threshold(self):
        for i in range(3):
            response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": f"wrong-{i}"})
            self.assertEqual(response.status_code, 401)

        # Fourth login should still succeed with correct password (counter < 5).
        response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": TEST_PASSWORD})
        self.assertEqual(response.status_code, 200)

    def test_five_wrong_passwords_lock_account_and_correct_password_blocked_while_locked(self):
        # 5 consecutive failures.
        for i in range(5):
            response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": f"wrong-{i}"})
            self.assertEqual(response.status_code, 401)

        # Correct password still blocked (locked by 15-minute window).
        response = self._client.post("/auth/login", json={"username": TEST_USERNAME, "password": TEST_PASSWORD})
        self.assertEqual(response.status_code, 401)

        # Verify the database records the lock.
        import psycopg

        with psycopg.connect(_real_dsn, connect_timeout=15) as conn:
            qname = create_admin.qname("auth", "user_account")
            with conn.cursor() as cur:
                cur.execute(
                    f"select failed_login_count, locked_until from {qname} where username = %s",
                    (TEST_USERNAME,),
                )
                row = cur.fetchone()
            conn.commit()
        self.assertIsNotNone(row, "Test account should exist")
        self.assertEqual(row[0], 5)
        self.assertIsNotNone(row[1], "locked_until should be set after 5 failures")
        self.assertGreater(row[1], datetime.now(timezone.utc), "Lock should still be active")


if __name__ == "__main__":
    unittest.main()
