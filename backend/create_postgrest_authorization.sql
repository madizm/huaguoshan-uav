-- Centralized PostgREST authorization module.
--
-- Run after application schemas/RPCs are installed. The script is intentionally
-- idempotent: it creates missing roles/schemas/tables and then converges grants
-- so older prototype grants (notably web_anon writes) are tightened again.
--
-- Deployment notes:
--   1. Set the password for postgrest_authenticator outside this file, e.g.
--      ALTER ROLE postgrest_authenticator PASSWORD :'PGRST_DB_PASSWORD';
--   2. Configure PostgREST with db-anon-role = "web_anon" and an HS256
--      jwt-secret supplied by environment-managed configuration.

begin;

create extension if not exists pgcrypto;

create schema if not exists auth;

create table if not exists auth.platform_identity (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  password_hash text not null,
  enabled boolean not null default true,
  display_name text not null,
  permission_level text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz,
  constraint platform_identity_username_not_blank_chk check (btrim(username) <> ''),
  constraint platform_identity_display_name_not_blank_chk check (btrim(display_name) <> ''),
  constraint platform_identity_password_argon2id_chk check (password_hash like '$argon2id$%'),
  constraint platform_identity_permission_level_chk check (
    permission_level in ('airspace_reader', 'flight_planner', 'airspace_admin')
  )
);

comment on schema auth is 'Platform operation identity store for the replaceable PostgREST auth adapter.';
comment on table auth.platform_identity is 'Login identities. Passwords are Argon2id hashes; no plaintext or default password is stored.';
comment on column auth.platform_identity.permission_level is 'Highest platform operation permission mapped by the auth adapter into the JWT role claim.';

create or replace function auth.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists platform_identity_touch_updated_at on auth.platform_identity;
create trigger platform_identity_touch_updated_at
before update on auth.platform_identity
for each row execute function auth.touch_updated_at();

create or replace function auth.jwt_claim(p_name text)
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.' || p_name, true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> p_name
  )
$$;

create or replace function auth.current_actor_sub()
returns text
language sql
stable
as $$
  select auth.jwt_claim('sub')
$$;

create or replace function auth.current_actor_display_name()
returns text
language sql
stable
as $$
  select auth.jwt_claim('display_name')
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'web_anon') then
    create role web_anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'airspace_reader') then
    create role airspace_reader nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'flight_planner') then
    create role flight_planner nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'airspace_admin') then
    create role airspace_admin nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'postgrest_authenticator') then
    create role postgrest_authenticator login noinherit;
  end if;
end;
$$;

grant web_anon, airspace_reader, flight_planner, airspace_admin to postgrest_authenticator;
grant airspace_reader to flight_planner;
grant flight_planner to airspace_admin;

grant usage on schema auth to airspace_reader, flight_planner, airspace_admin;
grant select (id, username, enabled, display_name, permission_level, created_at, updated_at, last_login_at)
  on auth.platform_identity to airspace_reader, flight_planner, airspace_admin;

revoke all on schema auth from public, web_anon;
revoke all on auth.platform_identity from public, web_anon;
revoke all on function auth.jwt_claim(text) from public, web_anon;
revoke all on function auth.current_actor_sub() from public, web_anon;
revoke all on function auth.current_actor_display_name() from public, web_anon;
grant execute on function auth.jwt_claim(text) to airspace_reader, flight_planner, airspace_admin;
grant execute on function auth.current_actor_sub() to airspace_reader, flight_planner, airspace_admin;
grant execute on function auth.current_actor_display_name() to airspace_reader, flight_planner, airspace_admin;

-- Airspace constraints: anonymous/readers can read; only admins can insert/update;
-- no PostgREST role receives physical delete.
grant usage on schema airspace to web_anon, airspace_reader, flight_planner, airspace_admin;
do $$
begin
  if to_regclass('airspace.no_fly_zone') is not null then
    revoke insert, update, delete on airspace.no_fly_zone from web_anon, airspace_reader, flight_planner, airspace_admin;
    grant select on airspace.no_fly_zone to web_anon, airspace_reader, flight_planner, airspace_admin;
    grant insert, update on airspace.no_fly_zone to airspace_admin;
  end if;

  if to_regclass('airspace.temp_control_zone') is not null then
    revoke insert, update, delete on airspace.temp_control_zone from web_anon, airspace_reader, flight_planner, airspace_admin;
    grant select on airspace.temp_control_zone to web_anon, airspace_reader, flight_planner, airspace_admin;
    grant insert, update on airspace.temp_control_zone to airspace_admin;
  end if;
end;
$$;
grant usage, select on all sequences in schema airspace to airspace_admin;

-- Flight planning: converge away from prototype direct table writes. The full
-- ownership-aware RPC tightening is implemented in the auth adapter slice; this
-- deployment slice makes direct writes unavailable to anonymous/read-only roles.
grant usage on schema flight_path to airspace_reader, flight_planner, airspace_admin;
do $$
begin
  if to_regclass('flight_path.plan') is not null then
    revoke insert, update, delete on flight_path.plan from web_anon, airspace_reader, flight_planner, airspace_admin;
    grant select on flight_path.plan to airspace_reader, flight_planner, airspace_admin;
  end if;
  if to_regclass('flight_path.plan_point') is not null then
    revoke insert, update, delete on flight_path.plan_point from web_anon, airspace_reader, flight_planner, airspace_admin;
    grant select on flight_path.plan_point to airspace_reader, flight_planner, airspace_admin;
  end if;
  if to_regclass('flight_path.plan_result') is not null then
    revoke insert, update, delete on flight_path.plan_result from web_anon, airspace_reader, flight_planner, airspace_admin;
    grant select on flight_path.plan_result to airspace_reader, flight_planner, airspace_admin;
  end if;
end;
$$;

-- Public display RPC allowlist remains available anonymously. Protected flight
-- path write RPCs are granted to flight_planner and inherited by airspace_admin.
do $$
begin
  if to_regprocedure('citydb.get_citydb_feature_properties(text)') is not null then
    revoke execute on function citydb.get_citydb_feature_properties(text) from public;
    grant execute on function citydb.get_citydb_feature_properties(text) to web_anon, airspace_reader, flight_planner, airspace_admin;
  end if;
  if to_regprocedure('citydb.get_citydb_feature_gger_grids(text)') is not null then
    revoke execute on function citydb.get_citydb_feature_gger_grids(text) from public;
    grant execute on function citydb.get_citydb_feature_gger_grids(text) to web_anon, airspace_reader, flight_planner, airspace_admin;
  end if;
  if to_regprocedure('citydb.list_flight_obstacles_gger(text, integer, boolean)') is not null then
    revoke execute on function citydb.list_flight_obstacles_gger(text, integer, boolean) from public;
    grant execute on function citydb.list_flight_obstacles_gger(text, integer, boolean) to web_anon, airspace_reader, flight_planner, airspace_admin;
  end if;
  if to_regprocedure('citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean)') is not null then
    revoke execute on function citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean) from public;
    grant execute on function citydb.list_flight_obstacles_gger_lod(text, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, boolean) to web_anon, airspace_reader, flight_planner, airspace_admin;
  end if;

  if to_regprocedure('citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text)') is not null then
    revoke execute on function citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text) from public, web_anon, airspace_reader;
    grant execute on function citydb.create_flight_path_plan(text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb, text) to flight_planner;
  end if;
  if to_regprocedure('citydb.update_flight_path_plan(bigint, text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb)') is not null then
    revoke execute on function citydb.update_flight_path_plan(bigint, text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) from public, web_anon, airspace_reader;
    grant execute on function citydb.update_flight_path_plan(bigint, text, text, integer, double precision, text, timestamptz, jsonb, boolean, double precision, jsonb) to flight_planner;
  end if;
  if to_regprocedure('citydb.archive_flight_path_plan(bigint)') is not null then
    revoke execute on function citydb.archive_flight_path_plan(bigint) from public, web_anon, airspace_reader;
    grant execute on function citydb.archive_flight_path_plan(bigint) to flight_planner;
  end if;
  if to_regprocedure('citydb.compute_flight_path_plan(bigint)') is not null then
    revoke execute on function citydb.compute_flight_path_plan(bigint) from public, web_anon, airspace_reader;
    grant execute on function citydb.compute_flight_path_plan(bigint) to flight_planner;
  end if;
  if to_regprocedure('citydb.delete_flight_path_plan(bigint)') is not null then
    revoke execute on function citydb.delete_flight_path_plan(bigint) from public, web_anon, airspace_reader, flight_planner, airspace_admin;
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
