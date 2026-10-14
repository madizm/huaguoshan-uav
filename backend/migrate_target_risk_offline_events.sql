-- 离线移除事件风险投影修复；以数据库所有者执行。
-- 执行前必须部署并重启排除 detection_offline_remove 的风险 worker/HTTP 写入服务。
-- 推荐维护窗口暂停写入；已更新的服务在线运行时，本事务的排他锁串行化风险写入。
-- 不得在旧版风险写入服务仍运行时执行，否则提交后可能再次覆盖 current。
-- 本脚本独立事务；锁阻止历史插入和当前投影写入，失败时整体回滚。
-- 不删除原始观测或不可变评估历史，也不修改引擎的迟到观测保护条件。
begin;
set local lock_timeout = '30s';
lock table event_response.target_risk_assessment,
  event_response.target_risk_current in access exclusive mode;

create or replace function api.get_risk_engine_status(p_worker_name text default 'defense-assessment')
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,event_response,situation,equipment,airspace as $$
with worker_cursor as (
  select * from event_response.risk_worker_cursor where worker_name=p_worker_name
), runtime as (
  select * from event_response.risk_worker_runtime where worker_name=p_worker_name
), pending_sample as materialized (
  select r.id observation_id,r.observed_at,a.id assessment_id,
    (r.id>c.last_observation_id) cursor_pending
  from worker_cursor c
  join situation.track_observation tr on true
  join equipment.raw_observation r on r.id=tr.observation_id
  join situation.target_observation o on o.observation_id=r.id
  left join event_response.target_risk_assessment a on a.observation_id=r.id
  where r.observation_type <> 'detection_offline_remove'
    and (r.id>c.last_observation_id or a.id is null)
  order by r.id limit 10001
), backlog as (
  select count(*) sample_count,
    count(*) filter(where cursor_pending) cursor_pending_count,
    count(*) filter(where not cursor_pending and assessment_id is null) repair_pending_count,
    min(observed_at) oldest_pending_at
  from pending_sample
), throughput as (
  select count(*) filter(where assessed_at>=now()-interval '1 minute') assessed_last_minute,
    count(*) filter(where assessed_at>=now()-interval '1 hour') assessed_last_hour,
    count(*) filter(where assessed_at>=now()-interval '1 hour' and status='failed') failed_last_hour,
    avg(greatest(0,extract(epoch from (assessed_at-observed_at)))) filter(where assessed_at>=now()-interval '1 hour') average_latency_seconds
  from event_response.target_risk_assessment
  where assessed_at>=now()-interval '1 hour'
), active_rule as (
  select version from event_response.risk_rule_set
  where code='defense-risk' and status='active' and effective_from<=now()
    and (effective_to is null or effective_to>now())
  order by version desc limit 1
), ring_config as (
  select count(*) protected_object_count,coalesce(sum(ring_count),0) defense_ring_count
  from (
    select p.id,count(r.id) ring_count
    from airspace.protected_object p
    left join airspace.defense_ring r on r.protected_object_id=p.id and r.version=p.current_version and r.enabled
    where p.enabled group by p.id
  ) configured
)
select jsonb_build_object(
  'state',case
    when r.heartbeat_at is null or r.heartbeat_at<now()-interval '60 seconds' then 'offline'
    when (r.last_error_at is not null and r.last_error_at>coalesce(r.last_success_at,'-infinity'::timestamptz))
      or (b.oldest_pending_at is not null and b.oldest_pending_at<now()-interval '30 seconds') then 'degraded'
    else 'healthy' end,
  'generatedAt',now(),
  'worker',jsonb_strip_nulls(jsonb_build_object(
    'name',c.worker_name,'instanceId',r.instance_id,'runtimeState',r.state,'engineVersion',r.engine_version,
    'startedAt',r.started_at,'heartbeatAt',r.heartbeat_at,
    'heartbeatAgeSeconds',case when r.heartbeat_at is null then null else greatest(0,extract(epoch from now()-r.heartbeat_at)::integer) end,
    'lastBatchStartedAt',r.last_batch_started_at,'lastBatchFinishedAt',r.last_batch_finished_at,
    'lastSuccessAt',r.last_success_at,'lastErrorAt',r.last_error_at,
    'lastErrorCode',r.last_error_code,'lastErrorMessage',r.last_error_message,
    'lastBatchSize',r.last_batch_size,'lastBatchDurationMs',r.last_batch_duration_ms,
    'processedTotal',r.processed_total,'failedTotal',r.failed_total,
    'lastObservationId',c.last_observation_id,'cursorUpdatedAt',c.updated_at)),
  'backlog',jsonb_build_object(
    'pendingCount',least(b.sample_count,10000),'pendingCountCapped',b.sample_count>10000,
    'cursorPendingCount',b.cursor_pending_count,'repairPendingCount',b.repair_pending_count,
    'oldestPendingAt',b.oldest_pending_at,
    'oldestPendingAgeSeconds',case when b.oldest_pending_at is null then 0 else greatest(0,extract(epoch from now()-b.oldest_pending_at)::integer) end),
  'throughput',jsonb_build_object(
    'assessedLastMinute',t.assessed_last_minute,'assessedLastHour',t.assessed_last_hour,
    'failedLastHour',t.failed_last_hour,
    'failureRateLastHour',case when t.assessed_last_hour=0 then 0 else round(t.failed_last_hour::numeric/t.assessed_last_hour,4) end,
    'averageLatencySeconds',round(coalesce(t.average_latency_seconds,0)::numeric,2)),
  'configuration',jsonb_build_object(
    'ruleVersion',(select version from active_rule),
    'protectedObjectCount',g.protected_object_count,'defenseRingCount',g.defense_ring_count)
)
from worker_cursor c
left join runtime r on true cross join backlog b cross join throughput t cross join ring_config g;
$$;
comment on function api.get_risk_engine_status(text) is '返回 JSON：worker 心跳与批次状态、最多 10000 条的积压统计、最近吞吐和当前规则/防御圈配置摘要。';
revoke all on function api.get_risk_engine_status(text) from public,anonymous;
grant execute on function api.get_risk_engine_status(text) to admin;


-- 仅修复当前仍指向离线事件的航迹；第二次执行不会再命中。
do $repair$
declare
  v_previous record;
  v_replacement event_response.target_risk_assessment%rowtype;
  v_repaired_at timestamptz := clock_timestamp();
  v_risk jsonb;
begin
  for v_previous in
    select c.*
    from event_response.target_risk_current c
    join event_response.target_risk_assessment a on a.id=c.assessment_id
    join equipment.raw_observation r on r.id=a.observation_id
    where r.observation_type='detection_offline_remove'
    order by c.track_id
  loop
    -- 仅按真实观测时间和观测 ID 排序；缺少坐标的真实观测仍然有效。
    select a.* into v_replacement
    from event_response.target_risk_assessment a
    join equipment.raw_observation r on r.id=a.observation_id
    where a.track_id=v_previous.track_id
      and r.observation_type <> 'detection_offline_remove'
    order by a.observed_at desc,a.observation_id desc
    limit 1;

    if found then
      update event_response.target_risk_current
      set assessment_id=v_replacement.id,
          observation_id=v_replacement.observation_id,
          observed_at=v_replacement.observed_at,
          assessed_at=v_replacement.assessed_at,
          status=v_replacement.status,
          risk_level=v_replacement.risk_level,
          risk_score=v_replacement.risk_score,
          protected_object_id=v_replacement.protected_object_id,
          protected_object_version=v_replacement.protected_object_version,
          defense_ring_id=v_replacement.defense_ring_id,
          defense_ring_code=v_replacement.defense_ring_code,
          defense_ring_level=v_replacement.defense_ring_level,
          defense_ring_version=v_replacement.defense_ring_version,
          distance_m=v_replacement.distance_m,
          rule_set_id=v_replacement.rule_set_id,
          rule_version=v_replacement.rule_version,
          factor_results=v_replacement.factor_results,
          error_code=v_replacement.error_code,
          updated_at=v_repaired_at
      where track_id=v_previous.track_id;
    else
      -- 无真实观测评估时删除投影，公共查询自然返回 pending。
      delete from event_response.target_risk_current
      where track_id=v_previous.track_id;
    end if;

    v_risk := event_response.risk_assessment_json(v_previous.track_id);
    insert into situation.change_event(
      event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload
    )
    select 'risk_changed','target_track',v_previous.track_id,s.observation_source_id,
      v_repaired_at,jsonb_build_object(
        'track_id',v_previous.track_id,
        'observation_id',v_replacement.observation_id,'assessment_id',v_replacement.id,
        'previous_status',v_previous.status,'previous_risk_level',v_previous.risk_level,
        'previous_risk_score',v_previous.risk_score,
        'status',v_risk->>'status','risk_level',v_replacement.risk_level,
        'risk_score',v_replacement.risk_score,'ring_code',v_replacement.defense_ring_code,
        'ring_version',v_replacement.defense_ring_version,'rule_version',v_replacement.rule_version,
        'risk_assessment',v_risk
      )
    from situation.target_track t
    join situation.source_target_session s on s.id=t.source_session_id
    where t.id=v_previous.track_id;
  end loop;
end
$repair$;

notify pgrst,'reload schema';
commit;
