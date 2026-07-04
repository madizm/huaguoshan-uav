#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "argon2-cffi>=23.1.0",
# ]
# ///
"""Seed an initial platform operation identity for the PostgREST auth adapter.

The script never contains or invents a default password. Provide either a
plaintext password through an environment variable (hashed as Argon2id) or an
already-generated Argon2id hash from a secret manager.

Examples:
  HGS_ADMIN_PASSWORD='change-me-outside-git' \
    uv run scripts/seed_platform_identity.py --username admin --display-name '值班管理员' \
    | psql "$DATABASE_URL"

  uv run scripts/seed_platform_identity.py --username admin --display-name '值班管理员' \
    --password-hash '$argon2id$v=19$m=65536,t=3,p=4$...' | psql "$DATABASE_URL"
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass


ARGON2ID_RE = re.compile(r"^\$argon2id\$v=\d+\$m=\d+,t=\d+,p=\d+\$[^\s]+\$[^\s]+$")
LEVELS = ("airspace_reader", "flight_planner", "airspace_admin")


@dataclass(frozen=True)
class PlatformIdentitySeed:
    username: str
    display_name: str
    permission_level: str
    password_hash: str
    enabled: bool = True

    def sql(self) -> str:
        enabled = "true" if self.enabled else "false"
        return f"""insert into auth.platform_identity (username, display_name, permission_level, password_hash, enabled)
values ({sql_literal(self.username)}, {sql_literal(self.display_name)}, {sql_literal(self.permission_level)}, {sql_literal(self.password_hash)}, {enabled})
on conflict (username) do update
set display_name = excluded.display_name,
    permission_level = excluded.permission_level,
    password_hash = excluded.password_hash,
    enabled = excluded.enabled,
    updated_at = now();"""


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def hash_password(password: str) -> str:
    try:
        from argon2 import PasswordHasher
    except ImportError as exc:  # pragma: no cover - depends on deployment env
        raise SystemExit(
            "argon2-cffi is required when using --password-env. "
            "Install it in the maintainer environment or pass --password-hash "
            "with an externally generated Argon2id hash."
        ) from exc

    return PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4).hash(password)


def build_seed(args: argparse.Namespace) -> PlatformIdentitySeed:
    if bool(args.password_env) == bool(args.password_hash):
        raise SystemExit("Provide exactly one of --password-env or --password-hash.")

    if args.password_hash:
        password_hash = args.password_hash
    else:
        password = os.environ.get(args.password_env)
        if not password:
            raise SystemExit(f"Environment variable {args.password_env!r} is not set or is empty.")
        password_hash = hash_password(password)

    if not ARGON2ID_RE.match(password_hash):
        raise SystemExit("Password hash must be an Argon2id encoded hash starting with '$argon2id$'.")

    return PlatformIdentitySeed(
        username=args.username,
        display_name=args.display_name,
        permission_level=args.permission_level,
        password_hash=password_hash,
        enabled=not args.disabled,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--username", required=True, help="Login username for the platform operation identity.")
    parser.add_argument("--display-name", required=True, help="Human-readable operator name shown in the workbench.")
    parser.add_argument(
        "--permission-level",
        default="airspace_admin",
        choices=LEVELS,
        help="Highest operation permission level for the identity.",
    )
    parser.add_argument(
        "--password-env",
        help="Environment variable containing the plaintext password to hash with Argon2id. Defaults to HGS_ADMIN_PASSWORD when --password-hash is omitted.",
    )
    parser.add_argument("--password-hash", help="Externally generated Argon2id password hash.")
    parser.add_argument("--disabled", action="store_true", help="Seed the account disabled.")
    args = parser.parse_args(argv)
    if not args.password_hash and not args.password_env:
        args.password_env = "HGS_ADMIN_PASSWORD"
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    seed = build_seed(args)
    print("begin;")
    print(seed.sql())
    print("commit;")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
