-- 轨迹预测：空域目标与无人机资产的短期外推结果存储与大屏查询接口。
-- 预测结果由 backend/prediction worker 追加写入，仅用于大屏展示，不参与风险研判。
-- 依赖 create_detection_situation_schema.sql 和 create_equipment_asset_schema.sql。
-- 可重复执行；PostgREST 仅公开 api schema，situation 为内部数据层。

begin;

create schema if not exists situation;
create schema if not exists api;

create table if not exists situation.trajectory_prediction (
  id bigserial primary key,
  subject_kind text not null check (subject_kind in ('airspace_target','aircraft_asset')),
  subject_id bigint not null,
  base_observed_at timestamptz not null,
  predicted_at timestamptz not null,
  model_code text not null check (model_code in ('cv','ct','hover')),
  model_version integer not null check (model_version > 0),
  quality text not null check (quality in ('ok','insufficient_data')),
  reason text,
  horizon_seconds integer not null check (horizon_seconds > 0),
  horizon_policy jsonb not null default '{}'::jsonb,
  step_seconds integer not null check (step_seconds > 0),
  speed_mps numeric check (speed_mps is null or speed_mps >= 0),
  heading_deg numeric check (heading_deg is null or (heading_deg >= 0 and heading_deg < 360)),
  turn_rate_dps numeric,
  window_seconds integer not null check (window_seconds > 0),
  window_point_count integer not null check (window_point_count >= 0),
  fit_residual_m numeric check (fit_residual_m is null or fit_residual_m >= 0),
  points jsonb not null default '[]'::jsonb,
  geom geometry(LineString, 4326),
  created_at timestamptz not null default now()
);
alter table situation.trajectory_prediction
  add column if not exists horizon_policy jsonb not null default '{}'::jsonb;
comment on table situation.trajectory_prediction is '空域目标与无人机资产的短期轨迹预测追加记录；由预测 worker 写入并定期清理，仅用于大屏展示。';
comment on column situation.trajectory_prediction.subject_kind is '预测对象类别：airspace_target 空域目标航迹，aircraft_asset 无人机资产。';
comment on column situation.trajectory_prediction.subject_id is '预测对象标识：subject_kind 为 airspace_target 时是 situation.target_track.id，为 aircraft_asset 时是 equipment.asset.id。';
comment on column situation.trajectory_prediction.base_observed_at is '预测基准时刻，即窗口内最后一个有效观测的观测时间；预测点 ETA 从该时刻起算。';
comment on column situation.trajectory_prediction.predicted_at is '预测计算时刻。';
comment on column situation.trajectory_prediction.model_code is '外推模型编码：cv 恒定速度，ct 恒定转向，hover 悬停。';
comment on column situation.trajectory_prediction.model_version is '预测算法版本，随 backend/prediction 模块升级递增。';
comment on column situation.trajectory_prediction.quality is '预测质量：ok 有效预测，insufficient_data 数据不足不生成预测点。';
comment on column situation.trajectory_prediction.reason is 'quality 为 insufficient_data 时的原因编码。';
comment on column situation.trajectory_prediction.horizon_seconds is '预测时长上限，单位秒。';
comment on column situation.trajectory_prediction.horizon_policy is '预测时长策略元数据；配置的时长上限仍为 horizon_seconds，固定模式为 {}。自适应模式包含 mode、actual_horizon_seconds（末个输出点 ETA，无点为 0）、remaining_horizon_seconds（max(末个 ETA - 计算时的观测年龄秒数, 0)）、stop_reason、rule_version、thresholds（阈值）和 metrics（指标）。';
comment on column situation.trajectory_prediction.step_seconds is '预测点间隔，单位秒。';
comment on column situation.trajectory_prediction.speed_mps is '窗口拟合地速，单位米每秒。';
comment on column situation.trajectory_prediction.heading_deg is '窗口拟合航向，真北顺时针角度。';
comment on column situation.trajectory_prediction.turn_rate_dps is '恒定转向模型的转向率，单位度每秒，右转为正。';
comment on column situation.trajectory_prediction.window_seconds is '拟合窗口时长，单位秒。';
comment on column situation.trajectory_prediction.window_point_count is '参与拟合的有效观测点数。';
comment on column situation.trajectory_prediction.fit_residual_m is '窗口拟合位置均方根残差，单位米，反映观测噪声水平。';
comment on column situation.trajectory_prediction.points is '预测点数组：[{"eta_seconds","longitude","latitude","height_amsl_m","uncertainty_m"}]，eta_seconds 从 base_observed_at 起算，uncertainty_m 为水平不确定半径。';
comment on column situation.trajectory_prediction.geom is '预测线 WGS84 LineString（EPSG:4326），由 points 派生，用于空间检索；无预测点时为 NULL。';
create index if not exists trajectory_prediction_subject_time_idx
  on situation.trajectory_prediction(subject_kind, subject_id, predicted_at desc, id desc);
create index if not exists trajectory_prediction_time_idx
  on situation.trajectory_prediction(predicted_at desc);
create table if not exists situation.trajectory_prediction_evaluation (
  id bigserial primary key,
  prediction_id bigint not null,
  subject_kind text not null check (subject_kind in ('airspace_target','aircraft_asset')),
  subject_id bigint not null,
  model_code text not null check (model_code in ('cv','ct','hover')),
  model_version integer not null check (model_version > 0),
  base_observed_at timestamptz not null,
  eta_seconds integer not null check (eta_seconds > 0),
  actual_observed_at timestamptz not null,
  time_offset_s numeric not null,
  error_m numeric not null check (error_m >= 0),
  uncertainty_m numeric not null check (uncertainty_m >= 0),
  within_uncertainty boolean not null,
  evaluated_at timestamptz not null default now(),
  unique (prediction_id, eta_seconds)
);
comment on table situation.trajectory_prediction_evaluation is '轨迹预测准确度评估追加记录：预测越过检查点时刻后与实际观测比对的结果；预测超期清理后评估仍保留，用于模型效果审计。';
comment on column situation.trajectory_prediction_evaluation.prediction_id is '被评估的轨迹预测记录 ID，软引用；situation.trajectory_prediction 超期清理后本表不级联删除。';
comment on column situation.trajectory_prediction_evaluation.subject_kind is '预测对象类别：airspace_target 空域目标航迹，aircraft_asset 无人机资产。';
comment on column situation.trajectory_prediction_evaluation.subject_id is '预测对象标识：空域目标为航迹 ID，无人机资产为设备资产 ID。';
comment on column situation.trajectory_prediction_evaluation.base_observed_at is '被评估预测的基准时刻；检查点目标时刻为该时刻加 eta_seconds。';
comment on column situation.trajectory_prediction_evaluation.eta_seconds is '评估检查点：从基准时刻起算的秒数，取预测点序列中的固定档位。';
comment on column situation.trajectory_prediction_evaluation.actual_observed_at is '匹配到的实际观测时刻；匹配容差由 worker 参数控制。';
comment on column situation.trajectory_prediction_evaluation.time_offset_s is '实际观测时刻减检查点目标时刻的秒数；正值表示实际观测偏晚。';
comment on column situation.trajectory_prediction_evaluation.error_m is '预测点与实际观测位置的水平误差，单位米，按 WGS84 椭球面距离计算。';
comment on column situation.trajectory_prediction_evaluation.uncertainty_m is '该预测点生成时输出的水平不确定半径，单位米。';
comment on column situation.trajectory_prediction_evaluation.within_uncertainty is '误差是否落在不确定半径内；用于校验不确定度口径是否可信。';
create index if not exists trajectory_prediction_evaluation_subject_idx
  on situation.trajectory_prediction_evaluation(subject_kind, subject_id, base_observed_at desc, id desc);
create index if not exists trajectory_prediction_evaluation_time_idx
  on situation.trajectory_prediction_evaluation(evaluated_at desc);

create index if not exists trajectory_prediction_geom_gix
  on situation.trajectory_prediction using gist (geom);

create or replace function api.get_trajectory_predictions(
  p_subject_kinds text[] default null,
  p_max_subjects integer default 200,
  p_max_prediction_age_seconds integer default 30
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
declare v_result jsonb;
begin
  if p_max_subjects not between 1 and 2000 then raise exception 'max subjects must be between 1 and 2000'; end if;
  if p_max_prediction_age_seconds not between 5 and 600 then raise exception 'max prediction age must be between 5 and 600 seconds'; end if;
  if p_subject_kinds is not null and exists(
    select 1 from unnest(p_subject_kinds) k where k not in ('airspace_target','aircraft_asset')
  ) then raise exception 'subject kinds must be airspace_target or aircraft_asset'; end if;
  -- 先按最新计算状态选定共同对象池，避免独立截断遗漏有效预测对应的新失败状态。
  with latest_states as (
    select distinct on (p.subject_kind, p.subject_id) p.*
    from situation.trajectory_prediction p
    where p.predicted_at >= now() - interval '10 minutes'
      and (p_subject_kinds is null or p.subject_kind = any(p_subject_kinds))
    order by p.subject_kind, p.subject_id, p.predicted_at desc, p.id desc
  ), selected_subjects as (
    select * from latest_states
    order by predicted_at desc, id desc
    limit p_max_subjects
  )
  select jsonb_build_object(
    'generated_at', now(),
    'predictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', latest.id,
        'subject_kind', latest.subject_kind,
        'subject_id', latest.subject_id,
        'base_observed_at', latest.base_observed_at,
        'predicted_at', latest.predicted_at,
        'model_code', latest.model_code,
        'model_version', latest.model_version,
        'horizon_seconds', latest.horizon_seconds,
        'horizon_policy', latest.horizon_policy,
        'step_seconds', latest.step_seconds,
        'speed_mps', latest.speed_mps,
        'heading_deg', latest.heading_deg,
        'turn_rate_dps', latest.turn_rate_dps,
        'window_point_count', latest.window_point_count,
        'fit_residual_m', latest.fit_residual_m,
        'points', latest.points
      ) order by latest.subject_kind, latest.subject_id)
      from (
        select distinct on (p.subject_kind, p.subject_id) p.*
        from situation.trajectory_prediction p
        join selected_subjects s
          on s.subject_kind = p.subject_kind and s.subject_id = p.subject_id
        where p.quality = 'ok'
          and p.predicted_at >= now() - make_interval(secs => p_max_prediction_age_seconds)
        order by p.subject_kind, p.subject_id, p.predicted_at desc, p.id desc
      ) latest
    ), '[]'::jsonb),
    'states', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', latest.id,
        'subject_kind', latest.subject_kind,
        'subject_id', latest.subject_id,
        'quality', latest.quality,
        'reason', latest.reason,
        'base_observed_at', latest.base_observed_at,
        'predicted_at', latest.predicted_at,
        'horizon_seconds', latest.horizon_seconds,
        'horizon_policy', latest.horizon_policy,
        'model_code', latest.model_code,
        'model_version', latest.model_version,
        'step_seconds', latest.step_seconds
      ) order by latest.subject_kind, latest.subject_id)
      from selected_subjects latest
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function api.get_trajectory_predictions(text[],integer,integer) is '查询预测与最新计算状态。返回 {"generated_at","predictions":[{"id","subject_kind","subject_id","base_observed_at","predicted_at","model_code","model_version","horizon_seconds","horizon_policy","step_seconds","speed_mps","heading_deg","turn_rate_dps","window_point_count","fit_residual_m","points":[{"eta_seconds","longitude","latitude","height_amsl_m","uncertainty_m"}]}],"states":[{"id","subject_kind","subject_id","quality","reason","base_observed_at","predicted_at","horizon_seconds","horizon_policy","model_code","model_version","step_seconds"}]}；horizon_policy 为时长策略元数据对象，固定模式为 {}，字段含 mode、actual_horizon_seconds、remaining_horizon_seconds、stop_reason、rule_version、thresholds、metrics；先按对象取近10分钟最新记录（不限质量），再按 predicted_at、id 倒序选最多 p_max_subjects 个对象作为共同对象池；states 返回池内全部最新状态（无预测点），predictions 仅取池内有效且不超过 p_max_prediction_age_seconds 秒的最新记录，每条预测必有对应状态；数组按对象类别与 ID 升序，空集返回空数组。';

do $$ begin
  if not exists(select 1 from pg_roles where rolname='prediction_engine') then
    create role prediction_engine login noinherit;
  end if;
end $$;
alter role prediction_engine login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;

revoke all on situation.trajectory_prediction from public, anonymous, admin, prediction_engine;
revoke all on sequence situation.trajectory_prediction_id_seq from public, anonymous, admin, prediction_engine;
grant select on situation.trajectory_prediction to admin;
grant usage on schema situation, equipment to prediction_engine;
grant select on situation.target_track, situation.track_observation,
  equipment.raw_observation, equipment.asset, equipment.asset_status_current to prediction_engine;
grant select, insert, delete on situation.trajectory_prediction to prediction_engine;
grant usage on sequence situation.trajectory_prediction_id_seq to prediction_engine;
grant execute on function api.get_trajectory_predictions(text[],integer,integer) to admin;

-- ── 预测 worker 运行状态与后台管理接口 ─────────────────────────────

create table if not exists situation.prediction_worker_runtime (
  worker_name text primary key,
  instance_id text,
  state text not null default 'stopped' check (state in ('running','idle','degraded','stopped')),
  engine_version text,
  started_at timestamptz,
  heartbeat_at timestamptz,
  last_batch_started_at timestamptz,
  last_batch_finished_at timestamptz,
  last_success_at timestamptz,
  last_error_at timestamptz,
  last_error_code text,
  last_error_message text,
  last_batch_size integer not null default 0 check (last_batch_size >= 0),
  last_batch_duration_ms integer check (last_batch_duration_ms >= 0),
  processed_total bigint not null default 0 check (processed_total >= 0),
  failed_total bigint not null default 0 check (failed_total >= 0),
  updated_at timestamptz not null default now()
);
comment on table situation.prediction_worker_runtime is '轨迹预测 worker 的当前运行状态、心跳、批次统计和最近错误；由 worker 维护，管理端只读。';
comment on column situation.prediction_worker_runtime.heartbeat_at is 'worker 存活心跳；每轮批次都会更新。';
comment on column situation.prediction_worker_runtime.last_batch_size is '最近一轮实际写入的预测条数（节流后）。';
comment on column situation.prediction_worker_runtime.processed_total is '累计写入的预测条数。';
insert into situation.prediction_worker_runtime(worker_name) values('trajectory-prediction')
on conflict(worker_name) do nothing;

create or replace function api.get_prediction_engine_status(
  p_offline_after_seconds integer default 15
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
declare
  v_worker situation.prediction_worker_runtime%rowtype;
  v_heartbeat_age double precision;
  v_state text;
begin
  if p_offline_after_seconds not between 5 and 600 then raise exception 'offline threshold must be between 5 and 600 seconds'; end if;
  select * into v_worker from situation.prediction_worker_runtime where worker_name='trajectory-prediction';
  v_heartbeat_age := case when v_worker.heartbeat_at is null then null
    else extract(epoch from now()-v_worker.heartbeat_at) end;
  v_state := case
    when v_worker.worker_name is null or v_heartbeat_age is null or v_heartbeat_age > p_offline_after_seconds then 'offline'
    when v_worker.state in ('degraded','stopped') then 'degraded'
    else 'healthy' end;
  return jsonb_build_object(
    'generated_at', now(),
    'state', v_state,
    'worker', jsonb_build_object(
      'name', coalesce(v_worker.worker_name, 'trajectory-prediction'),
      'instanceId', v_worker.instance_id,
      'runtimeState', coalesce(v_worker.state, 'stopped'),
      'engineVersion', v_worker.engine_version,
      'startedAt', v_worker.started_at,
      'heartbeatAt', v_worker.heartbeat_at,
      'heartbeatAgeSeconds', floor(v_heartbeat_age)::integer,
      'lastBatchStartedAt', v_worker.last_batch_started_at,
      'lastBatchFinishedAt', v_worker.last_batch_finished_at,
      'lastSuccessAt', v_worker.last_success_at,
      'lastErrorAt', v_worker.last_error_at,
      'lastErrorCode', v_worker.last_error_code,
      'lastErrorMessage', v_worker.last_error_message,
      'lastBatchSize', coalesce(v_worker.last_batch_size, 0),
      'lastBatchDurationMs', v_worker.last_batch_duration_ms,
      'processedTotal', coalesce(v_worker.processed_total, 0),
      'failedTotal', coalesce(v_worker.failed_total, 0)
    ),
    'throughput', jsonb_build_object(
      'writtenLastMinute', (select count(*) from situation.trajectory_prediction
        where predicted_at>=now()-interval '1 minute' and quality='ok'),
      'writtenLastHour', (select count(*) from situation.trajectory_prediction
        where predicted_at>=now()-interval '1 hour' and quality='ok'),
      'insufficientLastHour', (select count(*) from situation.trajectory_prediction
        where predicted_at>=now()-interval '1 hour' and quality='insufficient_data'),
      'activeSubjects', (select count(*) from (
        select distinct subject_kind, subject_id from situation.trajectory_prediction
        where predicted_at>=now()-interval '30 seconds' and quality='ok'
      ) active),
      'averageLatencySeconds', (select round(avg(extract(epoch from (predicted_at-base_observed_at)))::numeric, 2)
        from situation.trajectory_prediction
        where predicted_at>=now()-interval '1 hour' and quality='ok')
    ),
    'models', coalesce((select jsonb_object_agg(model_code, cnt) from (
      select model_code, count(*) cnt from situation.trajectory_prediction
      where predicted_at>=now()-interval '1 hour' and quality='ok'
      group by model_code
    ) m), '{}'::jsonb)
  );
end;
$$;
comment on function api.get_prediction_engine_status(integer) is '轨迹预测引擎健康状态。返回 {"generated_at","state","worker":{心跳、批次与错误字段},"throughput":{"writtenLastMinute","writtenLastHour","insufficientLastHour","activeSubjects","averageLatencySeconds"},"models":{"cv","ct","hover"}}；state 为 healthy、degraded、offline 之一，心跳超过 p_offline_after_seconds 秒判为 offline。';

create or replace function api.list_trajectory_predictions(
  p_limit integer default 50,
  p_subject_kinds text[] default null
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
begin
  if p_limit not between 1 and 500 then raise exception 'limit must be between 1 and 500'; end if;
  if p_subject_kinds is not null and exists(
    select 1 from unnest(p_subject_kinds) k where k not in ('airspace_target','aircraft_asset')
  ) then raise exception 'subject kinds must be airspace_target or aircraft_asset'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    'predictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'subject_kind', p.subject_kind,
        'subject_id', p.subject_id,
        'base_observed_at', p.base_observed_at,
        'predicted_at', p.predicted_at,
        'model_code', p.model_code,
        'model_version', p.model_version,
        'quality', p.quality,
        'reason', p.reason,
        'horizon_seconds', p.horizon_seconds,
        'horizon_policy', p.horizon_policy,
        'speed_mps', p.speed_mps,
        'heading_deg', p.heading_deg,
        'turn_rate_dps', p.turn_rate_dps,
        'window_point_count', p.window_point_count,
        'fit_residual_m', p.fit_residual_m,
        'point_count', jsonb_array_length(p.points)
      ) order by p.predicted_at desc, p.id desc)
      from (
        select * from situation.trajectory_prediction
        where p_subject_kinds is null or subject_kind = any(p_subject_kinds)
        order by predicted_at desc, id desc
        limit p_limit
      ) p
    ), '[]'::jsonb)
  );
end;
$$;
comment on function api.list_trajectory_predictions(integer,text[]) is '按预测时间倒序列出最近的轨迹预测记录（不含预测点几何）。返回 {"generated_at","predictions":[{"id","subject_kind","subject_id","base_observed_at","predicted_at","model_code","model_version","quality","reason","horizon_seconds","horizon_policy","speed_mps","heading_deg","turn_rate_dps","window_point_count","fit_residual_m","point_count"}]}，用于后台管理的预测质量核查。';

revoke all on situation.prediction_worker_runtime from public, anonymous, admin, prediction_engine;
grant select on situation.prediction_worker_runtime to admin;
grant select, insert, update on situation.prediction_worker_runtime to prediction_engine;
grant execute on function api.get_prediction_engine_status(integer) to admin;
grant execute on function api.list_trajectory_predictions(integer,text[]) to admin;

create or replace function api.get_prediction_accuracy_stats(
  p_hours integer default 24
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
begin
  if p_hours not between 1 and 720 then raise exception 'hours must be between 1 and 720'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    'hours', p_hours,
    'summary', (
      select jsonb_build_object(
        'evaluatedPredictions', count(distinct prediction_id),
        'samples', count(*),
        'meanErrorM', round(avg(error_m)::numeric,1),
        'medianErrorM', round(percentile_cont(0.5) within group (order by error_m)::numeric,1),
        'withinUncertaintyRate', round(avg(case when within_uncertainty then 1.0 else 0.0 end)::numeric,3)
      )
      from situation.trajectory_prediction_evaluation
      where base_observed_at >= now() - make_interval(hours => p_hours)
    ),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'modelCode', model_code,
        'subjectKind', subject_kind,
        'etaSeconds', eta_seconds,
        'samples', samples,
        'meanErrorM', mean_error_m,
        'medianErrorM', median_error_m,
        'p90ErrorM', p90_error_m,
        'withinUncertaintyRate', within_uncertainty_rate
      ) order by subject_kind, model_code, eta_seconds)
      from (
        select model_code, subject_kind, eta_seconds,
          count(*)::integer samples,
          round(avg(error_m)::numeric,1) mean_error_m,
          round(percentile_cont(0.5) within group (order by error_m)::numeric,1) median_error_m,
          round(percentile_cont(0.9) within group (order by error_m)::numeric,1) p90_error_m,
          round(avg(case when within_uncertainty then 1.0 else 0.0 end)::numeric,3) within_uncertainty_rate
        from situation.trajectory_prediction_evaluation
        where base_observed_at >= now() - make_interval(hours => p_hours)
        group by model_code, subject_kind, eta_seconds
      ) b
    ), '[]'::jsonb)
  );
end;
$$;
comment on function api.get_prediction_accuracy_stats(integer) is '轨迹预测准确度汇总。返回 {"generated_at","hours","summary":{"evaluatedPredictions","samples","meanErrorM","medianErrorM","withinUncertaintyRate"},"buckets":[{"modelCode","subjectKind","etaSeconds","samples","meanErrorM","medianErrorM","p90ErrorM","withinUncertaintyRate"}]}；误差单位米，覆盖率误差落在不确定半径内的比例；无样本时 summary 各指标为 NULL。';

create or replace function api.get_prediction_evaluation_detail(
  p_prediction_id bigint
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
begin
  return jsonb_build_object(
    'generated_at', now(),
    'prediction_id', p_prediction_id,
    'evaluations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'etaSeconds', e.eta_seconds,
        'errorM', e.error_m,
        'uncertaintyM', e.uncertainty_m,
        'withinUncertainty', e.within_uncertainty,
        'actualObservedAt', e.actual_observed_at,
        'timeOffsetS', e.time_offset_s,
        'evaluatedAt', e.evaluated_at
      ) order by e.eta_seconds)
      from situation.trajectory_prediction_evaluation e
      where e.prediction_id = p_prediction_id
    ), '[]'::jsonb)
  );
end;
$$;
comment on function api.get_prediction_evaluation_detail(bigint) is '单条预测的准确度评估明细。返回 {"generated_at","prediction_id","evaluations":[{"etaSeconds","errorM","uncertaintyM","withinUncertainty","actualObservedAt","timeOffsetS","evaluatedAt"}]}；预测记录超期清理后明细仍可查；未评估时 evaluations 为空数组。';

create or replace function api.get_track_prediction_history(
  p_track_id bigint,
  p_from timestamptz,
  p_to timestamptz,
  p_thin_seconds integer default 30
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation,api as $$
begin
  if p_thin_seconds not between 5 and 600 then raise exception 'thin seconds must be between 5 and 600'; end if;
  if p_from is null or p_to is null or p_from >= p_to then raise exception 'from must be earlier than to'; end if;
  if p_to - p_from > interval '7 days' then raise exception 'time window must not exceed 7 days'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    'track_id', p_track_id,
    'thin_seconds', p_thin_seconds,
    'predictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'base_observed_at', t.base_observed_at,
        'predicted_at', t.predicted_at,
        'model_code', t.model_code,
        'horizon_seconds', t.horizon_seconds,
        'horizon_policy', t.horizon_policy,
        'speed_mps', t.speed_mps,
        'heading_deg', t.heading_deg,
        'turn_rate_dps', t.turn_rate_dps,
        'points', t.points
      ) order by t.base_observed_at, t.id)
      from (
        select distinct on (floor(extract(epoch from p.base_observed_at)/p_thin_seconds))
          p.id, p.base_observed_at, p.predicted_at, p.model_code,
          p.speed_mps, p.heading_deg, p.turn_rate_dps, p.points, p.horizon_seconds, p.horizon_policy
        from situation.trajectory_prediction p
        where p.subject_kind='airspace_target' and p.subject_id=p_track_id
          and p.quality='ok' and p.points<>'[]'::jsonb
          and p.base_observed_at between p_from and p_to
        order by floor(extract(epoch from p.base_observed_at)/p_thin_seconds),
          p.base_observed_at desc, p.id desc
      ) t
    ), '[]'::jsonb)
  );
end;
$$;
comment on function api.get_track_prediction_history(bigint,timestamptz,timestamptz,integer) is '按航迹抽稀查询历史轨迹预测，用于大屏历史回放叠加"当时的预测"。返回 {"generated_at","track_id","thin_seconds","predictions":[{"id","base_observed_at","predicted_at","model_code","horizon_seconds","horizon_policy","speed_mps","heading_deg","turn_rate_dps","points":[{"eta_seconds","longitude","latitude","height_amsl_m","uncertainty_m"}]}]}；horizon_policy 为时长策略元数据对象，固定模式为 {}，字段含 mode、actual_horizon_seconds、remaining_horizon_seconds、stop_reason、rule_version、thresholds、metrics；每个抽稀时间桶取基准时刻最新的一条，仅含 quality=ok 且有预测点的记录；预测仅保留 24 小时，超出窗口返回空数组。';

grant execute on function api.get_track_prediction_history(bigint,timestamptz,timestamptz,integer) to admin;

revoke all on situation.trajectory_prediction_evaluation from public, anonymous, admin, prediction_engine;
revoke all on sequence situation.trajectory_prediction_evaluation_id_seq from public, anonymous, admin, prediction_engine;
grant select on situation.trajectory_prediction_evaluation to admin;
grant select, insert on situation.trajectory_prediction_evaluation to prediction_engine;
grant usage on sequence situation.trajectory_prediction_evaluation_id_seq to prediction_engine;
grant execute on function api.get_prediction_accuracy_stats(integer) to admin;
grant execute on function api.get_prediction_evaluation_detail(bigint) to admin;

commit;
