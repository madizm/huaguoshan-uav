"""只读历史回放：按入库时间防止未来泄漏，比较 LS 与可选 CV 卡尔曼。

按到达事件驱动，每个最新观测基准至多预测一次，不模拟线上轮询和写入频率。

DATABASE_URL=... uv run python -m backend.prediction.replay --output /tmp/prediction-replay.json
不写线上表；原始位置只留在进程内，输出仅包含聚合误差和数据摘要。
"""
from __future__ import annotations

import argparse
from bisect import bisect_left
from collections import Counter, defaultdict
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
import hashlib
import json
from math import atan2, cos, radians, sin, sqrt
import os
from pathlib import Path
from statistics import mean, median

import psycopg
from psycopg.rows import dict_row

from .domain import EARTH_RADIUS_M, ObservationPoint, Prediction, PredictionConfig, SubjectKind, predict_trajectory

Predictor = Callable[[SubjectKind, int, list[ObservationPoint], datetime, PredictionConfig], Prediction]

CHECKPOINTS = (10, 30, 60, 120)


@dataclass(frozen=True)
class ReplayObservation:
    kind: SubjectKind
    subject_id: int
    received_at: datetime
    point: ObservationPoint


def distance_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    """球面大圆距离；与线上 PostGIS WGS84 椭球口径略有差异。"""
    a = sin(radians(lat2 - lat1) / 2)**2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2)**2
    a = max(0.0, min(1.0, a))
    return 2 * EARTH_RADIUS_M * atan2(sqrt(a), sqrt(1 - a))


def summarize(samples: list[tuple[float, float]]) -> dict:
    errors = sorted(error for error, _ in samples)
    if not errors:
        return {"samples": 0}
    index = (len(errors) - 1) * 0.9
    low = int(index)
    p90 = errors[low] + (errors[min(low + 1, len(errors) - 1)] - errors[low]) * (index - low)
    return {
        "samples": len(samples), "mean_error_m": round(mean(errors), 3),
        "median_error_m": round(median(errors), 3), "p90_error_m": round(p90, 3),
        "within_uncertainty_rate": round(mean(e <= r for e, r in samples), 4),
        "mean_uncertainty_m": round(mean(r for _, r in samples), 3),
    }


def replay(observations: list[ReplayObservation], configs: dict[str, PredictionConfig],
           cutoff: datetime, cadence_seconds: int = 5, tolerance_seconds: float = 3,
           predictors: dict[str, Predictor] | None = None) -> dict:
    if not configs:
        raise ValueError("at least one algorithm is required")
    predictors = predictors or {}
    if predictors.keys() - configs.keys():
        raise ValueError("predictor names must match configured algorithms")
    if cadence_seconds <= 0 or tolerance_seconds < 0:
        raise ValueError("cadence must be positive; tolerance must be nonnegative")
    grouped = defaultdict(list)
    for item in observations:
        if item.point.observed_at <= cutoff and item.received_at <= cutoff:
            grouped[(item.kind, item.subject_id)].append(item)
    buckets = defaultdict(list)
    paired = defaultdict(lambda: defaultdict(list))
    paired_partitions = defaultdict(lambda: defaultdict(list))
    paired_models = defaultdict(lambda: defaultdict(list))
    paired_subjects = defaultdict(lambda: defaultdict(list))
    quality = Counter()
    models = Counter()
    horizon_stops = Counter()
    actual_horizons = defaultdict(list)
    origins = 0
    used_subjects = set()
    point_counts = []
    for (kind, subject_id), rows in sorted(grouped.items()):
        # Exactly the latest received ID at an observation instant is the reference.
        truth_by_time = {}
        for row in sorted(rows, key=lambda r: (r.point.observation_id or 0)):
            truth_by_time[row.point.observed_at] = row.point
        truth = sorted(truth_by_time.values(), key=lambda p: p.observed_at)
        times = [p.observed_at for p in truth]
        point_counts.append(len(truth))
        by_arrival = sorted(rows, key=lambda r: (max(r.received_at, r.point.observed_at), r.point.observation_id or 0))
        available = {}
        cursor = 0
        last_origin = None
        last_base = None
        for arrival in sorted({max(r.received_at, r.point.observed_at) for r in rows}):
            while cursor < len(by_arrival) and max(by_arrival[cursor].received_at, by_arrival[cursor].point.observed_at) <= arrival:
                point = by_arrival[cursor].point
                previous = available.get(point.observed_at)
                if previous is None or (point.observation_id or 0) > (previous.observation_id or 0):
                    available[point.observed_at] = point
                cursor += 1
            if last_origin is not None and (arrival - last_origin).total_seconds() < cadence_seconds:
                continue
            base = max(available)
            if base == last_base or (arrival - base).total_seconds() > 30:
                continue
            last_origin, last_base = arrival, base
            origins += 1
            # Same historical SQL budget as the worker; each model trims its fit window.
            fetch_seconds = max(int(c.window_seconds * 2) + 30 for c in configs.values())
            window = sorted((p for p in available.values() if p.observed_at >= arrival - timedelta(seconds=fetch_seconds)),
                            key=lambda p: p.observed_at)[-100:]
            predictions = {name: predictors.get(name, predict_trajectory)(kind, subject_id, window, arrival, config)
                           for name, config in configs.items()}
            for name, prediction in predictions.items():
                quality[(name, prediction.quality, prediction.reason)] += 1
                if prediction.horizon_policy:
                    policy = prediction.horizon_policy
                    horizon_stops[(name, policy["stop_reason"])] += 1
                    actual_horizons[name].append(policy["actual_horizon_seconds"])
                if prediction.quality == "ok":
                    models[(name, prediction.model_code)] += 1
            for eta in CHECKPOINTS:
                target = base + timedelta(seconds=eta)
                # An observed reference must be strictly later than the prediction origin.
                if target > cutoff:
                    continue
                index = bisect_left(times, target)
                candidates = [truth[i] for i in (index - 1, index) if 0 <= i < len(truth)
                              and truth[i].observed_at > arrival]
                if not candidates:
                    continue
                actual = min(candidates, key=lambda p: (abs((p.observed_at - target).total_seconds()), p.observed_at))
                if abs((actual.observed_at - target).total_seconds()) > tolerance_seconds:
                    continue
                values = {}
                for name, prediction in predictions.items():
                    predicted = next((p for p in prediction.points if p.eta_seconds == eta), None)
                    if predicted is None:
                        continue
                    error = distance_m(predicted.longitude, predicted.latitude, actual.longitude, actual.latitude)
                    values[name] = (error, predicted.uncertainty_m)
                    buckets[(name, kind, prediction.model_code, eta)].append(values[name])
                if len(values) == len(configs):
                    for name, value in values.items():
                        paired[eta][name].append(value)
                        # Predetermined object-level split; no per-point leakage
                        # between groups. These historical data are not a new blind dataset.
                        partition = "holdout" if int(hashlib.sha256(f"{kind}:{subject_id}".encode()).hexdigest(), 16) % 5 == 0 else "development"
                        paired_partitions[(partition, eta)][name].append(value)
                        reference_model = next(iter(predictions.values())).model_code
                        paired_models[(reference_model, eta)][name].append(value)
                        paired_subjects[(kind, subject_id, eta)][name].append(value[0])
                    used_subjects.add((kind, subject_id))
    return {
        "subjects": len(grouped), "subjects_with_paired_samples": len(used_subjects),
        "unique_points_per_subject": {"min": min(point_counts, default=0), "max": max(point_counts, default=0),
                                      "median": median(point_counts) if point_counts else 0},
        "prediction_origins": origins,
        "horizon_stops": [{"algorithm": name, "reason": reason, "count": count}
                          for (name, reason), count in sorted(horizon_stops.items())],
        "actual_horizons": {name: {"samples": len(values), "mean_seconds": round(mean(values), 3),
                                  "median_seconds": median(values)}
                            for name, values in actual_horizons.items()},
        "quality": [{"algorithm": k[0], "quality": k[1], "reason": k[2], "count": v} for k, v in quality.items()],
        "models": [{"algorithm": k[0], "model": k[1], "count": v} for k, v in models.items()],
        "paired": [{"eta_seconds": eta, "algorithms": {name: summarize(values) for name, values in entries.items()}}
                   for eta, entries in sorted(paired.items())],
        "paired_partitions": [{"partition": key[0], "eta_seconds": key[1],
                               "algorithms": {name: summarize(values) for name, values in entries.items()}}
                              for key, entries in sorted(paired_partitions.items())],
        "paired_by_reference_model": [{"reference_model": key[0], "eta_seconds": key[1],
                                      "algorithms": {name: summarize(values) for name, values in entries.items()}}
                                     for key, entries in sorted(paired_models.items())],
        "paired_subject_macro": [{"eta_seconds": eta, "algorithm": name,
                                  "subjects": len(means), "mean_subject_mean_error_m": round(mean(means), 3)}
                                 for (eta, name), means in sorted(_subject_means(paired_subjects).items())],
        "buckets": [{"algorithm": k[0], "subject_kind": k[1], "model": k[2], "eta_seconds": k[3], **summarize(v)}
                    for k, v in sorted(buckets.items())],
    }


def _subject_means(paired_subjects: dict) -> dict:
    result = defaultdict(list)
    for (_, _, eta), entries in paired_subjects.items():
        for name, errors in entries.items():
            result[(eta, name)].append(mean(errors))
    return result


def fetch_observations(database_url: str, hours: float, max_rows: int) -> tuple[list[ReplayObservation], dict]:
    """Repeatable-read read-only snapshot, timeout bounded, no DB writes."""
    with psycopg.connect(database_url, row_factory=dict_row, connect_timeout=10, client_encoding="utf8",
                         options="-c default_transaction_read_only=on -c statement_timeout=30000") as conn:
        conn.execute("set transaction isolation level repeatable read read only")
        cutoff = conn.execute("select now() cutoff").fetchone()["cutoff"]
        rows = conn.execute("""
            with observations as (
              select 'airspace_target' kind, x.track_id subject_id, r.*
              from situation.track_observation x
              join equipment.raw_observation r on r.id=x.observation_id
              where r.observed_at between %(start)s and %(cutoff)s
              union all
              select 'aircraft_asset' kind, r.asset_id subject_id, r.*
              from equipment.raw_observation r join equipment.asset a on a.id=r.asset_id
              where a.category_code='uav' and r.observed_at between %(start)s and %(cutoff)s
            )
            select kind,subject_id,id,observed_at,received_at,st_x(geom) longitude,st_y(geom) latitude,height_amsl_m
            from observations r where geom is not null and received_at<=%(cutoff)s
              and situation.position_time_valid(observed_at,received_at,observation_type,raw_payload)
              and coalesce(raw_payload->>'simulated','false')<>'true'
              and coalesce(raw_payload->>'isSimulated','false')<>'true'
            order by kind,subject_id,observed_at,id limit %(limit)s
        """, {"start": cutoff - timedelta(hours=hours), "cutoff": cutoff, "limit": max_rows + 1}).fetchall()
        if len(rows) > max_rows:
            raise ValueError("row budget exceeded; narrow --hours or raise --max-rows explicitly")
    digest = hashlib.sha256(json.dumps(rows, default=str, sort_keys=True).encode()).hexdigest()
    data = [ReplayObservation(r["kind"], r["subject_id"], r["received_at"], ObservationPoint(
        observation_id=r["id"], observed_at=r["observed_at"], longitude=r["longitude"],
        latitude=r["latitude"], height_amsl_m=r["height_amsl_m"])) for r in rows]
    return data, {"cutoff": cutoff.isoformat(), "hours": hours, "rows": len(rows), "sha256": digest,
                  "start_observed_at": min((r["observed_at"] for r in rows), default=None),
                  "end_observed_at": max((r["observed_at"] for r in rows), default=None)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--max-rows", type=int, default=100000)
    parser.add_argument("--window-seconds", type=float, default=20)
    parser.add_argument("--cadence-seconds", type=int, default=5)
    parser.add_argument("--horizon-seconds", type=int, default=120)
    parser.add_argument("--adaptive-horizon", action="store_true")
    parser.add_argument("--adaptive-max-uncertainty-m", type=float, default=250.0)
    parser.add_argument("--adaptive-max-observation-age-seconds", type=float, default=30.0)
    parser.add_argument("--adaptive-max-turn-degrees", type=float, default=None,
                        help="Optional cumulative-turn cap; disabled by default")
    parser.add_argument("--include-imm", action="store_true", help="Include experimental offline IMM CV/CT")
    parser.add_argument("--tolerance-seconds", type=float, default=3)
    parser.add_argument("--measurement-noise-std-m", type=float, default=10)
    parser.add_argument("--acceleration-noise-density-m2-s3", type=float, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 0 < args.hours <= 168 or args.max_rows < 1 or not 4 <= args.window_seconds <= 300:
        parser.error("--hours must be in (0,168]; --max-rows positive; --window-seconds in [4,300]")
    if args.horizon_seconds not in (30, 60, 120):
        parser.error("--horizon-seconds must be 30, 60 or 120")
    configs = {"least_squares": PredictionConfig(window_seconds=args.window_seconds, horizon_seconds=args.horizon_seconds), "kalman_cv": PredictionConfig(
        estimator="kalman_cv", window_seconds=args.window_seconds, horizon_seconds=args.horizon_seconds, measurement_noise_std_m=args.measurement_noise_std_m,
        acceleration_noise_density_m2_s3=args.acceleration_noise_density_m2_s3)}
    if args.include_imm and args.adaptive_horizon:
        parser.error("adaptive horizon is supported for LS/Kalman only, not experimental IMM")
    try:
        configs = {name: replace(config,
            adaptive_horizon=args.adaptive_horizon,
            adaptive_max_uncertainty_m=args.adaptive_max_uncertainty_m,
            adaptive_max_observation_age_seconds=args.adaptive_max_observation_age_seconds,
            adaptive_max_turn_degrees=args.adaptive_max_turn_degrees,
        ) for name, config in configs.items()}
    except ValueError as exc:
        parser.error(str(exc))
    predictors = {}
    experimental_parameters = {}
    if args.include_imm:
        from .imm import predict_imm_trajectory
        configs["imm_cv_ct"] = configs["kalman_cv"]
        predictors["imm_cv_ct"] = predict_imm_trajectory
        from .imm import (MODEL_TIME_CONSTANT_SECONDS, INITIAL_TURN_STD_RAD_S,
                          TURN_DIFFUSION_STD_RAD_S_SQRT_S, MAX_EKF_STEP_SECONDS)
        experimental_parameters = {
            "imm_model_time_constant_seconds": MODEL_TIME_CONSTANT_SECONDS,
            "imm_initial_turn_std_rad_s": INITIAL_TURN_STD_RAD_S,
            "imm_turn_diffusion_std_rad_s_sqrt_s": TURN_DIFFUSION_STD_RAD_S_SQRT_S,
            "imm_max_ekf_step_seconds": MAX_EKF_STEP_SECONDS,
            "imm_forecast": "dominant posterior component, fixed probabilities over horizon",
        }
    data, metadata = fetch_observations(os.environ["DATABASE_URL"], args.hours, args.max_rows)
    results = replay(data, configs, datetime.fromisoformat(metadata["cutoff"]), args.cadence_seconds,
                     args.tolerance_seconds, predictors)
    report = {"dataset": metadata, "parameters": vars(args) | {"output": str(args.output)},
              "experimental_parameters": experimental_parameters,
              "method": "Arrival-driven causal comparison, once per newest observation base; not worker polling/persistence replay. Paired references within tolerance; spherical horizontal distance; observations are not independent ground truth. Non-default window is diagnostic only.",
              **results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str) + "\n")
    print(json.dumps({"dataset": metadata, "paired": results["paired"], "output": str(args.output)}, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
