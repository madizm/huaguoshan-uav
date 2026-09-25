"""Persistence adapter for immutable assessment history and current projection."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

from psycopg.types.json import Jsonb

from .domain import RiskAssessment


class Database(Protocol):
    async def execute(self, query: str, params: tuple[Any, ...] = ()) -> Any: ...


async def fetch_persisted_assessment(db: Database, observation_id: int) -> RiskAssessment | None:
    cursor = await db.execute(
        """
        select status,risk_level,risk_score,track_id,observation_id,observed_at,assessed_at,
          protected_object_id,protected_object_version,defense_ring_id ring_id,
          defense_ring_code ring_code,defense_ring_level ring_level,distance_m,
          defense_ring_version ring_version,rule_set_id,rule_version,
          factor_results factors,error_code reason
        from event_response.target_risk_assessment where observation_id=%s
        """,
        (observation_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return None
    values = dict(row)
    for key in ("status", "risk_level", "ring_code", "reason"):
        if isinstance(values.get(key), bytes):
            values[key] = values[key].decode("utf-8")
    return RiskAssessment.model_validate(values)


async def persist_assessment(db: Database, assessment: RiskAssessment, input_snapshot: Mapping[str, Any]) -> None:
    """Insert one assessment idempotently and advance the current projection by observed_at."""
    values = assessment.model_dump(mode="json")
    await db.execute(
        """
        with previous as (
          select * from event_response.target_risk_current where track_id=%s for update
        ), inserted as (
          insert into event_response.target_risk_assessment(
            track_id,observation_id,observed_at,assessed_at,status,risk_level,risk_score,
            protected_object_id,protected_object_version,defense_ring_id,defense_ring_code,
            defense_ring_level,defense_ring_version,distance_m,rule_set_id,rule_version,
            factor_results,input_snapshot,error_code
          ) values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
          on conflict (observation_id) where observation_id is not null do nothing
          returning *
        ), projected as (
          insert into event_response.target_risk_current(
            track_id,assessment_id,observation_id,observed_at,assessed_at,status,risk_level,risk_score,
            protected_object_id,protected_object_version,defense_ring_id,defense_ring_code,
            defense_ring_level,defense_ring_version,distance_m,rule_set_id,rule_version,
            factor_results,error_code
          )
          select track_id,id,observation_id,observed_at,assessed_at,status,risk_level,risk_score,
            protected_object_id,protected_object_version,defense_ring_id,defense_ring_code,
            defense_ring_level,defense_ring_version,distance_m,rule_set_id,rule_version,
            factor_results,error_code
          from inserted
          on conflict (track_id) do update set
            assessment_id=excluded.assessment_id,observation_id=excluded.observation_id,
            observed_at=excluded.observed_at,assessed_at=excluded.assessed_at,status=excluded.status,
            risk_level=excluded.risk_level,risk_score=excluded.risk_score,
            protected_object_id=excluded.protected_object_id,protected_object_version=excluded.protected_object_version,
            defense_ring_id=excluded.defense_ring_id,defense_ring_code=excluded.defense_ring_code,
            defense_ring_level=excluded.defense_ring_level,defense_ring_version=excluded.defense_ring_version,
            distance_m=excluded.distance_m,rule_set_id=excluded.rule_set_id,rule_version=excluded.rule_version,
            factor_results=excluded.factor_results,error_code=excluded.error_code,updated_at=now()
          where (excluded.observed_at,coalesce(excluded.observation_id,0)) >
            (event_response.target_risk_current.observed_at,coalesce(event_response.target_risk_current.observation_id,0))
          returning *
        )
        insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
        select 'risk_changed','target_track',n.track_id,
          (select s.observation_source_id from situation.target_track t
           join situation.source_target_session s on s.id=t.source_session_id where t.id=n.track_id),
          n.observed_at,jsonb_build_object(
          'track_id',n.track_id,'observation_id',n.observation_id,'assessment_id',n.assessment_id,
          'previous_status',p.status,'previous_risk_level',p.risk_level,'previous_risk_score',p.risk_score,
          'status',n.status,'risk_level',n.risk_level,'risk_score',n.risk_score,
          'ring_code',n.defense_ring_code,'ring_version',n.defense_ring_version,'rule_version',n.rule_version,
          'risk_assessment',jsonb_strip_nulls(jsonb_build_object(
            'status',n.status,'riskLevel',n.risk_level,'riskScore',n.risk_score,
            'observationId',n.observation_id,'observedAt',n.observed_at,'assessedAt',n.assessed_at,
            'protectedObjectId',n.protected_object_id,'protectedObjectVersion',n.protected_object_version,
            'ringId',n.defense_ring_id,'ringCode',n.defense_ring_code,'ringLevel',n.defense_ring_level,
            'ringVersion',n.defense_ring_version,'distanceM',n.distance_m,
            'ruleSetId',n.rule_set_id,'ruleVersion',n.rule_version,
            'factors',n.factor_results,'reason',n.error_code
          ))
        )
        from projected n left join previous p on true
        where p.track_id is null or (p.status,p.risk_level,p.risk_score,p.defense_ring_id)
          is distinct from (n.status,n.risk_level,n.risk_score,n.defense_ring_id)
        """,
        (
            values["track_id"], values["track_id"], values["observation_id"],
            values["observed_at"], values["assessed_at"], values["status"],
            values["risk_level"], values["risk_score"], values["protected_object_id"],
            values["protected_object_version"], values["ring_id"], values["ring_code"],
            values["ring_level"], values["ring_version"], values["distance_m"],
            values["rule_set_id"], values["rule_version"], Jsonb(values["factors"]),
            Jsonb(dict(input_snapshot)), values["reason"],
        ),
    )
