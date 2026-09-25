-- 系统统一配置：通用 key-value 存储，管理端通过 api 视图读写。
-- 初始用途：地图底图配置（原先散落在各组件 localStorage 中）。
begin;

create schema if not exists system;
comment on schema system is '系统级配置与元数据。';
revoke all on schema system from public;
grant usage on schema system to admin;

create table if not exists system.config (
  key text primary key check (length(btrim(key)) between 1 and 120),
  value jsonb not null default '{}'::jsonb,
  description text not null default '',
  updated_at timestamptz not null default now()
);
comment on table system.config is '系统统一配置表，以 key-value 形式存储全局设置。';
comment on column system.config.key is '配置项编码，全局唯一，如 map.basemap。';
comment on column system.config.value is '配置值，JSON 格式。';
comment on column system.config.description is '配置项中文说明。';
comment on column system.config.updated_at is '最后修改时间。';

-- 初始底图配置：默认 OSM，天地图令牌为空。
insert into system.config (key, value, description)
values ('map.basemap', '{"provider":"osm","tiandituToken":"","customUrl":""}'::jsonb, '地图底图配置：provider 可选 osm/tianditu/custom/none，tiandituToken 天地图访问令牌，customUrl 自定义 XYZ 瓦片地址。')
on conflict (key) do nothing;

-- API 视图：直接暴露 system.config 供 PostgREST CRUD。
create or replace view api.system_config as
select key, value, description, updated_at
from system.config;
comment on view api.system_config is '系统统一配置读写视图；按 key 查询或修改。';
comment on column api.system_config.key is '配置项编码。';
comment on column api.system_config.value is '配置值 JSON。';
comment on column api.system_config.description is '配置项说明。';
comment on column api.system_config.updated_at is '最后修改时间。';

-- 权限
revoke all on system.config from public, anonymous;
revoke all on api.system_config from public, anonymous;
grant select, insert, update, delete on system.config to admin;
grant select, insert, update, delete on api.system_config to admin;

notify pgrst, 'reload schema';
commit;
