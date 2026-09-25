-- Versioned risk-assessment history and the latest per-track projection.
-- The Python risk engine is the only writer; PostgREST callers receive read-only data.
begin;

create schema if not exists event_response;

create table if not exists event_response.target_risk_assessment (
  id bigserial primary key,
  track_id bigint not null references situation.target_track(id) on delete restrict,
  observation_id bigint references equipment.raw_observation(id) on delete restrict,
  observed_at timestamptz not null,
  assessed_at timestamptz not null default now(),
  status text not null check (status in ('assessed','outside_protected_objects','target_location_unavailable','pending','failed')),
  risk_level text not null check (risk_level in ('none','low','medium','high','critical')),
  risk_score integer not null check (risk_score between 0 and 100),
  protected_object_id bigint references airspace.protected_object(id) on delete restrict,
  protected_object_version integer,
  defense_ring_id bigint references airspace.defense_ring(id) on delete restrict,
  defense_ring_code text,
  defense_ring_level integer,
  defense_ring_version integer,
  distance_m numeric,
  rule_set_id bigint references event_response.risk_rule_set(id) on delete restrict,
  rule_version integer,
  factor_results jsonb not null default '[]'::jsonb,
  input_snapshot jsonb not null default '{}'::jsonb,
  error_code text,
  created_at timestamptz not null default now(),
  check (observation_id is not null or status in ('pending','failed')),
  check (protected_object_id is null or defense_ring_id is not null),
  check (defense_ring_id is null or defense_ring_version is not null),
  check (distance_m is null or distance_m >= 0)
);
comment on table event_response.target_risk_assessment is 'Python 风险评估引擎写入的追加式目标风险评估历史；每条记录冻结输入和配置版本。';
comment on column event_response.target_risk_assessment.observation_id is '触发本次评估的原始目标观测 ID；用于幂等和审计关联。';
comment on column event_response.target_risk_assessment.factor_results is '受控评分因子的命中、分值和解释 JSON 数组。';
comment on column event_response.target_risk_assessment.input_snapshot is '评估时使用的最小输入快照，不替代原始观测。';

create unique index if not exists target_risk_assessment_observation_uq
  on event_response.target_risk_assessment(observation_id)
  where observation_id is not null;
create index if not exists target_risk_assessment_track_time_idx
  on event_response.target_risk_assessment(track_id, observed_at desc, id desc);
create index if not exists target_risk_assessment_ring_idx
  on event_response.target_risk_assessment(defense_ring_code, observed_at desc);

create table if not exists event_response.target_risk_current (
  track_id bigint primary key references situation.target_track(id) on delete cascade,
  assessment_id bigint not null unique references event_response.target_risk_assessment(id) on delete restrict,
  observation_id bigint references equipment.raw_observation(id) on delete restrict,
  observed_at timestamptz not null,
  assessed_at timestamptz not null,
  status text not null check (status in ('assessed','outside_protected_objects','target_location_unavailable','pending','failed')),
  risk_level text not null check (risk_level in ('none','low','medium','high','critical')),
  risk_score integer not null check (risk_score between 0 and 100),
  protected_object_id bigint references airspace.protected_object(id) on delete restrict,
  protected_object_version integer,
  defense_ring_id bigint references airspace.defense_ring(id) on delete restrict,
  defense_ring_code text,
  defense_ring_level integer,
  defense_ring_version integer,
  distance_m numeric,
  rule_set_id bigint references event_response.risk_rule_set(id) on delete restrict,
  rule_version integer,
  factor_results jsonb not null default '[]'::jsonb,
  error_code text,
  updated_at timestamptz not null default now()
);
comment on table event_response.target_risk_current is '每条航迹的最新风险评估投影；由历史评估结果按观测时间条件更新。';
comment on column event_response.target_risk_current.observed_at is '当前投影对应观测时间；迟到旧观测不得覆盖新结果。';
create index if not exists target_risk_current_status_idx
  on event_response.target_risk_current(status, risk_level, observed_at desc);

create table if not exists event_response.risk_worker_cursor (
  worker_name text primary key,
  last_observation_id bigint not null default 0 check (last_observation_id >= 0),
  updated_at timestamptz not null default now()
);
comment on table event_response.risk_worker_cursor is '风险评估 worker 的持久化消费游标；仅在评估事务成功后推进。';
insert into event_response.risk_worker_cursor(worker_name) values('defense-assessment')
on conflict(worker_name) do nothing;

create or replace function event_response.reject_risk_assessment_change() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  raise exception 'target risk assessment history is immutable';
end $$;
drop trigger if exists target_risk_assessment_immutable on event_response.target_risk_assessment;
create trigger target_risk_assessment_immutable before update or delete
on event_response.target_risk_assessment for each row
execute function event_response.reject_risk_assessment_change();

alter table situation.change_event drop constraint if exists change_event_event_type_check;
alter table situation.change_event add constraint change_event_event_type_check
  check (event_type in ('target_upsert','target_remove','source_status','risk_changed'));

do $$ begin
  if not exists(select 1 from pg_roles where rolname='risk_engine') then
    create role risk_engine login noinherit;
  end if;
end $$;
alter role risk_engine login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;

revoke all on event_response.target_risk_assessment,event_response.target_risk_current,event_response.risk_worker_cursor from public,anonymous,admin,risk_engine;
revoke all on sequence event_response.target_risk_assessment_id_seq,situation.change_event_id_seq from public,anonymous,admin,risk_engine;
grant select on event_response.target_risk_assessment,event_response.target_risk_current to admin;
grant usage on schema event_response,situation,equipment,airspace to risk_engine;
grant select on situation.track_observation,situation.target_track,situation.source_target_session,
  situation.airspace_target,situation.target_observation,
  equipment.raw_observation,airspace.protected_object,airspace.defense_ring,
  event_response.risk_rule_set,event_response.risk_rule_factor,event_response.risk_rule_parameter to risk_engine;
grant select,insert on event_response.target_risk_assessment to risk_engine;
grant select,insert,update on event_response.target_risk_current,event_response.risk_worker_cursor to risk_engine;
grant insert on situation.change_event to risk_engine;
grant usage,select on sequence event_response.target_risk_assessment_id_seq,situation.change_event_id_seq to risk_engine;

create or replace function event_response.risk_assessment_json(p_track_id bigint) returns jsonb
language sql stable security invoker set search_path=pg_catalog,public,event_response as $$
select coalesce((select jsonb_strip_nulls(jsonb_build_object(
  'status',status,'riskLevel',risk_level,'riskScore',risk_score,
  'observationId',observation_id,'observedAt',observed_at,'assessedAt',assessed_at,
  'protectedObjectId',protected_object_id,'protectedObjectVersion',protected_object_version,
  'ringId',defense_ring_id,'ringCode',defense_ring_code,'ringLevel',defense_ring_level,
  'ringVersion',defense_ring_version,'distanceM',distance_m,
  'ruleSetId',rule_set_id,'ruleVersion',rule_version,
  'factors',factor_results,'reason',error_code
)) from event_response.target_risk_current where track_id=p_track_id),
jsonb_build_object('status','pending'));
$$;
comment on function event_response.risk_assessment_json(bigint) is '返回航迹当前风险评估属性；无结果时返回 status=pending。';

revoke all on function event_response.risk_assessment_json(bigint) from public,anonymous;
grant execute on function event_response.risk_assessment_json(bigint) to admin;

create or replace function api.list_target_risk_assessments(
  p_track_id bigint,p_start_at timestamptz,p_end_at timestamptz,p_limit integer default 500
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,event_response,situation as $$
declare v_result jsonb;
begin
  if p_track_id is null then raise exception 'track ID is required'; end if;
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then
    raise exception 'invalid half-open time window';
  end if;
  if p_end_at-p_start_at>interval '7 days' then
    raise exception 'risk assessment window cannot exceed 7 days';
  end if;
  if p_limit not between 1 and 5000 then raise exception 'limit must be between 1 and 5000'; end if;
  if not exists(select 1 from situation.target_track where id=p_track_id) then
    raise exception 'target track % does not exist',p_track_id;
  end if;
  with selected as (
    select * from event_response.target_risk_assessment
    where track_id=p_track_id and observed_at>=p_start_at and observed_at<p_end_at
    order by observed_at desc,id desc limit p_limit
  )
  select jsonb_build_object(
    'trackId',p_track_id,'startAt',p_start_at,'endAtExclusive',p_end_at,'limit',p_limit,
    'assessments',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'assessmentId',id,'observationId',observation_id,'observedAt',observed_at,'assessedAt',assessed_at,
      'status',status,'riskLevel',risk_level,'riskScore',risk_score,
      'protectedObjectId',protected_object_id,'protectedObjectVersion',protected_object_version,
      'ringId',defense_ring_id,'ringCode',defense_ring_code,'ringLevel',defense_ring_level,
      'ringVersion',defense_ring_version,'distanceM',distance_m,
      'ruleSetId',rule_set_id,'ruleVersion',rule_version,'factors',factor_results,
      'inputSnapshot',input_snapshot,'reason',error_code
    )) order by observed_at,id),'[]'::jsonb)
  ) into v_result from selected;
  return v_result;
end $$;
comment on function api.list_target_risk_assessments(bigint,timestamptz,timestamptz,integer) is '返回 JSON：trackId、半开时间窗口、limit 和 assessments；按观测时间列出最多 5000 条版本化目标风险评估。';
revoke all on function api.list_target_risk_assessments(bigint,timestamptz,timestamptz,integer) from public,anonymous;
grant execute on function api.list_target_risk_assessments(bigint,timestamptz,timestamptz,integer) to admin;

commit;
