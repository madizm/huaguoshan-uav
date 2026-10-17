from datetime import timedelta

import pytest

from backend.prediction.domain import PredictionConfig
from backend.prediction.replay import ReplayObservation, distance_m, replay, summarize
from .test_domain import BASE_TIME, straight_line


def configs():
    return {"least_squares": PredictionConfig(), "kalman_cv": PredictionConfig(estimator="kalman_cv")}


def data(count=35, delay=0):
    return [ReplayObservation("airspace_target", 1, p.observed_at + timedelta(seconds=delay), p)
            for p in straight_line(count=count)]


def test_replay_pairs_same_references_and_reports_all_checkpoints():
    result = replay(data(), configs(), BASE_TIME + timedelta(seconds=170), tolerance_seconds=0)
    assert [r["eta_seconds"] for r in result["paired"]] == [10, 30, 60, 120]
    for bucket in result["paired"]:
        a, b = bucket["algorithms"].values()
        assert a["samples"] == b["samples"] > 0
        assert a["mean_error_m"] < 0.1
        assert b["mean_error_m"] < 1


def test_delayed_measurements_cannot_leak_into_earlier_predictions():
    # All points arrive after cutoff. Observed timestamps alone are not enough.
    assert replay(data(delay=1000), configs(), BASE_TIME + timedelta(seconds=170))["prediction_origins"] == 0
    # A huge delay means points are never active when received.
    assert replay(data(delay=1000), configs(), BASE_TIME + timedelta(seconds=2000))["prediction_origins"] == 0


def test_truth_must_be_later_than_prediction_origin():
    result = replay(data(delay=15), configs(), BASE_TIME + timedelta(seconds=200), tolerance_seconds=0)
    assert 10 not in [r["eta_seconds"] for r in result["paired"]]
    assert 30 in [r["eta_seconds"] for r in result["paired"]]


def test_sparse_tracks_do_not_fake_accuracy_samples():
    rows = [ReplayObservation("airspace_target", 1, p.observed_at, p)
            for p in straight_line(count=10, step=30)]
    result = replay(rows, configs(), BASE_TIME + timedelta(seconds=300))
    assert result["paired"] == []
    assert {r["reason"] for r in result["quality"]} == {"not_enough_points"}


def test_order_duplicates_and_future_rows_do_not_change_results():
    rows = data()
    cutoff = BASE_TIME + timedelta(seconds=170)
    expected = replay(rows, configs(), cutoff)
    future = data(count=40)[-1]
    # Identical duplicate physical measurements do not change origins or results.
    assert replay(list(reversed(rows)) + [rows[2], future], configs(), cutoff) == expected


def test_summary_and_distance():
    result = summarize([(10, 20), (30, 20), (20, 20)])
    assert result["mean_error_m"] == 20
    assert result["median_error_m"] == 20
    assert result["p90_error_m"] == 28
    assert result["within_uncertainty_rate"] == pytest.approx(2 / 3, abs=0.0001)
    assert summarize([]) == {"samples": 0}
    assert distance_m(119, 34, 119, 34) == 0
    with pytest.raises(ValueError):
        replay([], {}, BASE_TIME)


def test_late_history_with_unchanged_base_is_not_a_new_origin():
    rows = data(count=5)
    # Historical point arrives after the newest point, with the same timestamp
    # and a newer ID. This comparison intentionally does not mimic worker polls.
    late = rows[1].point.model_copy(update={"observation_id": 999})
    delayed = ReplayObservation("airspace_target", 1, BASE_TIME + timedelta(seconds=30), late)
    cutoff = BASE_TIME + timedelta(seconds=40)
    original = replay(rows, configs(), cutoff)
    result = replay(rows + [delayed], configs(), cutoff)
    assert result["prediction_origins"] == original["prediction_origins"]


def test_database_extraction_enforces_read_only_and_does_not_persist_raw_data(monkeypatch):
    from backend.prediction import replay as module

    queries = []
    options = {}

    class FakeConnection:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def execute(self, query, params=None):
            queries.append(query)
            return self

        def fetchone(self):
            return {"cutoff": BASE_TIME}

        def fetchall(self):
            return []

    def connect(dsn, **kwargs):
        options.update(kwargs)
        return FakeConnection()

    monkeypatch.setattr(module.psycopg, "connect", connect)
    rows, metadata = module.fetch_observations("not-a-real-dsn", 24, 100)
    assert rows == [] and metadata["rows"] == 0
    assert "default_transaction_read_only=on" in options["options"]
    assert "read only" in queries[0]
    assert all(q.lstrip().lower().startswith(("set transaction", "select", "with")) for q in queries)


def test_experimental_imm_is_opt_in_and_paired_on_identical_references():
    from backend.prediction.imm import predict_imm_trajectory

    choices = configs() | {"imm_cv_ct": PredictionConfig()}
    result = replay(data(), choices, BASE_TIME + timedelta(seconds=170),
                    predictors={"imm_cv_ct": predict_imm_trajectory})
    for bucket in result["paired"]:
        assert len({v["samples"] for v in bucket["algorithms"].values()}) == 1
        assert bucket["algorithms"]["imm_cv_ct"]["mean_error_m"] < 1
    # Partitioning never loses paired samples; no raw identifiers are reported.
    for bucket in result["paired"]:
        eta = bucket["eta_seconds"]
        partitions = [p for p in result["paired_partitions"] if p["eta_seconds"] == eta]
        assert sum(p["algorithms"]["imm_cv_ct"]["samples"] for p in partitions) == bucket["algorithms"]["imm_cv_ct"]["samples"]
    assert all(r["subjects"] == 1 for r in result["paired_subject_macro"])
    assert {r["reference_model"] for r in result["paired_by_reference_model"]} == {"cv"}
    with pytest.raises(ValueError, match="predictor names"):
        replay([], configs(), BASE_TIME, predictors={"unknown": predict_imm_trajectory})


def test_adaptive_replay_reports_stops_and_does_not_evaluate_truncated_points():
    config = PredictionConfig(adaptive_horizon=True, adaptive_max_uncertainty_m=100)
    result = replay(data(), {"adaptive": config}, BASE_TIME + timedelta(seconds=170), tolerance_seconds=0)
    assert result["actual_horizons"]["adaptive"]["samples"] == result["prediction_origins"]
    assert {row["reason"] for row in result["horizon_stops"]} == {"not_enough_points", "uncertainty_limit"}
    assert [row["eta_seconds"] for row in result["paired"]] == [10]


@pytest.mark.parametrize("extra", [
    ["--adaptive-horizon", "--include-imm"],
    ["--adaptive-max-uncertainty-m", "nan"],
])
def test_replay_cli_rejects_invalid_adaptive_config_before_database(monkeypatch, extra):
    import sys
    from backend.prediction import replay as module

    monkeypatch.setattr(sys, "argv", ["replay", "--output", "/unused.json"] + extra)
    with pytest.raises(SystemExit) as exc:
        module.main()
    assert exc.value.code == 2
