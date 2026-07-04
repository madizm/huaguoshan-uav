#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "argon2-cffi>=23.1",
#   "fastapi>=0.115",
#   "psycopg[binary]>=3.2",
#   "PyJWT>=2.8",
#   "uvicorn>=0.30",
# ]
# ///
"""FastAPI 认证入口服务 for PostgREST admin JWT login.

The service is intentionally narrow: it verifies credentials in auth.user_account,
applies persistent failed-login lockout, signs short-lived stateless tokens with
role=admin, and exposes only login, current-user, and health endpoints.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Protocol
from uuid import UUID

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, status
from pydantic import BaseModel, Field

PUBLIC_LOGIN_FAILURE = "Invalid username or password"
ADMIN_ROLE = "admin"
DEFAULT_TOKEN_TTL_SECONDS = 15 * 60
FAILED_LOGIN_LOCK_THRESHOLD = 5
LOCKOUT_SECONDS = 15 * 60


@dataclass(frozen=True)
class AuthSettings:
    jwt_secret: str = field(default_factory=lambda: os.getenv("PGRST_JWT_SECRET", os.getenv("AUTH_JWT_SECRET", "dev-postgrest-jwt-secret-change-me")))
    jwt_issuer: str = field(default_factory=lambda: os.getenv("AUTH_JWT_ISSUER", "huaguoshan-uav-auth"))
    token_ttl_seconds: int = field(default_factory=lambda: int(os.getenv("AUTH_TOKEN_TTL_SECONDS", str(DEFAULT_TOKEN_TTL_SECONDS))))
    database_dsn: str | None = field(default_factory=lambda: os.getenv("AUTH_DATABASE_DSN") or os.getenv("CITYDB_DSN"))
    auth_schema: str = field(default_factory=lambda: os.getenv("AUTH_SCHEMA", "auth"))


@dataclass(frozen=True)
class UserAccount:
    id: UUID
    username: str
    password_hash: str
    enabled: bool
    failed_login_count: int
    locked_until: datetime | None = None


class UserAccountRepository(Protocol):
    def get_by_username_for_update(self, username: str) -> UserAccount | None: ...

    def record_failed_login(self, account_id: UUID, *, failed_count: int, locked_until: datetime | None) -> None: ...

    def record_successful_login(self, account_id: UUID) -> None: ...


class PasswordVerifier(Protocol):
    def verify(self, password_hash: str, password: str) -> bool: ...


class Argon2PasswordVerifier:
    def __init__(self) -> None:
        from argon2 import PasswordHasher
        from argon2.exceptions import VerifyMismatchError, VerificationError

        self._hasher = PasswordHasher()
        self._mismatch_error = VerifyMismatchError
        self._verification_error = VerificationError

    def verify(self, password_hash: str, password: str) -> bool:
        try:
            return bool(self._hasher.verify(password_hash, password))
        except (self._mismatch_error, self._verification_error):
            return False


def _ensure_str(value: str | bytes) -> str:
    """Ensure a value from the database is a Python str."""
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return value


class PgUserAccountRepository:
    def __init__(self, dsn: str, auth_schema: str = "auth") -> None:
        import psycopg
        from psycopg.rows import dict_row

        self._conn = psycopg.connect(dsn, connect_timeout=15, row_factory=dict_row, client_encoding="UTF8")
        self._auth_schema = quote_identifier(auth_schema)

    def close(self) -> None:
        self._conn.close()

    def _table(self) -> str:
        return f'{self._auth_schema}."user_account"'

    def get_by_username_for_update(self, username: str) -> UserAccount | None:
        with self._conn.cursor() as cur:
            cur.execute(
                f"""
                select id, username, password_hash, enabled, failed_login_count, locked_until
                from {self._table()}
                where username = %s
                for update
                """,
                (username,),
            )
            row = cur.fetchone()
        if row is None:
            self._conn.commit()
            return None
        return UserAccount(
            id=row["id"],
            username=_ensure_str(row["username"]),
            password_hash=_ensure_str(row["password_hash"]),
            enabled=row["enabled"],
            failed_login_count=row["failed_login_count"],
            locked_until=row["locked_until"],
        )

    def record_failed_login(self, account_id: UUID, *, failed_count: int, locked_until: datetime | None) -> None:
        with self._conn.cursor() as cur:
            cur.execute(
                f"""
                update {self._table()}
                set failed_login_count = %s,
                    locked_until = %s,
                    last_failed_login_at = now()
                where id = %s
                """,
                (failed_count, locked_until, account_id),
            )
        self._conn.commit()

    def record_successful_login(self, account_id: UUID) -> None:
        with self._conn.cursor() as cur:
            cur.execute(
                f"""
                update {self._table()}
                set failed_login_count = 0,
                    locked_until = null,
                    last_successful_login_at = now()
                where id = %s
                """,
                (account_id,),
            )
        self._conn.commit()


def quote_identifier(value: str) -> str:
    if not value or "\x00" in value or "." in value:
        raise ValueError("identifier must be a simple non-empty identifier")
    return '"' + value.replace('"', '""') + '"'


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class LoginRequest(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)


class UserResponse(BaseModel):
    id: str
    username: str
    role: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserResponse


class MeResponse(UserResponse):
    expires_at: datetime


def _timestamp(value: datetime) -> int:
    return int(value.timestamp())


def sign_access_token(account: UserAccount, *, settings: AuthSettings, now: datetime | None = None) -> str:
    issued_at = now or utcnow()
    expires_at = issued_at + timedelta(seconds=settings.token_ttl_seconds)
    claims = {
        "iss": settings.jwt_issuer,
        "sub": f"user_account:{account.id}",
        "role": ADMIN_ROLE,
        "username": account.username,
        "iat": _timestamp(issued_at),
        "exp": _timestamp(expires_at),
    }
    return jwt.encode(claims, settings.jwt_secret, algorithm="HS256")


def decode_access_token(token: str, settings: AuthSettings, *, now: datetime | None = None) -> dict[str, Any]:
    try:
        claims = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=["HS256"],
            options={"verify_exp": False, "require": ["sub", "role", "username", "iat", "exp"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid bearer token") from exc

    current_time = now or utcnow()
    if int(claims["exp"]) <= _timestamp(current_time):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid bearer token")
    if claims.get("role") != ADMIN_ROLE or not str(claims.get("sub", "")).startswith("user_account:"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid bearer token")
    return claims


def is_locked(account: UserAccount, now: datetime) -> bool:
    return account.locked_until is not None and account.locked_until > now


def authenticate(
    request: LoginRequest,
    *,
    repository: UserAccountRepository,
    password_verifier: PasswordVerifier,
    settings: AuthSettings,
    now: datetime,
) -> LoginResponse:
    account = repository.get_by_username_for_update(request.username.strip())
    if account is None or not account.enabled or is_locked(account, now):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=PUBLIC_LOGIN_FAILURE)

    if not password_verifier.verify(account.password_hash, request.password):
        failed_count = account.failed_login_count + 1
        locked_until = now + timedelta(seconds=LOCKOUT_SECONDS) if failed_count >= FAILED_LOGIN_LOCK_THRESHOLD else None
        repository.record_failed_login(account.id, failed_count=failed_count, locked_until=locked_until)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=PUBLIC_LOGIN_FAILURE)

    repository.record_successful_login(account.id)
    return LoginResponse(
        access_token=sign_access_token(account, settings=settings, now=now),
        expires_in=settings.token_ttl_seconds,
        user=UserResponse(id=str(account.id), username=account.username, role=ADMIN_ROLE),
    )


def bearer_token(authorization: str | None = Header(default=None, alias="Authorization")) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    return token


def create_app(
    *,
    settings: AuthSettings | None = None,
    repository_factory: Callable[[], UserAccountRepository] | None = None,
    password_verifier: PasswordVerifier | None = None,
    clock: Callable[[], datetime] = utcnow,
) -> FastAPI:
    settings = settings or AuthSettings()
    password_verifier = password_verifier or Argon2PasswordVerifier()

    def default_repository_factory() -> UserAccountRepository:
        if not settings.database_dsn:
            raise RuntimeError("AUTH_DATABASE_DSN or CITYDB_DSN is required")
        return PgUserAccountRepository(settings.database_dsn, settings.auth_schema)

    repository_factory = repository_factory or default_repository_factory
    app = FastAPI(title="Huaguoshan 认证入口服务", version="0.1.0")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "healthy"}

    @app.post("/auth/login", response_model=LoginResponse)
    def login(request: LoginRequest) -> LoginResponse:
        repository = repository_factory()
        try:
            return authenticate(
                request,
                repository=repository,
                password_verifier=password_verifier,
                settings=settings,
                now=clock(),
            )
        finally:
            close = getattr(repository, "close", None)
            if callable(close):
                close()

    @app.get("/auth/me", response_model=MeResponse)
    def me(token: str = Depends(bearer_token)) -> MeResponse:
        claims = decode_access_token(token, settings, now=clock())
        subject = str(claims["sub"])
        return MeResponse(
            id=subject.removeprefix("user_account:"),
            username=str(claims["username"]),
            role=str(claims["role"]),
            expires_at=datetime.fromtimestamp(int(claims["exp"]), tz=timezone.utc),
        )

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("auth_service:app", host="0.0.0.0", port=int(os.getenv("AUTH_SERVICE_PORT", "8000")))
