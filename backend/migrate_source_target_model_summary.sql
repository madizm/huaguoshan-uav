-- 来源目标机型架次统计：扩展视图增加 models 列，新增两个聚合 RPC。
-- 依赖 create_source_sortie_statistics.sql。
begin;

-- ---------------------------------------------------------------------------
-- 1. 扩展 source_sortie_statistics 视图：增加 models 列
--    需要先 DROP 依赖的函数和视图，再重建（不能改变已有列顺序）。
-- ---------------------------------------------------------------------------
drop function if exists api.get_source_sortie_statistics(timestamptz,timestamptz,bigint[],text[],text[]);
drop function if exists api.get_source_sortie_series(timestamptz,timestamptz,text,bigint[],text[],text[]);
drop function if exists api.list_source_sorties(timestamptz,timestamptz,bigint[],text[],text[],text,integer,integer);
drop view if exists situation.source_sortie_statistics;

create view situation.source_sortie_statistics as
with session_lifecycle as (
  select s.*,
    lag(s.ended_at) over(
      partition by s.observation_source_id,s.source_target_id
      order by s.started_at,s.id
    ) previous_ended_at
  from situation.source_target_session s
), observation_rows as (
  select t.id track_id,r.id observation_id,r.observed_at,r.received_at,r.geom,
    o.detection_method_code,o.model,
    lag(r.observed_at) over(partition by t.id order by r.observed_at,r.id) previous_observed_at
  from situation.target_track t
  join situation.track_observation x on x.track_id=t.id
  join equipment.raw_observation r on r.id=x.observation_id
  join situation.target_observation o on o.observation_id=r.id
  where o.event_type<>'offline_remove'
), observation_summary as (
  select track_id,count(*) observation_count,
    count(*) filter(where geom is not null) spatial_observation_count,
    count(distinct observed_at) distinct_observed_at_count,
    min(received_at) first_received_at,max(received_at) last_received_at,
    max(extract(epoch from observed_at-previous_observed_at)) max_observation_gap_seconds,
    max(extract(epoch from received_at-observed_at)) max_receive_delay_seconds,
    bool_or(received_at-observed_at>interval '1 hour' or observed_at-received_at>interval '5 minutes') timestamp_suspect,
    array_agg(distinct detection_method_code order by detection_method_code) detection_method_codes,
    array_agg(distinct model order by model) filter(where model is not null and model<>'') models
  from observation_rows group by track_id
), risk_summary as (
  select a.track_id,count(*) risk_assessment_count,
    count(*) filter(where a.status='failed') failed_assessment_count,
    count(*) filter(where a.status='target_location_unavailable') location_unavailable_count,
    count(*) filter(where a.status='outside_protected_objects') outside_protected_objects_count,
    max(a.risk_score) filter(where a.status='assessed') max_risk_score,
    max(case a.risk_level when 'critical' then 5 when 'high' then 4 when 'medium' then 3 when 'low' then 2 when 'none' then 1 else 0 end)
      filter(where a.status='assessed') max_risk_rank,
    max(a.defense_ring_level) filter(where a.defense_ring_id is not null) deepest_ring_level,
    (array_agg(a.defense_ring_code order by a.defense_ring_level desc nulls last,a.id desc)
      filter(where a.defense_ring_code is not null))[1] deepest_ring_code
  from event_response.target_risk_assessment a
  join situation.target_observation o on o.observation_id=a.observation_id and o.event_type<>'offline_remove'
  group by a.track_id
)
select s.id sortie_id,s.observation_source_id,src.name source_name,src.source_system,
  src.external_station_id station_id,s.source_type_code,s.source_target_id,s.source_session_id,s.session_key,
  s.state,s.started_at,s.last_observed_at,s.ended_at,s.end_reason,t.id track_id,t.track_code,
  greatest(0,extract(epoch from s.last_observed_at-s.started_at)) duration_seconds,
  coalesce(o.observation_count,0) observation_count,
  coalesce(o.spatial_observation_count,0) spatial_observation_count,
  o.first_received_at,o.last_received_at,o.max_observation_gap_seconds,o.max_receive_delay_seconds,
  coalesce(o.timestamp_suspect,false) timestamp_suspect,
  coalesce(o.distinct_observed_at_count,0)<=1 single_timestamp,
  coalesce(o.spatial_observation_count,0)=0 non_spatial,
  s.previous_ended_at is not null and s.started_at<s.previous_ended_at lifecycle_overlap,
  coalesce(o.detection_method_codes,array[]::text[]) detection_method_codes,
  coalesce(r.risk_assessment_count,0) risk_assessment_count,
  coalesce(r.failed_assessment_count,0) failed_assessment_count,
  coalesce(r.location_unavailable_count,0) location_unavailable_count,
  coalesce(r.outside_protected_objects_count,0) outside_protected_objects_count,
  r.max_risk_score,
  case r.max_risk_rank when 5 then 'critical' when 4 then 'high' when 3 then 'medium'
    when 2 then 'low' when 1 then 'none' end max_risk_level,
  r.deepest_ring_level,r.deepest_ring_code,
  coalesce(o.models,array[]::text[]) models
from session_lifecycle s
join situation.observation_source src on src.id=s.observation_source_id
join situation.target_track t on t.source_session_id=s.id
left join observation_summary o on o.track_id=t.id
left join risk_summary r on r.track_id=t.id;
comment on view situation.source_sortie_statistics is '以 source_target_session 为一条来源架次的可重建只读统计投影，汇总观测、风险、防御圈、机型和时间质量信息。';
comment on column situation.source_sortie_statistics.models is '架次内所有观测出现过的去重机型列表，按字母排序；无机型观测时为空数组。';

revoke all on situation.source_sortie_statistics from public,anonymous,admin;

-- 重建原有三个 RPC（从 create_source_sortie_statistics.sql 复制，无逻辑变更）
create or replace function api.get_source_sortie_statistics(
  p_start_at timestamptz,p_end_at timestamptz,
  p_source_ids bigint[] default null,p_detection_method_codes text[] default null,
  p_quality_issue text default null
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '90 days' then raise exception 'sortie statistics window cannot exceed 90 days'; end if;
  if p_quality_issue is not null and p_quality_issue not in ('normal','timestamp_suspect','single_timestamp','non_spatial','lifecycle_overlap') then
    raise exception 'invalid quality issue';
  end if;
  with filtered as (
    select * from situation.source_sortie_statistics
    where started_at>=p_start_at and started_at<p_end_at
      and (p_source_ids is null or observation_source_id=any(p_source_ids))
      and (p_detection_method_codes is null or detection_method_codes&&p_detection_method_codes)
      and (p_quality_issue is null
        or p_quality_issue='normal' and not timestamp_suspect and not single_timestamp and not non_spatial and not lifecycle_overlap
        or p_quality_issue='timestamp_suspect' and timestamp_suspect
        or p_quality_issue='single_timestamp' and single_timestamp
        or p_quality_issue='non_spatial' and non_spatial
        or p_quality_issue='lifecycle_overlap' and lifecycle_overlap)
  )
  select jsonb_build_object(
    'startAt',p_start_at,'endAtExclusive',p_end_at,
    'summary',jsonb_build_object(
      'sortieCount',count(*),'activeCount',count(*) filter(where state='active'),
      'spatialCount',count(*) filter(where spatial_observation_count>0),
      'highRiskCount',count(*) filter(where max_risk_level in ('high','critical')),
      'coreRingCount',count(*) filter(where deepest_ring_code='core'),
      'averageDurationSeconds',round(coalesce(avg(duration_seconds),0)::numeric,2),
      'observationCount',coalesce(sum(observation_count),0)),
    'riskDistribution',jsonb_build_object(
      'critical',count(*) filter(where max_risk_level='critical'),
      'high',count(*) filter(where max_risk_level='high'),
      'medium',count(*) filter(where max_risk_level='medium'),
      'low',count(*) filter(where max_risk_level='low'),
      'none',count(*) filter(where max_risk_level='none'),
      'unavailable',count(*) filter(where max_risk_level is null)),
    'quality',jsonb_build_object(
      'timestampSuspectCount',count(*) filter(where timestamp_suspect),
      'singleTimestampCount',count(*) filter(where single_timestamp),
      'nonSpatialCount',count(*) filter(where non_spatial),
      'lifecycleOverlapCount',count(*) filter(where lifecycle_overlap))
  ) into v_result from filtered;
  return v_result;
end $$;
comment on function api.get_source_sortie_statistics(timestamptz,timestamptz,bigint[],text[],text) is '返回 JSON：时间窗口、来源架次总览、架次最大风险分布和数据质量统计；支持正常或指定质量问题过滤，窗口最大 90 天。';
revoke all on function api.get_source_sortie_statistics(timestamptz,timestamptz,bigint[],text[],text) from public,anonymous;
grant execute on function api.get_source_sortie_statistics(timestamptz,timestamptz,bigint[],text[],text) to admin;

create or replace function api.get_source_sortie_series(
  p_start_at timestamptz,p_end_at timestamptz,p_bucket text default 'day',
  p_source_ids bigint[] default null,p_detection_method_codes text[] default null,
  p_quality_issue text default null
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '90 days' then raise exception 'sortie series window cannot exceed 90 days'; end if;
  if p_bucket not in ('hour','day') then raise exception 'bucket must be hour or day'; end if;
  if p_quality_issue is not null and p_quality_issue not in ('normal','timestamp_suspect','single_timestamp','non_spatial','lifecycle_overlap') then
    raise exception 'invalid quality issue';
  end if;
  with filtered as (
    select * from situation.source_sortie_statistics
    where started_at>=p_start_at and started_at<p_end_at
      and (p_source_ids is null or observation_source_id=any(p_source_ids))
      and (p_detection_method_codes is null or detection_method_codes&&p_detection_method_codes)
      and (p_quality_issue is null
        or p_quality_issue='normal' and not timestamp_suspect and not single_timestamp and not non_spatial and not lifecycle_overlap
        or p_quality_issue='timestamp_suspect' and timestamp_suspect
        or p_quality_issue='single_timestamp' and single_timestamp
        or p_quality_issue='non_spatial' and non_spatial
        or p_quality_issue='lifecycle_overlap' and lifecycle_overlap)
  ), buckets as (
    select (date_trunc(p_bucket,started_at at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai') bucket_at,
      count(*) sortie_count,count(*) filter(where max_risk_level in ('high','critical')) high_risk_count,
      count(*) filter(where spatial_observation_count>0) spatial_count,
      count(*) filter(where timestamp_suspect) timestamp_suspect_count
    from filtered group by bucket_at
  )
  select jsonb_build_object('startAt',p_start_at,'endAtExclusive',p_end_at,'bucket',p_bucket,
    'points',coalesce(jsonb_agg(jsonb_build_object(
      'bucketAt',bucket_at,'sortieCount',sortie_count,'highRiskCount',high_risk_count,
      'spatialCount',spatial_count,'timestampSuspectCount',timestamp_suspect_count
    ) order by bucket_at),'[]'::jsonb)) into v_result from buckets;
  return v_result;
end $$;
comment on function api.get_source_sortie_series(timestamptz,timestamptz,text,bigint[],text[],text) is '返回 JSON：按 Asia/Shanghai 小时或日期分桶的来源架次、空间架次、高风险架次和时间戳异常架次序列；支持质量过滤。';
revoke all on function api.get_source_sortie_series(timestamptz,timestamptz,text,bigint[],text[],text) from public,anonymous;
grant execute on function api.get_source_sortie_series(timestamptz,timestamptz,text,bigint[],text[],text) to admin;

create or replace function api.list_source_sorties(
  p_start_at timestamptz,p_end_at timestamptz,
  p_source_ids bigint[] default null,p_detection_method_codes text[] default null,
  p_risk_levels text[] default null,p_quality_issue text default null,
  p_limit integer default 100,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '31 days' then raise exception 'sortie list window cannot exceed 31 days'; end if;
  if p_limit not between 1 and 500 then raise exception 'limit must be between 1 and 500'; end if;
  if p_offset not between 0 and 10000 then raise exception 'offset must be between 0 and 10000'; end if;
  if p_quality_issue is not null and p_quality_issue not in ('normal','timestamp_suspect','single_timestamp','non_spatial','lifecycle_overlap') then
    raise exception 'invalid quality issue';
  end if;
  with filtered as materialized (
    select * from situation.source_sortie_statistics
    where started_at>=p_start_at and started_at<p_end_at
      and (p_source_ids is null or observation_source_id=any(p_source_ids))
      and (p_detection_method_codes is null or detection_method_codes&&p_detection_method_codes)
      and (p_risk_levels is null or coalesce(max_risk_level,'unavailable')=any(p_risk_levels))
      and (p_quality_issue is null
        or p_quality_issue='normal' and not timestamp_suspect and not single_timestamp and not non_spatial and not lifecycle_overlap
        or p_quality_issue='timestamp_suspect' and timestamp_suspect
        or p_quality_issue='single_timestamp' and single_timestamp
        or p_quality_issue='non_spatial' and non_spatial
        or p_quality_issue='lifecycle_overlap' and lifecycle_overlap)
  ), selected as (
    select * from filtered order by started_at desc,sortie_id desc limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'startAt',p_start_at,'endAtExclusive',p_end_at,'limit',p_limit,'offset',p_offset,
    'total',(select count(*) from filtered),
    'sorties',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'sortieId',sortie_id,'trackId',track_id,'trackCode',track_code,
      'sourceId',observation_source_id,'sourceName',source_name,'stationId',station_id,
      'sourceTargetId',source_target_id,'state',state,'startedAt',started_at,
      'lastObservedAt',last_observed_at,'endedAt',ended_at,'endReason',end_reason,
      'durationSeconds',duration_seconds,'observationCount',observation_count,
      'spatialObservationCount',spatial_observation_count,
      'firstReceivedAt',first_received_at,'maxObservationGapSeconds',max_observation_gap_seconds,
      'maxReceiveDelaySeconds',max_receive_delay_seconds,'detectionMethodCodes',detection_method_codes,
      'timestampSuspect',timestamp_suspect,'singleTimestamp',single_timestamp,
      'nonSpatial',non_spatial,'lifecycleOverlap',lifecycle_overlap,
      'maxRiskLevel',max_risk_level,'maxRiskScore',max_risk_score,
      'deepestRingCode',deepest_ring_code,'riskAssessmentCount',risk_assessment_count,
      'locationUnavailableCount',location_unavailable_count,'outsideProtectedObjectsCount',outside_protected_objects_count
    )) order by started_at desc,sortie_id desc),'[]'::jsonb)
  ) into v_result from selected;
  return v_result;
end $$;
comment on function api.list_source_sorties(timestamptz,timestamptz,bigint[],text[],text[],text,integer,integer) is '返回 JSON：总数和分页来源架次列表；支持来源、侦测方式、最大风险和质量问题过滤，窗口最大 31 天，单页最多 500 条。';
revoke all on function api.list_source_sorties(timestamptz,timestamptz,bigint[],text[],text[],text,integer,integer) from public,anonymous;
grant execute on function api.list_source_sorties(timestamptz,timestamptz,bigint[],text[],text[],text,integer,integer) to admin;

-- ---------------------------------------------------------------------------
-- 2. 来源目标机型汇总 RPC
-- ---------------------------------------------------------------------------
drop function if exists api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[],integer,integer);
drop function if exists api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[]);

create or replace function api.get_source_target_model_summary(
  p_start_at timestamptz,p_end_at timestamptz,
  p_source_ids bigint[] default null,
  p_risk_levels text[] default null,
  p_models text[] default null,
  p_detection_method_codes text[] default null,
  p_source_target_ids text[] default null,
  p_limit integer default 50,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '90 days' then raise exception 'model summary window cannot exceed 90 days'; end if;
  if p_limit not between 1 and 500 then raise exception 'limit must be between 1 and 500'; end if;
  if p_offset not between 0 and 10000 then raise exception 'offset must be between 0 and 10000'; end if;
  with filtered as (
    select * from situation.source_sortie_statistics
    where started_at>=p_start_at and started_at<p_end_at
      and (p_source_ids is null or observation_source_id=any(p_source_ids))
      and (p_risk_levels is null or coalesce(max_risk_level,'unavailable')=any(p_risk_levels))
      and (p_detection_method_codes is null or detection_method_codes&&p_detection_method_codes)
      and (p_source_target_ids is null or source_target_id=any(p_source_target_ids))
  ), exploded as (
    select f.source_target_id,f.source_name,f.observation_source_id,
      m.model,
      f.sortie_id,f.duration_seconds,f.max_risk_level,f.max_risk_score,
      f.deepest_ring_code,f.state,f.started_at,f.last_observed_at
    from filtered f
    left join lateral unnest(
      case when array_length(f.models,1)>0 then f.models else array['unknown'] end
    ) m(model) on true
    where p_models is null or m.model=any(p_models)
  ), grouped as (
    select source_target_id,source_name,
      min(observation_source_id) observation_source_id,
      model,
      count(*) sortie_count,
      coalesce(sum(duration_seconds),0) total_duration_seconds,
      count(*) filter(where max_risk_level in ('high','critical')) high_risk_count,
      max(case max_risk_level when 'critical' then 5 when 'high' then 4 when 'medium' then 3 when 'low' then 2 when 'none' then 1 else 0 end) max_risk_rank,
      max(last_observed_at) last_sortie_at
    from exploded group by source_target_id,source_name,model
  ), paginated as (
    select * from grouped order by sortie_count desc,source_target_id,model
    limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'startAt',p_start_at,'endAtExclusive',p_end_at,
    'limit',p_limit,'offset',p_offset,
    'totalGroups',(select count(*) from grouped),
    'rows',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'sourceTargetId',source_target_id,
      'sourceName',source_name,
      'observationSourceId',observation_source_id,
      'model',model,
      'sortieCount',sortie_count,
      'totalDurationSeconds',total_duration_seconds,
      'highRiskCount',high_risk_count,
      'maxRiskLevel',case max_risk_rank when 5 then 'critical' when 4 then 'high' when 3 then 'medium'
        when 2 then 'low' when 1 then 'none' end,
      'lastSortieAt',last_sortie_at
    )) order by sortie_count desc,source_target_id,model),'[]'::jsonb)
  ) into v_result from paginated;
  return v_result;
end $$;
comment on function api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[],text[],integer,integer) is
'返回 JSON：按来源目标 + 机型分组的架次汇总列表；支持侦测来源、风险等级、机型、侦测方式和来源目标过滤，窗口最大 90 天，单页最多 500 条。
返回字段：
- startAt / endAtExclusive：统计时间窗口。
- totalGroups：分组总数。
- rows[]：每个分组的 sourceTargetId、sourceName、observationSourceId、model、sortieCount（飞行次数）、totalDurationSeconds（总飞行时长）、highRiskCount（高风险架次数）、maxRiskLevel（最高风险等级）、lastSortieAt（最近飞行时间）。';
revoke all on function api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[],text[],integer,integer) from public,anonymous;
grant execute on function api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[],text[],integer,integer) to admin;

-- ---------------------------------------------------------------------------
-- 3. 来源目标机型架次明细 RPC
-- ---------------------------------------------------------------------------
drop function if exists api.list_source_target_model_sorties(timestamptz,timestamptz,text,text,bigint[],text[],integer,integer);

create or replace function api.list_source_target_model_sorties(
  p_start_at timestamptz,p_end_at timestamptz,
  p_source_target_id text,p_model text,
  p_source_ids bigint[] default null,
  p_risk_levels text[] default null,
  p_detection_method_codes text[] default null,
  p_limit integer default 100,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '90 days' then raise exception 'sortie list window cannot exceed 90 days'; end if;
  if p_source_target_id is null or p_source_target_id='' then raise exception 'source_target_id is required'; end if;
  if p_model is null or p_model='' then raise exception 'model is required'; end if;
  if p_limit not between 1 and 500 then raise exception 'limit must be between 1 and 500'; end if;
  if p_offset not between 0 and 10000 then raise exception 'offset must be between 0 and 10000'; end if;
  with filtered as materialized (
    select * from situation.source_sortie_statistics
    where started_at>=p_start_at and started_at<p_end_at
      and source_target_id=p_source_target_id
      and (p_model='unknown' and (array_length(models,1) is null)
        or p_model<>'unknown' and p_model=any(models))
      and (p_source_ids is null or observation_source_id=any(p_source_ids))
      and (p_risk_levels is null or coalesce(max_risk_level,'unavailable')=any(p_risk_levels))
      and (p_detection_method_codes is null or detection_method_codes&&p_detection_method_codes)
  ), selected as (
    select * from filtered order by started_at desc,sortie_id desc limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'startAt',p_start_at,'endAtExclusive',p_end_at,
    'sourceTargetId',p_source_target_id,'model',p_model,
    'limit',p_limit,'offset',p_offset,
    'total',(select count(*) from filtered),
    'sorties',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'sortieId',sortie_id,'trackId',track_id,'trackCode',track_code,
      'sourceId',observation_source_id,'sourceName',source_name,
      'state',state,'startedAt',started_at,
      'lastObservedAt',last_observed_at,'endedAt',ended_at,'endReason',end_reason,
      'durationSeconds',duration_seconds,'observationCount',observation_count,
      'spatialObservationCount',spatial_observation_count,
      'detectionMethodCodes',detection_method_codes,
      'maxRiskLevel',max_risk_level,'maxRiskScore',max_risk_score,
      'deepestRingCode',deepest_ring_code,'riskAssessmentCount',risk_assessment_count
    )) order by started_at desc,sortie_id desc),'[]'::jsonb)
  ) into v_result from selected;
  return v_result;
end $$;
comment on function api.list_source_target_model_sorties(timestamptz,timestamptz,text,text,bigint[],text[],text[],integer,integer) is
'返回 JSON：指定来源目标 + 机型的架次明细分页列表；支持侦测来源、风险等级和侦测方式过滤，窗口最大 90 天，单页最多 500 条。
返回字段：
- startAt / endAtExclusive：查询时间窗口。
- sourceTargetId / model：查询条件。
- total：匹配架次总数。
- sorties[]：架次列表，每条包含 sortieId、trackCode、sourceName、state、startedAt、durationSeconds、observationCount、maxRiskLevel、maxRiskScore、deepestRingCode 等。';
revoke all on function api.list_source_target_model_sorties(timestamptz,timestamptz,text,text,bigint[],text[],text[],integer,integer) from public,anonymous;
grant execute on function api.list_source_target_model_sorties(timestamptz,timestamptz,text,text,bigint[],text[],text[],integer,integer) to admin;

notify pgrst,'reload schema';
commit;
