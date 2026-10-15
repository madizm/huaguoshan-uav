"""数据库适配：读取目标航迹与无人机资产的观测窗口，持久化预测结果。"""

from __future__ import annotations

import json
from typing import Any, Protocol

from .domain import ObservationPoint, Prediction


class AsyncConnection(Protocol):
    async def execute(self, query: str, params: tuple[Any, ...] = ()) -> Any: ...


async def _fetch_all(conn: AsyncConnection, query: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    cursor = await conn.execute(query, params)
    return await cursor.fetchall()


def _decode_points(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, (bytes, str)):
        value = json.loads(value)
    return value or []


def _points_from_row(row: dict[str, Any]) -> list[ObservationPoint]:
    points = []
    for item in _decode_points(row.get("points")):
        if item.get("longitude") is None or item.get("latitude") is None:
            continue
        points.append(ObservationPoint(
            observation_id=item.get("observation_id"),
            observed_at=item["observed_at"],
            longitude=float(item["longitude"]),
            latitude=float(item["latitude"]),
            height_amsl_m=None if item.get("height_amsl_m") is None else float(item["height_amsl_m"]),
        ))
    return points


async def fetch_target_windows(
    conn: AsyncConnection,
    active_seconds: int,
    fetch_window_seconds: int,
    max_points: int,
    max_subjects: int,
) -> list[tuple[int, list[ObservationPoint]]]:
    """取活跃空域目标航迹的近期观测窗口，按航迹分组返回。"""
    rows = await _fetch_all(
        conn,
        """
        select t.id subject_id, coalesce(history.points,'[]'::jsonb) points
        from situation.target_track t
        left join lateral (
          select jsonb_agg(jsonb_build_object(
            'observation_id',p.id,'observed_at',p.observed_at,
            'longitude',st_x(p.geom),'latitude',st_y(p.geom),'height_amsl_m',p.height_amsl_m
          ) order by p.observed_at,p.id) points
          from (
            select distinct on (r.observed_at) r.id,r.observed_at,r.geom,r.height_amsl_m
            from situation.track_observation x
            join equipment.raw_observation r on r.id=x.observation_id
            where x.track_id=t.id and r.geom is not null
              and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
              and r.observed_at<=now()
              and r.observed_at>=now()-make_interval(secs=>%s)
            order by r.observed_at desc,r.id desc limit %s
          ) p
        ) history on true
        where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>%s)
        order by t.last_observed_at desc,t.id desc
        limit %s
        """,
        (fetch_window_seconds, max_points, active_seconds, max_subjects),
    )
    return [(int(row["subject_id"]), _points_from_row(row)) for row in rows]


async def fetch_asset_windows(
    conn: AsyncConnection,
    active_seconds: int,
    fetch_window_seconds: int,
    max_points: int,
    max_subjects: int,
) -> list[tuple[int, list[ObservationPoint]]]:
    """取活跃无人机资产的近期观测窗口，按资产分组返回。"""
    rows = await _fetch_all(
        conn,
        """
        select a.id subject_id, coalesce(history.points,'[]'::jsonb) points
        from equipment.asset a
        left join lateral (
          select jsonb_agg(jsonb_build_object(
            'observation_id',p.id,'observed_at',p.observed_at,
            'longitude',st_x(p.geom),'latitude',st_y(p.geom),'height_amsl_m',p.height_amsl_m
          ) order by p.observed_at,p.id) points
          from (
            select distinct on (r.observed_at) r.id,r.observed_at,r.geom,r.height_amsl_m
            from equipment.raw_observation r
            where r.asset_id=a.id and r.geom is not null
              and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
              and r.observed_at<=now()
              and r.observed_at>=now()-make_interval(secs=>%s)
            order by r.observed_at desc,r.id desc limit %s
          ) p
        ) history on true
        where a.category_code='uav' and a.lifecycle_status='active'
          and exists(
            select 1 from equipment.raw_observation r
            where r.asset_id=a.id and r.geom is not null
              and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
              and r.observed_at<=now()
              and r.observed_at>=now()-make_interval(secs=>%s)
          )
        order by a.id
        limit %s
        """,
        (fetch_window_seconds, max_points, active_seconds, max_subjects),
    )
    return [(int(row["subject_id"]), _points_from_row(row)) for row in rows]


async def fetch_latest_prediction_times(conn: AsyncConnection) -> dict[tuple[str, int, str], Any]:
    """取每个预测对象各质量档最近一次写入的预测时刻，用于同质量档写入节流。"""
    rows = await _fetch_all(
        conn,
        """
        select subject_kind, subject_id, quality, max(predicted_at) predicted_at
        from situation.trajectory_prediction
        where predicted_at>=now()-interval '10 minutes'
        group by subject_kind, subject_id, quality
        """,
    )
    return {(row["subject_kind"], int(row["subject_id"]), row["quality"]): row["predicted_at"] for row in rows}


def _prediction_params(prediction: Prediction) -> tuple[Any, ...]:
    coordinates = [(point.longitude, point.latitude) for point in prediction.points]
    geom = None
    if len(coordinates) >= 2:
        geom = "SRID=4326;LINESTRING(" + ",".join(f"{lon} {lat}" for lon, lat in coordinates) + ")"
    return (
        prediction.subject_kind,
        prediction.subject_id,
        prediction.base_observed_at,
        prediction.predicted_at,
        prediction.model_code,
        prediction.model_version,
        prediction.quality,
        prediction.reason,
        prediction.horizon_seconds,
        prediction.step_seconds,
        prediction.speed_mps,
        prediction.heading_deg,
        prediction.turn_rate_dps,
        prediction.window_seconds,
        prediction.window_point_count,
        prediction.fit_residual_m,
        json.dumps([point.model_dump() for point in prediction.points]),
        geom,
    )


async def persist_predictions(
    conn: AsyncConnection,
    predictions: list[Prediction],
    min_interval_seconds: float,
    retention_hours: int,
) -> int:
    """节流追加预测结果并清理过期历史，返回实际写入条数。"""
    latest = await fetch_latest_prediction_times(conn)
    written = 0
    for prediction in predictions:
        key = (prediction.subject_kind, prediction.subject_id, prediction.quality)
        last = latest.get(key)
        if last is not None and (prediction.predicted_at - last).total_seconds() < min_interval_seconds:
            continue
        await conn.execute(
            """
            insert into situation.trajectory_prediction(
              subject_kind,subject_id,base_observed_at,predicted_at,model_code,model_version,
              quality,reason,horizon_seconds,step_seconds,speed_mps,heading_deg,turn_rate_dps,
              window_seconds,window_point_count,fit_residual_m,points,geom
            ) values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s::geometry)
            """,
            _prediction_params(prediction),
        )
        latest[key] = prediction.predicted_at
        written += 1
    await conn.execute(
        "delete from situation.trajectory_prediction where predicted_at < now() - make_interval(hours => %s)",
        (retention_hours,),
    )
    return written

EVALUATION_CHECKPOINT_ETAS = (10, 30, 60, 120)
"""准确度评估的检查点档位（秒）：只对预测点序列中这些 ETA 与实际观测比对。"""

EVALUATION_TOLERANCE_SECONDS = 3
"""实际观测匹配的容差（秒）：取检查点目标时刻前后该范围内的最近一条实际观测。"""


async def evaluate_due_predictions(
    conn: AsyncConnection,
    retention_hours: int,
    checkpoint_etas: tuple[int, ...] = EVALUATION_CHECKPOINT_ETAS,
    tolerance_seconds: int = EVALUATION_TOLERANCE_SECONDS,
) -> int:
    """对已越过检查点时刻的有效预测匹配实际观测，追加准确度评估记录，返回评估条数。"""
    cursor = await conn.execute(
        """
        insert into situation.trajectory_prediction_evaluation(
          prediction_id,subject_kind,subject_id,model_code,model_version,base_observed_at,
          eta_seconds,actual_observed_at,time_offset_s,error_m,uncertainty_m,within_uncertainty
        )
        select p.id,p.subject_kind,p.subject_id,p.model_code,p.model_version,p.base_observed_at,
          ck.eta_seconds,a.observed_at,
          round(extract(epoch from a.observed_at-(p.base_observed_at+make_interval(secs=>ck.eta_seconds)))::numeric,1),
          round(st_distance(ck.geom::geography,a.geom::geography)::numeric,1),
          ck.uncertainty_m,
          st_distance(ck.geom::geography,a.geom::geography)<=ck.uncertainty_m
        from situation.trajectory_prediction p
        cross join lateral (
          select (pt->>'eta_seconds')::numeric::int eta_seconds,(pt->>'uncertainty_m')::float8 uncertainty_m,
            st_setsrid(st_makepoint((pt->>'longitude')::float8,(pt->>'latitude')::float8),4326) geom
          from jsonb_array_elements(p.points) pt
        ) ck
        join lateral (
          select a.observed_at,a.geom
          from (
            select r.observed_at,r.geom from situation.track_observation x
              join equipment.raw_observation r on r.id=x.observation_id
              where p.subject_kind='airspace_target' and x.track_id=p.subject_id and r.geom is not null
                and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
                and r.observed_at<=now()
            union all
            select r.observed_at,r.geom from equipment.raw_observation r
              where p.subject_kind='aircraft_asset' and r.asset_id=p.subject_id and r.geom is not null
                and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
                and r.observed_at<=now()
          ) a
          where a.observed_at between p.base_observed_at+make_interval(secs=>ck.eta_seconds)-make_interval(secs=>%s)
                                  and p.base_observed_at+make_interval(secs=>ck.eta_seconds)+make_interval(secs=>%s)
          order by abs(extract(epoch from a.observed_at-(p.base_observed_at+make_interval(secs=>ck.eta_seconds))))
          limit 1
        ) a on true
        where p.quality='ok' and p.points<>'[]'::jsonb
          and ck.eta_seconds=any(%s)
          and p.base_observed_at+make_interval(secs=>ck.eta_seconds)<=now()
          and p.predicted_at>=now()-make_interval(hours=>%s)
          and not exists(
            select 1 from situation.trajectory_prediction_evaluation e
            where e.prediction_id=p.id and e.eta_seconds=ck.eta_seconds)
        on conflict(prediction_id,eta_seconds) do nothing
        returning id
        """,
        (tolerance_seconds, tolerance_seconds, list(checkpoint_etas), retention_hours + 2),
    )
    return len(await cursor.fetchall())


async def register_worker_runtime(
    conn: AsyncConnection, worker_name: str, instance_id: str, engine_version: str,
) -> None:
    """登记 worker 实例并置为 running；幂等，可在每次启动时调用。"""
    await conn.execute(
        """
        insert into situation.prediction_worker_runtime(
          worker_name,instance_id,state,engine_version,started_at,heartbeat_at,updated_at
        ) values(%s,%s,'running',%s,now(),now(),now())
        on conflict(worker_name) do update set
          instance_id=excluded.instance_id,state='running',engine_version=excluded.engine_version,
          started_at=excluded.started_at,heartbeat_at=excluded.heartbeat_at,updated_at=now()
        """,
        (worker_name, instance_id, engine_version),
    )


async def record_batch_started(conn: AsyncConnection, worker_name: str) -> None:
    await conn.execute(
        """update situation.prediction_worker_runtime
        set state='running',heartbeat_at=now(),last_batch_started_at=now(),updated_at=now()
        where worker_name=%s""",
        (worker_name,),
    )


async def record_batch_success(conn: AsyncConnection, worker_name: str, written: int, duration_ms: int) -> None:
    await conn.execute(
        """
        update situation.prediction_worker_runtime set
          state='running',heartbeat_at=now(),last_batch_finished_at=now(),last_success_at=now(),
          last_batch_size=%s,last_batch_duration_ms=%s,
          processed_total=processed_total+%s,updated_at=now()
        where worker_name=%s
        """,
        (written, duration_ms, written, worker_name),
    )


async def record_worker_failure(conn: AsyncConnection, worker_name: str, error_code: str, error_message: str) -> None:
    await conn.execute(
        """
        update situation.prediction_worker_runtime set
          state='degraded',heartbeat_at=now(),last_error_at=now(),
          last_error_code=%s,last_error_message=%s,updated_at=now()
        where worker_name=%s
        """,
        (error_code[:120], error_message[:500], worker_name),
    )


async def record_worker_stopped(conn: AsyncConnection, worker_name: str) -> None:
    await conn.execute(
        """update situation.prediction_worker_runtime
        set state='stopped',heartbeat_at=now(),updated_at=now() where worker_name=%s""",
        (worker_name,),
    )
