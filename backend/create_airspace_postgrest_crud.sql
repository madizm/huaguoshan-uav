-- PostgREST direct CRUD exposure for airspace management tables.
--
-- Endpoints after PostgREST exposes the `airspace` schema:
--   GET    /no_fly_zone        (Accept-Profile: airspace)
--   POST   /no_fly_zone        (Content-Profile: airspace)
--   PATCH  /no_fly_zone?id=eq.N
--   DELETE /no_fly_zone?id=eq.N
--
--   GET    /temp_control_zone  (Accept-Profile: airspace)
--   POST   /temp_control_zone  (Content-Profile: airspace)
--   PATCH  /temp_control_zone?id=eq.N
--   DELETE /temp_control_zone?id=eq.N
--
-- Geometry payload convention used by frontend/tianditu-3d.html:
--   geom is a GeoJSON string, e.g.
--   {"geom":"{\"type\":\"MultiPolygon\",\"coordinates\":[...]}"}
-- PostGIS accepts that string through the geometry input cast, and PostgREST
-- serializes geometry columns back as GeoJSON objects.
--
-- Auto-refresh convention:
--   These triggers only emit NOTIFY airspace_changed. A separate worker
--   (scripts/watch_airspace_refresh.py) listens, debounces changes, and runs the
--   airspace obstacle-grid refresh command outside the user write transaction.
--
-- SECURITY NOTE:
-- This grants web_anon write access for P1 prototyping because permission
-- control is explicitly deferred. Do not use these grants as-is in production.

begin;

grant usage on schema airspace to web_anon;

grant select, insert, update, delete on table airspace.no_fly_zone to web_anon;
grant select, insert, update, delete on table airspace.temp_control_zone to web_anon;

grant usage, select on all sequences in schema airspace to web_anon;

create or replace function airspace.notify_airspace_changed()
returns trigger
language plpgsql
security definer
set search_path = airspace, public, pg_temp
as $$
declare
  v_kind text;
  v_id bigint;
begin
  if TG_TABLE_NAME = 'no_fly_zone' then
    v_kind := 'no_fly_zone';
  elsif TG_TABLE_NAME = 'temp_control_zone' then
    v_kind := 'temp_control';
  else
    v_kind := TG_TABLE_NAME;
  end if;

  v_id := case when TG_OP = 'DELETE' then OLD.id else NEW.id end;

  perform pg_notify(
    'airspace_changed',
    jsonb_build_object(
      'schema', TG_TABLE_SCHEMA,
      'table', TG_TABLE_NAME,
      'kind', v_kind,
      'id', v_id,
      'operation', lower(TG_OP),
      'changed_at', now()
    )::text
  );

  return case when TG_OP = 'DELETE' then OLD else NEW end;
end;
$$;

drop trigger if exists no_fly_zone_airspace_changed on airspace.no_fly_zone;
create trigger no_fly_zone_airspace_changed
after insert or update or delete on airspace.no_fly_zone
for each row execute function airspace.notify_airspace_changed();

drop trigger if exists temp_control_zone_airspace_changed on airspace.temp_control_zone;
create trigger temp_control_zone_airspace_changed
after insert or update or delete on airspace.temp_control_zone
for each row execute function airspace.notify_airspace_changed();

notify pgrst, 'reload schema';

commit;
