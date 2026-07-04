# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "fastapi>=0.115",
#   "httpx>=0.27",
#   "PyJWT>=2.8",
#   "argon2-cffi>=23.1",
# ]
# ///

from __future__ import annotations

import importlib.util
import sys
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "backend" / "auth_service.py"

spec = importlib.util.spec_from_file_location("auth_service", MODULE_PATH)
auth_service = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = auth_service
assert spec.loader is not None
spec.loader.exec_module(auth_service)


class FakeClock:
    def __init__(self) -> None:
        self.now = datetime(2026, 1, 1, 8, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        return self.now


class FakePasswordVerifier:
    def verify(self, password_hash: str, password: str) -> bool:
        return password_hash == f"hash:{password}"


class FakeUserAccountRepository:
    def __init__(self) -> None:
        self.accounts: dict[str, auth_service.UserAccount] = {}

    def add(self, account: auth_service.UserAccount) -> None:
        self.accounts[account.username] = account

    def get_by_username_for_update(self, username: str):
        return self.accounts.get(username)

    def record_failed_login(self, account_id: UUID, *, failed_count: int, locked_until):
        for username, account in self.accounts.items():
            if account.id == account_id:
                self.accounts[username] = replace(account, failed_login_count=failed_count, locked_until=locked_until)
                return
        raise AssertionError("account not found")

    def record_successful_login(self, account_id: UUID):
        for username, account in self.accounts.items():
            if account.id == account_id:
                self.accounts[username] = replace(account, failed_login_count=0, locked_until=None)
                return
        raise AssertionError("account not found")


clock = FakeClock()


def make_client(repo: FakeUserAccountRepository):
    from fastapi.testclient import TestClient

    settings = auth_service.AuthSettings(
        jwt_secret="test-secret-with-at-least-32-bytes",
        jwt_issuer="huaguoshan-uav-test",
        token_ttl_seconds=300,
    )
    app = auth_service.create_app(
        settings=settings,
        repository_factory=lambda: repo,
        password_verifier=FakePasswordVerifier(),
        clock=clock,
    )
    return TestClient(app)


def account(username="admin", password="correct", enabled=True, failed_login_count=0, locked_until=None):
    return auth_service.UserAccount(
        id=UUID("00000000-0000-0000-0000-000000000001"),
        username=username,
        password_hash=f"hash:{password}",
        enabled=enabled,
        failed_login_count=failed_login_count,
        locked_until=locked_until,
    )


class AuthServiceHttpTests(unittest.TestCase):
    def setUp(self) -> None:
        clock.now = datetime(2026, 1, 1, 8, 0, tzinfo=timezone.utc)

    def test_healthz_is_anonymous(self):
        repo = FakeUserAccountRepository()
        client = make_client(repo)

        response = client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "healthy"})

    def test_login_returns_postgrest_admin_token_and_current_user(self):
        repo = FakeUserAccountRepository()
        repo.add(account())
        client = make_client(repo)

        response = client.post("/auth/login", json={"username": "admin", "password": "correct"})

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["token_type"], "bearer")
        self.assertEqual(payload["expires_in"], 300)
        self.assertEqual(payload["user"], {"id": "00000000-0000-0000-0000-000000000001", "username": "admin", "role": "admin"})
        claims = auth_service.decode_access_token(payload["access_token"], auth_service.AuthSettings(jwt_secret="test-secret-with-at-least-32-bytes"), now=clock())
        self.assertEqual(claims["iss"], "huaguoshan-uav-test")
        self.assertEqual(claims["sub"], "user_account:00000000-0000-0000-0000-000000000001")
        self.assertEqual(claims["role"], "admin")
        self.assertEqual(claims["username"], "admin")
        self.assertEqual(repo.accounts["admin"].failed_login_count, 0)

        me = client.get("/auth/me", headers={"Authorization": f"Bearer {payload['access_token']}"})
        self.assertEqual(me.status_code, 200)
        self.assertEqual(me.json()["id"], "00000000-0000-0000-0000-000000000001")
        self.assertEqual(me.json()["username"], "admin")
        self.assertEqual(me.json()["role"], "admin")
        self.assertEqual(me.json()["expires_at"], "2026-01-01T08:05:00Z")

    def test_unknown_wrong_disabled_and_locked_logins_share_public_failure(self):
        repo = FakeUserAccountRepository()
        repo.add(account(username="admin", password="correct"))
        repo.add(account(username="disabled", enabled=False))
        repo.add(account(username="locked", locked_until=clock() + timedelta(minutes=5)))
        client = make_client(repo)

        attempts = [
            {"username": "missing", "password": "whatever"},
            {"username": "admin", "password": "wrong"},
            {"username": "disabled", "password": "correct"},
            {"username": "locked", "password": "correct"},
        ]

        bodies = []
        for login in attempts:
            response = client.post("/auth/login", json=login)
            self.assertEqual(response.status_code, 401)
            bodies.append(response.json())
        self.assertEqual(bodies, [bodies[0]] * len(bodies))
        self.assertEqual(bodies[0], {"detail": "Invalid username or password"})

    def test_five_consecutive_failures_lock_account_and_success_resets_counter(self):
        repo = FakeUserAccountRepository()
        repo.add(account())
        client = make_client(repo)

        for _ in range(5):
            response = client.post("/auth/login", json={"username": "admin", "password": "wrong"})
            self.assertEqual(response.status_code, 401)

        locked_account = repo.accounts["admin"]
        self.assertEqual(locked_account.failed_login_count, 5)
        self.assertEqual(locked_account.locked_until, clock() + timedelta(minutes=15))
        self.assertEqual(client.post("/auth/login", json={"username": "admin", "password": "correct"}).status_code, 401)

        clock.now += timedelta(minutes=16)
        self.assertEqual(client.post("/auth/login", json={"username": "admin", "password": "correct"}).status_code, 200)
        self.assertEqual(repo.accounts["admin"].failed_login_count, 0)
        self.assertIsNone(repo.accounts["admin"].locked_until)

    def test_me_rejects_missing_invalid_and_expired_tokens(self):
        repo = FakeUserAccountRepository()
        client = make_client(repo)

        self.assertEqual(client.get("/auth/me").status_code, 401)
        self.assertEqual(client.get("/auth/me", headers={"Authorization": "Bearer nope"}).status_code, 401)

        settings = auth_service.AuthSettings(jwt_secret="test-secret-with-at-least-32-bytes", token_ttl_seconds=1)
        token = auth_service.sign_access_token(account(), settings=settings, now=clock())
        clock.now += timedelta(seconds=2)
        self.assertEqual(client.get("/auth/me", headers={"Authorization": f"Bearer {token}"}).status_code, 401)


if __name__ == "__main__":
    unittest.main()
