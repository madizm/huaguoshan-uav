"""Database adapter for detection observations and published risk configuration."""

from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any, Protocol

from .domain import ProtectedObjectInput, RingInput, RuleSet, TargetInput


def _text(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


class AsyncConnection(Protocol):
    async def execute(self, query: str, params: tuple[Any, ...] = ()) -> Any: ...


async def _fetch_all(conn: AsyncConnection, query: str, params: tuple[Any, ...] = ()) -> Sequence[dict[str, Any]]:
    cursor = await conn.execute(query, params)
    return await cursor.fetchall()


async def _fetch_one(conn: AsyncConnection, query: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
    cursor = await conn.execute(query, params)
    return await cursor.fetchone()


async def lock_worker_cursor(conn: AsyncConnection, worker_name: str) -> int:
    cursor = await conn.execute(
        "select last_observation_id from event_response.risk_worker_cursor where worker_name=%s for update",
        (worker_name,),
    )
    row = await cursor.fetchone()
    if row is None:
        raise RuntimeError(f"risk worker cursor {worker_name!r} is unavailable")
    return int(row["last_observation_id"])


async def update_worker_cursor(conn: AsyncConnection, worker_name: str, observation_id: int) -> None:
    await conn.execute(
        "update event_response.risk_worker_cursor set last_observation_id=greatest(last_observation_id,%s),updated_at=now() where worker_name=%s",
        (observation_id, worker_name),
    )


async def register_worker_runtime(
    conn: AsyncConnection, worker_name: str, instance_id: str, engine_version: str,
) -> None:
    await conn.execute(
        """
        insert into event_response.risk_worker_runtime(
          worker_name,instance_id,state,engine_version,started_at,heartbeat_at,updated_at
        ) values(%s,%s,'running',%s,now(),now(),now())
        on conflict(worker_name) do update set
          instance_id=excluded.instance_id,state='running',engine_version=excluded.engine_version,
          started_at=excluded.started_at,heartbeat_at=excluded.heartbeat_at,updated_at=now()
        """,
        (worker_name, instance_id, engine_version),
    )


async def record_worker_idle(conn: AsyncConnection, worker_name: str) -> None:
    await conn.execute(
        """
        update event_response.risk_worker_runtime
        set state='idle',heartbeat_at=now(),updated_at=now()
        where worker_name=%s and (heartbeat_at is null or heartbeat_at<now()-interval '5 seconds')
        """,
        (worker_name,),
    )


async def record_batch_started(conn: AsyncConnection, worker_name: str) -> None:
    await conn.execute(
        """update event_response.risk_worker_runtime
        set state='running',heartbeat_at=now(),last_batch_started_at=now(),updated_at=now()
        where worker_name=%s""",
        (worker_name,),
    )


async def record_batch_success(
    conn: AsyncConnection, worker_name: str, batch_size: int,
    failed_count: int, duration_ms: int,
) -> None:
    await conn.execute(
        """
        update event_response.risk_worker_runtime set
          state='running',heartbeat_at=now(),last_batch_finished_at=now(),last_success_at=now(),
          last_batch_size=%s,last_batch_duration_ms=%s,
          processed_total=processed_total+%s,failed_total=failed_total+%s,updated_at=now()
        where worker_name=%s
        """,
        (batch_size, duration_ms, batch_size, failed_count, worker_name),
    )


async def record_worker_failure(
    conn: AsyncConnection, worker_name: str, error_code: str, error_message: str,
) -> None:
    await conn.execute(
        """
        update event_response.risk_worker_runtime set
          state='degraded',heartbeat_at=now(),last_error_at=now(),
          last_error_code=%s,last_error_message=%s,updated_at=now()
        where worker_name=%s
        """,
        (error_code[:120], error_message[:500], worker_name),
    )


async def record_worker_stopped(conn: AsyncConnection, worker_name: str) -> None:
    await conn.execute(
        """update event_response.risk_worker_runtime
        set state='stopped',heartbeat_at=now(),updated_at=now() where worker_name=%s""",
        (worker_name,),
    )


async def fetch_pending_observations(conn: AsyncConnection, after_id: int, limit: int = 100) -> Sequence[dict[str, Any]]:
    return await _fetch_all(
        conn,
        """
        select t.track_id, r.id observation_id, r.observed_at,
          case when r.geom is null then null else st_x(r.geom) end longitude,
          case when r.geom is null then null else st_y(r.geom) end latitude,
          o.speed_mps,a.identity_status,coalesce(history.trajectory,'[]'::jsonb) trajectory
        from situation.track_observation t
        join situation.target_track tr on tr.id=t.track_id
        join situation.airspace_target a on a.id=tr.target_id
        join equipment.raw_observation r on r.id=t.observation_id
        join situation.target_observation o on o.observation_id=r.id
        left join lateral (
          select jsonb_agg(jsonb_build_object(
            'observation_id',h.id,'observed_at',h.observed_at,
            'longitude',st_x(h.geom),'latitude',st_y(h.geom)
          ) order by h.observed_at,h.id) trajectory
          from (
            select pr.id,pr.observed_at,pr.geom
            from situation.track_observation pt
            join equipment.raw_observation pr on pr.id=pt.observation_id
            where pt.track_id=t.track_id and pr.geom is not null
              and (pr.observed_at,pr.id)<=(r.observed_at,r.id)
              and pr.observed_at>=r.observed_at-interval '120 seconds'
            order by pr.observed_at desc,pr.id desc limit 100
          ) h
        ) history on true
        where r.id > %s or not exists (
          select 1 from event_response.target_risk_assessment a where a.observation_id=r.id
        )
        order by r.id
        limit %s
        """,
        (after_id, limit),
    )


async def fetch_observation(conn: AsyncConnection, observation_id: int) -> dict[str, Any] | None:
    return await _fetch_one(
        conn,
        """
        select t.track_id, r.id observation_id, r.observed_at,
          case when r.geom is null then null else st_x(r.geom) end longitude,
          case when r.geom is null then null else st_y(r.geom) end latitude,
          o.speed_mps,a.identity_status,coalesce(history.trajectory,'[]'::jsonb) trajectory
        from situation.track_observation t
        join situation.target_track tr on tr.id=t.track_id
        join situation.airspace_target a on a.id=tr.target_id
        join equipment.raw_observation r on r.id=t.observation_id
        join situation.target_observation o on o.observation_id=r.id
        left join lateral (
          select jsonb_agg(jsonb_build_object(
            'observation_id',h.id,'observed_at',h.observed_at,
            'longitude',st_x(h.geom),'latitude',st_y(h.geom)
          ) order by h.observed_at,h.id) trajectory
          from (
            select pr.id,pr.observed_at,pr.geom
            from situation.track_observation pt
            join equipment.raw_observation pr on pr.id=pt.observation_id
            where pt.track_id=t.track_id and pr.geom is not null
              and (pr.observed_at,pr.id)<=(r.observed_at,r.id)
              and pr.observed_at>=r.observed_at-interval '120 seconds'
            order by pr.observed_at desc,pr.id desc limit 100
          ) h
        ) history on true
        where r.id=%s
        """,
        (observation_id,),
    )


async def fetch_published_configuration(conn: AsyncConnection) -> tuple[list[ProtectedObjectInput], RuleSet]:
    rule_rows = await _fetch_all(
        conn,
        """
        select s.id rule_set_id,s.version rule_version,f.factor_code,f.threshold_value,f.score
        from event_response.risk_rule_set s
        join event_response.risk_rule_factor f on f.rule_set_id=s.id and f.enabled
        where s.code='defense-risk' and s.status='active'
          and s.effective_from<=now() and (s.effective_to is null or s.effective_to>now())
        order by f.factor_code
        """,
    )
    if not rule_rows:
        raise RuntimeError("active defense-risk rule set is unavailable")
    rules = RuleSet(
        id=int(rule_rows[0]["rule_set_id"]),
        version=int(rule_rows[0]["rule_version"]),
        scores={_text(row["factor_code"]): int(row["score"]) for row in rule_rows},
        thresholds={
            _text(row["factor_code"]): None if row["threshold_value"] is None else float(row["threshold_value"])
            for row in rule_rows
        },
    )
    parameter_rows = await _fetch_all(
        conn,
        "select parameter_code,value_numeric from event_response.risk_rule_parameter where rule_set_id=%s",
        (rules.id,),
    )
    rules = RuleSet(
        id=rules.id, version=rules.version, scores=rules.scores, thresholds=rules.thresholds,
        parameters={_text(row["parameter_code"]): float(row["value_numeric"]) for row in parameter_rows},
    )

    ring_rows = await _fetch_all(
        conn,
        """
        select p.id object_id,p.name object_name,st_x(r.center_geom) longitude,st_y(r.center_geom) latitude,
          p.current_version object_version,p.enabled object_enabled,
          r.id ring_id,r.code ring_code,r.name ring_name,r.ring_level,r.radius_m,r.priority,r.version ring_version
        from airspace.protected_object p
        join airspace.defense_ring r on r.protected_object_id=p.id and r.version=p.current_version
        where p.enabled and r.enabled and r.valid_from<=now() and (r.valid_to is null or r.valid_to>now())
        order by p.id,r.ring_level
        """,
    )
    objects: dict[int, ProtectedObjectInput] = {}
    seen_rings: set[int] = set()
    for row in ring_rows:
        object_id = int(row["object_id"])
        if object_id not in objects:
            objects[object_id] = ProtectedObjectInput(
                id=object_id, name=_text(row["object_name"]), longitude=float(row["longitude"]),
                latitude=float(row["latitude"]), version=int(row["object_version"]),
                enabled=bool(row["object_enabled"]), rings=[],
            )
        ring_id = int(row["ring_id"])
        if ring_id not in seen_rings:
            seen_rings.add(ring_id)
            objects[object_id].rings.append(RingInput(
                id=ring_id, code=_text(row["ring_code"]), name=_text(row["ring_name"]),
                ring_level=int(row["ring_level"]), radius_m=float(row["radius_m"]),
                priority=int(row["priority"]), version=int(row["ring_version"]),
            ))
    return list(objects.values()), rules


def target_from_row(row: dict[str, Any]) -> TargetInput:
    trajectory = row.get("trajectory") or []
    if isinstance(trajectory, bytes):
        trajectory = json.loads(trajectory.decode("utf-8"))
    return TargetInput(
        track_id=int(row["track_id"]), observation_id=int(row["observation_id"]),
        observed_at=row["observed_at"], longitude=row["longitude"], latitude=row["latitude"],
        speed_mps=row["speed_mps"], identity_status=_text(row.get("identity_status", "unverified")),
        trajectory=trajectory,
    )
