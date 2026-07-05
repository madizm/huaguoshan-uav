# Use a lightweight authentication entry service

The platform will use a lightweight FastAPI-based authentication entry service rather than a full identity and access-management system. The service owns only login credential verification in `auth.user_account`, stores passwords as Argon2id PHC hashes, applies persistent failed-login lockout, and signs short-lived stateless JWTs for PostgREST with `role=admin`; it does not proxy business APIs, manage fine-grained permissions, or revoke sessions in the first version.

Nginx is the unified entry point: `/auth/` routes to the authentication entry service, `/postgrest/` routes to PostgREST, `/docs/` serves an anonymous Scalar documentation portal, and `/` serves the frontend. Scalar replaces Swagger UI as the target API documentation portal; it may be opened anonymously, but the PostgREST business OpenAPI document is loaded with an admin JWT while the authentication service OpenAPI remains anonymously visible.
