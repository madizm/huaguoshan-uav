# Use an API schema and three PostgREST roles

The development database exposes PostgREST through a single `api` schema and three roles: `authenticator` for the database login, `anonymous` for unauthenticated requests with no business access, and `admin` for authenticated JWT requests with full business DML/RPC access but no DDL or superuser capability. We chose this over the previous mix of anonymous, web, airspace, and planner roles because the application is currently a large-screen/admin-style system, but PostgREST still needs a clean separation between connection identity, unauthenticated requests, and authenticated administrative access.

`api` is the only HTTP-facing schema; underlying schemas such as `citydb`, `airspace`, `terrain`, `citydb_grid`, and `flight_path` remain data-layer schemas. Simple airspace configuration objects are exposed as updatable `api` views with their existing table-like names, while complex actions remain RPC functions.
