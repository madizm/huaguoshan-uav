"""轨迹预测 worker：周期性为活跃空域目标和无人机资产生成短期外推预测。"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
from datetime import datetime, timezone

import psycopg
from psycopg.rows import dict_row

from .adapter import fetch_asset_windows, fetch_target_windows, persist_predictions
from .domain import Prediction, PredictionConfig, predict_trajectory

LOGGER = logging.getLogger(__name__)


async def process_once(
    conn,
    config: PredictionConfig,
    min_interval_seconds: float,
    retention_hours: int,
    max_subjects: int,
    active_seconds: int = 30,
) -> dict[str, int]:
    """完成一轮预测：读取窗口、逐对象外推、节流写入并清理历史。"""
    fetch_window_seconds = int(config.window_seconds * 2) + 30
    max_points = 100
    target_windows = await fetch_target_windows(conn, active_seconds, fetch_window_seconds, max_points, max_subjects)
    asset_windows = await fetch_asset_windows(conn, active_seconds, fetch_window_seconds, max_points, max_subjects)
    predicted_at = datetime.now(timezone.utc)
    predictions: list[Prediction] = []
    for subject_id, points in target_windows:
        predictions.append(predict_trajectory("airspace_target", subject_id, points, predicted_at, config))
    for subject_id, points in asset_windows:
        predictions.append(predict_trajectory("aircraft_asset", subject_id, points, predicted_at, config))
    written = await persist_predictions(conn, predictions, min_interval_seconds, retention_hours)
    return {"subjects": len(predictions), "written": written}


async def run_once(
    database_url: str,
    config: PredictionConfig,
    min_interval_seconds: float,
    retention_hours: int,
    max_subjects: int,
    active_seconds: int = 30,
) -> dict[str, int]:
    async with await psycopg.AsyncConnection.connect(database_url, row_factory=dict_row) as conn:
        async with conn.transaction():
            return await process_once(
                conn, config, min_interval_seconds, retention_hours, max_subjects, active_seconds,
            )


async def run_forever(
    database_url: str,
    config: PredictionConfig,
    poll_interval: float,
    min_interval_seconds: float,
    retention_hours: int,
    max_subjects: int,
    active_seconds: int = 30,
) -> None:
    while True:
        try:
            stats = await run_once(
                database_url, config, min_interval_seconds, retention_hours, max_subjects, active_seconds,
            )
            if stats["subjects"]:
                LOGGER.info("predicted %s subjects, wrote %s rows", stats["subjects"], stats["written"])
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("trajectory prediction batch failed")
        await asyncio.sleep(poll_interval)


def main() -> None:
    parser = argparse.ArgumentParser(description="Predict short-term trajectories for active subjects")
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL"))
    parser.add_argument("--poll-interval", type=float, default=2.0)
    parser.add_argument("--min-interval-seconds", type=float, default=5.0)
    parser.add_argument("--retention-hours", type=int, default=24)
    parser.add_argument("--max-subjects", type=int, default=500)
    parser.add_argument("--horizon-seconds", type=int, default=120)
    parser.add_argument("--step-seconds", type=int, default=5)
    parser.add_argument("--active-seconds", type=int, default=30)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if not args.database_url:
        parser.error("--database-url or DATABASE_URL is required")
    if args.poll_interval < 0.5:
        parser.error("--poll-interval must be at least 0.5 seconds")
    logging.basicConfig(level=os.environ.get("PREDICTION_LOG_LEVEL", os.environ.get("LOG_LEVEL", "INFO")))
    config = PredictionConfig(horizon_seconds=args.horizon_seconds, step_seconds=args.step_seconds)
    if args.once:
        print(asyncio.run(run_once(
            args.database_url, config, args.min_interval_seconds, args.retention_hours,
            args.max_subjects, args.active_seconds,
        )))
    else:
        asyncio.run(run_forever(
            args.database_url, config, args.poll_interval, args.min_interval_seconds,
            args.retention_hours, args.max_subjects, args.active_seconds,
        ))


if __name__ == "__main__":
    main()
