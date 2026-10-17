"""只读比较固定时长、自适应 v1 与当前规则；输出不含原始坐标。

DATABASE_URL=... uv run python -m scripts.prediction.compare_adaptive_horizons --output /tmp/adaptive.json
旧版规则从指定的本地 Git 提交读取，不修改工作区或数据库。
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import replace
from datetime import datetime
import json
import os
from pathlib import Path
from statistics import median
import subprocess
import types

from backend.prediction.domain import PredictionConfig, _predict_trajectory, predict_trajectory, prepare_window
from backend.prediction.replay import fetch_observations, replay


def summarize_lengths(rows: list[dict]) -> dict:
    valid = [r for r in rows if r['valid']]
    by_model = {}
    for model in sorted({r['model'] for r in valid}):
        group = [r for r in valid if r['model'] == model]
        by_model[model] = {
            'samples': len(group),
            'actual_median_s': median(r['actual'] for r in group),
            'remaining_median_s': median(r['remaining'] for r in group),
            'up_to_5s': sum(r['actual'] <= 5 for r in group),
        }
    return {
        'origins': len(rows), 'valid_origins': len(valid),
        'valid_up_to_5s': sum(r['actual'] <= 5 for r in valid),
        'valid_remaining_up_to_5s': sum(r['remaining'] <= 5 for r in valid),
        'valid_actual_median_s': median(r['actual'] for r in valid) if valid else None,
        'valid_remaining_median_s': median(r['remaining'] for r in valid) if valid else None,
        'motion_evidence': dict(Counter(r['motion_evidence'] for r in rows if r['motion_evidence'])),
        'valid_by_model': by_model,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours', type=float, default=24)
    parser.add_argument('--window-seconds', type=float, default=20)
    parser.add_argument('--horizon-seconds', type=int, default=90)
    parser.add_argument('--legacy-ref', default='bd9aee1')
    parser.add_argument('--max-rows', type=int, default=100000)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 0 < args.hours <= 168 or args.max_rows < 1:
        parser.error('hours must be in (0,168]; max rows must be positive')
    if not os.environ.get('DATABASE_URL'):
        parser.error('DATABASE_URL is required')
    try:
        base = PredictionConfig(estimator='kalman_cv', horizon_seconds=args.horizon_seconds,
                                window_seconds=args.window_seconds)
    except ValueError as exc:
        parser.error(str(exc))

    # This executes trusted local repository code, never code fetched from the DB.
    legacy = types.ModuleType('backend.prediction.adaptive_v1')
    legacy.__package__ = 'backend.prediction'
    source = subprocess.check_output(
        ['git', 'show', f'{args.legacy_ref}:backend/prediction/adaptive.py'], text=True,
    )
    exec(compile(source, 'adaptive_v1_snapshot', 'exec'), legacy.__dict__)
    configs = {
        'fixed': base,
        'adaptive_v1': replace(base, adaptive_horizon=True, adaptive_max_turn_degrees=90),
        'adaptive_v2': replace(base, adaptive_horizon=True),
    }
    data, dataset = fetch_observations(os.environ['DATABASE_URL'], args.hours, args.max_rows)
    summaries = defaultdict(list)

    def predictor(name):
        def run(kind, subject_id, points, at, config):
            if name == 'adaptive_v1':
                candidate = _predict_trajectory(kind, subject_id, points, at, config)
                window = prepare_window([p for p in points if p.observed_at <= at], config)
                result = legacy.apply_adaptive_horizon(candidate, window, config)
            else:
                result = predict_trajectory(kind, subject_id, points, at, config)
            policy = result.horizon_policy
            actual = result.points[-1].eta_seconds if result.points else 0
            remaining = max(0, actual - (at-result.base_observed_at).total_seconds())
            summaries[name].append({
                'valid': result.quality == 'ok', 'model': result.model_code,
                'actual': policy.get('actual_horizon_seconds', actual),
                'remaining': policy.get('remaining_horizon_seconds', remaining),
                'motion_evidence': policy.get('metrics', {}).get('motion_evidence'),
            })
            return result
        return run

    results = replay(data, configs, datetime.fromisoformat(dataset['cutoff']),
                     predictors={name: predictor(name) for name in configs})
    lengths = {name: summarize_lengths(rows) for name, rows in summaries.items()}
    report = {
        'dataset': dataset,
        'parameters': {
            'hours': args.hours, 'estimator': 'kalman_cv', 'window_seconds': args.window_seconds,
            'horizon_seconds': args.horizon_seconds, 'step_seconds': 5, 'max_uncertainty_m': 250,
            'max_observation_age_seconds': 30, 'v1_max_turn_degrees': 90, 'v2_max_turn_degrees': None,
            'measurement_noise_std_m': 10, 'legacy_ref': args.legacy_ref,
        },
        'method': 'Read-only arrival-driven causal replay. Legacy code loaded from the specified local Git ref. '
                  'Same candidates for all strategies. Per-algorithm error buckets have different retained '
                  'populations; not an accuracy improvement claim. Paired results are common checkpoints only. '
                  'Observations are not independent truth.',
        'lengths': lengths, **results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str)+'\n')
    print(json.dumps({'dataset': dataset, 'lengths': lengths, 'output': str(args.output)},
                     ensure_ascii=False, indent=2, default=str))


if __name__ == '__main__':
    main()
