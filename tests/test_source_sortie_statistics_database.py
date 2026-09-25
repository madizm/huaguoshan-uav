import os
from datetime import timedelta

import psycopg
import pytest
from psycopg.rows import dict_row

DATABASE_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DATABASE_URL, reason="TEST_DATABASE_URL is not configured")


def test_source_sortie_statistics_contract():
    with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:
        row = conn.execute(
            "select min(started_at) first_at,max(started_at) last_at from situation.source_target_session"
        ).fetchone()
        if row["first_at"] is None:
            pytest.skip("source_target_session is empty")
        start_at = row["first_at"] - timedelta(seconds=1)
        end_at = min(row["last_at"] + timedelta(seconds=1), start_at + timedelta(days=31))

        overview = conn.execute(
            "select api.get_source_sortie_statistics(%s,%s,null,null) result",
            (start_at, end_at),
        ).fetchone()["result"]
        assert set(overview) == {"startAt", "endAtExclusive", "summary", "riskDistribution", "quality"}
        assert overview["summary"]["sortieCount"] >= 1
        assert sum(overview["riskDistribution"].values()) == overview["summary"]["sortieCount"]

        series = conn.execute(
            "select api.get_source_sortie_series(%s,%s,'day',null,null) result",
            (start_at, end_at),
        ).fetchone()["result"]
        assert sum(point["sortieCount"] for point in series["points"]) == overview["summary"]["sortieCount"]

        listing = conn.execute(
            "select api.list_source_sorties(%s,%s,null,null,null,null,5,0) result",
            (start_at, end_at),
        ).fetchone()["result"]
        assert listing["total"] == overview["summary"]["sortieCount"]
        assert 1 <= len(listing["sorties"]) <= 5
        assert {"sortieId", "trackId", "sourceTargetId", "observationCount"} <= set(listing["sorties"][0])
