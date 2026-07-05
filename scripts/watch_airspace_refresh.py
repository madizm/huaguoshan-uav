#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Listen for airspace table changes and refresh obstacle geomgrids.

The airspace CRUD SQL emits ``NOTIFY airspace_changed`` from row-level triggers
on ``airspace.no_fly_zone`` and ``airspace.temp_control_zone``. This worker
coalesces bursts of notifications, then runs the existing airspace-only refresh
outside the PostgREST write transaction.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import psycopg


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
DEFAULT_CHANNEL = "airspace_changed"
DEFAULT_DEBOUNCE_SECONDS = 3.0
DEFAULT_RETRY_DELAY_SECONDS = 30.0
DEFAULT_ADVISORY_LOCK_KEY = 2026070201


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Listen for airspace_changed NOTIFY events and refresh airspace obstacle grids.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument("--channel", default=DEFAULT_CHANNEL, help="PostgreSQL NOTIFY channel to LISTEN on.")
    parser.add_argument("--debounce-seconds", type=float, default=DEFAULT_DEBOUNCE_SECONDS, help="Delay after the last event before refreshing, to coalesce bursts.")
    parser.add_argument("--retry-delay-seconds", type=float, default=DEFAULT_RETRY_DELAY_SECONDS, help="Delay before retrying after a failed refresh.")
    parser.add_argument("--lock-key", type=int, default=DEFAULT_ADVISORY_LOCK_KEY, help="PostgreSQL advisory lock key used to avoid multiple workers refreshing concurrently.")
    parser.add_argument("--refresh-script", default=str(Path(__file__).with_name("refresh_citydb_obstacle_grids.py")), help="Path to refresh_citydb_obstacle_grids.py.")
    parser.add_argument("--airspace-mode", choices=["bbox", "polygon-prism"], default="polygon-prism", help="Airspace prism generation mode passed to the refresh script.")
    parser.add_argument("--grant-role", default="admin", help="Optional role passed to --grant-role. Use empty string to omit.")
    parser.add_argument("--python", default=sys.executable, help="Python executable used to invoke the refresh script.")
    parser.add_argument("--dry-run-refresh", action="store_true", help="Listen and debounce, but print the refresh command instead of executing it.")
    parser.add_argument("--once", action="store_true", help="Exit after the first refresh attempt. Useful for supervised tests.")
    return parser.parse_args()


def log(message: str) -> None:
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{stamp}] {message}", flush=True)


def quote_ident(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def refresh_command(args: argparse.Namespace) -> list[str]:
    script = str(Path(args.refresh_script).resolve())
    command = [
        args.python,
        script,
        "--dsn",
        args.dsn,
        "--refresh-only",
        "--source",
        "airspace",
        "--refresh-total",
        "--airspace-mode",
        args.airspace_mode,
    ]
    if args.grant_role:
        command.extend(["--grant-role", args.grant_role])
    return command


def payload_summary(payload: str) -> str:
    try:
        data: Any = json.loads(payload)
    except json.JSONDecodeError:
        return payload
    parts = []
    for key in ("operation", "kind", "id"):
        if key in data:
            parts.append(f"{key}={data[key]}")
    return ", ".join(parts) or payload


def run_refresh(args: argparse.Namespace, lock_conn: psycopg.Connection[Any]) -> bool:
    with lock_conn.cursor() as cur:
        cur.execute("select pg_try_advisory_lock(%s)", (args.lock_key,))
        locked = bool(cur.fetchone()[0])
    if not locked:
        log("another worker holds the refresh advisory lock; skipping this batch")
        return True

    command = refresh_command(args)
    try:
        if args.dry_run_refresh:
            log("dry run refresh command: " + " ".join(command))
            return True

        log("running airspace obstacle refresh")
        started = time.monotonic()
        subprocess.run(command, check=True)
        log(f"airspace obstacle refresh completed in {time.monotonic() - started:.1f}s")
        return True
    except subprocess.CalledProcessError as error:
        log(f"airspace obstacle refresh failed with exit code {error.returncode}")
        return False
    finally:
        with lock_conn.cursor() as cur:
            cur.execute("select pg_advisory_unlock(%s)", (args.lock_key,))


def listen_loop(args: argparse.Namespace) -> int:
    debounce = max(0.0, float(args.debounce_seconds))
    retry_delay = max(1.0, float(args.retry_delay_seconds))
    pending = False
    due_at: float | None = None

    with psycopg.connect(args.dsn, autocommit=True) as listen_conn, psycopg.connect(args.dsn, autocommit=True) as lock_conn:
        with listen_conn.cursor() as cur:
            cur.execute(f"listen {quote_ident(args.channel)}")
        log(f"listening on channel {args.channel!r}; debounce={debounce:.1f}s")

        while True:
            timeout = None
            if pending and due_at is not None:
                timeout = max(0.0, due_at - time.monotonic())

            received = False
            for notify in listen_conn.notifies(timeout=timeout, stop_after=1):
                received = True
                pending = True
                due_at = time.monotonic() + debounce
                log("received airspace change: " + payload_summary(notify.payload))

            if received:
                # Drain any immediately queued events without resetting on a blocking wait.
                for notify in listen_conn.notifies(timeout=0, stop_after=100):
                    pending = True
                    due_at = time.monotonic() + debounce
                    log("received airspace change: " + payload_summary(notify.payload))
                continue

            if pending and due_at is not None and time.monotonic() >= due_at:
                pending = False
                due_at = None
                ok = run_refresh(args, lock_conn)
                if args.once:
                    return 0 if ok else 1
                if not ok:
                    pending = True
                    due_at = time.monotonic() + retry_delay
                    log(f"scheduled retry in {retry_delay:.1f}s")



def main() -> int:
    args = parse_args()
    try:
        return listen_loop(args)
    except KeyboardInterrupt:
        log("stopped")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
