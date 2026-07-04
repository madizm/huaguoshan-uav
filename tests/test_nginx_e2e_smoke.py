#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "httpx>=0.27",
#   "PyJWT>=2.8",
# ]
# ///
"""E2E smoke test for the unified Nginx entry point.

This test verifies the complete login-to-PostgREST flow through Nginx:

  1. /healthz is anonymously reachable
  2. Anonymous PostgREST business API requests are rejected through /postgrest/
  3. Anonymous PostgREST OpenAPI is accessible but may be empty (expected)
  4. /auth/login returns a PostgREST-compatible JWT with role=admin
  5. /auth/me validates the bearer token
  6. PostgREST business API requests succeed with admin JWT through /postgrest/
  7. PostgREST OpenAPI loaded with admin JWT shows business paths

Usage:
    uv run tests/test_nginx_e2e_smoke.py
    uv run tests/test_nginx_e2e_smoke.py --host http://10.1.109.151
    uv run tests/test_nginx_e2e_smoke.py --host http://10.1.109.151 --username admin --password secret
"""

from __future__ import annotations

import argparse
import os
import sys
import unittest
from typing import Any

import httpx


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="E2E smoke test for the Nginx unified entry point login-to-PostgREST flow.",
    )
    parser.add_argument(
        "--host",
        default=env("NGINX_HOST", "http://127.0.0.1"),
        help="Nginx entry point base URL (default: http://127.0.0.1).",
    )
    parser.add_argument(
        "--username",
        default=env("SMOKE_TEST_USERNAME", "admin"),
        help="Login username for the 认证入口服务.",
    )
    parser.add_argument(
        "--password",
        default=env("SMOKE_TEST_PASSWORD", ""),
        help="Login password. Prefer SMOKE_TEST_PASSWORD env var.",
    )
    args = parser.parse_args()

    base = args.host.rstrip("/")
    username = args.username
    password = args.password

    if not password:
        import getpass

        password = getpass.getpass(f"Password for {username}: ")

    client = httpx.Client(base_url=base, timeout=30)
    failures: list[str] = []
    token: str | None = None

    def check(label: str, condition: bool, detail: str = "") -> None:
        if not condition:
            failures.append(f"FAIL: {label}" + (f" — {detail}" if detail else ""))

    def section(title: str) -> None:
        print(f"\n  ── {title} ──")

    # ── 1. /healthz ────────────────────────────────────────────────────────

    section("1. /healthz is anonymous")
    resp = client.get("/healthz")
    check("GET /healthz returns 200", resp.status_code == 200, f"got {resp.status_code}")
    if resp.status_code == 200:
        body = resp.json()
        check("/healthz reports healthy", body.get("status") == "healthy", str(body))
    print(f"     GET /healthz → {resp.status_code} {resp.json() if resp.status_code == 200 else resp.text}")

    # ── 2. Anonymous PostgREST rejection ───────────────────────────────────

    section("2. Anonymous PostgREST business API rejection")
    resp = client.get("/postgrest/no_fly_zone", headers={"Accept": "application/json"})
    check("Anonymous GET /postgrest/no_fly_zone is rejected", resp.status_code in (401, 403), f"got {resp.status_code}")
    print(f"     Anonymous GET /postgrest/no_fly_zone → {resp.status_code}")

    resp = client.get("/postgrest/temp_control_zone", headers={"Accept": "application/json"})
    check("Anonymous GET /postgrest/temp_control_zone is rejected", resp.status_code in (401, 403), f"got {resp.status_code}")
    print(f"     Anonymous GET /postgrest/temp_control_zone → {resp.status_code}")

    # ── 3. Anonymous PostgREST OpenAPI ─────────────────────────────────────

    section("3. Anonymous PostgREST OpenAPI")
    resp = client.get("/postgrest/", headers={"Accept": "application/openapi+json"})
    check("Anonymous POST /postgrest/ OpenAPI is reachable", resp.status_code == 200, f"got {resp.status_code}")
    if resp.status_code == 200:
        body: dict[str, Any] = resp.json()
        paths: dict[str, Any] = body.get("paths", {})
        # Expect empty paths from anonymous role (this is expected behavior).
        print(f"     Anonymous OpenAPI paths count: {len(paths)} — {'empty (expected for anonymous)' if len(paths) == 0 else 'WARNING: paths visible anonymously'}")

    # ── 4. Login ───────────────────────────────────────────────────────────

    section("4. POST /auth/login")
    resp = client.post("/auth/login", json={"username": username, "password": password})
    check("POST /auth/login returns 200", resp.status_code == 200, f"got {resp.status_code}: {resp.text}")
    if resp.status_code != 200:
        print(f"     Login failed — skipping remaining tests.")
        _print_summary(failures)
        return 1 if failures else 0

    login_payload = resp.json()
    token = login_payload.get("access_token")
    check("Login response has access_token", bool(token), str(login_payload))
    check("Login response has token_type=bearer", login_payload.get("token_type") == "bearer")
    check("Login response has expires_in > 0", isinstance(login_payload.get("expires_in"), int) and login_payload["expires_in"] > 0)

    user_obj = login_payload.get("user", {})
    check("Login response has user object", bool(user_obj))
    check("User object has id", bool(user_obj.get("id")))
    check("User object has username", user_obj.get("username") == username)
    check("User object has role=admin", user_obj.get("role") == "admin")

    # Verify JWT claims (without verifying signature against the secret).
    try:
        import jwt

        unverified = jwt.decode(token, options={"verify_signature": False})
        check("JWT iss claim is set", "iss" in unverified)
        check("JWT sub claim starts with user_account:", str(unverified.get("sub", "")).startswith("user_account:"))
        check("JWT role claim is admin", unverified.get("role") == "admin")
        check("JWT username claim matches", unverified.get("username") == username)
        check("JWT has iat claim", "iat" in unverified)
        check("JWT has exp claim", "exp" in unverified)
    except Exception as exc:
        check("JWT is parseable", False, str(exc))

    print(f"     Login OK — token length={len(token) if token else 0}, user={user_obj.get('username')}")

    # ── 5. /auth/me ────────────────────────────────────────────────────────

    section("5. GET /auth/me (token validation)")
    auth_headers = {"Authorization": f"Bearer {token}"}
    resp = client.get("/auth/me", headers=auth_headers)
    check("GET /auth/me returns 200 with valid token", resp.status_code == 200, f"got {resp.status_code}: {resp.text}")
    if resp.status_code == 200:
        me = resp.json()
        check("/auth/me id matches", bool(me.get("id")))
        check("/auth/me username matches", me.get("username") == username)
        check("/auth/me role is admin", me.get("role") == "admin")
        check("/auth/me has expires_at", "expires_at" in me)
        print(f"     /auth/me → {me.get('username')} (role={me.get('role')}), expires={me.get('expires_at')}")

    # Test /auth/me without token.
    resp = client.get("/auth/me")
    check("GET /auth/me without token returns 401", resp.status_code == 401, f"got {resp.status_code}")

    # ── 6. Authenticated PostgREST access ──────────────────────────────────

    section("6. PostgREST business API with admin JWT")
    resp = client.get("/postgrest/no_fly_zone", headers={**auth_headers, "Accept": "application/json"})
    check("Authenticated GET /postgrest/no_fly_zone succeeds", resp.status_code == 200, f"got {resp.status_code}: {resp.text[:200]}")
    if resp.status_code == 200:
        # May be empty array if no zones seeded, which is fine.
        print(f"     GET /postgrest/no_fly_zone → {resp.status_code} (body length={len(resp.text)})")

    resp = client.get("/postgrest/temp_control_zone", headers={**auth_headers, "Accept": "application/json"})
    check("Authenticated GET /postgrest/temp_control_zone succeeds", resp.status_code == 200, f"got {resp.status_code}: {resp.text[:200]}")
    if resp.status_code == 200:
        print(f"     GET /postgrest/temp_control_zone → {resp.status_code} (body length={len(resp.text)})")

    resp = client.get("/postgrest/flight_path_plans", headers={**auth_headers, "Accept": "application/json"})
    check("Authenticated GET /postgrest/flight_path_plans succeeds", resp.status_code == 200, f"got {resp.status_code}: {resp.text[:200]}")
    if resp.status_code == 200:
        print(f"     GET /postgrest/flight_path_plans → {resp.status_code} (body length={len(resp.text)})")

    # ── 7. PostgREST OpenAPI with admin JWT ────────────────────────────────

    section("7. PostgREST OpenAPI with admin JWT")
    resp = client.get("/postgrest/", headers={**auth_headers, "Accept": "application/openapi+json"})
    check("Authenticated POST /postgrest/ OpenAPI is reachable", resp.status_code == 200, f"got {resp.status_code}")
    if resp.status_code == 200:
        body = resp.json()
        paths = body.get("paths", {})
        check("Authenticated OpenAPI has business paths", len(paths) > 0, f"got {len(paths)} paths")
        print(f"     Authenticated OpenAPI paths count: {len(paths)} — {'OK' if len(paths) > 0 else 'WARNING: no paths visible'}")
        for p in list(paths.keys())[:5]:
            print(f"       {p}")

    # ── 8. Auth service OpenAPI (always anonymous) ─────────────────────────

    section("8. Auth service OpenAPI (anonymous)")
    resp = client.get("/openapi.json")
    check("GET /openapi.json is anonymously reachable", resp.status_code == 200, f"got {resp.status_code}")
    if resp.status_code == 200:
        body = resp.json()
        openapi_paths = body.get("paths", {})
        check("Auth OpenAPI has login path", "/auth/login" in openapi_paths or "/login" in openapi_paths, str(list(openapi_paths.keys())))
        print(f"     Auth OpenAPI paths: {list(openapi_paths.keys())}")

    # ── Summary ────────────────────────────────────────────────────────────
    _print_summary(failures)
    return 1 if failures else 0


def _print_summary(failures: list[str]) -> None:
    print()
    if failures:
        print(f"  ❌ {len(failures)} failure(s):")
        for f in failures:
            print(f"     {f}")
        print()
    else:
        print("  ✅ All E2E smoke checks passed.")
        print()


if __name__ == "__main__":
    raise SystemExit(main())
