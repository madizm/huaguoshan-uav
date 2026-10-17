import json
import sys
from datetime import timedelta

import pytest

from scripts.prediction import compare_adaptive_horizons as comparison
from .test_domain import BASE_TIME
from .test_replay import data


def test_comparison_generates_aggregate_report_without_db_or_raw_positions(monkeypatch, tmp_path):
    output = tmp_path / 'comparison.json'
    monkeypatch.setenv('DATABASE_URL', 'unused')
    monkeypatch.setattr(sys, 'argv', ['compare', '--output', str(output)])
    calls = []

    def fetch(url, hours, limit):
        calls.append((url, hours, limit))
        return data(), {'cutoff': (BASE_TIME+timedelta(seconds=170)).isoformat(), 'rows': 35}

    monkeypatch.setattr(comparison, 'fetch_observations', fetch)
    comparison.main()
    report_text = output.read_text()
    report = json.loads(report_text)
    assert calls == [('unused', 24, 100000)]
    assert set(report['lengths']) == {'fixed', 'adaptive_v1', 'adaptive_v2'}
    assert report['lengths']['adaptive_v2']['valid_origins'] > 0
    assert report['lengths']['adaptive_v2']['valid_by_model']['cv']['actual_median_s'] > 5
    assert 'longitude' not in report_text
    assert 'latitude' not in report_text
    assert 'subject_id' not in report_text
    assert report['parameters']['v1_max_turn_degrees'] == 90
    assert report['parameters']['v2_max_turn_degrees'] is None


@pytest.mark.parametrize('extra', [['--hours', '0'], ['--max-rows', '0'], ['--window-seconds', 'nan']])
def test_comparison_rejects_invalid_arguments_before_fetch(monkeypatch, tmp_path, extra):
    monkeypatch.setenv('DATABASE_URL', 'unused')
    monkeypatch.setattr(sys, 'argv', ['compare', '--output', str(tmp_path/'unused.json')] + extra)

    def unexpected(*args):
        pytest.fail('must validate before accessing database')

    monkeypatch.setattr(comparison, 'fetch_observations', unexpected)
    with pytest.raises(SystemExit) as exc:
        comparison.main()
    assert exc.value.code == 2
