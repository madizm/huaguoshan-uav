import sys

import pytest

from backend.prediction import worker


@pytest.mark.parametrize("extra,estimator,std,q", [
    ([], "least_squares", 10, 1),
    (["--estimator", "kalman_cv", "--measurement-noise-std-m", "7",
      "--acceleration-noise-density-m2-s3", "0.25"], "kalman_cv", 7, 0.25),
])
def test_cli_config_passed_to_worker(monkeypatch, capsys, extra, estimator, std, q):
    captured = []

    async def fake_run_once(database_url, config, *args):
        captured.append(config)
        return {"subjects": 0}

    monkeypatch.setattr(worker, "run_once", fake_run_once)
    monkeypatch.setattr(sys, "argv", ["prediction", "--once", "--database-url", "unused"] + extra)
    worker.main()
    assert captured[0].estimator == estimator
    assert captured[0].measurement_noise_std_m == std
    assert captured[0].acceleration_noise_density_m2_s3 == q
    assert "subjects" in capsys.readouterr().out


@pytest.mark.parametrize("extra", [
    ["--estimator", "unknown"],
    ["--measurement-noise-std-m", "0"],
    ["--measurement-noise-std-m", "nan"],
    ["--acceleration-noise-density-m2-s3", "-1"],
    ["--acceleration-noise-density-m2-s3", "inf"],
])
def test_cli_rejects_invalid_config_before_connecting(monkeypatch, extra):
    monkeypatch.setattr(sys, "argv", ["prediction", "--once", "--database-url", "unused"] + extra)
    with pytest.raises(SystemExit) as exc:
        worker.main()
    assert exc.value.code == 2


def test_cli_adaptive_config(monkeypatch):
    captured = []

    async def fake_run_once(database_url, config, *args):
        captured.append(config)
        return {}

    monkeypatch.setattr(worker, "run_once", fake_run_once)
    monkeypatch.setattr(sys, "argv", ["prediction", "--once", "--database-url", "unused",
        "--adaptive-horizon", "--adaptive-max-uncertainty-m", "180",
        "--adaptive-max-observation-age-seconds", "25", "--adaptive-max-turn-degrees", "60",
        "--window-seconds", "90"])
    worker.main()
    config = captured[0]
    assert config.adaptive_horizon
    assert config.adaptive_max_uncertainty_m == 180
    assert config.adaptive_max_observation_age_seconds == 25
    assert config.adaptive_max_turn_degrees == 60
    assert config.window_seconds == 90


@pytest.mark.parametrize("extra", [
    ["--adaptive-max-uncertainty-m", "nan"],
    ["--adaptive-max-observation-age-seconds", "0"],
    ["--adaptive-max-turn-degrees", "-1"],
    ["--horizon-seconds", "0"], ["--step-seconds", "0"], ["--window-seconds", "nan"],
])
def test_invalid_horizon_cli(monkeypatch, extra):
    monkeypatch.setattr(sys, "argv", ["prediction", "--once", "--database-url", "unused"] + extra)
    with pytest.raises(SystemExit) as exc:
        worker.main()
    assert exc.value.code == 2
