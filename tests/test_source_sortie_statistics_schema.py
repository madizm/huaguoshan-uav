from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "backend/create_source_sortie_statistics.sql").read_text(encoding="utf-8").lower()


def test_projection_uses_source_session_as_sortie_and_keeps_quality_flags():
    assert "create or replace view situation.source_sortie_statistics" in SQL
    assert "s.id sortie_id" in SQL
    assert "t.source_session_id=s.id" in SQL
    assert "timestamp_suspect" in SQL
    assert "single_timestamp" in SQL
    assert "non_spatial" in SQL
    assert "lifecycle_overlap" in SQL
    assert "max_risk_level" in SQL
    assert "deepest_ring_code" in SQL
    assert SQL.count("event_type<>'offline_remove'") == 2


def test_statistics_rpcs_are_bounded_and_admin_only():
    assert "create or replace function api.get_source_sortie_statistics" in SQL
    assert "sortie statistics window cannot exceed 90 days" in SQL
    assert "create or replace function api.get_source_sortie_series" in SQL
    assert "bucket must be hour or day" in SQL
    assert "create or replace function api.list_source_sorties" in SQL
    assert "sortie list window cannot exceed 31 days" in SQL
    assert "limit must be between 1 and 500" in SQL
    assert "offset must be between 0 and 10000" in SQL
    assert "('normal','timestamp_suspect','single_timestamp','non_spatial','lifecycle_overlap')" in SQL
    assert "p_quality_issue='normal' and not timestamp_suspect" in SQL
    assert SQL.count("grant execute on function api.") == 3
    assert "grant select on situation.source_sortie_statistics to admin" not in SQL


def test_projection_documents_business_meaning_in_chinese():
    assert "以 source_target_session 为一条来源架次" in SQL
    assert "返回 json：时间窗口、来源架次总览" in SQL
    assert "返回 json：总数和分页来源架次列表" in SQL
