from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "backend/migrate_source_target_model_summary.sql").read_text(encoding="utf-8").lower()


def test_view_extension_adds_models_column():
    assert "drop view if exists situation.source_sortie_statistics" in SQL
    assert "create view situation.source_sortie_statistics" in SQL
    assert "o.model" in SQL
    assert "array_agg(distinct model order by model) filter(where model is not null and model<>'') models" in SQL
    assert "coalesce(o.models,array[]::text[]) models" in SQL
    assert "架次内所有观测出现过的去重机型列表" in SQL


def test_model_summary_rpc_is_bounded_and_admin_only():
    assert "create or replace function api.get_source_target_model_summary" in SQL
    assert "model summary window cannot exceed 90 days" in SQL
    assert "limit must be between 1 and 500" in SQL
    assert "offset must be between 0 and 10000" in SQL
    assert "grant execute on function api.get_source_target_model_summary" in SQL
    assert "revoke all on function api.get_source_target_model_summary" in SQL


def test_model_summary_rpc_supports_detection_method_filter():
    assert "p_detection_method_codes text[] default null" in SQL
    assert "detection_method_codes&&p_detection_method_codes" in SQL


def test_model_summary_rpc_supports_source_target_filter():
    assert "p_source_target_ids text[] default null" in SQL
    assert "source_target_id=any(p_source_target_ids)" in SQL


def test_existing_rpcs_are_dropped_and_rebuilt():
    assert "drop function if exists api.get_source_sortie_statistics" in SQL
    assert "drop function if exists api.get_source_sortie_series" in SQL
    assert "drop function if exists api.list_source_sorties" in SQL


def test_model_sorties_rpc_is_bounded_and_admin_only():
    assert "create or replace function api.list_source_target_model_sorties" in SQL
    assert "source_target_id is required" in SQL
    assert "model is required" in SQL
    assert "limit must be between 1 and 500" in SQL
    assert "offset must be between 0 and 10000" in SQL
    assert "grant execute on function api.list_source_target_model_sorties" in SQL
    assert "revoke all on function api.list_source_target_model_sorties" in SQL


def test_model_sorties_rpc_supports_detection_method_filter():
    assert SQL.count("p_detection_method_codes text[] default null") >= 2
    assert SQL.count("detection_method_codes&&p_detection_method_codes") >= 2


def test_rpc_documents_business_meaning_in_chinese():
    assert "按来源目标 + 机型分组的架次汇总列表" in SQL
    assert "指定来源目标 + 机型的架次明细分页列表" in SQL
