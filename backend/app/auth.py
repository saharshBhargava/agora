import hashlib
import time
from dataclasses import dataclass
from uuid import UUID

import jwt
from fastapi import Depends, Request
from fastapi.concurrency import run_in_threadpool

from app.config import Settings
from app.db import Database, audit
from app.errors import Problem

DEV_ISSUER = "agora-dev"
DEV_AUDIENCE = "agora-api"


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    subject: str
    handle: str


def mint_dev_token(settings: Settings, subject: str) -> tuple[str, int]:
    now = int(time.time())
    exp = now + settings.dev_token_ttl_s
    token = jwt.encode(
        {"iss": DEV_ISSUER, "aud": DEV_AUDIENCE, "sub": subject, "iat": now, "nbf": now, "exp": exp},
        settings.dev_jwt_secret.get_secret_value(), algorithm="HS256",
    )
    return token, exp


class TokenVerifier:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._jwks = jwt.PyJWKClient(settings.oidc_jwks_url, cache_keys=True) if settings.auth_mode == "oidc" else None

    def verify(self, token: str) -> str:
        """Return the token's subject, or raise Problem(401). Algorithms are pinned; ``none`` is never accepted."""
        try:
            if self._jwks is not None:
                key = self._jwks.get_signing_key_from_jwt(token).key
                claims = jwt.decode(token, key, algorithms=["RS256", "ES256"], audience=self.settings.oidc_audience,
                                    issuer=self.settings.oidc_issuer, options={"require": ["exp", "sub", "iss", "aud"]})
            else:
                claims = jwt.decode(token, self.settings.dev_jwt_secret.get_secret_value(), algorithms=["HS256"],
                                    audience=DEV_AUDIENCE, issuer=DEV_ISSUER,
                                    options={"require": ["exp", "sub", "iss", "aud"]})
        except jwt.PyJWTError as error:
            raise Problem(401, "invalid_token", "Sign in again.") from error
        subject = claims["sub"]
        if not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            raise Problem(401, "invalid_token", "Sign in again.")
        return subject


def _bearer(request: Request) -> str:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise Problem(401, "missing_token", "Send Authorization: Bearer <token>.")
    return token.strip()


async def ensure_user(db: Database, subject: str, handle: str, display_name: str) -> UUID:
    """Create the user, their settings and a personal household on first sign-in. Idempotent."""
    async with db.system() as conn:
        existing = await conn.fetchval("SELECT id FROM users WHERE auth_subject = $1", subject)
        if existing:
            return existing
        user_id = await conn.fetchval(
            """INSERT INTO users (auth_subject, handle, display_name) VALUES ($1, $2, $3)
               ON CONFLICT (auth_subject) DO NOTHING RETURNING id""", subject, handle, display_name)
        if user_id is None:  # lost a race with a concurrent first request
            return await conn.fetchval("SELECT id FROM users WHERE auth_subject = $1", subject)
        await conn.execute("INSERT INTO user_settings (user_id) VALUES ($1)", user_id)
        household_id = await conn.fetchval(
            "INSERT INTO households (name, created_by) VALUES ($1, $2) RETURNING id", f"{display_name}'s home", user_id)
        await conn.execute("INSERT INTO household_members (household_id, user_id, role) VALUES ($1, $2, 'owner')",
                           household_id, user_id)
        await conn.executemany(
            "INSERT INTO storage_locations (household_id, name, kind) VALUES ($1, $2, $3)",
            [(household_id, "Fridge", "fridge"), (household_id, "Pantry", "pantry")])
        await audit(conn, "user.created", actor_id=user_id, household_id=household_id, target_type="user",
                    target_id=user_id)
        return user_id


async def current_principal(request: Request) -> Principal:
    state = request.app.state
    # JWKS fetches are blocking network calls (cached after the first), so keep them off the event loop.
    token = _bearer(request)
    if token.startswith("ags_"):
        async with state.db.system() as conn:
            row = await conn.fetchrow(
                """SELECT u.id, u.auth_subject, u.handle FROM app_sessions s JOIN users u ON u.id = s.user_id
                   WHERE s.token_hash = $1 AND s.expires_at > now() AND u.deleted_at IS NULL""",
                hashlib.sha256(token.encode()).hexdigest())
        if row is None:
            raise Problem(401, "invalid_token", "Sign in again.")
        request.state.user_id = row["id"]
        return Principal(user_id=row["id"], subject=row["auth_subject"], handle=row["handle"])
    if state.settings.auth_mode == "google":
        raise Problem(401, "invalid_token", "Sign in with Google.")
    subject = await run_in_threadpool(state.verifier.verify, token)
    async with state.db.system() as conn:
        row = await conn.fetchrow("SELECT id, handle FROM users WHERE auth_subject = $1 AND deleted_at IS NULL",
                                  subject)
    if row is None:
        if state.settings.auth_mode != "oidc":
            raise Problem(401, "unknown_user", "Sign in again.")
        # First OIDC sign-in: derive a placeholder handle the user can change later.
        handle = "user_" + subject.encode().hex()[-12:]
        user_id = await ensure_user(state.db, subject, handle, "New user")
        row = {"id": user_id, "handle": handle}
    request.state.user_id = row["id"]
    return Principal(user_id=row["id"], subject=subject, handle=row["handle"])


CurrentUser = Depends(current_principal)
