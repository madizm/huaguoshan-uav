-- 仅修正后续接入与处理；不回填原始观测，不重建已有会话/航迹/预测/风险。
-- 依赖已安装的侦测与风险 schema；与主建表脚本中的同名函数保持一致。
begin;

-- Shared by ingestion, prediction, evaluation and risk adapters. Legacy normal
-- payloads without an explicit validity bit remain supported (e.g. Lizheng).
alter table situation.source_target_session add column if not exists last_received_at timestamptz;
comment on column situation.source_target_session.last_received_at is '来源目标最近接收时间，用于存活对账，不代表位置更新。';

create or replace function situation.position_time_valid(
  p_observed_at timestamptz,p_received_at timestamptz,p_type text,p_payload jsonb
) returns boolean language sql immutable as $$
  select coalesce(p_observed_at is not null and isfinite(p_observed_at)
    and p_observed_at<=p_received_at
    and p_type<>'detection_offline_remove'
    and (p_payload#>>'{_normalized,positionTimeValid}') is distinct from 'false'
    and not (coalesce(p_payload#>'{_normalized,qualityFlags}','[]'::jsonb)
      ?| array['missing_source_time','invalid_position_time','future_source_time','lifecycle_event']),false);
$$;
comment on function situation.position_time_valid(timestamptz,timestamptz,text,jsonb)
  is '判断位置时间是否可信；离线、缺失时间和晚于接收时间的观测不作为运动样本；迟到不等于时钟偏差。';

create or replace function situation.ingest_target_observation(p_observation jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, equipment, situation
as $$
declare
  v_source situation.observation_source%rowtype;
  v_source_system text := p_observation->>'sourceSystem';
  v_station_id text := p_observation->>'stationId';
  v_observation_key text := p_observation->>'sourceObservationId';
  v_serial text := nullif(btrim(p_observation->>'sourceTargetId'),'');
  v_source_type smallint := situation.safe_numeric(p_observation->>'sourceTypeCode')::smallint;
  v_detection_method text := nullif(btrim(p_observation->>'detectionMethodCode'),'');
  v_mapped_method text;
  v_source_producer_asset_id text := nullif(btrim(p_observation->>'sourceProducerAssetId'),'');
  v_producer_asset_id bigint;
  v_event_type text := p_observation->>'eventType';
  v_observed_at timestamptz;
  v_received_at timestamptz;
  v_lng numeric := situation.safe_numeric(p_observation->>'longitude');
  v_lat numeric := situation.safe_numeric(p_observation->>'latitude');
  v_pilot_lng numeric := situation.safe_numeric(p_observation#>>'{remotePilotLocation,longitude}');
  v_pilot_lat numeric := situation.safe_numeric(p_observation#>>'{remotePilotLocation,latitude}');
  v_pilot_geom geometry(Point,4326);
  v_geom geometry(Point,4326);
  v_quality text[];
  v_observation_id bigint;
  v_session situation.source_target_session%rowtype;
  v_target_id bigint;
  v_track_id bigint;
  v_change_cursor bigint;
  v_time_valid boolean;
begin
  if p_observation is null or jsonb_typeof(p_observation)<>'object' then
    raise exception 'normalized observation must be a JSON object';
  end if;
  if p_observation->>'schemaVersion' is distinct from '1' then
    raise exception 'unsupported normalized observation schemaVersion';
  end if;
  if v_source_system is null or v_station_id is null or v_observation_key is null or v_serial is null then
    raise exception 'sourceSystem, stationId, sourceObservationId and sourceTargetId are required';
  end if;
  if v_event_type not in ('online_upsert','snapshot','offline_remove') then
    raise exception 'invalid normalized eventType %',v_event_type;
  end if;
  begin
    v_observed_at := (p_observation->>'observedAt')::timestamptz;
    v_received_at := (p_observation->>'receivedAt')::timestamptz;
  exception when others then
    raise exception 'observedAt and receivedAt must be ISO 8601 timestamps with timezone';
  end;
  if v_observed_at is null or v_received_at is null then
    raise exception 'observedAt and receivedAt are required';
  end if;
  if jsonb_typeof(coalesce(p_observation->'rawPayload','null'::jsonb))<>'object' then
    raise exception 'rawPayload must be a JSON object';
  end if;
  if v_source_type is not null and not exists(
    select 1 from situation.detection_source_type where vendor_code=v_source_type and enabled
  ) then raise exception 'unsupported sourceTypeCode %',v_source_type; end if;
  if v_source_type is not null then
    select method_code into v_mapped_method from situation.detection_method_mapping
    where source_system=v_source_system and vendor_code=v_source_type::text and accept_ingest;
    if not found then
      raise exception 'source type %.% is not configured for ingestion',v_source_system,v_source_type;
    end if;
    if v_detection_method is not null and v_detection_method<>v_mapped_method then
      raise exception 'detectionMethodCode % conflicts with source type mapping %',v_detection_method,v_mapped_method;
    end if;
    v_detection_method:=coalesce(v_detection_method,v_mapped_method);
  end if;
  if v_detection_method is not null and not exists(
    select 1 from situation.detection_method where code=v_detection_method
  ) then raise exception 'unsupported detectionMethodCode %',v_detection_method; end if;
  if (v_lng is null)<>(v_lat is null) or (v_lng is not null and
      (v_lng not between -180 and 180 or v_lat not between -90 and 90 or (v_lng=0 and v_lat=0))) then
    raise exception 'longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_geom := case when v_lng is not null then ST_SetSRID(ST_MakePoint(v_lng,v_lat),4326) end;
  if p_observation ? 'remotePilotLocation'
     and p_observation->'remotePilotLocation' <> 'null'::jsonb
     and jsonb_typeof(p_observation->'remotePilotLocation') <> 'object' then
    raise exception 'remotePilotLocation must be an object or null';
  end if;
  if (v_pilot_lng is null)<>(v_pilot_lat is null) or (v_pilot_lng is not null and
      (v_pilot_lng not between -180 and 180 or v_pilot_lat not between -90 and 90
       or (v_pilot_lng=0 and v_pilot_lat=0))) then
    raise exception 'remote pilot longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_pilot_geom := case when v_pilot_lng is not null then
    ST_SetSRID(ST_MakePoint(v_pilot_lng,v_pilot_lat),4326) end;
  select coalesce(array_agg(value),array[]::text[]) into v_quality
  from jsonb_array_elements_text(coalesce(p_observation->'qualityFlags','[]'::jsonb));
  if v_observed_at>least(v_received_at,clock_timestamp()) then
    v_quality := array_append(v_quality,'future_source_time');
  elsif v_received_at-v_observed_at>interval '5 seconds' then
    v_quality := array_append(v_quality,'late_observation');
  end if;
  v_time_valid := situation.position_time_valid(v_observed_at,v_received_at,
    'detection_'||v_event_type,jsonb_build_object('_normalized',
      p_observation||jsonb_build_object('qualityFlags',to_jsonb(v_quality))));
  -- Raw evidence keeps supplied coordinates, but lifecycle messages never do.
  if v_event_type='offline_remove' then v_geom:=null; end if;

  select * into v_source from situation.observation_source
  where source_system=v_source_system and external_station_id=v_station_id and enabled
  order by (external_box_code<>'') desc,id limit 1;
  if not found then raise exception 'enabled observation source %.% is not configured',v_source_system,v_station_id; end if;

  if v_source_producer_asset_id is not null then
    select id into v_producer_asset_id from equipment.asset
    where source_system=v_source_system and source_asset_id=v_source_producer_asset_id;
    if not found then
      raise exception 'producer asset %.% is not registered',v_source_system,v_source_producer_asset_id;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_source.id::text||':'||v_serial,0));
  -- Even an idempotent snapshot confirms source presence, not a new position.
  update situation.source_target_session set last_received_at=greatest(last_received_at,least(v_received_at,clock_timestamp()))
  where observation_source_id=v_source.id and source_target_id=v_serial and state='active';
  insert into situation.observation_source_status_current(observation_source_id,connector_state,last_message_at,updated_at)
  values(v_source.id,'connected',v_received_at,now())
  on conflict(observation_source_id) do update set connector_state='connected',
    last_message_at=greatest(situation.observation_source_status_current.last_message_at,excluded.last_message_at),updated_at=now();

  insert into equipment.raw_observation(
    asset_id,source_system,source_observation_id,observation_type,observed_at,received_at,
    geom,height_amsl_m,height_datum,processing_status,raw_payload,is_simulated
  ) values(
    v_source.asset_id,v_source_system,v_observation_key,'detection_'||v_event_type,
    v_observed_at,v_received_at,v_geom,situation.safe_numeric(p_observation->>'altitudeAmslM'),'AMSL',
    case when cardinality(v_quality)>0 then 'needs_review' else 'normalized' end,
    p_observation->'rawPayload'||jsonb_build_object('_normalized',
      (p_observation-'rawPayload')||jsonb_build_object('qualityFlags',to_jsonb(v_quality))),false
  ) on conflict(source_system,source_observation_id) do nothing returning id into v_observation_id;
  if v_observation_id is null then
    select id into v_observation_id from equipment.raw_observation
    where source_system=v_source_system and source_observation_id=v_observation_key;
    return jsonb_build_object('status','duplicate','observationId',v_observation_id,'changeCursor',null);
  end if;

  insert into situation.target_observation(
    observation_id,observation_source_id,source_type_code,detection_method_code,producer_asset_id,source_target_id,source_session_id,event_type,
    model,frequency_mhz,relative_height_m,horizontal_distance_m,azimuth_deg,elevation_deg,speed_mps,list_type,pilot_geom,quality_flags
  ) values(
    v_observation_id,v_source.id,v_source_type,v_detection_method,v_producer_asset_id,v_serial,nullif(p_observation->>'sourceSessionId',''),v_event_type,
    nullif(p_observation->>'model',''),situation.safe_numeric(p_observation->>'frequencyMhz'),
    situation.safe_numeric(p_observation->>'relativeHeightM'),situation.safe_numeric(p_observation->>'horizontalDistanceM'),
    situation.safe_numeric(p_observation->>'azimuthDeg'),situation.safe_numeric(p_observation->>'elevationDeg'),
    situation.safe_numeric(p_observation->>'speedMps'),situation.safe_numeric(p_observation->>'listType')::smallint,v_pilot_geom,v_quality
  );

  -- Invalid position times remain auditable raw records, not invented motion.
  -- In particular, a future time must never reach a greatest() watermark.
  if not v_time_valid and v_event_type<>'offline_remove' then
    return jsonb_build_object('status','accepted','observationId',v_observation_id,
      'trackId',null,'changeCursor',null,'positionTimeValid',false);
  end if;
  if v_event_type='offline_remove' then
    v_observed_at:=least(v_observed_at,v_received_at,clock_timestamp());
  end if;

  select * into v_session from situation.source_target_session
  where observation_source_id=v_source.id and source_target_id=v_serial and state='active'
  order by last_observed_at desc limit 1 for update;
  if not found and v_event_type<>'offline_remove' then
    insert into situation.airspace_target(target_code,target_class,display_name,first_observed_at,last_observed_at)
    values('TGT-'||nextval('situation.airspace_target_id_seq'),
      case when p_observation->>'model' is null then 'unknown' else 'uav' end,
      p_observation->>'model',v_observed_at,v_observed_at) returning id into v_target_id;
    insert into situation.source_target_session(
      observation_source_id,source_type_code,source_target_id,source_session_id,session_key,target_id,
      started_at,last_observed_at,current_observation_id
    ) values(v_source.id,v_source_type,v_serial,nullif(p_observation->>'sourceSessionId',''),
      coalesce(nullif(p_observation->>'sourceSessionId',''),v_serial||':'||v_observation_id),
      v_target_id,v_observed_at,v_observed_at,v_observation_id) returning * into v_session;
    insert into situation.target_track(
      track_code,target_id,source_session_id,first_observed_at,last_observed_at,current_observation_id
    ) values('TRK-'||nextval('situation.target_track_id_seq'),v_target_id,v_session.id,
      v_observed_at,v_observed_at,case when v_geom is not null then v_observation_id end) returning id into v_track_id;
  elsif found then
    v_target_id:=v_session.target_id;
    select id into v_track_id from situation.target_track where source_session_id=v_session.id for update;
    if v_event_type='offline_remove' and v_observed_at>=v_session.last_observed_at then
      update situation.source_target_session set state='closed',ended_at=v_observed_at,
        end_reason=coalesce(nullif(p_observation->>'endReason',''),'source_remove'),
        current_observation_id=v_observation_id,version=version+1 where id=v_session.id;
      update situation.target_track set status='closed',lost_at=v_observed_at,
        version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=false,updated_at=now() where id=v_target_id;
    elsif v_event_type<>'offline_remove' then
      update situation.source_target_session set source_type_code=coalesce(source_type_code,v_source_type),
        source_session_id=coalesce(source_session_id,nullif(p_observation->>'sourceSessionId','')),
        last_observed_at=case when last_observed_at>clock_timestamp() then v_observed_at else greatest(last_observed_at,v_observed_at) end,
        current_observation_id=case when v_observed_at>=last_observed_at or last_observed_at>clock_timestamp() then v_observation_id else current_observation_id end,
        version=version+1 where id=v_session.id;
      -- A non-spatial sample cannot repair the position watermark while keeping
      -- its old future pointer: a later-arriving, older real position must win.
      update situation.target_track set status='tracking',
        last_observed_at=case when v_geom is null then last_observed_at
          when current_observation_id is null or last_observed_at>clock_timestamp() then v_observed_at else greatest(last_observed_at,v_observed_at) end,
        current_observation_id=case when v_geom is not null and (current_observation_id is null or v_observed_at>last_observed_at or last_observed_at>clock_timestamp()) then v_observation_id else current_observation_id end,
        version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=true,
        last_observed_at=case when last_observed_at>clock_timestamp() then v_observed_at else greatest(last_observed_at,v_observed_at) end,
        updated_at=now() where id=v_target_id;
    end if;
  end if;

  if v_session.id is not null then
    update situation.source_target_session set last_received_at=greatest(last_received_at,least(v_received_at,clock_timestamp()))
    where id=v_session.id;
  end if;
  if v_track_id is not null then
    insert into situation.track_observation(track_id,observation_id,association_method,association_confidence)
    values(v_track_id,v_observation_id,'source_session',1);
    insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
    values(case when v_event_type='offline_remove' then 'target_remove' else 'target_upsert' end,
      'target_track',v_track_id,v_source.id,v_observed_at,
      jsonb_build_object('track_id',v_track_id,'target_id',v_target_id,'observation_id',v_observation_id))
    returning id into v_change_cursor;
  end if;
  return jsonb_build_object('status','accepted','observationId',v_observation_id,
    'targetId',v_target_id,'trackId',v_track_id,'changeCursor',v_change_cursor);
end;
$$;
comment on function situation.ingest_target_observation(jsonb) is '写入单条版本化规范目标观测，原子维护原始证据、来源会话、目标航迹和增量事件；返回 JSON：status、observationId、targetId、trackId、changeCursor。';

create or replace function situation.reconcile_detection_targets(
  p_source_system text,p_station_id text,p_observed_at timestamptz,p_present_target_ids text[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_source situation.observation_source%rowtype; v_row record; v_closed int:=0; v_cursor bigint;
begin
  select * into v_source from situation.observation_source where source_system=p_source_system
    and external_station_id=p_station_id and enabled order by id limit 1;
  if not found then raise exception 'observation source is not configured'; end if;
  update situation.observation_source_status_current set last_snapshot_at=p_observed_at,updated_at=now()
    where observation_source_id=v_source.id;
  for v_row in select s.id session_id,s.target_id,t.id track_id from situation.source_target_session s
    join situation.target_track t on t.source_session_id=s.id
    where s.observation_source_id=v_source.id and s.state='active'
      and not (s.source_target_id=any(coalesce(p_present_target_ids,array[]::text[])))
      and coalesce(s.last_received_at,s.last_observed_at) < p_observed_at-make_interval(secs=>v_source.lost_timeout_seconds)
    for update of s,t
  loop
    update situation.source_target_session set state='lost',ended_at=p_observed_at,end_reason='reconciled_absent',version=version+1
      where id=v_row.session_id;
    update situation.target_track set status='lost',lost_at=p_observed_at,version=version+1,updated_at=now() where id=v_row.track_id;
    update situation.airspace_target set active=false,updated_at=now() where id=v_row.target_id;
    insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
    values('target_remove','target_track',v_row.track_id,v_source.id,p_observed_at,
      jsonb_build_object('track_id',v_row.track_id,'target_id',v_row.target_id,'reason','reconciled_absent')) returning id into v_cursor;
    v_closed:=v_closed+1;
  end loop;
  return jsonb_build_object('status','accepted','closedSessions',v_closed,'changeCursor',v_cursor);
end;
$$;
comment on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) is '按在线目标快照和来源宽限时间关闭缺失会话；返回 JSON：status、closedSessions、changeCursor。';

comment on column api.detection_observation_sources.skew_median_seconds is '近 15 分钟观测时间减连接器接收时间的中位数（秒）；含传输、快照陈旧和时钟差，不能单独证明源时钟偏差；NULL 表示无样本。';
comment on column api.detection_observation_sources.skew_abs_max_seconds is '近 15 分钟观测与接收时差绝对值最大值（秒）；不是已确认的源时钟偏差。';

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
    and situation.position_time_valid(r.observed_at,r.received_at,r.observation_type,r.raw_payload)
    and r.observed_at<=now()
    and not exists (
      select 1 from situation.track_observation dx
      join equipment.raw_observation dr on dr.id=dx.observation_id
      where dx.track_id=tr.track_id and dr.observed_at=r.observed_at and dr.id<r.id
        and dr.asset_id=r.asset_id and dr.geom is not distinct from r.geom
        and situation.position_time_valid(dr.observed_at,dr.received_at,dr.observation_type,dr.raw_payload)
    )
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

commit;
