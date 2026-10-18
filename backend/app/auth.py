import hashlib
import re
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
# Must match app.demo_account.DEMO_SUBJECT and the handle pattern on DevLoginIn.
# Kept here (not imported) because demo_account imports this module.
_DEMO_TOKEN_SUBJECT = "demo:primary"  # noqa: S105 - auth subject namespace, not a password
_DEV_HANDLE = re.compile(r"^[a-z0-9_]{3,32}$")


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    subject: str
    handle: str


def is_dev_token_subject(subject: str) -> bool:
    """True only for subjects ``/v1/dev/login`` is allowed to mint (``demo:primary`` or ``dev:<handle>``)."""
    return subject == _DEMO_TOKEN_SUBJECT or (
        subject.startswith("dev:") and _DEV_HANDLE.fullmatch(subject.removeprefix("dev:")) is not None
    )


def mint_dev_token(settings: Settings, subject: str) -> tuple[str, int]:
    if not is_dev_token_subject(subject):
        raise ValueError(f"refusing to mint HS256 token for non-dev subject: {subject!r}")
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
        self._native_google = settings.auth_mode == "google" and bool(settings.google_ios_client_id)
        jwks_url = "https://www.googleapis.com/oauth2/v3/certs" if self._native_google else settings.oidc_jwks_url
        self._jwks = (jwt.PyJWKClient(jwks_url, cache_keys=True)
                      if self._native_google or settings.auth_mode == "oidc" else None)

    def verify(self, token: str) -> str:
        """Return the token's subject, or raise Problem(401). Algorithms are pinned; ``none`` is never accepted."""
        return self.identify(token)[0]

    def identify(self, token: str) -> tuple[str, str | None]:
        """(subject, verified email or None)."""
        try:
            if self.settings.dev_login_enabled and jwt.get_unverified_header(token).get("alg") == "HS256":
                # Demo/dev tokens next to Google ones. Signature proves the secret holder minted the JWT;
                # the subject allowlist below stops a stolen secret from impersonating Google accounts.
                claims = jwt.decode(token, self.settings.dev_jwt_secret.get_secret_value(), algorithms=["HS256"],
                                    audience=DEV_AUDIENCE, issuer=DEV_ISSUER,
                                    options={"require": ["exp", "sub", "iss", "aud"]})
                return self._dev_token_subject(claims), None
            if self._native_google:
                key = self._jwks.get_signing_key_from_jwt(token).key
                claims = jwt.decode(
                    token, key, algorithms=["RS256"], audience=self.settings.google_ios_client_id,
                    issuer=["https://accounts.google.com", "accounts.google.com"],
                    options={"require": ["exp", "sub", "iss", "aud", "iat"]},
                )
                if claims.get("azp", self.settings.google_ios_client_id) != self.settings.google_ios_client_id:
                    raise jwt.InvalidAudienceError("Unexpected authorized party")
            elif self._jwks is not None:
                key = self._jwks.get_signing_key_from_jwt(token).key
                claims = jwt.decode(token, key, algorithms=["RS256", "ES256"], audience=self.settings.oidc_audience,
                                    issuer=self.settings.oidc_issuer, options={"require": ["exp", "sub", "iss", "aud"]})
            else:
                claims = jwt.decode(token, self.settings.dev_jwt_secret.get_secret_value(), algorithms=["HS256"],
                                    audience=DEV_AUDIENCE, issuer=DEV_ISSUER,
                                    options={"require": ["exp", "sub", "iss", "aud"]})
                return self._dev_token_subject(claims), None
        except jwt.PyJWTError as error:
            raise Problem(401, "invalid_token", "Sign in again.") from error
        email = claims.get("email") if claims.get("email_verified") in (True, "true") else None
        return self._subject(claims, namespace="google:" if self._native_google else ""), (
            email.strip().lower() if isinstance(email, str) else None)

    @classmethod
    def _dev_token_subject(cls, claims: dict) -> str:
        subject = cls._subject(claims, namespace="")
        if not is_dev_token_subject(subject):
            raise Problem(401, "invalid_token", "Sign in again.")
        return subject

    @staticmethod
    def _subject(claims: dict, namespace: str) -> str:
        subject = claims["sub"]
        if not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            raise Problem(401, "invalid_token", "Sign in again.")
        return namespace + subject


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
    if state.settings.auth_mode == "google" and not state.settings.google_ios_client_id:
        raise Problem(401, "invalid_token", "Sign in with Google.")
    subject, email = await run_in_threadpool(state.verifier.identify, token)
    if email and email in state.settings.demo_email_set:
        # The designated demo Google address signs in to the demo account (see app/demo_account.py).
        from app.demo_account import DEMO_SUBJECT, ensure_demo_account  # local import: it imports this module

        await ensure_demo_account(state.db, state.settings)
        subject = DEMO_SUBJECT
    async with state.db.system() as conn:
        row = await conn.fetchrow("SELECT id, handle FROM users WHERE auth_subject = $1 AND deleted_at IS NULL",
                                  subject)
    if row is None:
        if state.settings.auth_mode not in ("oidc", "google") or subject.startswith(("dev:", "demo:")):
            raise Problem(401, "unknown_user", "Sign in again.")
        # Preserve the Google subject/handle used by the earlier server-side OAuth flow.
        handle = ("g_" + hashlib.sha256(subject.removeprefix("google:").encode()).hexdigest()[:28]
                  if state.settings.auth_mode == "google" else "user_" + subject.encode().hex()[-12:])
        await ensure_user(state.db, subject, handle, "New user")
        async with state.db.system() as conn:
            row = await conn.fetchrow("SELECT id, handle FROM users WHERE auth_subject = $1 AND deleted_at IS NULL",
                                      subject)
        if row is None:
            raise Problem(401, "account_unavailable", "This account is unavailable.")
        if state.settings.seed_new_users:
            from app.seed import seed_new_user  # local import: app.seed depends on this module

            await seed_new_user(state.db, row["id"])
    request.state.user_id = row["id"]
    return Principal(user_id=row["id"], subject=subject, handle=row["handle"])


CurrentUser = Depends(current_principal)
