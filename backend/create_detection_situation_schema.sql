-- 云平台雷达/电侦数据接入、目标会话、航迹与态势查询。
-- 依赖 create_equipment_asset_schema.sql 和 migrate_equipment_detection_devices.sql。
-- 可重复执行；PostgREST 仅公开 api schema，situation 为内部数据层。

begin;

create extension if not exists postgis;
create schema if not exists situation;
create schema if not exists api;
comment on schema situation is '空域目标观测、来源会话、目标航迹和态势增量数据域。';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'detection_ingest') then
    create role detection_ingest nologin;
  end if;
end;
$$;

create table if not exists situation.detection_source_type (
  vendor_code smallint primary key,
  code text not null unique,
  name text not null,
  enabled boolean not null default true,
  description text
);
comment on table situation.detection_source_type is '厂商侦测来源类型与平台稳定编码的映射字典。';
comment on column situation.detection_source_type.vendor_code is '厂商 sourceType 数值。';
comment on column situation.detection_source_type.code is '平台内部稳定来源类型编码。';
comment on column situation.detection_source_type.name is '来源类型中文名称。';
comment on column situation.detection_source_type.enabled is '是否允许接收该来源类型。';
comment on column situation.detection_source_type.description is '来源类型说明。';
insert into situation.detection_source_type(vendor_code, code, name, description) values
  (10, 'radar', '雷达', '云平台 sourceType=10 的雷达侦测数据。'),
  (20, 'radio_detection', '电侦', '云平台 sourceType=20 的无线电侦测数据。')
on conflict (vendor_code) do update set code=excluded.code, name=excluded.name,
  enabled=true, description=excluded.description;

create table if not exists situation.observation_source (
  id bigserial primary key,
  source_system text not null,
  external_station_id text not null,
  external_box_code text not null default '',
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  name text not null,
  source_timezone text not null default 'Asia/Shanghai',
  coordinate_system text not null default 'WGS84' check (coordinate_system = 'WGS84'),
  enabled boolean not null default true,
  lost_timeout_seconds integer not null default 30 check (lost_timeout_seconds between 5 and 3600),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_system, external_station_id, external_box_code)
);
comment on table situation.observation_source is '外部站点或边缘盒子的观测接入身份及规范化配置。';
comment on column situation.observation_source.source_system is '来源系统稳定编码。';
comment on column situation.observation_source.external_station_id is '来源系统站点 ID。';
comment on column situation.observation_source.external_box_code is '来源系统盒子编码。';
comment on column situation.observation_source.asset_id is '对应的统一设施设备资产 ID。';
comment on column situation.observation_source.source_timezone is '解释来源无时区时间字符串所用时区。';
comment on column situation.observation_source.coordinate_system is '来源坐标系，当前固定为 WGS84。';
comment on column situation.observation_source.lost_timeout_seconds is '目标缺失后判定丢失的宽限秒数。';
comment on column situation.observation_source.metadata is '不含密钥的来源扩展配置。';

create table if not exists situation.observation_source_status_current (
  observation_source_id bigint primary key references situation.observation_source(id) on delete cascade,
  connector_state text not null default 'unknown' check (connector_state in ('connected','disconnected','degraded','unknown')),
  last_connected_at timestamptz,
  last_disconnected_at timestamptz,
  last_message_at timestamptz,
  last_snapshot_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  details jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
comment on table situation.observation_source_status_current is '观测接入链路的当前连接和消息健康状态。';
comment on column situation.observation_source_status_current.connector_state is '连接器状态，不等同于物理雷达在线状态。';
comment on column situation.observation_source_status_current.last_message_at is '最近收到合法来源消息的时间。';
comment on column situation.observation_source_status_current.last_snapshot_at is '最近完成在线列表对账的时间。';
comment on column situation.observation_source_status_current.last_error_code is '最近错误编码，不保存敏感错误详情。';
comment on column situation.observation_source_status_current.details is '不含密码、令牌和控制密钥的状态扩展信息。';
create index if not exists observation_source_status_message_idx
  on situation.observation_source_status_current(last_message_at desc);

create table if not exists situation.target_observation (
  observation_id bigint primary key references equipment.raw_observation(id) on delete restrict,
  observation_source_id bigint not null references situation.observation_source(id) on delete restrict,
  source_type_code smallint references situation.detection_source_type(vendor_code),
  producer_asset_id bigint references equipment.asset(id) on delete restrict,
  source_target_id text not null,
  source_session_id text,
  event_type text not null check (event_type in ('online_upsert','snapshot','offline_remove')),
  model text,
  frequency_mhz numeric check (frequency_mhz is null or frequency_mhz >= 0),
  relative_height_m numeric,
  horizontal_distance_m numeric check (horizontal_distance_m is null or horizontal_distance_m >= 0),
  azimuth_deg numeric check (azimuth_deg is null or azimuth_deg between 0 and 360),
  elevation_deg numeric check (elevation_deg is null or elevation_deg between -90 and 90),
  speed_mps numeric check (speed_mps is null or speed_mps >= 0),
  list_type smallint,
  pilot_geom geometry(Point,4326),
  home_geom geometry(Point,4326),
  quality_flags text[] not null default '{}'
);
comment on table situation.target_observation is '原始设备观测的一对一目标侦测语义扩展。';
comment on column situation.target_observation.observation_id is '对应的追加式设备原始观测 ID。';
comment on column situation.target_observation.source_type_code is '厂商来源类型：10 雷达、20 电侦；缺失时为空。';
comment on column situation.target_observation.source_target_id is '来源系统目标标识，当前对应 serial。';
comment on column situation.target_observation.source_session_id is '来源系统提供的目标会话 ID。';
comment on column situation.target_observation.frequency_mhz is '侦测频率，单位 MHz。';
comment on column situation.target_observation.relative_height_m is '来源相对高度，单位米，不作为 AMSL 高度。';
comment on column situation.target_observation.horizontal_distance_m is '站点到目标的水平距离，单位米。';
comment on column situation.target_observation.azimuth_deg is '站点到目标的方位角，单位度，不是目标航向。';
comment on column situation.target_observation.quality_flags is '规范化过程发现的数据质量标记。';
create index if not exists target_observation_source_target_idx
  on situation.target_observation(observation_source_id, source_target_id, observation_id desc);
create index if not exists target_observation_source_type_idx
  on situation.target_observation(source_type_code, observation_id desc);
create index if not exists target_observation_quality_gin
  on situation.target_observation using gin(quality_flags);

create table if not exists situation.airspace_target (
  id bigserial primary key,
  target_code text not null unique,
  target_class text not null default 'unknown',
  display_name text,
  identity_status text not null default 'unverified' check (identity_status in ('unverified','identified','conflicted')),
  confidence numeric check (confidence is null or confidence between 0 and 1),
  first_observed_at timestamptz not null,
  last_observed_at timestamptz not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table situation.airspace_target is '平台基于来源观测形成的当前空域目标解释。';
comment on column situation.airspace_target.target_code is '平台内部稳定目标编码。';
comment on column situation.airspace_target.target_class is '目标类别，如 uav、bird 或 unknown。';
comment on column situation.airspace_target.identity_status is '目标身份研判状态。';
comment on column situation.airspace_target.active is '目标当前是否活动。';

create table if not exists situation.source_target_session (
  id bigserial primary key,
  observation_source_id bigint not null references situation.observation_source(id) on delete restrict,
  source_type_code smallint references situation.detection_source_type(vendor_code),
  source_target_id text not null,
  source_session_id text,
  session_key text not null,
  target_id bigint not null references situation.airspace_target(id) on delete restrict,
  state text not null default 'active' check (state in ('active','lost','closed')),
  started_at timestamptz not null,
  last_observed_at timestamptz not null,
  ended_at timestamptz,
  end_reason text,
  current_observation_id bigint references equipment.raw_observation(id) on delete restrict,
  version bigint not null default 1,
  unique (observation_source_id, session_key)
);
comment on table situation.source_target_session is '来源目标从首次发现到离线的一次连续发现会话。';
comment on column situation.source_target_session.session_key is '来源会话 ID 或平台生成的确定性会话键。';
comment on column situation.source_target_session.state is '会话状态：active、lost 或 closed。';
comment on column situation.source_target_session.end_reason is '会话结束原因，如 source_remove、timeout 或 reconciled_absent。';
create index if not exists source_target_session_active_idx
  on situation.source_target_session(observation_source_id, source_target_id, last_observed_at desc)
  where state = 'active';
create index if not exists source_target_session_state_time_idx
  on situation.source_target_session(state, last_observed_at);

create table if not exists situation.target_track (
  id bigserial primary key,
  track_code text not null unique,
  target_id bigint not null references situation.airspace_target(id) on delete restrict,
  source_session_id bigint unique references situation.source_target_session(id) on delete restrict,
  status text not null default 'tracking' check (status in ('tracking','lost','closed')),
  first_observed_at timestamptz not null,
  last_observed_at timestamptz not null,
  lost_at timestamptz,
  current_observation_id bigint references equipment.raw_observation(id) on delete restrict,
  track_confidence numeric check (track_confidence is null or track_confidence between 0 and 1),
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);
comment on table situation.target_track is '空域目标在一段时间内的连续跟踪结果和当前状态。';
comment on column situation.target_track.track_code is '平台内部稳定航迹编码。';
comment on column situation.target_track.current_observation_id is '最新有效空间位置观测 ID，无坐标观测不覆盖该字段。';
comment on column situation.target_track.track_confidence is '航迹关联可信度，范围 0 到 1。';
create index if not exists target_track_status_time_idx
  on situation.target_track(status, last_observed_at desc);

create table if not exists situation.track_observation (
  track_id bigint not null references situation.target_track(id) on delete cascade,
  observation_id bigint not null unique references equipment.raw_observation(id) on delete restrict,
  association_method text not null check (association_method in ('source_session','manual','fused')),
  association_confidence numeric check (association_confidence is null or association_confidence between 0 and 1),
  associated_at timestamptz not null default now(),
  primary key (track_id, observation_id)
);
comment on table situation.track_observation is '目标航迹与雷达、电侦及后续其他来源观测的证据关联。';
comment on column situation.track_observation.association_method is '观测关联方式：来源会话、人工或融合。';
comment on column situation.track_observation.association_confidence is '观测与航迹的关联可信度。';

create table if not exists situation.change_event (
  id bigserial primary key,
  event_type text not null check (event_type in ('target_upsert','target_remove','source_status')),
  aggregate_type text not null check (aggregate_type in ('target_track','observation_source')),
  aggregate_id bigint not null,
  observation_source_id bigint references situation.observation_source(id) on delete restrict,
  occurred_at timestamptz not null,
  payload jsonb not null,
  created_at timestamptz not null default now()
);
comment on table situation.change_event is '供态势客户端按游标补读的持久化增量变更，不是业务空域事件。';
comment on column situation.change_event.id is '单调递增的增量读取游标。';
comment on column situation.change_event.event_type is '增量类型：目标更新、目标移除或来源状态。';
comment on column situation.change_event.payload is '内部稳定事件载荷 JSON。';
create index if not exists change_event_source_cursor_idx
  on situation.change_event(observation_source_id, id);
create index if not exists change_event_created_idx on situation.change_event(created_at);

-- 登记已通过厂商接口验证的站点 90 实体盒子。
insert into equipment.asset(
  asset_code,category_code,type_code,name,source_system,source_asset_id,deployment_mode,
  lifecycle_status,geom,height_datum,manufacturer,model,is_simulated,metadata
) values (
  'RADAR-CLOUD-BOX-90','counter_uas','edge_detection_box','连云港雷达云平台站点 90 边缘盒子',
  'radar_cloud','b260705174118582','fixed','active',
  ST_SetSRID(ST_MakePoint(119.1929320,34.5919520),4326),'AMSL','边缘盒子','D007-V',false,
  jsonb_build_object('station_id',90,'vendor_box_code','b260705174118582','counter_device',2)
)
on conflict (source_system,source_asset_id) do update set
  name=excluded.name,geom=excluded.geom,model=excluded.model,metadata=excluded.metadata,updated_at=now();

insert into equipment.counter_uas_profile(asset_id,detection_mode,identification_mode,tracking_mode,recommendation_notes)
select id,'radar_and_radio','vendor_identification','vendor_track','只接收侦测数据，不接入真实控制指令。'
from equipment.asset where source_system='radar_cloud' and source_asset_id='b260705174118582'
on conflict (asset_id) do update set detection_mode=excluded.detection_mode,
  identification_mode=excluded.identification_mode,tracking_mode=excluded.tracking_mode,
  recommendation_notes=excluded.recommendation_notes;

-- 建立站点 90 的观测来源映射。
insert into situation.observation_source(
  source_system, external_station_id, external_box_code, asset_id, name, metadata
)
select 'radar_cloud', '90', 'b260705174118582', id, '连云港雷达云平台站点 90',
       jsonb_build_object('vendor_host', '47.110.44.5', 'vendor_port', 8003)
from equipment.asset
where source_system = 'radar_cloud' and source_asset_id = 'b260705174118582'
order by id limit 1
on conflict (source_system, external_station_id, external_box_code) do update set
  asset_id=excluded.asset_id, name=excluded.name, metadata=excluded.metadata, updated_at=now();

create or replace function situation.safe_numeric(p_value text)
returns numeric language plpgsql immutable as $$
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  return p_value::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;
comment on function situation.safe_numeric(text) is '将来源字符串安全转换为数值，非法值返回空。';

drop function if exists situation.source_timestamp(text,text,timestamptz);

drop function if exists situation.ingest_detection_message(text,text,text,text,timestamptz,jsonb);

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
  v_event_type text := p_observation->>'eventType';
  v_observed_at timestamptz;
  v_received_at timestamptz;
  v_lng numeric := situation.safe_numeric(p_observation->>'longitude');
  v_lat numeric := situation.safe_numeric(p_observation->>'latitude');
  v_geom geometry(Point,4326);
  v_quality text[];
  v_observation_id bigint;
  v_session situation.source_target_session%rowtype;
  v_target_id bigint;
  v_track_id bigint;
  v_change_cursor bigint;
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
  if (v_lng is null)<>(v_lat is null) or (v_lng is not null and
      (v_lng not between -180 and 180 or v_lat not between -90 and 90 or (v_lng=0 and v_lat=0))) then
    raise exception 'longitude and latitude must form a valid non-zero WGS84 position';
  end if;
  v_geom := case when v_lng is not null then ST_SetSRID(ST_MakePoint(v_lng,v_lat),4326) end;
  select coalesce(array_agg(value),array[]::text[]) into v_quality
  from jsonb_array_elements_text(coalesce(p_observation->'qualityFlags','[]'::jsonb));

  select * into v_source from situation.observation_source
  where source_system=v_source_system and external_station_id=v_station_id and enabled
  order by (external_box_code<>'') desc,id limit 1;
  if not found then raise exception 'enabled observation source %.% is not configured',v_source_system,v_station_id; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_source.id::text||':'||v_serial,0));
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
    p_observation->'rawPayload'||jsonb_build_object('_normalized',p_observation-'rawPayload'),false
  ) on conflict(source_system,source_observation_id) do nothing returning id into v_observation_id;
  if v_observation_id is null then
    select id into v_observation_id from equipment.raw_observation
    where source_system=v_source_system and source_observation_id=v_observation_key;
    return jsonb_build_object('status','duplicate','observationId',v_observation_id,'changeCursor',null);
  end if;

  insert into situation.target_observation(
    observation_id,observation_source_id,source_type_code,source_target_id,source_session_id,event_type,
    model,frequency_mhz,relative_height_m,horizontal_distance_m,azimuth_deg,elevation_deg,speed_mps,list_type,quality_flags
  ) values(
    v_observation_id,v_source.id,v_source_type,v_serial,nullif(p_observation->>'sourceSessionId',''),v_event_type,
    nullif(p_observation->>'model',''),situation.safe_numeric(p_observation->>'frequencyMhz'),
    situation.safe_numeric(p_observation->>'relativeHeightM'),situation.safe_numeric(p_observation->>'horizontalDistanceM'),
    situation.safe_numeric(p_observation->>'azimuthDeg'),situation.safe_numeric(p_observation->>'elevationDeg'),
    situation.safe_numeric(p_observation->>'speedMps'),situation.safe_numeric(p_observation->>'listType')::smallint,v_quality
  );

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
        last_observed_at=greatest(last_observed_at,v_observed_at),version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=false,
        last_observed_at=greatest(last_observed_at,v_observed_at),updated_at=now() where id=v_target_id;
    elsif v_event_type<>'offline_remove' then
      update situation.source_target_session set source_type_code=coalesce(source_type_code,v_source_type),
        source_session_id=coalesce(source_session_id,nullif(p_observation->>'sourceSessionId','')),
        last_observed_at=greatest(last_observed_at,v_observed_at),
        current_observation_id=case when v_observed_at>=last_observed_at then v_observation_id else current_observation_id end,
        version=version+1 where id=v_session.id;
      update situation.target_track set status='tracking',last_observed_at=greatest(last_observed_at,v_observed_at),
        current_observation_id=case when v_geom is not null and v_observed_at>=last_observed_at then v_observation_id else current_observation_id end,
        version=version+1,updated_at=now() where id=v_track_id;
      update situation.airspace_target set active=true,last_observed_at=greatest(last_observed_at,v_observed_at),
        updated_at=now() where id=v_target_id;
    end if;
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


create or replace function situation.update_detection_connector_status(
  p_source_system text,p_station_id text,p_state text,p_observed_at timestamptz,
  p_last_message_at timestamptz default null,p_error_code text default null,p_details jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,situation as $$
declare v_source_id bigint; v_cursor bigint;
begin
  if p_state not in ('connected','disconnected','degraded','unknown') then raise exception 'invalid connector state'; end if;
  if p_details ?| array['password','token','secret','credential'] then raise exception 'connector details contain a forbidden key'; end if;
  select id into v_source_id from situation.observation_source
    where source_system=p_source_system and external_station_id=p_station_id and enabled order by id limit 1;
  if v_source_id is null then raise exception 'observation source is not configured'; end if;
  insert into situation.observation_source_status_current(
    observation_source_id,connector_state,last_connected_at,last_disconnected_at,last_message_at,
    last_error_code,last_error_at,details,updated_at
  ) values(v_source_id,p_state,case when p_state='connected' then p_observed_at end,
    case when p_state='disconnected' then p_observed_at end,p_last_message_at,p_error_code,
    case when p_error_code is not null then p_observed_at end,p_details,now())
  on conflict(observation_source_id) do update set connector_state=excluded.connector_state,
    last_connected_at=coalesce(excluded.last_connected_at,situation.observation_source_status_current.last_connected_at),
    last_disconnected_at=coalesce(excluded.last_disconnected_at,situation.observation_source_status_current.last_disconnected_at),
    last_message_at=coalesce(excluded.last_message_at,situation.observation_source_status_current.last_message_at),
    last_error_code=excluded.last_error_code,last_error_at=coalesce(excluded.last_error_at,situation.observation_source_status_current.last_error_at),
    details=excluded.details,updated_at=now();
  insert into situation.change_event(event_type,aggregate_type,aggregate_id,observation_source_id,occurred_at,payload)
  values('source_status','observation_source',v_source_id,v_source_id,p_observed_at,
    jsonb_build_object('source_id',v_source_id,'connector_state',p_state,'last_message_at',p_last_message_at)) returning id into v_cursor;
  return jsonb_build_object('status','accepted','sourceId',v_source_id,'changeCursor',v_cursor);
end;
$$;
comment on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) is '更新侦测连接器状态并生成来源状态增量；返回 JSON：status、sourceId、changeCursor。';

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
      and s.last_observed_at < p_observed_at-make_interval(secs=>v_source.lost_timeout_seconds)
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

create or replace view api.detection_source_types as
select vendor_code as source_type_code,code,name,description from situation.detection_source_type where enabled;
comment on view api.detection_source_types is '雷达和电侦来源类型只读字典。';
comment on column api.detection_source_types.source_type_code is '厂商来源类型数值，10 雷达、20 电侦。';

create or replace view api.detection_observation_sources as
select s.id,s.source_system,s.external_station_id as station_id,s.external_box_code as box_code,
  s.name,s.coordinate_system,s.enabled,st.connector_state,st.last_message_at,st.last_snapshot_at,st.updated_at
from situation.observation_source s left join situation.observation_source_status_current st on st.observation_source_id=s.id;
comment on view api.detection_observation_sources is '侦测观测来源和接入链路状态只读资源。';
comment on column api.detection_observation_sources.station_id is '来源系统站点 ID。';
comment on column api.detection_observation_sources.connector_state is '接入连接器状态，不等同于物理设备在线状态。';

create or replace function api.get_detection_situation_snapshot(
  p_station_ids text[] default null,p_source_type_codes smallint[] default null,
  p_west double precision default null,p_south double precision default null,
  p_east double precision default null,p_north double precision default null,
  p_active_within_seconds integer default 30,p_limit integer default 1000
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation,api as $$
declare v_result jsonb;
begin
  if p_active_within_seconds not between 5 and 3600 then raise exception 'active window must be between 5 and 3600 seconds'; end if;
  if p_limit not between 1 and 5000 then raise exception 'limit must be between 1 and 5000'; end if;
  if (p_west is null)<>(p_south is null) or (p_west is null)<>(p_east is null) or (p_west is null)<>(p_north is null) then
    raise exception 'bbox requires west, south, east and north';
  end if;
  with current_rows as (
    select t.id track_id,t.track_code,t.status,t.target_id,s.source_target_id,s.source_type_code,
      dt.name source_type_name,o.model,o.frequency_mhz,o.relative_height_m,o.horizontal_distance_m,
      o.azimuth_deg,o.elevation_deg,o.speed_mps,o.quality_flags,r.observed_at,r.geom,r.height_amsl_m,
      src.external_station_id station_id
    from situation.target_track t join situation.source_target_session s on s.id=t.source_session_id
    join situation.observation_source src on src.id=s.observation_source_id
    left join equipment.raw_observation r on r.id=t.current_observation_id
    left join situation.target_observation o on o.observation_id=coalesce(t.current_observation_id,s.current_observation_id)
    left join situation.detection_source_type dt on dt.vendor_code=s.source_type_code
    where t.status='tracking' and t.last_observed_at>=now()-make_interval(secs=>p_active_within_seconds)
      and (p_station_ids is null or src.external_station_id=any(p_station_ids))
      and (p_source_type_codes is null or s.source_type_code=any(p_source_type_codes))
  ), bounded as (
    select * from current_rows where geom is null or p_west is null or ST_Intersects(geom,ST_MakeEnvelope(p_west,p_south,p_east,p_north,4326))
    order by observed_at desc nulls last limit p_limit
  ) select jsonb_build_object('generated_at',now(),'cursor',coalesce((select max(id) from situation.change_event),0),
    'targets',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'target_id',target_id,'track_id',track_id,'track_code',track_code,'status',status,
      'source_target_id',source_target_id,'source_type_code',source_type_code,'source_type_name',source_type_name,
      'model',model,'observed_at',observed_at,'position',ST_AsGeoJSON(geom)::jsonb,'altitude_amsl_m',height_amsl_m,
      'relative_height_m',relative_height_m,'speed_mps',speed_mps,'azimuth_deg',azimuth_deg,
      'elevation_deg',elevation_deg,'horizontal_distance_m',horizontal_distance_m,'frequency_mhz',frequency_mhz,
      'position_status','valid','quality_flags',quality_flags)) order by observed_at desc) from bounded where geom is not null),'[]'::jsonb),
    'non_spatial_detections',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'target_id',target_id,'track_id',track_id,'source_target_id',source_target_id,'source_type_code',source_type_code,
      'source_type_name',source_type_name,'model',model,'frequency_mhz',frequency_mhz,'observed_at',observed_at,
      'quality_flags',quality_flags)) order by observed_at desc) from bounded where geom is null),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(v) order by station_id) from api.detection_observation_sources v
      where p_station_ids is null or station_id=any(p_station_ids)),'[]'::jsonb)) into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) is '返回 JSON：generated_at、cursor、targets（有位置活动目标）、non_spatial_detections（无位置侦测）和 sources（来源状态）；支持站点、来源类型、WGS84 bbox、活动窗口和数量上限。';

create or replace function api.get_detection_situation_changes(
  p_after_cursor bigint,p_station_ids text[] default null,p_limit integer default 500
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,situation as $$
declare v_result jsonb;
begin
  if p_after_cursor is null or p_after_cursor<0 then raise exception 'after cursor must be non-negative'; end if;
  if p_limit not between 1 and 1000 then raise exception 'limit must be between 1 and 1000'; end if;
  with filtered as (
    select e.* from situation.change_event e left join situation.observation_source s on s.id=e.observation_source_id
    where e.id>p_after_cursor and (p_station_ids is null or s.external_station_id=any(p_station_ids)) order by e.id limit p_limit+1
  ), page as (select * from filtered order by id limit p_limit)
  select jsonb_build_object('from_cursor',p_after_cursor,'next_cursor',coalesce((select max(id) from page),p_after_cursor),
    'has_more',(select count(*)>p_limit from filtered),'changes',coalesce((select jsonb_agg(
      jsonb_build_object('cursor',id,'type',event_type,'occurred_at',occurred_at,'payload',payload) order by id) from page),'[]'::jsonb))
  into v_result;
  return v_result;
end;
$$;
comment on function api.get_detection_situation_changes(bigint,text[],integer) is '返回 JSON：from_cursor、next_cursor、has_more 和 changes；按持久化游标补读目标及来源状态增量，单次最多 1000 条。';

create or replace function api.get_target_track_detail(
  p_track_id bigint,p_start_at timestamptz,p_end_at timestamptz,p_max_points integer default 2000
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,equipment,situation as $$
declare v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid half-open time window'; end if;
  if p_end_at-p_start_at>interval '24 hours' then raise exception 'track detail window cannot exceed 24 hours'; end if;
  if p_max_points not between 1 and 5000 then raise exception 'max points must be between 1 and 5000'; end if;
  with observations as (
    select r.id,r.observed_at,r.geom,r.height_amsl_m,o.source_type_code,o.frequency_mhz,o.relative_height_m,
      o.horizontal_distance_m,o.azimuth_deg,o.elevation_deg,o.speed_mps,o.quality_flags,
      row_number() over(order by r.observed_at,r.id) rn,count(*) over() total
    from situation.track_observation x join equipment.raw_observation r on r.id=x.observation_id
    join situation.target_observation o on o.observation_id=r.id
    where x.track_id=p_track_id and r.observed_at>=p_start_at and r.observed_at<p_end_at
  ), sampled as (select * from observations where total<=p_max_points or mod(rn-1,ceil(total::numeric/p_max_points)::bigint)=0 limit p_max_points)
  select jsonb_build_object('track',(select jsonb_build_object('id',t.id,'track_code',t.track_code,'status',t.status,
      'first_observed_at',t.first_observed_at,'last_observed_at',t.last_observed_at,'lost_at',t.lost_at) from situation.target_track t where t.id=p_track_id),
    'points',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('observation_id',id,'observed_at',observed_at,
      'position',ST_AsGeoJSON(geom)::jsonb,'altitude_amsl_m',height_amsl_m,'source_type_code',source_type_code,
      'frequency_mhz',frequency_mhz,'relative_height_m',relative_height_m,'horizontal_distance_m',horizontal_distance_m,
      'azimuth_deg',azimuth_deg,'elevation_deg',elevation_deg,'speed_mps',speed_mps,'quality_flags',quality_flags)) order by observed_at,id)
      from sampled where geom is not null),'[]'::jsonb),
    'non_spatial_observations',coalesce((select jsonb_agg(jsonb_build_object('observation_id',id,'observed_at',observed_at,
      'source_type_code',source_type_code,'frequency_mhz',frequency_mhz,'quality_flags',quality_flags) order by observed_at,id)
      from sampled where geom is null),'[]'::jsonb),
    'evidence',jsonb_build_object('observation_count',coalesce((select max(total) from observations),0),
      'returned_count',(select count(*) from sampled),'sampled',coalesce((select max(total) from observations),0)>p_max_points)) into v_result;
  if v_result->'track'='null'::jsonb then raise exception 'target track % does not exist',p_track_id; end if;
  return v_result;
end;
$$;
comment on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) is '返回 JSON：track、points、non_spatial_observations 和 evidence；查询半开时间区间内航迹证据，窗口最大 24 小时，最多返回 5000 个抽样点。';

revoke all on schema situation from public,anonymous,admin,detection_ingest;
revoke all on all tables in schema situation from public,anonymous,admin,detection_ingest;
revoke all on all functions in schema situation from public,anonymous,admin,detection_ingest;
revoke all on function situation.ingest_target_observation(jsonb) from public,anonymous,admin,detection_ingest;
revoke all on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) from public,anonymous,admin,detection_ingest;
revoke all on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) from public,anonymous,admin,detection_ingest;
grant usage on schema situation to detection_ingest;
grant execute on function situation.ingest_target_observation(jsonb) to detection_ingest;
grant execute on function situation.update_detection_connector_status(text,text,text,timestamptz,timestamptz,text,jsonb) to detection_ingest;
grant execute on function situation.reconcile_detection_targets(text,text,timestamptz,text[]) to detection_ingest;

revoke all on api.detection_source_types,api.detection_observation_sources from public,anonymous;
revoke all on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) from public,anonymous;
revoke all on function api.get_detection_situation_changes(bigint,text[],integer) from public,anonymous;
revoke all on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) from public,anonymous;
grant select on api.detection_source_types,api.detection_observation_sources to admin;
grant execute on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) to admin;
grant execute on function api.get_detection_situation_changes(bigint,text[],integer) to admin;
grant execute on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) to admin;

notify pgrst,'reload schema';
commit;
