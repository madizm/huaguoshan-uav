-- 先执行 backend/create_system_time_rpc.sql，再以可 SET ROLE admin 的数据库管理员运行。
\set ON_ERROR_STOP on
begin;

do $$
begin
  assert not has_function_privilege('anonymous', 'api.get_system_time()', 'EXECUTE'),
    '匿名角色不得读取服务器时钟';
  assert has_function_privilege('admin', 'api.get_system_time()', 'EXECUTE'),
    '管理员应有执行权限';
  assert not exists (
    select 1 from pg_proc p,
      lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = 'api.get_system_time()'::regprocedure
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ), 'PUBLIC 不得有执行权限';
end;
$$;

set local role admin;
do $$
declare
  v_result jsonb := api.get_system_time();
  v_first timestamptz := (v_result->>'server_time')::timestamptz;
  v_second timestamptz;
begin
  assert v_result->>'source' = 'database', '应标识数据库时间来源';
  assert v_result->>'server_time' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
    '应返回 UTC 毫秒时间';
  assert abs(extract(epoch from (clock_timestamp() - v_first))) < 2, '应接近数据库当前时间';
  perform pg_sleep(0.05);
  v_second := (api.get_system_time()->>'server_time')::timestamptz;
  assert v_second > v_first, '同一事务内应持续走时，而非固定为事务开始时间';
end;
$$;

rollback;
