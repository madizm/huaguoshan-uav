-- Create the minimal credentials foundation for the 认证入口服务.
--
-- This migration intentionally keeps authentication separate from the PostgREST
-- business roles from ADR-0004. The auth_service login role can manage only
-- auth.user_account credentials and receives no privileges on business schemas.

begin;

create schema if not exists auth;
comment on schema auth is 'Credential storage owned by the lightweight authentication entry service.';

create or replace function auth.generate_uuid_v4()
returns uuid
language sql
volatile
as $$
  select (
    substr(v_seed, 1, 8) || '-' ||
    substr(v_seed, 9, 4) || '-4' ||
    substr(v_seed, 14, 3) || '-' ||
    substr('89ab', 1 + floor(random() * 4)::integer, 1) ||
    substr(v_seed, 18, 3) || '-' ||
    substr(v_seed, 21, 12)
  )::uuid
  from (select md5(random()::text || clock_timestamp()::text || txid_current()::text) as v_seed) seed;
$$;

create table if not exists auth.user_account (
  id uuid primary key default auth.generate_uuid_v4(),
  username text not null,
  password_hash text not null,
  enabled boolean not null default true,
  failed_login_count integer not null default 0,
  locked_until timestamptz,
  last_failed_login_at timestamptz,
  last_successful_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_account_username_not_blank check (btrim(username) <> ''),
  constraint user_account_username_unique unique (username),
  constraint user_account_password_hash_argon2id check (password_hash like '$argon2id$%'),
  constraint user_account_failed_login_count_non_negative check (failed_login_count >= 0)
);

comment on table auth.user_account is 'Narrow login credentials table for the 认证入口服务; not a user profile or permission model.';
comment on column auth.user_account.id is 'Stable credential identity used in JWT subject claims as user_account:<uuid>.';
comment on column auth.user_account.password_hash is 'Argon2id PHC password hash; plaintext, reversible passwords, and separate salt columns are forbidden.';
comment on column auth.user_account.failed_login_count is 'Persistent consecutive failed-login counter used for lockout.';
comment on column auth.user_account.locked_until is 'Temporary lockout expiry after repeated failed logins.';

create or replace function auth.touch_user_account_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists user_account_touch_updated_at on auth.user_account;
create trigger user_account_touch_updated_at
before update on auth.user_account
for each row
execute function auth.touch_user_account_updated_at();

-- Dedicated database login role for the 认证入口服务. The password is a local
-- development placeholder and should be overridden in deployment automation.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'auth_service') then
    create role auth_service login noinherit password 'auth_service';
  end if;
end;
$$;

alter role auth_service login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls password 'auth_service';

revoke all on schema auth from public;
revoke all on all tables in schema auth from public;
revoke all on all functions in schema auth from public;

grant usage on schema auth to auth_service;
grant select, insert, update on auth.user_account to auth_service;
grant usage, select on all sequences in schema auth to auth_service;
grant execute on function auth.generate_uuid_v4() to auth_service;
grant execute on function auth.touch_user_account_updated_at() to auth_service;

alter default privileges for role postgres in schema auth revoke all on tables from public;
alter default privileges for role postgres in schema auth grant select, insert, update on tables to auth_service;
alter default privileges for role postgres in schema auth revoke all on functions from public;
alter default privileges for role postgres in schema auth grant execute on functions to auth_service;
alter default privileges for role postgres in schema auth grant usage, select on sequences to auth_service;

-- Belt-and-suspenders separation from PostgREST and business data schemas.
do $$
declare
  v_schema text;
begin
  foreach v_schema in array array['api', 'citydb', 'airspace', 'terrain', 'citydb_grid', 'flight_path'] loop
    if exists (select 1 from pg_namespace where nspname = v_schema) then
      execute format('revoke all on schema %I from auth_service', v_schema);
      execute format('revoke all on all tables in schema %I from auth_service', v_schema);
      execute format('revoke all on all sequences in schema %I from auth_service', v_schema);
      execute format('revoke all on all functions in schema %I from auth_service', v_schema);
    end if;
  end loop;
end;
$$;

commit;
