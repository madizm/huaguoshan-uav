#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "argon2-cffi>=23.1",
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Create the first administrator credential for the 认证入口服务.

The script never embeds a default administrator password or password hash. Pass a
password explicitly, provide AUTH_ADMIN_PASSWORD, use --password-stdin, or allow
an interactive prompt.
"""

from __future__ import annotations

import argparse
import getpass
import os
import sys
from dataclasses import dataclass
from typing import Any, Callable

DEFAULT_DSN_ENV = "AUTH_DATABASE_DSN"
FALLBACK_DSN_ENV = "CITYDB_DSN"
DEFAULT_AUTH_SCHEMA = "auth"
MIN_PASSWORD_LENGTH = 12


class ScriptError(RuntimeError):
    """Raised for user-actionable initializer errors."""


@dataclass(frozen=True)
class AdminCredential:
    username: str
    password_hash: str
    enabled: bool


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create the first auth.user_account administrator credential.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--dsn",
        default=os.getenv(DEFAULT_DSN_ENV) or os.getenv(FALLBACK_DSN_ENV),
        help=f"PostgreSQL DSN; defaults to ${DEFAULT_DSN_ENV}, then ${FALLBACK_DSN_ENV}.",
    )
    parser.add_argument("--auth-schema", default=DEFAULT_AUTH_SCHEMA, help="Authentication schema containing user_account.")
    parser.add_argument("--username", required=True, help="Administrator login username.")
    password_group = parser.add_mutually_exclusive_group()
    password_group.add_argument("--password", help="Administrator password. Prefer AUTH_ADMIN_PASSWORD or --password-stdin to avoid shell history.")
    password_group.add_argument("--password-stdin", action="store_true", help="Read the password from standard input.")
    parser.add_argument("--disabled", action="store_true", help="Create the credential with enabled=false.")
    parser.add_argument("--replace", action="store_true", help="Replace an existing credential with the same username.")
    return parser.parse_args(argv)


def validate_identifier(value: str, label: str) -> None:
    if not value or "\x00" in value or "." in value:
        raise ScriptError(f"{label} must be a simple non-empty identifier")


def normalize_username(username: str) -> str:
    normalized = username.strip()
    if not normalized:
        raise ScriptError("--username must not be blank")
    return normalized


def resolve_password(args: argparse.Namespace, stdin: Any = sys.stdin) -> str:
    if args.password is not None:
        password = args.password
    elif args.password_stdin:
        if stdin.isatty():
            password = getpass.getpass("Admin password: ")
        else:
            lines = stdin.read().splitlines()
            if not lines:
                raise ScriptError("--password-stdin did not receive a password")
            password = lines[0]
    elif os.getenv("AUTH_ADMIN_PASSWORD") is not None:
        password = os.environ["AUTH_ADMIN_PASSWORD"]
    else:
        password = getpass.getpass("Admin password: ")
        confirmation = getpass.getpass("Confirm admin password: ")
        if password != confirmation:
            raise ScriptError("Passwords do not match")

    if len(password) < MIN_PASSWORD_LENGTH:
        raise ScriptError(f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    return password


def hash_password(password: str) -> str:
    try:
        from argon2 import PasswordHasher
    except ImportError as exc:  # pragma: no cover - exercised when run without uv script deps
        raise ScriptError("argon2-cffi is required; run with `uv run scripts/create_initial_admin.py ...`") from exc

    # PasswordHasher defaults are Argon2id and produce a PHC string. Keep the
    # hasher centralized so future policy tuning stays in one place.
    return PasswordHasher().hash(password)


def build_credential(args: argparse.Namespace, password: str, hasher: Callable[[str], str] = hash_password) -> AdminCredential:
    username = normalize_username(args.username)
    password_hash = hasher(password)
    if not password_hash.startswith("$argon2id$"):
        raise ScriptError("Password hasher did not produce an Argon2id PHC string")
    return AdminCredential(username=username, password_hash=password_hash, enabled=not args.disabled)


def quote_identifier(value: str) -> str:
    validate_identifier(value, "identifier")
    return '"' + value.replace('"', '""') + '"'


def qname(schema_name: str, relation_name: str) -> str:
    return f"{quote_identifier(schema_name)}.{quote_identifier(relation_name)}"


def insert_credential(conn: Any, auth_schema: str, credential: AdminCredential, replace: bool) -> str:
    target = qname(auth_schema, "user_account")
    with conn.cursor() as cur:
        if replace:
            cur.execute(f"delete from {target} where username = %s", (credential.username,))
        cur.execute(
            f"""
            insert into {target} (username, password_hash, enabled)
            values (%s, %s, %s)
            returning id
            """,
            (credential.username, credential.password_hash, credential.enabled),
        )
        row = cur.fetchone()
    return str(row[0])


def create_admin(args: argparse.Namespace, stdin: Any = sys.stdin, hasher: Callable[[str], str] = hash_password) -> str:
    if not args.dsn:
        raise ScriptError(f"--dsn is required when neither ${DEFAULT_DSN_ENV} nor ${FALLBACK_DSN_ENV} is set")
    validate_identifier(args.auth_schema, "--auth-schema")
    password = resolve_password(args, stdin=stdin)
    credential = build_credential(args, password, hasher=hasher)

    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover
        raise ScriptError("psycopg is required; run with `uv run scripts/create_initial_admin.py ...`") from exc

    with psycopg.connect(args.dsn, connect_timeout=15) as conn:
        account_id = insert_credential(conn, args.auth_schema, credential, args.replace)
        conn.commit()
    return account_id


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        account_id = create_admin(args)
        print(f"Created administrator credential {args.username!r} with id {account_id}.")
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
