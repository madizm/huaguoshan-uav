-- 先执行 backend/create_countermeasure_amplifier_schema.sql。
-- 以可 SET ROLE 的数据库管理员运行；全部业务数据在事务末尾回滚。
\set ON_ERROR_STOP on
begin;

-- 权限隔离。
do $$
begin
  assert has_function_privilege('admin','api.start_amplifier_operation(jsonb)','EXECUTE'),
    '登录用户应能开启功放';
  assert has_function_privilege('admin','api.stop_amplifier_operation(bigint,uuid,text,text)','EXECUTE'),
    '登录用户应能关闭全向功放';
  assert has_function_privilege('admin','api.emergency_stop_amplifier(bigint,text,text)','EXECUTE'),
    '登录用户应能紧急关闭全向功放';
  assert not has_function_privilege('anonymous','api.start_amplifier_operation(jsonb)','EXECUTE'),
    '匿名用户不得开启功放';
  assert has_function_privilege('detection_ingest','countermeasure.ingest_amplifier_status(jsonb)','EXECUTE'),
    '侦测接入角色应能写功放状态';
  assert not has_function_privilege('detection_ingest','api.start_amplifier_operation(jsonb)','EXECUTE'),
    '侦测接入角色不得创建指令';
end;
$$;

set local role admin;
set local request.jwt.claims='{"sub":"user_account:integration-user","username":"integration","role":"admin"}';

select api.start_amplifier_operation(jsonb_build_object(
  'assetId',82,
  'mode','omnidirectional_frequency',
  'frequenciesMhz',jsonb_build_array(2400,5200,5800),
  'durationSeconds',5,
  'reason','integration test',
  'idempotencyKey','integration-start-1'
)) operation \gset start_

select (:'start_operation'::jsonb->>'operationId') operation_id \gset start_
select set_config('test.amplifier_operation_id',:'start_operation_id',true);

-- 相同请求幂等返回原操作；不同请求体使用相同 key 必须冲突。
do $$
declare v_result jsonb;
begin
  v_result:=api.start_amplifier_operation(jsonb_build_object(
    'assetId',82,'mode','omnidirectional_frequency','frequenciesMhz',jsonb_build_array(5800,2400,5200),
    'durationSeconds',5,'reason','integration test','idempotencyKey','integration-start-1'));
  assert (v_result->>'idempotentReplay')::boolean, '相同请求应幂等重放';
  begin
    perform api.start_amplifier_operation(jsonb_build_object(
      'assetId',82,'mode','omnidirectional_frequency','frequenciesMhz',jsonb_build_array(2400),
      'durationSeconds',5,'reason','changed','idempotencyKey','integration-start-1'));
    raise exception '相同 key 的不同请求应失败';
  exception when others then
    assert sqlerrm like '%idempotency_conflict%', '应返回 idempotency_conflict';
  end;
end;
$$;

reset role;
set local role countermeasure_worker;
select countermeasure.claim_next_amplifier_command('integration-worker',15) command \gset claim_
select (:'claim_command'::jsonb->>'commandId') command_id,
       (:'claim_command'::jsonb->>'leaseToken') lease_token \gset claim_
reset role;

-- 领取 amp_start 前必须已有持久化 amp_stop。
do $$
begin
  assert exists(
    select 1 from countermeasure.command_outbox
    where operation_id=current_setting('test.amplifier_operation_id')::uuid and command_kind='amp_stop'
  ), 'HTTP 开启前必须持久化关闭计划';
end;
$$;

set local role countermeasure_worker;
select countermeasure.complete_amplifier_command(
  :'claim_command_id'::uuid,:'claim_lease_token'::uuid,200,
  '{"status":200,"msg":"指令已下发","data":null,"serverErrorMsg":null}'::jsonb
);

reset role;
set local role detection_ingest;
select countermeasure.ingest_amplifier_status(jsonb_build_object(
  'schemaVersion',1,'sourceSystem','radar_cloud','stationId','90','sourceAssetId','b260705174118582',
  'actualState','on','activeFrequenciesMhz',jsonb_build_array(2400,5200,5800),
  'triggerSource','manual','observedAt',clock_timestamp(),'receivedAt',clock_timestamp(),
  'qualityFlags','[]'::jsonb,'rawPayload','{"ampStatus":1}'::jsonb
));

reset role;
-- 到期计划关闭在领取时必须写 requested_stop_at 和 stop_queued，才能关联 off 状态。
update countermeasure.command_outbox set available_at=clock_timestamp()
where operation_id=:'start_operation_id'::uuid and command_kind='amp_stop';
set local role countermeasure_worker;
select countermeasure.claim_next_amplifier_command('integration-worker',15) command \gset stop_claim_
select (:'stop_claim_command'::jsonb->>'commandId') command_id,
       (:'stop_claim_command'::jsonb->>'leaseToken') lease_token \gset stop_claim_
reset role;
do $$
begin
  assert exists(select 1 from countermeasure.amplifier_operation
    where id=current_setting('test.amplifier_operation_id')::uuid and state='stop_queued' and requested_stop_at is not null),
    '计划关闭领取时应进入 stop_queued 并记录请求时间';
end;
$$;
set local role countermeasure_worker;
select countermeasure.complete_amplifier_command(
  :'stop_claim_command_id'::uuid,:'stop_claim_lease_token'::uuid,200,
  '{"status":200,"msg":"指令已下发","data":null,"serverErrorMsg":null}'::jsonb
);
reset role;
-- 已下发但未收到 off 确认的计划关闭，允许人工重新排队。
set local role admin;
select api.stop_amplifier_operation(
  82,:'start_operation_id'::uuid,'integration stop','integration-stop-1'
);
reset role;
do $$
begin
  assert exists(select 1 from countermeasure.command_outbox
    where operation_id=current_setting('test.amplifier_operation_id')::uuid and command_kind='amp_stop' and state='queued'),
    '已完成但未确认的关闭应允许人工重新排队';
end;
$$;

-- strike 不允许使用 amp action=0 关闭。
-- 使用独立事务数据前先把上一操作模拟为关闭。
reset role;
update countermeasure.amplifier_operation
set state='stopped',terminal_at=clock_timestamp()
where id=:'start_operation_id'::uuid;
update countermeasure.command_outbox set state='failed',last_error_code='test_cleanup'
where operation_id=:'start_operation_id'::uuid and command_kind='amp_stop';

-- 尚未领取的开启必须被取消，不能先关闭后再发送开启。
set local role admin;
select api.start_amplifier_operation(jsonb_build_object(
  'assetId',82,'mode','omnidirectional_frequency','frequenciesMhz',jsonb_build_array(2400),
  'durationSeconds',5,'reason','cancel before dispatch','idempotencyKey','integration-cancel-start'
)) operation \gset cancel_
select (:'cancel_operation'::jsonb->>'operationId') operation_id \gset cancel_
select set_config('test.cancel_operation_id',:'cancel_operation_id',true);
select api.stop_amplifier_operation(82,:'cancel_operation_id'::uuid,'cancel queued start','integration-cancel-stop');
reset role;
do $$
begin
  assert exists(select 1 from countermeasure.amplifier_operation
    where id=current_setting('test.cancel_operation_id')::uuid and state='stopped' and terminal_at is not null),
    '排队中的开启应直接取消并终结';
  assert exists(select 1 from countermeasure.command_outbox
    where operation_id=current_setting('test.cancel_operation_id')::uuid and command_kind='amp_start'
      and state='failed' and last_error_code='cancelled_before_dispatch'),
    '已取消的开启指令不得再被 worker 领取';
end;
$$;
-- 确定性的开启失败必须同时取消旧操作的计划关闭，避免影响后续操作。
set local role admin;
select api.start_amplifier_operation(jsonb_build_object(
  'assetId',82,'mode','omnidirectional_frequency','frequenciesMhz',jsonb_build_array(2400),
  'durationSeconds',5,'reason','deterministic failure','idempotencyKey','integration-failed-start'
)) operation \gset failed_
select (:'failed_operation'::jsonb->>'operationId') operation_id \gset failed_
select set_config('test.failed_operation_id',:'failed_operation_id',true);
reset role;
set local role countermeasure_worker;
select countermeasure.claim_next_amplifier_command('integration-worker',15) command \gset failed_claim_
select countermeasure.fail_amplifier_command(
  (:'failed_claim_command'::jsonb->>'commandId')::uuid,
  (:'failed_claim_command'::jsonb->>'leaseToken')::uuid,
  'vendor_rejected',false,null
);
reset role;
do $$
begin
  assert exists(select 1 from countermeasure.command_outbox
    where operation_id=current_setting('test.failed_operation_id')::uuid and command_kind='amp_stop'
      and state='failed' and last_error_code='opening_command_failed'),
    '确定性开启失败应取消计划关闭';
end;
$$;
set local role admin;
select api.start_amplifier_operation(jsonb_build_object(
  'assetId',82,'mode','target_coordinate','frequenciesMhz',jsonb_build_array(2400),
  'durationSeconds',60,'target',jsonb_build_object('longitude',119.196054,'latitude',34.591989,'coordinateSystem','WGS84'),
  'reason','integration strike','idempotencyKey','integration-strike-1'
)) operation \gset strike_
select (:'strike_operation'::jsonb->>'operationId') operation_id \gset strike_
select set_config('test.strike_operation_id',:'strike_operation_id',true);

do $$
begin
  begin
    perform api.stop_amplifier_operation(82,current_setting('test.strike_operation_id')::uuid,'invalid stop','integration-strike-stop');
    raise exception 'strike 不应允许 amp stop';
  exception when others then
    assert sqlerrm like '%unsupported_operation_mode%', 'strike 应返回 unsupported_operation_mode';
  end;
end;
$$;


-- 紧急关闭要求有效设备路由，并对同一请求做真实幂等校验。
do $$
declare v_first jsonb; v_replay jsonb;
begin
  v_first:=api.emergency_stop_amplifier(82,'integration emergency','integration-emergency-1');
  v_replay:=api.emergency_stop_amplifier(82,'integration emergency','integration-emergency-1');
  assert v_first->>'commandId'=v_replay->>'commandId', '紧急关闭重放应返回原指令';
  assert (v_replay->>'idempotentReplay')::boolean, '紧急关闭重放应明确标记';
  begin
    perform api.emergency_stop_amplifier(82,'changed emergency reason','integration-emergency-1');
    raise exception '变更后的紧急关闭请求不应复用相同 key';
  exception when others then
    assert sqlerrm like '%idempotency_conflict%', '紧急关闭请求变化应返回 idempotency_conflict';
  end;
end;
$$;

rollback;
