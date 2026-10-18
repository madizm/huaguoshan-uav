-- 云平台功放控制：能力授权、操作状态机、指令 outbox、设备状态和审计。
-- 依赖 create_auth_credentials.sql、create_equipment_asset_schema.sql、
-- migrate_equipment_detection_devices.sql、create_detection_situation_schema.sql。

begin;

create schema if not exists countermeasure;
comment on schema countermeasure is '真实反制设备控制、状态确认和审计数据域。';

do $$
begin
  if not exists(select 1 from pg_roles where rolname='countermeasure_worker') then
    create role countermeasure_worker nologin;
  end if;
end;
$$;

alter role countermeasure_worker nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls;

create table if not exists countermeasure.control_authorization (
  asset_id bigint not null,
  capability_code text not null default 'radio_jamming',
  enabled boolean not null default false,
  valid_from timestamptz,
  valid_to timestamptz,
  max_operation_seconds integer not null default 60 check(max_operation_seconds between 1 and 60),
  device_hard_protection_seconds integer not null default 120 check(device_hard_protection_seconds >= 60),
  allowed_modes text[] not null default array['omnidirectional_frequency','target_coordinate'],
  allowed_frequencies_mhz numeric[] not null default array[2400,5200,5800]::numeric[],
  updated_by_sub text not null,
  updated_by_username text,
  updated_at timestamptz not null default now(),
  primary key(asset_id,capability_code),
  foreign key(asset_id,capability_code)
    references equipment.asset_capability(asset_id,capability_code) on delete cascade,
  check(capability_code='radio_jamming'),
  check(valid_from is null or valid_to is null or valid_from<valid_to),
  check(allowed_modes <@ array['omnidirectional_frequency','target_coordinate']::text[]),
  check(cardinality(allowed_modes)>0),
  check(allowed_frequencies_mhz <@ array[2400,5200,5800]::numeric[]),
  check(cardinality(allowed_frequencies_mhz)>0)
);
comment on table countermeasure.control_authorization is '设备真实功放控制的显式授权白名单和单次操作限制。';
comment on column countermeasure.control_authorization.asset_id is '获得真实控制授权的统一设备资产 ID。';
comment on column countermeasure.control_authorization.capability_code is '获得授权的设备能力编码，当前固定为 radio_jamming。';
comment on column countermeasure.control_authorization.enabled is '是否允许创建新的开启操作；不影响关闭操作。';
comment on column countermeasure.control_authorization.max_operation_seconds is '业务允许的单次最长开启时间，单位秒，最大 60。';
comment on column countermeasure.control_authorization.device_hard_protection_seconds is '设备侧硬保护时间，单位秒；当前为 120，不能替代 60 秒业务上限。';
comment on column countermeasure.control_authorization.allowed_modes is '允许的控制模式数组。';
comment on column countermeasure.control_authorization.allowed_frequencies_mhz is '允许的功放频率白名单，单位 MHz。';

-- 只有显式白名单能力可以突破敏感设备默认的 recommendable 上限。
create or replace function equipment.limit_sensitive_device_access()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id=new.asset_id;
  if v_category in ('counter_uas','jamming_device','directed_energy_device')
     and new.access_level not in ('observable','recommendable') then
    if not (v_category='counter_uas' and new.capability_code='radio_jamming'
      and new.access_level='controllable' and exists(
        select 1 from countermeasure.control_authorization x
        where x.asset_id=new.asset_id and x.capability_code=new.capability_code
      )) then
      raise exception 'sensitive equipment capability access level cannot exceed recommendable without control authorization';
    end if;
  end if;
  return new;
end;
$$;
comment on function equipment.limit_sensitive_device_access() is '限制敏感设备直接控制；仅允许授权表中已登记的无线电干扰能力设为可控制。返回触发器记录。';

create or replace function equipment.limit_counter_uas_access()
returns trigger language plpgsql as $$
declare v_category text;
begin
  select category_code into v_category from equipment.asset where id=new.asset_id;
  if v_category='counter_uas' and new.access_level not in ('observable','recommendable') then
    if not (new.capability_code='radio_jamming' and new.access_level='controllable' and exists(
      select 1 from countermeasure.control_authorization x
      where x.asset_id=new.asset_id and x.capability_code=new.capability_code
    )) then
      raise exception 'counter-UAS capability access level cannot exceed recommendable without control authorization';
    end if;
  end if;
  return new;
end;
$$;
comment on function equipment.limit_counter_uas_access() is '兼容旧触发器并限制反无设备直接控制；授权的无线电干扰能力可以设为可控制。返回触发器记录。';

create table if not exists countermeasure.amplifier_operation (
  id uuid primary key default auth.generate_uuid_v4(),
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  mode text not null check(mode in ('omnidirectional_frequency','target_coordinate')),
  state text not null check(state in (
    'queued','dispatching','awaiting_on_confirmation','active','stop_queued',
    'awaiting_off_confirmation','awaiting_duration_expiry','stopped','failed','unknown'
  )),
  terminal_at timestamptz,
  requested_frequencies_mhz numeric[] not null,
  requested_duration_seconds integer not null check(requested_duration_seconds between 1 and 60),
  reason text not null check(btrim(reason)<>''),
  request_fingerprint text not null,
  idempotency_key text not null check(btrim(idempotency_key)<>''),
  target_longitude numeric check(target_longitude is null or target_longitude between -180 and 180),
  target_latitude numeric check(target_latitude is null or target_latitude between -90 and 90),
  target_coordinate_system text,
  target_observed_at timestamptz,
  target_track_id bigint references situation.target_track(id) on delete restrict,
  requested_by_sub text not null,
  requested_by_username text,
  requested_at timestamptz not null default clock_timestamp(),
  opening_deadline_at timestamptz not null,
  start_dispatch_attempted_at timestamptz,
  start_dispatched_at timestamptz,
  dispatched_duration_seconds integer check(dispatched_duration_seconds is null or dispatched_duration_seconds between 1 and 60),
  expected_expiry_at timestamptz,
  requested_stop_at timestamptz,
  stop_idempotency_key text,
  hard_deadline_at timestamptz not null,
  confirmed_on_at timestamptz,
  confirmed_off_at timestamptz,
  correlation_quality text check(correlation_quality is null or correlation_quality in ('exact','time_window','unmatched')),
  failure_code text,
  failure_detail text,
  updated_at timestamptz not null default clock_timestamp(),
  unique(requested_by_sub,idempotency_key),
  check(requested_frequencies_mhz <@ array[2400,5200,5800]::numeric[] and cardinality(requested_frequencies_mhz)>0),
  check((mode='target_coordinate' and target_longitude is not null and target_latitude is not null and target_coordinate_system='WGS84')
     or (mode='omnidirectional_frequency' and target_longitude is null and target_latitude is null and target_coordinate_system is null))
);
alter table countermeasure.amplifier_operation add column if not exists stop_idempotency_key text;
alter table countermeasure.amplifier_operation add column if not exists dispatched_duration_seconds integer;
alter table countermeasure.amplifier_operation add column if not exists expected_expiry_at timestamptz;
alter table countermeasure.amplifier_operation add column if not exists opening_deadline_at timestamptz;
update countermeasure.amplifier_operation set opening_deadline_at=hard_deadline_at where opening_deadline_at is null;
alter table countermeasure.amplifier_operation alter column opening_deadline_at set not null;
comment on table countermeasure.amplifier_operation is '操作员发起的一次功放开启及其关闭或到期确认生命周期。';
comment on column countermeasure.amplifier_operation.mode is '控制模式：全向频段或 WGS84 目标坐标。';
comment on column countermeasure.amplifier_operation.state is '平台请求状态，不等同于设备实际开关状态。';
comment on column countermeasure.amplifier_operation.terminal_at is '操作进入 stopped 或不可恢复 failed 的时间；为空表示操作未终结。';
comment on column countermeasure.amplifier_operation.hard_deadline_at is '全向模式为请求后 60 秒截止；目标模式在厂商接受后更新为实际 duration 的预期结束时间。';
comment on column countermeasure.amplifier_operation.opening_deadline_at is '开启指令最晚领取时间，防止排队中的旧请求迟到执行。';
comment on column countermeasure.amplifier_operation.dispatched_duration_seconds is '目标坐标模式实际下发给设备的 duration 秒数，范围 1 至 60。';
comment on column countermeasure.amplifier_operation.expected_expiry_at is '按厂商接受时间和实际下发 duration 计算的目标模式预期结束时间。';
comment on column countermeasure.amplifier_operation.requested_frequencies_mhz is '请求频率数组，单位 MHz。';
comment on column countermeasure.amplifier_operation.target_coordinate_system is '目标坐标系，目标模式固定为 WGS84。';
create unique index if not exists amplifier_operation_one_active_asset_idx
  on countermeasure.amplifier_operation(asset_id) where terminal_at is null;
create index if not exists amplifier_operation_asset_time_idx
  on countermeasure.amplifier_operation(asset_id,requested_at desc);

create table if not exists countermeasure.command_outbox (
  id uuid primary key default auth.generate_uuid_v4(),
  operation_id uuid references countermeasure.amplifier_operation(id) on delete restrict,
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  command_kind text not null check(command_kind in ('amp_start','amp_stop','strike','emergency_amp_stop')),
  priority integer not null default 100,
  canonical_request jsonb not null,
  idempotency_key text not null,
  state text not null default 'queued' check(state in ('queued','processing','retry','completed','failed','ambiguous')),
  available_at timestamptz not null default clock_timestamp(),
  lease_owner text,
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer not null default 0 check(attempt_count>=0),
  max_attempts integer not null default 1 check(max_attempts>0),
  attempt_started_at timestamptz,
  dispatched_at timestamptz,
  http_status integer,
  vendor_status integer,
  sanitized_response jsonb,
  last_error_code text,
  last_error_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique(operation_id,command_kind),
  requested_by_sub text,
  requested_by_username text,
  request_reason text,
  unique(asset_id,idempotency_key)
);
alter table countermeasure.command_outbox add column if not exists requested_by_sub text;
alter table countermeasure.command_outbox add column if not exists requested_by_username text;
alter table countermeasure.command_outbox add column if not exists request_reason text;
comment on table countermeasure.command_outbox is '功放指令的持久化 outbox、领取租约和脱敏发送结果。';
comment on column countermeasure.command_outbox.canonical_request is '已校验的平台规范指令，不含厂商 HTTP 信封和密钥。';
comment on column countermeasure.command_outbox.lease_token is '防止过期 worker 回写新租约结果的随机令牌。';
comment on column countermeasure.command_outbox.sanitized_response is '仅保留 status、msg、serverErrorMsg 的厂商响应。';
comment on column countermeasure.command_outbox.requested_by_sub is '请求该指令的 JWT 主体；计划关闭等系统指令可为空。';
comment on column countermeasure.command_outbox.request_reason is '人工指令的审计原因；系统计划指令可为空。';
create index if not exists command_outbox_due_idx
  on countermeasure.command_outbox(priority,available_at,created_at)
  where state in ('queued','retry','processing');

create table if not exists countermeasure.amplifier_status_event (
  id bigserial primary key,
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  source_system text not null,
  station_id text not null,
  source_asset_id text not null,
  actual_state text not null check(actual_state in ('on','off','unknown')),
  active_frequencies_mhz numeric[] not null default '{}',
  trigger_source text not null default 'unknown' check(trigger_source in ('manual','unattended','unknown','config_status')),
  source_target_id text,
  vendor_duration_seconds integer check(vendor_duration_seconds is null or vendor_duration_seconds between 0 and 120),
  observed_at timestamptz not null,
  received_at timestamptz not null,
  quality_flags text[] not null default '{}',
  raw_payload jsonb not null,
  matched_operation_id uuid references countermeasure.amplifier_operation(id) on delete set null,
  correlation_quality text check(correlation_quality is null or correlation_quality in ('time_window','unmatched')),
  created_at timestamptz not null default clock_timestamp()
);
comment on table countermeasure.amplifier_status_event is 'WebSocket 功放开关状态的追加式原始事件和弱关联结果。';
comment on column countermeasure.amplifier_status_event.actual_state is '厂商 ampStatus 规范化状态：on、off 或 unknown。';
comment on column countermeasure.amplifier_status_event.active_frequencies_mhz is '厂商频率规范为 MHz 后的数组。';
comment on column countermeasure.amplifier_status_event.raw_payload is '厂商 uav_amp_status 原始 payload。';
create index if not exists amplifier_status_event_asset_time_idx
  on countermeasure.amplifier_status_event(asset_id,observed_at desc,id desc);

create table if not exists countermeasure.amplifier_state_current (
  asset_id bigint primary key references equipment.asset(id) on delete cascade,
  actual_state text not null check(actual_state in ('on','off','unknown')),
  active_frequencies_mhz numeric[] not null default '{}',
  trigger_source text not null default 'unknown',
  source_target_id text,
  vendor_duration_seconds integer,
  observed_at timestamptz not null,
  received_at timestamptz not null,
  quality_flags text[] not null default '{}',
  source_event_id bigint references countermeasure.amplifier_status_event(id) on delete set null,
  active_operation_id uuid references countermeasure.amplifier_operation(id) on delete set null,
  correlation_quality text check(correlation_quality is null or correlation_quality in ('time_window','unmatched')),
  updated_at timestamptz not null default clock_timestamp()
);
comment on table countermeasure.amplifier_state_current is '每台设备由 WebSocket 或 config_status 确认的最新功放实际状态。';
comment on column countermeasure.amplifier_state_current.actual_state is '设备实际状态；WebSocket 断开时写 unknown，不能推断为 off。';
comment on column countermeasure.amplifier_state_current.active_operation_id is '按时间窗口弱关联的当前平台操作 ID。';

create table if not exists countermeasure.operation_event (
  id bigserial primary key,
  operation_id uuid not null references countermeasure.amplifier_operation(id) on delete restrict,
  event_type text not null,
  from_state text,
  to_state text,
  actor_type text not null,
  actor_sub text,
  actor_username text,
  reason text,
  details jsonb not null default '{}',
  created_at timestamptz not null default clock_timestamp()
);
comment on table countermeasure.operation_event is '功放操作状态变化、操作人和 worker 行为的追加式审计事件。';
comment on column countermeasure.operation_event.details is '不含密钥的状态变化补充信息。';
create index if not exists operation_event_operation_time_idx
  on countermeasure.operation_event(operation_id,created_at,id);

create table if not exists countermeasure.alert (
  id bigserial primary key,
  asset_id bigint not null references equipment.asset(id) on delete restrict,
  alert_type text not null check(alert_type in ('external_amplifier_activation','stop_confirmation_timeout','business_deadline_exceeded','ambiguous_command_delivery')),
  severity text not null check(severity in ('warning','critical')),
  status text not null default 'open' check(status in ('open','acknowledged','closed')),
  status_event_id bigint references countermeasure.amplifier_status_event(id) on delete set null,
  operation_id uuid references countermeasure.amplifier_operation(id) on delete set null,
  details jsonb not null default '{}',
  created_at timestamptz not null default clock_timestamp(),
  acknowledged_at timestamptz,
  acknowledged_by text
);
comment on table countermeasure.alert is '外部开启、关闭确认超时和指令投递不确定等控制告警。';
comment on column countermeasure.alert.alert_type is '稳定告警类型编码。';

create or replace function countermeasure.reject_append_only_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'countermeasure audit records are append-only';
end;
$$;
comment on function countermeasure.reject_append_only_mutation() is '拒绝功放状态、操作审计和告警记录的更新或删除。返回触发器记录。';

do $$
declare v_table text;
begin
  foreach v_table in array array['amplifier_status_event','operation_event'] loop
    execute format('drop trigger if exists append_only_guard on countermeasure.%I',v_table);
    execute format('create trigger append_only_guard before update or delete on countermeasure.%I for each row execute function countermeasure.reject_append_only_mutation()',v_table);
  end loop;
end;
$$;

create or replace function countermeasure.normalize_amplifier_frequencies(p_values jsonb)
returns numeric[] language plpgsql immutable as $$
declare v_result numeric[];
begin
  if jsonb_typeof(p_values)<>'array' or jsonb_array_length(p_values)=0 then
    raise exception 'frequenciesMhz must be a non-empty array';
  end if;
  select array_agg(distinct v order by v) into v_result
  from (select value::numeric v from jsonb_array_elements_text(p_values)) x;
  if not v_result <@ array[2400,5200,5800]::numeric[] then
    raise exception 'frequenciesMhz supports only 2400, 5200 and 5800';
  end if;
  return v_result;
exception when invalid_text_representation then
  raise exception 'frequenciesMhz must contain numbers';
end;
$$;
comment on function countermeasure.normalize_amplifier_frequencies(jsonb) is '规范化并校验功放频率为去重升序 MHz 数组。返回 numeric[]。';

create or replace function countermeasure.jwt_claims()
returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb)
$$;
comment on function countermeasure.jwt_claims() is '读取当前 PostgREST JWT claims；无请求上下文时返回空对象。';

create or replace function countermeasure.require_actor(p_roles text[])
returns jsonb language plpgsql stable as $$
declare v_claims jsonb:=countermeasure.jwt_claims();
begin
  if nullif(v_claims->>'sub','') is null or not coalesce(v_claims->>'role','')=any(p_roles) then
    raise exception 'countermeasure operation requires an authorized JWT actor' using errcode='42501';
  end if;
  return v_claims;
end;
$$;
comment on function countermeasure.require_actor(text[]) is '要求 JWT 主体和允许的控制角色；返回 claims JSON。';

create or replace function countermeasure.record_operation_event(
  p_operation_id uuid,p_event_type text,p_from_state text,p_to_state text,
  p_actor_type text,p_actor_sub text,p_actor_username text,p_reason text,p_details jsonb default '{}'::jsonb
) returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into countermeasure.operation_event(
    operation_id,event_type,from_state,to_state,actor_type,actor_sub,actor_username,reason,details
  ) values(
    p_operation_id,p_event_type,p_from_state,p_to_state,p_actor_type,p_actor_sub,p_actor_username,p_reason,coalesce(p_details,'{}'::jsonb)
  ) returning id into v_id;
  return v_id;
end;
$$;
comment on function countermeasure.record_operation_event(uuid,text,text,text,text,text,text,text,jsonb) is '追加功放操作审计事件；返回事件 ID。';

create or replace function api.start_amplifier_operation(p_request jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare
  v_claims jsonb:=countermeasure.require_actor(array['admin']);
  v_asset_id bigint;
  v_mode text;
  v_duration integer;
  v_reason text;
  v_key text;
  v_freqs numeric[];
  v_lng numeric;
  v_lat numeric;
  v_target_time timestamptz;
  v_track_id bigint;
  v_now timestamptz:=clock_timestamp();
  v_auth countermeasure.control_authorization%rowtype;
  v_existing countermeasure.amplifier_operation%rowtype;
  v_id uuid;
  v_fp text;
  v_kind text;
  v_source record;
  v_result jsonb;
begin
  if p_request is null or jsonb_typeof(p_request)<>'object' then raise exception 'request must be an object'; end if;
  v_asset_id:=(p_request->>'assetId')::bigint;
  v_mode:=p_request->>'mode';
  v_duration:=(p_request->>'durationSeconds')::integer;
  v_reason:=nullif(btrim(p_request->>'reason'),'');
  v_key:=nullif(btrim(p_request->>'idempotencyKey'),'');
  if v_mode not in ('omnidirectional_frequency','target_coordinate') then raise exception 'unsupported amplifier mode'; end if;
  if v_duration not between 1 and 60 then raise exception 'durationSeconds must be between 1 and 60'; end if;
  if v_reason is null or v_key is null then raise exception 'reason and idempotencyKey are required'; end if;
  v_freqs:=countermeasure.normalize_amplifier_frequencies(p_request->'frequenciesMhz');
  if v_mode='target_coordinate' then
    if p_request#>>'{target,coordinateSystem}' is distinct from 'WGS84' then raise exception 'target coordinateSystem must be WGS84'; end if;
    v_lng:=(p_request#>>'{target,longitude}')::numeric;
    v_lat:=(p_request#>>'{target,latitude}')::numeric;
    if v_lng not between -180 and 180 or v_lat not between -90 and 90 then raise exception 'target coordinate is invalid'; end if;
    v_target_time:=nullif(p_request#>>'{target,observedAt}','')::timestamptz;
    v_track_id:=nullif(p_request#>>'{target,trackId}','')::bigint;
  end if;
  v_fp:=md5(jsonb_build_object('assetId',v_asset_id,'mode',v_mode,'durationSeconds',v_duration,
    'frequenciesMhz',to_jsonb(v_freqs),'longitude',v_lng,'latitude',v_lat,'targetObservedAt',v_target_time,
    'targetTrackId',v_track_id,'reason',v_reason)::text);

  select * into v_existing from countermeasure.amplifier_operation
  where requested_by_sub=v_claims->>'sub' and idempotency_key=v_key;
  if found then
    if v_existing.request_fingerprint<>v_fp then raise exception 'idempotency_conflict'; end if;
    return jsonb_build_object('operationId',v_existing.id,'assetId',v_existing.asset_id,'state',v_existing.state,
      'requestedDurationSeconds',v_existing.requested_duration_seconds,'requestedAt',v_existing.requested_at,
      'hardDeadlineAt',v_existing.hard_deadline_at,'idempotentReplay',true);
  end if;

  perform pg_advisory_xact_lock(8201,v_asset_id::integer);
  -- A concurrent request may have inserted the same key while this request waited for the asset lock.
  select * into v_existing from countermeasure.amplifier_operation
  where requested_by_sub=v_claims->>'sub' and idempotency_key=v_key;
  if found then
    if v_existing.request_fingerprint<>v_fp then raise exception 'idempotency_conflict'; end if;
    return jsonb_build_object('operationId',v_existing.id,'assetId',v_existing.asset_id,'state',v_existing.state,
      'requestedDurationSeconds',v_existing.requested_duration_seconds,'requestedAt',v_existing.requested_at,
      'hardDeadlineAt',v_existing.hard_deadline_at,'idempotentReplay',true);
  end if;
  select * into v_auth from countermeasure.control_authorization
  where asset_id=v_asset_id and capability_code='radio_jamming' and enabled
    and (valid_from is null or valid_from<=v_now) and (valid_to is null or valid_to>v_now);
  if not found then raise exception 'radio_jamming control authorization is not active' using errcode='42501'; end if;
  if not v_mode=any(v_auth.allowed_modes) then raise exception 'mode is not authorized'; end if;
  if not v_freqs <@ v_auth.allowed_frequencies_mhz then raise exception 'frequency is not authorized'; end if;
  if v_duration>v_auth.max_operation_seconds then raise exception 'duration exceeds authorization'; end if;
  if not exists(select 1 from equipment.asset_capability c where c.asset_id=v_asset_id
    and c.capability_code='radio_jamming' and c.enabled and c.access_level='controllable') then
    raise exception 'asset radio_jamming capability is not controllable';
  end if;
  select min(s.external_station_id) external_station_id,min(s.external_box_code) external_box_code,count(*) source_count into v_source
  from situation.observation_source s join equipment.asset a on a.id=s.asset_id
  where s.asset_id=v_asset_id and s.source_system='radar_cloud' and s.enabled and a.lifecycle_status='active';
  if v_source.source_count<>1 then raise exception 'asset must have exactly one active radar_cloud source mapping'; end if;
  if (select connectivity_status from equipment.asset_status_current where asset_id=v_asset_id) is distinct from 'online' then
    raise exception 'box is not online';
  end if;
  if (select countermeasure_device_online from equipment.counter_uas_telemetry_current where asset_id=v_asset_id) is not true then
    raise exception 'countermeasure device is not online';
  end if;
  if exists(select 1 from countermeasure.amplifier_operation where asset_id=v_asset_id and terminal_at is null) then
    raise exception 'asset already has a nonterminal amplifier operation';
  end if;
  if exists(select 1 from countermeasure.command_outbox where asset_id=v_asset_id and state in ('queued','retry','processing')) then
    raise exception 'asset still has a pending amplifier command';
  end if;

  v_id:=auth.generate_uuid_v4();
  insert into countermeasure.amplifier_operation(
    id,asset_id,mode,state,requested_frequencies_mhz,requested_duration_seconds,reason,
    request_fingerprint,idempotency_key,target_longitude,target_latitude,target_coordinate_system,
    target_observed_at,target_track_id,requested_by_sub,requested_by_username,requested_at,opening_deadline_at,hard_deadline_at
  ) values(
    v_id,v_asset_id,v_mode,'queued',v_freqs,v_duration,v_reason,v_fp,v_key,v_lng,v_lat,
    case when v_mode='target_coordinate' then 'WGS84' end,v_target_time,v_track_id,
    v_claims->>'sub',v_claims->>'username',v_now,v_now+interval '60 seconds',v_now+interval '60 seconds'
  );
  v_kind:=case when v_mode='target_coordinate' then 'strike' else 'amp_start' end;
  insert into countermeasure.command_outbox(
    operation_id,asset_id,command_kind,priority,canonical_request,idempotency_key,max_attempts,
    requested_by_sub,requested_by_username,request_reason
  ) values(
    v_id,v_asset_id,v_kind,100,jsonb_build_object('frequenciesMhz',v_freqs,'durationSeconds',v_duration,
      'targetLongitude',v_lng,'targetLatitude',v_lat,'targetCoordinateSystem',case when v_mode='target_coordinate' then 'WGS84' end),
    'start:'||v_key,1,v_claims->>'sub',v_claims->>'username',v_reason
  );
  perform countermeasure.record_operation_event(v_id,'requested',null,'queued','operator',v_claims->>'sub',v_claims->>'username',v_reason,'{}');
  v_result:=jsonb_build_object('operationId',v_id,'assetId',v_asset_id,'state','queued',
    'requestedDurationSeconds',v_duration,'requestedAt',v_now,'hardDeadlineAt',v_now+interval '60 seconds');
  return v_result;
end;
$$;
comment on function api.start_amplifier_operation(jsonb) is '创建已校验的功放开启操作和同事务 outbox；返回 JSON：operationId、assetId、state、requestedDurationSeconds、requestedAt、hardDeadlineAt。';

create or replace function api.stop_amplifier_operation(
  p_asset_id bigint,p_operation_id uuid,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare
  v_claims jsonb:=countermeasure.require_actor(array['admin']);
  v_op countermeasure.amplifier_operation%rowtype;
  v_start countermeasure.command_outbox%rowtype;
  v_stop countermeasure.command_outbox%rowtype;
  v_now timestamptz:=clock_timestamp();
  v_available_at timestamptz;
begin
  if nullif(btrim(p_reason),'') is null or nullif(btrim(p_idempotency_key),'') is null then
    raise exception 'reason and idempotency key are required';
  end if;
  perform pg_advisory_xact_lock(8201,p_asset_id::integer);
  select * into v_op from countermeasure.amplifier_operation where id=p_operation_id for update;
  if not found or v_op.asset_id<>p_asset_id then raise exception 'amplifier operation does not exist for asset'; end if;
  if v_op.mode<>'omnidirectional_frequency' then raise exception 'unsupported_operation_mode: strike cannot be stopped by amp action=0'; end if;
  if v_op.stop_idempotency_key is not null then
    if v_op.stop_idempotency_key<>p_idempotency_key then raise exception 'idempotency_conflict'; end if;
    select * into v_stop from countermeasure.command_outbox where operation_id=v_op.id and command_kind='amp_stop';
    return jsonb_strip_nulls(jsonb_build_object('operationId',v_op.id,'commandId',v_stop.id,
      'state',v_op.state,'idempotentReplay',true));
  end if;

  select * into v_start from countermeasure.command_outbox
  where operation_id=v_op.id and command_kind='amp_start' for update;
  if found and v_start.state in ('queued','retry') and v_op.start_dispatch_attempted_at is null then
    update countermeasure.command_outbox set state='failed',last_error_code='cancelled_before_dispatch',
      last_error_at=v_now,updated_at=v_now where id=v_start.id;
    update countermeasure.amplifier_operation set state='stopped',terminal_at=v_now,requested_stop_at=v_now,
      stop_idempotency_key=p_idempotency_key,confirmed_off_at=v_now,updated_at=v_now where id=v_op.id;
    perform countermeasure.record_operation_event(v_op.id,'cancelled_before_dispatch',v_op.state,'stopped','operator',
      v_claims->>'sub',v_claims->>'username',p_reason,jsonb_build_object('startCommandId',v_start.id));
    return jsonb_build_object('operationId',v_op.id,'state','stopped','requestedAt',v_now);
  end if;

  v_available_at:=case when v_start.state='processing' and v_start.lease_expires_at>v_now
    then v_start.lease_expires_at else v_now end;
  update countermeasure.amplifier_operation set state=case when terminal_at is null then 'stop_queued' else state end,
    requested_stop_at=coalesce(requested_stop_at,v_now),stop_idempotency_key=p_idempotency_key,updated_at=v_now where id=v_op.id;
  insert into countermeasure.command_outbox(
    operation_id,asset_id,command_kind,priority,canonical_request,idempotency_key,max_attempts,available_at,
    requested_by_sub,requested_by_username,request_reason
  ) values(
    v_op.id,p_asset_id,'amp_stop',10,jsonb_build_object('frequenciesMhz',v_op.requested_frequencies_mhz),
    'stop:'||p_idempotency_key,7,v_available_at,v_claims->>'sub',v_claims->>'username',p_reason
  ) on conflict(operation_id,command_kind) do update set
    priority=least(countermeasure.command_outbox.priority,excluded.priority),
    available_at=case when countermeasure.command_outbox.state='processing'
      then countermeasure.command_outbox.available_at else least(countermeasure.command_outbox.available_at,excluded.available_at) end,
    state=case when countermeasure.command_outbox.state in ('queued','retry','failed','completed') then 'queued' else countermeasure.command_outbox.state end,
    attempt_count=case when countermeasure.command_outbox.state in ('failed','completed') then 0 else countermeasure.command_outbox.attempt_count end,
    dispatched_at=case when countermeasure.command_outbox.state='completed' then null else countermeasure.command_outbox.dispatched_at end,
    http_status=case when countermeasure.command_outbox.state='completed' then null else countermeasure.command_outbox.http_status end,
    vendor_status=case when countermeasure.command_outbox.state='completed' then null else countermeasure.command_outbox.vendor_status end,
    sanitized_response=case when countermeasure.command_outbox.state='completed' then null else countermeasure.command_outbox.sanitized_response end,
    idempotency_key=excluded.idempotency_key,requested_by_sub=excluded.requested_by_sub,
    requested_by_username=excluded.requested_by_username,request_reason=excluded.request_reason,updated_at=v_now
  returning * into v_stop;
  perform countermeasure.record_operation_event(v_op.id,'manual_stop_requested',v_op.state,
    case when v_op.terminal_at is null then 'stop_queued' else v_op.state end,'operator',
    v_claims->>'sub',v_claims->>'username',p_reason,jsonb_build_object('commandId',v_stop.id));
  return jsonb_build_object('operationId',v_op.id,'commandId',v_stop.id,
    'state',case when v_op.terminal_at is null then 'stop_queued' else v_op.state end,'requestedAt',v_now);
end;
$$;
comment on function api.stop_amplifier_operation(bigint,uuid,text,text) is '为全向功放创建幂等手动关闭指令；strike 返回 unsupported_operation_mode；返回 JSON：operationId、commandId、state、requestedAt。';

create or replace function api.emergency_stop_amplifier(
  p_asset_id bigint,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare
  v_claims jsonb:=countermeasure.require_actor(array['admin']);
  v_command countermeasure.command_outbox%rowtype;
  v_freqs numeric[];
  v_source_count integer;
begin
  if nullif(btrim(p_reason),'') is null or nullif(btrim(p_idempotency_key),'') is null then raise exception 'reason and idempotency key are required'; end if;
  perform pg_advisory_xact_lock(8201,p_asset_id::integer);
  select allowed_frequencies_mhz into v_freqs from countermeasure.control_authorization
    where asset_id=p_asset_id and capability_code='radio_jamming';
  if v_freqs is null or not exists(select 1 from equipment.asset_capability
    where asset_id=p_asset_id and capability_code='radio_jamming') then
    raise exception 'asset has no radio_jamming control configuration';
  end if;
  select count(*) into v_source_count from situation.observation_source
    where asset_id=p_asset_id and source_system='radar_cloud' and enabled;
  if v_source_count<>1 then raise exception 'asset must have exactly one enabled radar_cloud source mapping'; end if;
  select * into v_command from countermeasure.command_outbox
    where asset_id=p_asset_id and idempotency_key='emergency:'||p_idempotency_key for update;
  if found then
    if v_command.requested_by_sub is distinct from v_claims->>'sub'
       or v_command.request_reason is distinct from btrim(p_reason)
       or v_command.canonical_request is distinct from jsonb_build_object('frequenciesMhz',v_freqs) then
      raise exception 'idempotency_conflict';
    end if;
    return jsonb_build_object('commandId',v_command.id,'assetId',p_asset_id,'state',v_command.state,
      'strikeInterruptSupported',false,'requestedBy',v_command.requested_by_sub,'idempotentReplay',true);
  end if;
  insert into countermeasure.command_outbox(
    asset_id,command_kind,priority,canonical_request,idempotency_key,max_attempts,
    requested_by_sub,requested_by_username,request_reason
  ) values(
    p_asset_id,'emergency_amp_stop',0,jsonb_build_object('frequenciesMhz',v_freqs),
    'emergency:'||p_idempotency_key,7,v_claims->>'sub',v_claims->>'username',btrim(p_reason)
  )
  returning * into v_command;
  return jsonb_build_object('commandId',v_command.id,'assetId',p_asset_id,'state',v_command.state,
    'strikeInterruptSupported',false,'requestedBy',v_claims->>'sub');
end;
$$;
comment on function api.emergency_stop_amplifier(bigint,text,text) is '创建全频段高优先级 amp action=0；不能中止 strike；返回 JSON：commandId、assetId、state、strikeInterruptSupported、requestedBy。';

create or replace function countermeasure.claim_next_amplifier_command(p_worker_id text,p_lease_seconds integer)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare
  v_cmd countermeasure.command_outbox%rowtype;
  v_op countermeasure.amplifier_operation%rowtype;
  v_token uuid;
  v_now timestamptz:=clock_timestamp();
  v_source record;
  v_source_count integer;
  v_stop_at timestamptz;
  v_duration integer;
begin
  if nullif(btrim(p_worker_id),'') is null or p_lease_seconds not between 5 and 30 then raise exception 'invalid worker lease'; end if;

  -- A maxed-out expired lease is an uncertain delivery, never an implicit retry.
  select * into v_cmd from countermeasure.command_outbox
  where state='processing' and lease_expires_at<=v_now and attempt_count>=max_attempts
  order by priority,lease_expires_at,created_at for update skip locked limit 1;
  if found then
    update countermeasure.command_outbox set state=case when command_kind in ('amp_start','strike') then 'ambiguous' else 'failed' end,
      last_error_code='worker_lease_expired',last_error_at=v_now,lease_owner=null,lease_token=null,
      lease_expires_at=null,updated_at=v_now where id=v_cmd.id;
    if v_cmd.operation_id is not null then
      select * into v_op from countermeasure.amplifier_operation where id=v_cmd.operation_id for update;
      update countermeasure.amplifier_operation set state='unknown',failure_code='worker_lease_expired',updated_at=v_now where id=v_op.id;
      perform countermeasure.record_operation_event(v_op.id,'worker_lease_expired',v_op.state,'unknown','worker',null,null,null,
        jsonb_build_object('commandId',v_cmd.id,'commandKind',v_cmd.command_kind));
    end if;
    insert into countermeasure.alert(asset_id,alert_type,severity,operation_id,details)
    values(v_cmd.asset_id,'ambiguous_command_delivery','critical',v_cmd.operation_id,
      jsonb_build_object('commandId',v_cmd.id,'commandKind',v_cmd.command_kind,'errorCode','worker_lease_expired'));
    return null;
  end if;

  select * into v_cmd from countermeasure.command_outbox c
  where c.attempt_count<c.max_attempts
    and ((c.state in ('queued','retry') and c.available_at<=v_now)
      or (c.state='processing' and c.lease_expires_at<=v_now))
    and not exists(
      select 1 from countermeasure.command_outbox other
      where other.asset_id=c.asset_id and other.id<>c.id and other.state='processing' and other.lease_expires_at>v_now
    )
  order by c.priority,c.available_at,c.created_at
  for update skip locked limit 1;
  if not found then return null; end if;
  if not pg_try_advisory_xact_lock(8202,v_cmd.asset_id::integer) then return null; end if;
  if exists(
    select 1 from countermeasure.command_outbox other
    where other.asset_id=v_cmd.asset_id and other.id<>v_cmd.id
      and other.state='processing' and other.lease_expires_at>v_now
  ) then return null; end if;
  if v_cmd.operation_id is not null then
    select * into v_op from countermeasure.amplifier_operation where id=v_cmd.operation_id for update;
    if v_cmd.command_kind in ('amp_start','strike') and v_op.opening_deadline_at<=v_now then
      update countermeasure.command_outbox set state='failed',last_error_code='opening_deadline_expired',last_error_at=v_now,updated_at=v_now where id=v_cmd.id;
      update countermeasure.amplifier_operation set state='failed',terminal_at=v_now,failure_code='opening_deadline_expired',updated_at=v_now where id=v_op.id;
      perform countermeasure.record_operation_event(v_op.id,'opening_deadline_expired',v_op.state,'failed','worker',null,null,null,'{}');
      return null;
    end if;
    if v_cmd.command_kind='amp_stop' and v_op.terminal_at is not null then
      update countermeasure.command_outbox set state='failed',last_error_code='stale_stop_for_terminal_operation',
        last_error_at=v_now,updated_at=v_now where id=v_cmd.id;
      return null;
    end if;
  end if;
  v_token:=auth.generate_uuid_v4();
  update countermeasure.command_outbox set state='processing',lease_owner=p_worker_id,lease_token=v_token,
    lease_expires_at=v_now+make_interval(secs=>p_lease_seconds),attempt_count=attempt_count+1,
    attempt_started_at=v_now,updated_at=v_now where id=v_cmd.id returning * into v_cmd;
  if v_cmd.operation_id is not null and v_cmd.command_kind='amp_stop' then
    update countermeasure.amplifier_operation set state='stop_queued',requested_stop_at=coalesce(requested_stop_at,v_now),
      updated_at=v_now where id=v_op.id;
    if v_op.state<>'stop_queued' then
      perform countermeasure.record_operation_event(v_op.id,'scheduled_stop_dispatch_started',v_op.state,'stop_queued',
        'worker',null,null,null,jsonb_build_object('commandId',v_cmd.id));
    end if;
  end if;
  if v_cmd.operation_id is not null and v_cmd.command_kind in ('amp_start','strike') then
    update countermeasure.amplifier_operation set state='dispatching',start_dispatch_attempted_at=coalesce(start_dispatch_attempted_at,v_now),updated_at=v_now where id=v_op.id;
    perform countermeasure.record_operation_event(v_op.id,'dispatch_started',v_op.state,'dispatching','worker',null,null,null,
      jsonb_build_object('commandId',v_cmd.id,'attempt',v_cmd.attempt_count));
    if v_cmd.command_kind='amp_start' then
      v_stop_at:=least(v_now+make_interval(secs=>v_op.requested_duration_seconds),v_op.hard_deadline_at);
      insert into countermeasure.command_outbox(operation_id,asset_id,command_kind,priority,canonical_request,idempotency_key,state,available_at,max_attempts)
      values(v_op.id,v_op.asset_id,'amp_stop',5,jsonb_build_object('frequenciesMhz',v_op.requested_frequencies_mhz),
        'scheduled-stop:'||v_op.id,'queued',v_stop_at,7)
      on conflict(operation_id,command_kind) do update set available_at=least(countermeasure.command_outbox.available_at,excluded.available_at);
    else
      v_duration:=v_op.requested_duration_seconds;
      update countermeasure.command_outbox set canonical_request=jsonb_set(canonical_request,'{durationSeconds}',to_jsonb(v_duration)),
        updated_at=v_now where id=v_cmd.id returning * into v_cmd;
    end if;
  end if;
  select min(external_station_id) external_station_id,min(external_box_code) external_box_code,count(*) source_count
    into v_source from situation.observation_source
    where asset_id=v_cmd.asset_id and source_system='radar_cloud' and enabled;
  v_source_count:=v_source.source_count;
  if v_source_count<>1 then
    update countermeasure.command_outbox set state='failed',last_error_code='invalid_radar_cloud_routing',
      last_error_at=v_now,lease_owner=null,lease_token=null,lease_expires_at=null,updated_at=v_now where id=v_cmd.id;
    if v_cmd.operation_id is not null then
      update countermeasure.amplifier_operation set state=case when v_cmd.command_kind in ('amp_start','strike') then 'failed' else 'unknown' end,
        terminal_at=case when v_cmd.command_kind in ('amp_start','strike') then v_now else terminal_at end,
        failure_code='invalid_radar_cloud_routing',updated_at=v_now where id=v_cmd.operation_id;
      if v_cmd.command_kind='amp_start' then
        update countermeasure.command_outbox set state='failed',last_error_code='opening_command_failed',
          last_error_at=v_now,updated_at=v_now
        where operation_id=v_cmd.operation_id and command_kind='amp_stop' and state in ('queued','retry');
      end if;
      perform countermeasure.record_operation_event(v_cmd.operation_id,'routing_invalid',v_op.state,
        case when v_cmd.command_kind in ('amp_start','strike') then 'failed' else 'unknown' end,
        'worker',null,null,null,jsonb_build_object('commandId',v_cmd.id));
    end if;
    return null;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'commandId',v_cmd.id,'leaseToken',v_token,'commandKind',v_cmd.command_kind,'attemptCount',v_cmd.attempt_count,
    'stationId',v_source.external_station_id,'boxCode',v_source.external_box_code,
    'frequenciesMhz',v_cmd.canonical_request->'frequenciesMhz',
    'durationSeconds',case when v_cmd.command_kind='strike' then to_jsonb(v_duration) else v_cmd.canonical_request->'durationSeconds' end,
    'targetLongitude',v_cmd.canonical_request->'targetLongitude','targetLatitude',v_cmd.canonical_request->'targetLatitude',
    'targetCoordinateSystem',v_cmd.canonical_request->'targetCoordinateSystem'
  ));
end;
$$;
comment on function countermeasure.claim_next_amplifier_command(text,integer) is '使用 FOR UPDATE SKIP LOCKED 领取一条到期指令；全向开启在 HTTP 前持久化关闭计划；返回 JSON 指令和租约。';

create or replace function countermeasure.complete_amplifier_command(
  p_command_id uuid,p_lease_token uuid,p_http_status integer,p_response jsonb
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare v_cmd countermeasure.command_outbox%rowtype; v_old text; v_new text; v_now timestamptz:=clock_timestamp();
begin
  select * into v_cmd from countermeasure.command_outbox where id=p_command_id for update;
  if not found or v_cmd.state<>'processing' or v_cmd.lease_token is distinct from p_lease_token
     or v_cmd.lease_expires_at<=v_now then raise exception 'command lease is stale'; end if;
  if p_http_status<>200 or coalesce((p_response->>'status')::integer,-1)<>200 then raise exception 'vendor response is not successful'; end if;
  update countermeasure.command_outbox set state='completed',dispatched_at=v_now,http_status=p_http_status,
    vendor_status=(p_response->>'status')::integer,sanitized_response=jsonb_build_object('status',p_response->'status','msg',p_response->'msg','serverErrorMsg',p_response->'serverErrorMsg'),
    lease_owner=null,lease_token=null,lease_expires_at=null,updated_at=v_now where id=v_cmd.id;
  if v_cmd.operation_id is not null then
    select state into v_old from countermeasure.amplifier_operation where id=v_cmd.operation_id for update;
    update countermeasure.amplifier_operation set
      state=case
        when v_cmd.command_kind in ('amp_start','strike') and state in ('queued','dispatching') then 'awaiting_on_confirmation'
        when v_cmd.command_kind='amp_stop' and state='stop_queued' then 'awaiting_off_confirmation'
        else state
      end,
      start_dispatched_at=case when v_cmd.command_kind in ('amp_start','strike') then coalesce(start_dispatched_at,v_now) else start_dispatched_at end,
      dispatched_duration_seconds=case when v_cmd.command_kind='strike'
        then (v_cmd.canonical_request->>'durationSeconds')::integer else dispatched_duration_seconds end,
      expected_expiry_at=case when v_cmd.command_kind='strike'
        then v_now+make_interval(secs=>(v_cmd.canonical_request->>'durationSeconds')::integer)
        else expected_expiry_at end,
      hard_deadline_at=case when v_cmd.command_kind='strike'
        then v_now+make_interval(secs=>(v_cmd.canonical_request->>'durationSeconds')::integer)
        else hard_deadline_at end,
      updated_at=v_now where id=v_cmd.operation_id returning state into v_new;
    if v_cmd.command_kind='amp_start' and v_new='stop_queued' then
      update countermeasure.command_outbox set available_at=least(available_at,v_now),priority=least(priority,10),updated_at=v_now
      where operation_id=v_cmd.operation_id and command_kind='amp_stop' and state in ('queued','retry');
    end if;
    perform countermeasure.record_operation_event(v_cmd.operation_id,'vendor_accepted',v_old,v_new,'worker',null,null,null,
      jsonb_build_object('commandId',v_cmd.id,'httpStatus',p_http_status));
  end if;
  return jsonb_build_object('commandId',v_cmd.id,'state','completed','dispatchedAt',v_now);
end;
$$;
comment on function countermeasure.complete_amplifier_command(uuid,uuid,integer,jsonb) is '校验租约并记录 HTTP 200 且 body.status=200 的已下发结果；不确认设备开关；返回 JSON。';

create or replace function countermeasure.fail_amplifier_command(
  p_command_id uuid,p_lease_token uuid,p_error_code text,p_ambiguous boolean,p_retry_seconds double precision
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare v_cmd countermeasure.command_outbox%rowtype; v_now timestamptz:=clock_timestamp(); v_state text;
begin
  select * into v_cmd from countermeasure.command_outbox where id=p_command_id for update;
  if not found or v_cmd.state<>'processing' or v_cmd.lease_token is distinct from p_lease_token
     or v_cmd.lease_expires_at<=v_now then raise exception 'command lease is stale'; end if;
  if v_cmd.command_kind in ('amp_stop','emergency_amp_stop') and p_retry_seconds is not null and v_cmd.attempt_count<v_cmd.max_attempts then
    update countermeasure.command_outbox set state='retry',available_at=v_now+make_interval(secs=>p_retry_seconds),
      last_error_code=p_error_code,last_error_at=v_now,lease_owner=null,lease_token=null,lease_expires_at=null,updated_at=v_now where id=v_cmd.id;
    return jsonb_build_object('commandId',v_cmd.id,'state','retry');
  end if;
  v_state:=case when p_ambiguous then 'ambiguous' else 'failed' end;
  update countermeasure.command_outbox set state=v_state,last_error_code=p_error_code,last_error_at=v_now,
    lease_owner=null,lease_token=null,lease_expires_at=null,updated_at=v_now where id=v_cmd.id;
  if v_cmd.operation_id is not null then
    update countermeasure.amplifier_operation set state=case when p_ambiguous then 'unknown' else 'failed' end,
      terminal_at=case when not p_ambiguous and v_cmd.command_kind in ('amp_start','strike') then v_now else terminal_at end,
      failure_code=p_error_code,updated_at=v_now where id=v_cmd.operation_id;
    if not p_ambiguous and v_cmd.command_kind='amp_start' then
      update countermeasure.command_outbox set state='failed',last_error_code='opening_command_failed',
        last_error_at=v_now,updated_at=v_now
      where operation_id=v_cmd.operation_id and command_kind='amp_stop' and state in ('queued','retry');
    end if;
  end if;
  if p_ambiguous then
    insert into countermeasure.alert(asset_id,alert_type,severity,operation_id,details)
    values(v_cmd.asset_id,'ambiguous_command_delivery','critical',v_cmd.operation_id,jsonb_build_object('commandId',v_cmd.id,'errorCode',p_error_code));
  end if;
  return jsonb_build_object('commandId',v_cmd.id,'state',v_state);
end;
$$;
comment on function countermeasure.fail_amplifier_command(uuid,uuid,text,boolean,double precision) is '记录指令失败或不确定投递；仅关闭指令允许有界重试；返回 JSON。';

create or replace function countermeasure.ingest_amplifier_status(p_status jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare
  v_source situation.observation_source%rowtype;
  v_asset_id bigint;
  v_state text:=p_status->>'actualState';
  v_observed timestamptz:=(p_status->>'observedAt')::timestamptz;
  v_received timestamptz:=(p_status->>'receivedAt')::timestamptz;
  v_freqs numeric[];
  v_flags text[];
  v_event_id bigint;
  v_op countermeasure.amplifier_operation%rowtype;
  v_current countermeasure.amplifier_state_current%rowtype;
  v_quality text:='unmatched';
  v_old_state text;
  v_new_state text;
  v_current_asset_id bigint;
  v_is_stale boolean:=false;
begin
  if p_status->>'schemaVersion'<>'1' or p_status->>'sourceSystem'<>'radar_cloud' then raise exception 'unsupported amplifier status schema'; end if;
  if v_state not in ('on','off') then raise exception 'actualState must normalize vendor ampStatus to on or off'; end if;
  select * into v_source from situation.observation_source where source_system='radar_cloud'
    and external_station_id=p_status->>'stationId' and external_box_code=p_status->>'sourceAssetId' and enabled;
  if not found then raise exception 'amplifier status source is not configured'; end if;
  v_asset_id:=v_source.asset_id;
  select coalesce(array_agg(value::numeric order by value::numeric),'{}') into v_freqs from jsonb_array_elements_text(coalesce(p_status->'activeFrequenciesMhz','[]'));
  select coalesce(array_agg(value),'{}') into v_flags from jsonb_array_elements_text(coalesce(p_status->'qualityFlags','[]'));

  select * into v_current from countermeasure.amplifier_state_current where asset_id=v_asset_id for update;
  v_is_stale:=found and (v_current.observed_at,v_current.received_at)>(v_observed,v_received);
  if not v_is_stale then
    select * into v_op from countermeasure.amplifier_operation
    where asset_id=v_asset_id and terminal_at is null and start_dispatch_attempted_at is not null
      and v_received>=start_dispatch_attempted_at
      and ((v_state='on' and v_observed>=start_dispatch_attempted_at
            and state in ('dispatching','awaiting_on_confirmation','active','awaiting_duration_expiry','unknown')
            and cardinality(v_freqs)>0 and requested_frequencies_mhz&&v_freqs)
        or (v_state='off' and ((mode='omnidirectional_frequency' and requested_stop_at is not null
                               and v_observed>=requested_stop_at
                               and state in ('stop_queued','awaiting_off_confirmation','unknown'))
                           or (mode='target_coordinate' and expected_expiry_at is not null
                               and v_observed>=expected_expiry_at))))
    order by requested_at desc limit 1 for update;
    v_quality:=case when found then 'time_window' else 'unmatched' end;
  end if;

  insert into countermeasure.amplifier_status_event(
    asset_id,source_system,station_id,source_asset_id,actual_state,active_frequencies_mhz,trigger_source,
    source_target_id,vendor_duration_seconds,observed_at,received_at,quality_flags,raw_payload,matched_operation_id,correlation_quality
  ) values(
    v_asset_id,'radar_cloud',p_status->>'stationId',p_status->>'sourceAssetId',v_state,v_freqs,
    coalesce(nullif(p_status->>'triggerSource',''),'unknown'),nullif(p_status->>'sourceTargetId',''),
    nullif(p_status->>'vendorDurationSeconds','')::integer,v_observed,v_received,v_flags,coalesce(p_status->'rawPayload','{}'),v_op.id,v_quality
  ) returning id into v_event_id;
  insert into countermeasure.amplifier_state_current(
    asset_id,actual_state,active_frequencies_mhz,trigger_source,source_target_id,vendor_duration_seconds,
    observed_at,received_at,quality_flags,source_event_id,active_operation_id,correlation_quality
  ) values(
    v_asset_id,v_state,v_freqs,coalesce(nullif(p_status->>'triggerSource',''),'unknown'),nullif(p_status->>'sourceTargetId',''),
    nullif(p_status->>'vendorDurationSeconds','')::integer,v_observed,v_received,v_flags,v_event_id,v_op.id,v_quality
  ) on conflict(asset_id) do update set
    actual_state=excluded.actual_state,active_frequencies_mhz=excluded.active_frequencies_mhz,
    trigger_source=excluded.trigger_source,source_target_id=excluded.source_target_id,
    vendor_duration_seconds=excluded.vendor_duration_seconds,observed_at=excluded.observed_at,
    received_at=excluded.received_at,quality_flags=excluded.quality_flags,source_event_id=excluded.source_event_id,
    active_operation_id=excluded.active_operation_id,correlation_quality=excluded.correlation_quality,updated_at=clock_timestamp()
  where (countermeasure.amplifier_state_current.observed_at,countermeasure.amplifier_state_current.received_at,
         coalesce(countermeasure.amplifier_state_current.source_event_id,0))
      < (excluded.observed_at,excluded.received_at,coalesce(excluded.source_event_id,0))
  returning asset_id into v_current_asset_id;
  if v_current_asset_id is not null and v_op.id is not null then
    v_old_state:=v_op.state;
    if v_state='on' then
      v_new_state:=case when v_op.mode='target_coordinate' then 'awaiting_duration_expiry' else 'active' end;
      update countermeasure.amplifier_operation set state=v_new_state,
        confirmed_on_at=coalesce(confirmed_on_at,v_observed),correlation_quality='time_window',updated_at=clock_timestamp() where id=v_op.id;
      if v_old_state<>v_new_state then
        perform countermeasure.record_operation_event(v_op.id,'on_confirmed',v_old_state,v_new_state,
          'connector',null,null,null,jsonb_build_object('statusEventId',v_event_id));
      end if;
    else
      update countermeasure.amplifier_operation set state='stopped',terminal_at=v_observed,confirmed_off_at=v_observed,
        correlation_quality='time_window',updated_at=clock_timestamp() where id=v_op.id;
      if v_old_state<>'stopped' then
        perform countermeasure.record_operation_event(v_op.id,'off_confirmed',v_old_state,'stopped','connector',null,null,null,
          jsonb_build_object('statusEventId',v_event_id));
      end if;
    end if;
  elsif v_current_asset_id is not null and v_state='on' and v_op.id is null
        and not exists(select 1 from countermeasure.amplifier_operation where asset_id=v_asset_id and terminal_at is null) then
    insert into countermeasure.alert(asset_id,alert_type,severity,status_event_id,details)
    values(v_asset_id,'external_amplifier_activation','critical',v_event_id,jsonb_build_object('stationId',p_status->>'stationId'));
  end if;
  return jsonb_build_object('status',case when v_is_stale then 'stale' else 'accepted' end,
    'assetId',v_asset_id,'eventId',v_event_id,'operationId',v_op.id,'correlationQuality',v_quality);
end;
$$;
comment on function countermeasure.ingest_amplifier_status(jsonb) is '接收规范化 uav_amp_status，追加事件、更新实际状态并弱关联操作；返回 JSON：status、assetId、eventId、operationId、correlationQuality。';

create or replace function countermeasure.mark_amplifier_source_unknown(
  p_source_system text,p_station_id text,p_disconnected_at timestamptz
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare v_count integer;
begin
  update countermeasure.amplifier_state_current c set actual_state='unknown',active_frequencies_mhz='{}',
    observed_at=p_disconnected_at,received_at=p_disconnected_at,quality_flags=array['websocket_disconnected'],updated_at=clock_timestamp()
  from situation.observation_source s where s.asset_id=c.asset_id and s.source_system=p_source_system
    and s.external_station_id=p_station_id and c.received_at<=p_disconnected_at;
  get diagnostics v_count=row_count;
  update countermeasure.amplifier_operation o set state='unknown',updated_at=clock_timestamp()
  where o.asset_id in(select asset_id from situation.observation_source where source_system=p_source_system and external_station_id=p_station_id)
    and o.terminal_at is null and o.state not in ('queued','dispatching');
  return jsonb_build_object('status','accepted','updatedAssets',v_count);
end;
$$;
comment on function countermeasure.mark_amplifier_source_unknown(text,text,timestamptz) is 'WebSocket 断开时把该来源功放状态标记为 unknown，不推断为 off；返回 JSON：status、updatedAssets。';

create or replace function countermeasure.reconcile_amplifier_from_config_status()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare v_state text; v_op countermeasure.amplifier_operation%rowtype; v_current_asset_id bigint;
begin
  v_state:=case when cardinality(new.active_frequencies_mhz)>0 then 'on' else 'off' end;
  insert into countermeasure.amplifier_state_current(
    asset_id,actual_state,active_frequencies_mhz,trigger_source,observed_at,received_at,quality_flags
  ) values(new.asset_id,v_state,new.active_frequencies_mhz,'config_status',new.observed_at,new.received_at,new.quality_flags)
  on conflict(asset_id) do update set actual_state=excluded.actual_state,active_frequencies_mhz=excluded.active_frequencies_mhz,
    trigger_source='config_status',observed_at=excluded.observed_at,received_at=excluded.received_at,
    quality_flags=excluded.quality_flags,source_event_id=null,updated_at=clock_timestamp()
  where countermeasure.amplifier_state_current.received_at<excluded.received_at
  returning asset_id into v_current_asset_id;
  select * into v_op from countermeasure.amplifier_operation where asset_id=new.asset_id and terminal_at is null
    and start_dispatch_attempted_at is not null and new.received_at>=start_dispatch_attempted_at
    and ((v_state='on' and start_dispatched_at is not null and new.observed_at>=start_dispatched_at
          and state in ('awaiting_on_confirmation','active','awaiting_duration_expiry','unknown')
          and cardinality(new.active_frequencies_mhz)>0 and requested_frequencies_mhz&&new.active_frequencies_mhz)
      or (v_state='off' and ((mode='omnidirectional_frequency' and requested_stop_at is not null
                             and new.observed_at>=requested_stop_at
                             and state in ('stop_queued','awaiting_off_confirmation','unknown'))
                         or (mode='target_coordinate' and expected_expiry_at is not null
                             and new.observed_at>=expected_expiry_at))))
    order by requested_at desc limit 1 for update;
  if v_current_asset_id is not null and v_op.id is not null then
    if v_state='on' then
      update countermeasure.amplifier_operation set
        state=case when mode='target_coordinate' then 'awaiting_duration_expiry' else 'active' end,
        confirmed_on_at=coalesce(confirmed_on_at,new.observed_at),correlation_quality='time_window',updated_at=clock_timestamp()
      where id=v_op.id;
      if v_op.state<>(case when v_op.mode='target_coordinate' then 'awaiting_duration_expiry' else 'active' end) then
        perform countermeasure.record_operation_event(v_op.id,'on_reconciled',v_op.state,
          case when v_op.mode='target_coordinate' then 'awaiting_duration_expiry' else 'active' end,
          'connector',null,null,null,'{}');
      end if;
    else
      update countermeasure.amplifier_operation set state='stopped',terminal_at=new.observed_at,confirmed_off_at=new.observed_at,
        correlation_quality='time_window',updated_at=clock_timestamp() where id=v_op.id;
      perform countermeasure.record_operation_event(v_op.id,'off_reconciled',v_op.state,'stopped','connector',null,null,null,'{}');
    end if;
  end if;
  return new;
end;
$$;
comment on function countermeasure.reconcile_amplifier_from_config_status() is '使用每 2 秒 config_status 的 freqsOn 对账当前功放状态，并在关闭时终结操作。返回触发器记录。';
drop trigger if exists amplifier_config_status_reconcile on equipment.counter_uas_telemetry_current;
create trigger amplifier_config_status_reconcile after insert or update on equipment.counter_uas_telemetry_current
for each row execute function countermeasure.reconcile_amplifier_from_config_status();

create or replace function countermeasure.advance_due_amplifier_operations()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare v_now timestamptz:=clock_timestamp(); v_deadlines integer; v_targets integer;
begin
  update countermeasure.command_outbox c set available_at=v_now,priority=0,updated_at=v_now
  from countermeasure.amplifier_operation o
  where c.operation_id=o.id and c.command_kind='amp_stop' and c.state in ('queued','retry')
    and o.terminal_at is null and o.hard_deadline_at<=v_now;
  get diagnostics v_deadlines=row_count;
  insert into countermeasure.alert(asset_id,alert_type,severity,operation_id,details)
  select o.asset_id,'business_deadline_exceeded','critical',o.id,jsonb_build_object('hardDeadlineAt',o.hard_deadline_at)
  from countermeasure.amplifier_operation o where o.mode='omnidirectional_frequency' and o.terminal_at is null
    and o.hard_deadline_at<=v_now and not exists(select 1 from countermeasure.alert a where a.operation_id=o.id and a.alert_type='business_deadline_exceeded');
  insert into countermeasure.alert(asset_id,alert_type,severity,operation_id,details)
  select o.asset_id,'stop_confirmation_timeout','critical',o.id,jsonb_build_object('hardDeadlineAt',o.hard_deadline_at)
  from countermeasure.amplifier_operation o where o.mode='target_coordinate' and o.terminal_at is null
    and o.expected_expiry_at is not null and o.expected_expiry_at+interval '5 seconds'<=v_now
    and not exists(select 1 from countermeasure.alert a where a.operation_id=o.id and a.alert_type='stop_confirmation_timeout');
  update countermeasure.amplifier_state_current c set actual_state='unknown',active_frequencies_mhz='{}',
    quality_flags=array['duration_expiry_not_confirmed'],updated_at=v_now
  where c.asset_id in(select asset_id from countermeasure.amplifier_operation
    where mode='target_coordinate' and terminal_at is null and expected_expiry_at is not null
      and expected_expiry_at+interval '5 seconds'<=v_now);
  update countermeasure.amplifier_operation set state='unknown',failure_code='duration_expiry_not_confirmed',updated_at=v_now
  where mode='target_coordinate' and terminal_at is null and expected_expiry_at is not null
    and expected_expiry_at+interval '5 seconds'<=v_now and state<>'unknown';
  get diagnostics v_targets=row_count;
  return jsonb_build_object('status','advanced','deadlineStops',v_deadlines,'targetTimeouts',v_targets);
end;
$$;
comment on function countermeasure.advance_due_amplifier_operations() is '提升逾期全向关闭优先级，并在 strike 到期未确认时写 unknown；返回 JSON：status、deadlineStops、targetTimeouts。';

create or replace view api.amplifier_state_current as
select c.asset_id,a.asset_code,a.name asset_name,c.actual_state,c.active_frequencies_mhz,c.trigger_source,
  c.source_target_id,c.vendor_duration_seconds,c.observed_at,c.received_at,
  c.received_at<clock_timestamp()-interval '15 seconds' telemetry_stale,
  c.active_operation_id,o.state operation_state,c.correlation_quality,c.updated_at
from countermeasure.amplifier_state_current c
join equipment.asset a on a.id=c.asset_id
left join countermeasure.amplifier_operation o on o.id=c.active_operation_id;
comment on view api.amplifier_state_current is '功放设备实际状态和弱关联操作的只读资源；unknown 不等同于 off。';

create or replace view api.amplifier_operations as
select id,asset_id,mode,state,terminal_at,requested_frequencies_mhz,requested_duration_seconds,reason,
  target_longitude,target_latitude,target_coordinate_system,target_observed_at,target_track_id,
  requested_by_sub,requested_by_username,requested_at,start_dispatched_at,dispatched_duration_seconds,
  expected_expiry_at,requested_stop_at,
  opening_deadline_at,hard_deadline_at,confirmed_on_at,confirmed_off_at,correlation_quality,failure_code,updated_at
from countermeasure.amplifier_operation;
comment on view api.amplifier_operations is '功放操作请求、时限、状态确认和失败码的只读审计资源。';

create or replace view api.amplifier_operation_events as
select id,operation_id,event_type,from_state,to_state,actor_type,actor_sub,actor_username,reason,details,created_at
from countermeasure.operation_event;
comment on view api.amplifier_operation_events is '功放操作状态变化和操作人的追加式只读审计资源。';

-- 仅首次建立资产 82 的能力和授权。重跑迁移不得恢复人工撤销或收紧的授权。
do $$
declare v_asset_id bigint;
begin
  select id into v_asset_id from equipment.asset
  where source_system='radar_cloud' and source_asset_id='b260705174118582';
  if v_asset_id is null or exists(
    select 1 from countermeasure.control_authorization where asset_id=v_asset_id and capability_code='radio_jamming'
  ) then return; end if;
  insert into equipment.asset_capability(asset_id,capability_code,access_level,enabled,parameters)
  values(v_asset_id,'radio_jamming','recommendable',true,jsonb_build_object(
    'control_modes',jsonb_build_array('omnidirectional_frequency','target_coordinate'),
    'omnidirectional_supported',true,'supported_frequencies_mhz',jsonb_build_array(2400,5200,5800),
    'max_operation_seconds',60,'device_hard_protection_seconds',120,'coordinate_system','WGS84'
  )) on conflict(asset_id,capability_code) do nothing;
  insert into countermeasure.control_authorization(
    asset_id,capability_code,enabled,max_operation_seconds,device_hard_protection_seconds,
    allowed_modes,allowed_frequencies_mhz,updated_by_sub,updated_by_username
  ) values(
    v_asset_id,'radio_jamming',true,60,120,array['omnidirectional_frequency','target_coordinate'],
    array[2400,5200,5800]::numeric[],'migration:create_countermeasure_amplifier_schema','database migration'
  );
  update equipment.asset_capability set access_level='controllable',enabled=true where asset_id=v_asset_id and capability_code='radio_jamming';
end;
$$;

revoke all on schema countermeasure from public,anonymous,admin;
revoke all on all tables in schema countermeasure from public,anonymous,admin,countermeasure_worker,detection_ingest;
revoke all on all sequences in schema countermeasure from public,anonymous,admin,countermeasure_worker,detection_ingest;
revoke all on all functions in schema countermeasure from public,anonymous,admin,countermeasure_worker,detection_ingest;
revoke all on function api.start_amplifier_operation(jsonb) from public,anonymous;
revoke all on function api.stop_amplifier_operation(bigint,uuid,text,text) from public,anonymous;
revoke all on function api.emergency_stop_amplifier(bigint,text,text) from public,anonymous;

-- 当前认证模型中所有登录用户使用 admin JWT；登录即可读取并操作显式授权的功放能力。
grant usage on schema api to admin;
grant select on api.amplifier_state_current,api.amplifier_operations,api.amplifier_operation_events to admin;
grant execute on function api.start_amplifier_operation(jsonb) to admin;
grant execute on function api.stop_amplifier_operation(bigint,uuid,text,text) to admin;
grant execute on function api.emergency_stop_amplifier(bigint,text,text) to admin;

grant usage on schema countermeasure to detection_ingest;
grant execute on function countermeasure.ingest_amplifier_status(jsonb) to detection_ingest;
grant execute on function countermeasure.mark_amplifier_source_unknown(text,text,timestamptz) to detection_ingest;

grant usage on schema countermeasure to countermeasure_worker;
grant execute on function countermeasure.claim_next_amplifier_command(text,integer) to countermeasure_worker;
grant execute on function countermeasure.complete_amplifier_command(uuid,uuid,integer,jsonb) to countermeasure_worker;
grant execute on function countermeasure.fail_amplifier_command(uuid,uuid,text,boolean,double precision) to countermeasure_worker;
grant execute on function countermeasure.advance_due_amplifier_operations() to countermeasure_worker;

notify pgrst,'reload schema';
commit;
