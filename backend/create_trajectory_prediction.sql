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
  select jsonb_build_object(
    'generated_at', now(),
    'predictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'subject_kind', latest.subject_kind,
        'subject_id', latest.subject_id,
        'base_observed_at', latest.base_observed_at,
        'predicted_at', latest.predicted_at,
        'model_code', latest.model_code,
        'model_version', latest.model_version,
        'horizon_seconds', latest.horizon_seconds,
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
        where p.quality = 'ok'
          and p.predicted_at >= now() - make_interval(secs => p_max_prediction_age_seconds)
          and (p_subject_kinds is null or p.subject_kind = any(p_subject_kinds))
        order by p.subject_kind, p.subject_id, p.predicted_at desc, p.id desc
      ) latest
      limit p_max_subjects
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function api.get_trajectory_predictions(text[],integer,integer) is '查询各预测对象最新有效轨迹预测。返回 {"generated_at","predictions":[{"subject_kind","subject_id","base_observed_at","predicted_at","model_code","model_version","horizon_seconds","step_seconds","speed_mps","heading_deg","turn_rate_dps","window_point_count","fit_residual_m","points":[{"eta_seconds","longitude","latitude","height_amsl_m","uncertainty_m"}]}]}；仅含 quality=ok 且预测时刻不超过 p_max_prediction_age_seconds 的记录。';

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

commit;
