from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RISK_SQL = (ROOT / "backend/create_target_risk_assessment.sql").read_text(encoding="utf-8").lower()
DETECTION_SQL = (ROOT / "backend/create_detection_situation_schema.sql").read_text(encoding="utf-8").lower()


def test_creates_immutable_history_current_projection_and_cursor():
    assert "create table if not exists event_response.target_risk_assessment" in RISK_SQL
    assert "create table if not exists event_response.target_risk_current" in RISK_SQL
    assert "create table if not exists event_response.risk_worker_cursor" in RISK_SQL
    assert "target_risk_assessment_immutable" in RISK_SQL
    persistence = (ROOT / "backend/risk_engine/persistence.py").read_text(encoding="utf-8").lower()
    assert "where (excluded.observed_at,coalesce(excluded.observation_id,0)) >" in persistence


def test_risk_engine_role_has_narrow_write_permissions():
    assert "create role risk_engine login noinherit" in RISK_SQL
    assert "grant select,insert on event_response.target_risk_assessment to risk_engine" in RISK_SQL
    assert "grant select,insert,update on event_response.target_risk_current,event_response.risk_worker_cursor to risk_engine" in RISK_SQL
    assert "grant insert on situation.change_event to risk_engine" in RISK_SQL
    assert "grant update on situation.target_track" not in RISK_SQL


def test_detection_queries_expose_current_risk_consistently():
    assert DETECTION_SQL.count("'riskassessment',event_response.risk_assessment_json") >= 3
    assert "when event_type='risk_changed' then payload->'risk_assessment'" in DETECTION_SQL
    assert "when aggregate_type='target_track' then event_response.risk_assessment_json(aggregate_id)" in DETECTION_SQL
    assert "'aggregate_id',aggregate_id" in DETECTION_SQL
    assert "'riskassessment',event_response.risk_assessment_json(t.id)" in DETECTION_SQL
    assert "'riskassessment',event_response.observation_risk_assessment_json(id)" in DETECTION_SQL
    assert "create or replace function event_response.observation_risk_assessment_json" in RISK_SQL
    assert "'status',status,'risklevel',risk_level,'riskscore',risk_score,'ringcode',defense_ring_code" in RISK_SQL


def test_history_rpc_is_bounded_and_admin_only():
    signature = "api.list_target_risk_assessments(bigint,timestamptz,timestamptz,integer)"
    assert "create or replace function api.list_target_risk_assessments" in RISK_SQL
    assert "risk assessment window cannot exceed 7 days" in RISK_SQL
    assert "limit must be between 1 and 5000" in RISK_SQL
    assert f"revoke all on function {signature} from public,anonymous" in RISK_SQL
    assert f"grant execute on function {signature} to admin" in RISK_SQL


def test_engine_uses_published_thresholds_parameters_and_versioned_centers():
    adapter = (ROOT / "backend/risk_engine/detection_adapter.py").read_text(encoding="utf-8").lower()
    domain = (ROOT / "backend/risk_engine/domain.py").read_text(encoding="utf-8").lower()
    assert "f.threshold_value" in adapter
    assert "event_response.risk_rule_parameter" in adapter
    assert "st_x(r.center_geom)" in adapter
    assert "history.trajectory" in adapter
    assert "next_ring_eta_30" in domain
    assert "target.speed_mps >= 15" not in domain
