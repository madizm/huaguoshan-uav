-- 管理后台只读时钟：时间基准为数据库服务器，不读取浏览器时间。
begin;

create or replace function api.get_system_time()
returns jsonb
language sql
volatile
security invoker
set search_path = pg_catalog
as $$
  select jsonb_build_object(
    'server_time', to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'source', 'database'
  );
$$;
comment on function api.get_system_time() is
  '读取数据库服务器当前时间，只读。返回 JSON 对象：server_time 为 UTC ISO 8601 时间字符串（毫秒精度），source 固定为 database。';

revoke all on function api.get_system_time() from public, anonymous;
grant execute on function api.get_system_time() to admin;

notify pgrst, 'reload schema';
commit;
