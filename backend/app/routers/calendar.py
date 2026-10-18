import secrets
from datetime import timedelta
from urllib.parse import urlencode
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Query, Request
from fastapi.responses import RedirectResponse
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

from app.auth import CurrentUser, Principal, current_principal, ensure_user
from app.db import audit
from app.demo_account import is_demo_user
from app.errors import Problem
from app.google_calendar import CALENDAR_SCOPES, SCOPES, challenge, digest
from app.idempotency import key_from, request_hash

router = APIRouter(prefix="/v1", tags=["calendar"])
APP_CALLBACK = "dev.agora.browserchat://google-callback"


class StartIn(BaseModel):
    code_challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")


class ExchangeIn(BaseModel):
    state: str = Field(min_length=32, max_length=128)
    code: str = Field(min_length=1, max_length=4096)
    code_verifier: str = Field(pattern=r"^[A-Za-z0-9._~-]{43,128}$")


class TimeWindow(BaseModel):
    model_config = ConfigDict(extra="forbid")
    start: AwareDatetime
    end: AwareDatetime
    timezone: str = Field(max_length=100)

    @field_validator("timezone")
    @classmethod
    def timezone_exists(cls, value):
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError("Use an IANA timezone") from error
        return value

    @model_validator(mode="after")
    def ordered_window(self):
        if not timedelta(0) < self.end - self.start <= timedelta(days=31):
            raise ValueError("End must follow start by at most 31 days")
        # Avoid silently shifting wall-clock times when the model guesses the wrong DST offset.
        for value in (self.start, self.end):
            if value.utcoffset() != value.astimezone(ZoneInfo(self.timezone)).utcoffset():
                raise ValueError("Timestamp offset must agree with timezone")
        return self


class EventIn(TimeWindow):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=4000)
    location: str = Field(default="", max_length=500)
    confirmed: bool

    @field_validator("title")
    @classmethod
    def nonblank_title(cls, value):
        if not value.strip():
            raise ValueError("Title is required")
        return value.strip()


@router.post("/integrations/google/start")
async def start(body: StartIn, request: Request):
    service = request.app.state.calendar
    service.require_config()
    if service.settings.auth_mode == "oidc":
        raise Problem(409, "google_login_disabled", "This onboarding flow requires AGORA_AUTH_MODE=google.")
    user = await current_principal(request) if request.headers.get("authorization") else None
    state = secrets.token_urlsafe(32)
    async with service.db.system() as conn:
        await conn.execute("DELETE FROM google_oauth_states WHERE expires_at < now()")
        await conn.execute("DELETE FROM app_sessions WHERE expires_at < now()")
        await conn.execute(
            "INSERT INTO google_oauth_states (state_hash, challenge, user_id) VALUES ($1, $2, $3)",
            digest(state),
            body.code_challenge,
            user.user_id if user else None,
        )
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode(
        {
            "client_id": service.settings.google_client_id,
            "redirect_uri": service.settings.google_redirect_uri,
            "response_type": "code",
            "scope": " ".join(sorted(SCOPES)),
            "state": state,
            "code_challenge": body.code_challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent select_account",
        }
    )
    return {"authorization_url": url, "state": state}


@router.get("/integrations/google/callback")
async def callback(
    request: Request,
    state: str = Query(min_length=32, max_length=128),
    code: str | None = Query(default=None, max_length=4096),
    error: str | None = Query(default=None, max_length=200),
):
    async with request.app.state.db.system() as conn:
        valid = await conn.fetchval(
            "SELECT 1 FROM google_oauth_states WHERE state_hash = $1 AND expires_at > now()", digest(state)
        )
    if not valid:
        raise Problem(400, "invalid_oauth_state", "Connection expired. Return to Agora and connect again.")
    # Only the originating device has the PKCE verifier needed to redeem this code.
    params = {"state": state, "error": "access_denied"} if error or not code else {"state": state, "code": code}
    return RedirectResponse(APP_CALLBACK + "?" + urlencode(params), status_code=302)


@router.post("/integrations/google/exchange")
async def exchange(body: ExchangeIn, request: Request):
    service = request.app.state.calendar
    service.require_config()
    async with service.db.system() as conn:
        pending = await conn.fetchrow(
            """DELETE FROM google_oauth_states WHERE state_hash = $1 AND challenge = $2 AND expires_at > now()
               RETURNING user_id""",
            digest(body.state),
            challenge(body.code_verifier),
        )
    if pending is None:
        raise Problem(400, "invalid_oauth_state", "Connection expired. Please connect again.")
    tokens = await service.exchange(body.code, body.code_verifier)
    scopes = set(tokens.get("scope", "").split())
    if not CALENDAR_SCOPES.issubset(scopes) or not tokens.get("access_token"):
        raise Problem(403, "calendar_permission_required", "Approve Calendar permissions to finish onboarding.")
    profile_response = await service.request(
        "GET",
        "https://openidconnect.googleapis.com/v1/userinfo",
        headers={"Authorization": f"Bearer {tokens['access_token']}"},
    )
    if profile_response.status_code != 200:
        raise Problem(400, "google_identity_failed", "Could not verify your Google account. Connect again.")
    profile = service.data(profile_response)
    sub, email = profile.get("sub"), profile.get("email")
    if not isinstance(sub, str) or not 1 <= len(sub) <= 200 or not email or profile.get("email_verified") is not True:
        raise Problem(400, "google_identity_failed", "A verified Google account is required.")
    subject = "google:" + sub
    # On reconnect, never silently switch the existing Agora account to another Google identity.
    if pending["user_id"]:
        async with service.db.system() as conn:
            expected = await conn.fetchval("SELECT auth_subject FROM users WHERE id = $1", pending["user_id"])
        if expected != subject:
            raise Problem(409, "google_account_mismatch", "Reconnect the same Google account, or sign out first.")
    user_id = await ensure_user(service.db, subject, "g_" + digest(sub)[:28], email.split("@")[0][:80] or "Agora user")
    session = "ags_" + secrets.token_urlsafe(32)
    async with service.db.scoped(user_id) as conn:
        if await conn.fetchval("SELECT deleted_at IS NOT NULL FROM users WHERE id = $1", user_id):
            raise Problem(403, "account_unavailable", "This account is unavailable.")
        refresh = tokens.get("refresh_token")
        existing = await conn.fetchval(
            "SELECT refresh_token_enc FROM google_calendar_connections WHERE user_id = $1", user_id
        )
        if not refresh and not existing:
            raise Problem(400, "offline_access_required", "Connect again and approve offline Calendar access.")
        encrypted = service.encrypt(refresh, user_id) if refresh else existing
        await conn.execute(
            """INSERT INTO google_calendar_connections (user_id, refresh_token_enc, email, scopes)
               VALUES ($1, $2, $3, $4) ON CONFLICT (user_id) DO UPDATE
               SET refresh_token_enc = EXCLUDED.refresh_token_enc, email = EXCLUDED.email, scopes = EXCLUDED.scopes,
                   status = 'connected', updated_at = now()""",
            user_id,
            encrypted,
            email,
            sorted(scopes),
        )
        await conn.execute(
            "INSERT INTO consents (user_id, scope, policy_version) VALUES ($1, 'calendar', 'v1')", user_id
        )
        await audit(conn, "calendar.connected", actor_id=user_id)
    async with service.db.system() as conn:
        expires = await conn.fetchval(
            "INSERT INTO app_sessions (token_hash, user_id) VALUES ($1, $2) RETURNING expires_at",
            digest(session),
            user_id,
        )
    return {"access_token": session, "expires_at": expires, "email": email, "user_id": str(user_id)}


@router.get("/integrations/google")
async def status(request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(
            "SELECT email, status FROM google_calendar_connections WHERE user_id = $1", user.user_id
        )
    return {"connected": bool(row and row["status"] == "connected"), "email": row["email"] if row else None}


@router.post("/auth/logout")
async def logout(request: Request, user: Principal = CurrentUser):
    token = request.headers["authorization"].split(" ", 1)[1].strip()
    async with request.app.state.db.system() as conn:
        await conn.execute(
            "DELETE FROM app_sessions WHERE token_hash = $1 AND user_id = $2", digest(token), user.user_id
        )
    return {"signed_out": True}


@router.delete("/integrations/google")
async def disconnect(request: Request, user: Principal = CurrentUser):
    service = request.app.state.calendar
    async with service.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(
            "SELECT refresh_token_enc FROM google_calendar_connections WHERE user_id = $1", user.user_id
        )
    if row:
        response = await service.request(
            "POST",
            "https://oauth2.googleapis.com/revoke",
            data={"token": service.decrypt(row["refresh_token_enc"], user.user_id)},
        )
        if response.status_code not in (200, 400):
            raise Problem(502, "google_unavailable", "Could not revoke access. Please try again.")
    async with service.db.scoped(user.user_id) as conn:
        await conn.execute("DELETE FROM google_calendar_connections WHERE user_id = $1", user.user_id)
        await conn.execute(
            """INSERT INTO consents (user_id, scope, revoked_at, policy_version)
                              VALUES ($1, 'calendar', now(), 'v1')""",
            user.user_id,
        )
        await audit(conn, "calendar.disconnected", actor_id=user.user_id)
    async with service.db.system() as conn:
        await conn.execute("DELETE FROM app_sessions WHERE user_id = $1", user.user_id)
        await conn.execute("DELETE FROM google_oauth_states WHERE user_id = $1", user.user_id)
    return {"connected": False}


@router.post("/calendar/freebusy")
async def freebusy(body: TimeWindow, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        demo = await is_demo_user(conn, user.user_id)
    if demo:
        from app.routers.demo import freebusy as simulated_freebusy
        return await simulated_freebusy(body, request, user)
    service = request.app.state.calendar
    response = await service.calendar_request(
        user.user_id,
        "POST",
        "freeBusy",
        json={
            "timeMin": body.start.isoformat(),
            "timeMax": body.end.isoformat(),
            "timeZone": body.timezone,
            "items": [{"id": "primary"}],
        },
    )
    if response.status_code != 200:
        raise Problem(502, "google_unavailable", "Could not check Calendar availability.")
    primary = service.data(response).get("calendars", {}).get("primary")
    if not primary or primary.get("errors") or "busy" not in primary:
        raise Problem(
            502, "availability_unknown", "Google could not confirm availability. Do not assume the time is free."
        )
    return {"busy": primary["busy"], "timezone": body.timezone}


@router.post("/calendar/events", status_code=201)
async def create_event(body: EventIn, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        demo = await is_demo_user(conn, user.user_id)
    if demo:
        from app.routers.demo import create_event as simulated_create_event
        return await simulated_create_event(body, request, user)
    if not body.confirmed:
        raise Problem(403, "approval_required", "Confirm the event in Agora before creating it.")
    key = key_from(request)
    service = request.app.state.calendar
    event_id = digest(f"agora:{user.user_id}:{key}")  # Google accepts base32hex; deterministic across retries.
    fingerprint = request_hash(body.model_dump(mode="json"))
    payload = {
        "id": event_id,
        "summary": body.title,
        "description": body.description,
        "location": body.location,
        "start": {"dateTime": body.start.isoformat(), "timeZone": body.timezone},
        "end": {"dateTime": body.end.isoformat(), "timeZone": body.timezone},
        "extendedProperties": {"private": {"agora_request": fingerprint}},
    }
    response = await service.calendar_request(
        user.user_id, "POST", "calendars/primary/events", params={"sendUpdates": "none"}, json=payload
    )
    if response.status_code == 409:
        response = await service.calendar_request(user.user_id, "GET", f"calendars/primary/events/{event_id}")
        if response.status_code == 200:
            existing = service.data(response)
            if existing.get("extendedProperties", {}).get("private", {}).get("agora_request") != fingerprint:
                raise Problem(422, "idempotency_key_reused", "This request key was used for different event details.")
    if response.status_code not in (200, 201):
        code = "outcome_unknown" if response.status_code >= 500 else "calendar_event_failed"
        raise Problem(502, code, "Google did not confirm event creation. Check Calendar before retrying.")
    event = service.data(response)
    if event.get("id") != event_id or event.get("status") == "cancelled":
        raise Problem(502, "outcome_unknown", "Event creation could not be confirmed. Check Google Calendar.")
    async with service.db.scoped(user.user_id) as conn:
        await audit(
            conn, "calendar.event_created", actor_id=user.user_id, target_type="calendar_event", target_id=event_id
        )
    return {"id": event_id, "url": event.get("htmlLink"), "created": True}
