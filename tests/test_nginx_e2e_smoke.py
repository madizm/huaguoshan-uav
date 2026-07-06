#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "httpx>=0.27",
#   "PyJWT>=2.8",
# ]
# ///
"""Deployment-level smoke test for the unified Nginx entry point.

This test verifies the complete authentication, PostgREST, and documentation path
through Nginx:

  1. /healthz is anonymously reachable
  2. Anonymous PostgREST business API requests are rejected through /postgrest/
  3. Anonymous PostgREST OpenAPI is reachable but may be empty (expected)
  4. /auth/login returns a PostgREST-compatible JWT with role=admin
  5. /auth/me validates the bearer token
  6. Configured protected business endpoints succeed with the admin JWT
  7. PostgREST OpenAPI loaded with the admin JWT shows expected business paths
  8. /docs/ serves the Scalar documentation portal

Usage:
    uv run tests/test_nginx_e2e_smoke.py
    NGINX_HOST=http://10.1.109.151:20000 SMOKE_TEST_PASSWORD=secret uv run tests/test_nginx_e2e_smoke.py
    uv run tests/test_nginx_e2e_smoke.py --host http://10.1.109.151:20000 --username admin --password secret
"""

from __future__ import annotations

import argparse
import os
from typing import Any

DEFAULT_BUSINESS_ENDPOINTS = "no_fly_zone,temp_control_zone"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def normalize_endpoint(value: str) -> str:
    """Return a bare PostgREST endpoint name without leading/trailing slashes."""
    value = value.strip()
    if value.startswith("/postgrest/"):
        value = value[len("/postgrest/") :]
    return value.strip("/")


def parse_business_endpoints(value: str) -> list[str]:
    endpoints = [normalize_endpoint(part) for part in value.split(",")]
    return [endpoint for endpoint in endpoints if endpoint]


def main() -> int:
    import httpx

    parser = argparse.ArgumentParser(
        description="Deployment-level smoke test for the Nginx unified entry point.",
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
    parser.add_argument(
        "--business-endpoints",
        default=env("SMOKE_TEST_BUSINESS_ENDPOINTS", DEFAULT_BUSINESS_ENDPOINTS),
        help=(
            "Comma-separated protected PostgREST endpoint names to probe through /postgrest/. "
            f"Default: {DEFAULT_BUSINESS_ENDPOINTS}."
        ),
    )
    args = parser.parse_args()

    base = args.host.rstrip("/")
    username = args.username
    password = args.password
    business_endpoints = parse_business_endpoints(args.business_endpoints)

    if not business_endpoints:
        print("SMOKE_TEST_BUSINESS_ENDPOINTS must contain at least one protected business endpoint.")
        return 2

    if not password:
        import getpass

        password = getpass.getpass(f"Password for {username}: ")

    failures: list[str] = []
    token: str | None = None

    def check(label: str, condition: bool, detail: str = "") -> None:
        if not condition:
            failures.append(f"FAIL: {label}" + (f" — {detail}" if detail else ""))

    def section(title: str) -> None:
        print(f"\n  ── {title} ──")

    with httpx.Client(base_url=base, timeout=30, follow_redirects=True) as client:
        # ── 1. /healthz ────────────────────────────────────────────────────

        section("1. /healthz is anonymous")
        resp = client.get("/healthz")
        check("GET /healthz returns 200", resp.status_code == 200, f"got {resp.status_code}")
        if resp.status_code == 200:
            body = resp.json()
            check("/healthz reports healthy", body.get("status") == "healthy", str(body))
        print(f"     GET /healthz → {resp.status_code} {resp.json() if resp.status_code == 200 else resp.text}")

        # ── 2. Anonymous PostgREST rejection ───────────────────────────────

        section("2. Anonymous PostgREST business API rejection")
        for endpoint in business_endpoints:
            path = f"/postgrest/{endpoint}"
            resp = client.get(path, headers={"Accept": "application/json"})
            check(
                f"Anonymous GET {path} is rejected",
                resp.status_code in (401, 403),
                f"got {resp.status_code}: {resp.text[:200]}",
            )
            print(f"     Anonymous GET {path} → {resp.status_code}")

        # ── 3. Anonymous PostgREST OpenAPI ─────────────────────────────────

        section("3. Anonymous PostgREST OpenAPI")
        resp = client.get("/postgrest/", headers={"Accept": "application/openapi+json"})
        check("Anonymous GET /postgrest/ OpenAPI is reachable", resp.status_code == 200, f"got {resp.status_code}")
        if resp.status_code == 200:
            body: dict[str, Any] = resp.json()
            paths: dict[str, Any] = body.get("paths", {})
            print(
                "     Anonymous OpenAPI paths count: "
                f"{len(paths)} — {'empty (expected for anonymous)' if len(paths) == 0 else 'WARNING: paths visible anonymously'}"
            )

        # ── 4. Login ───────────────────────────────────────────────────────

        section("4. POST /auth/login")
        resp = client.post("/auth/login", json={"username": username, "password": password})
        check("POST /auth/login returns 200", resp.status_code == 200, f"got {resp.status_code}: {resp.text}")
        if resp.status_code != 200:
            print("     Login failed — skipping token-dependent tests.")
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

        # Verify JWT claims without verifying signature against the deployment secret.
        try:
            import jwt

            unverified = jwt.decode(token, options={"verify_signature": False})
            check("JWT iss claim is set", "iss" in unverified)
            check("JWT sub claim starts with user_account:", str(unverified.get("sub", "")).startswith("user_account:"))
            check("JWT role claim is admin", unverified.get("role") == "admin")
            check("JWT username claim matches", unverified.get("username") == username)
            check("JWT has iat claim", "iat" in unverified)
            check("JWT has exp claim", "exp" in unverified)
        except Exception as exc:  # pragma: no cover - exercised only by deployed smoke failures.
            check("JWT is parseable", False, str(exc))

        print(f"     Login OK — token length={len(token) if token else 0}, user={user_obj.get('username')}")

        # ── 5. /auth/me ────────────────────────────────────────────────────

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

        resp = client.get("/auth/me")
        check("GET /auth/me without token returns 401", resp.status_code == 401, f"got {resp.status_code}")

        # ── 6. Authenticated PostgREST access ──────────────────────────────

        section("6. PostgREST business API with admin JWT")
        for endpoint in business_endpoints:
            path = f"/postgrest/{endpoint}"
            resp = client.get(path, headers={**auth_headers, "Accept": "application/json"})
            check(
                f"Authenticated GET configured protected business endpoint {path} succeeds",
                resp.status_code == 200,
                f"got {resp.status_code}: {resp.text[:200]}",
            )
            if resp.status_code == 200:
                print(f"     GET {path} → {resp.status_code} (body length={len(resp.text)})")

        # ── 7. PostgREST OpenAPI with admin JWT ────────────────────────────

        section("7. PostgREST OpenAPI with admin JWT")
        resp = client.get("/postgrest/", headers={**auth_headers, "Accept": "application/openapi+json"})
        check("Authenticated GET /postgrest/ OpenAPI is reachable", resp.status_code == 200, f"got {resp.status_code}")
        if resp.status_code == 200:
            body = resp.json()
            paths = body.get("paths", {})
            expected_paths = {f"/{endpoint}" for endpoint in business_endpoints}
            present_paths = expected_paths.intersection(paths.keys())
            missing_paths = expected_paths.difference(paths.keys())
            check("Authenticated OpenAPI has business paths", len(paths) > 0, f"got {len(paths)} paths")
            check(
                "Authenticated OpenAPI has expected business paths",
                not missing_paths,
                f"missing {sorted(missing_paths)}, got first paths {list(paths.keys())[:10]}",
            )
            print(
                "     Authenticated OpenAPI paths count: "
                f"{len(paths)} — expected matches={sorted(present_paths) if present_paths else 'none'}"
            )
            for p in list(paths.keys())[:5]:
                print(f"       {p}")

        # ── 8. Scalar documentation portal ─────────────────────────────────

        section("8. Scalar documentation portal")
        resp = client.get("/docs/", headers={"Accept": "text/html"})
        check("GET /docs/ returns 200", resp.status_code == 200, f"got {resp.status_code}: {resp.text[:200]}")
        if resp.status_code == 200:
            check("GET /docs/ returns HTML", "text/html" in resp.headers.get("content-type", ""))
            check("GET /docs/ serves Scalar documentation portal", "Scalar" in resp.text and "PostgREST" in resp.text)
            print(f"     GET /docs/ → {resp.status_code} (body length={len(resp.text)})")

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
