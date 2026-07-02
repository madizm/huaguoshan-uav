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
-- SECURITY NOTE:
-- This grants web_anon write access for P1 prototyping because permission
-- control is explicitly deferred. Do not use these grants as-is in production.

begin;

grant usage on schema airspace to web_anon;

grant select, insert, update, delete on table airspace.no_fly_zone to web_anon;
grant select, insert, update, delete on table airspace.temp_control_zone to web_anon;

grant usage, select on all sequences in schema airspace to web_anon;

notify pgrst, 'reload schema';

commit;
