"""Google-owned OAuth and Calendar endpoints. Never send provider error bodies to clients or logs."""

import base64
import hashlib
import secrets
from uuid import UUID

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.errors import Problem

SCOPES = {
    "openid",
    "email",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/calendar.freebusy",
}
CALENDAR_SCOPES = {s for s in SCOPES if s.startswith("https:")}


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def challenge(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class GoogleCalendar:
    def __init__(self, settings, db, http: httpx.AsyncClient):
        self.settings, self.db, self.http = settings, db, http

    def require_config(self):
        if not self.settings.google_client_id:
            raise Problem(503, "google_not_configured", "Google Calendar connection is not configured yet.")

    def encrypt(self, token: str, user_id: UUID) -> str:
        nonce = secrets.token_bytes(12)
        key = base64.b64decode(self.settings.google_token_key.get_secret_value())
        encrypted = AESGCM(key).encrypt(nonce, token.encode(), str(user_id).encode())
        return "v1:" + base64.b64encode(nonce + encrypted).decode()

    def decrypt(self, encrypted: str, user_id: UUID) -> str:
        try:
            version, payload = encrypted.split(":", 1)
            if version != "v1":
                raise ValueError()
            raw = base64.b64decode(payload, validate=True)
            key = base64.b64decode(self.settings.google_token_key.get_secret_value())
            return AESGCM(key).decrypt(raw[:12], raw[12:], str(user_id).encode()).decode()
        except Exception as error:
            raise Problem(503, "calendar_key_unavailable", "Calendar credentials could not be unlocked.") from error

    async def request(self, method: str, url: str, **kwargs) -> httpx.Response:
        try:
            return await self.http.request(method, url, timeout=20, **kwargs)
        except httpx.HTTPError as error:
            code = "outcome_unknown" if method == "POST" and url.endswith("/events") else "google_unavailable"
            raise Problem(502, code, "Google did not confirm the request. Check Calendar before retrying.") from error

    @staticmethod
    def data(response: httpx.Response) -> dict:
        try:
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError()
            return result
        except ValueError as error:
            raise Problem(502, "google_invalid_response", "Google returned an invalid response.") from error

    async def exchange(self, code: str, verifier: str) -> dict:
        response = await self.request(
            "POST",
            "https://oauth2.googleapis.com/token",
            data={
                "client_id": self.settings.google_client_id,
                "client_secret": self.settings.google_client_secret.get_secret_value(),
                "redirect_uri": self.settings.google_redirect_uri,
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
            },
        )
        if response.status_code != 200:
            raise Problem(400, "google_authorization_failed", "Google sign-in expired. Please connect again.")
        return self.data(response)

    async def access_token(self, user_id: UUID) -> str:
        self.require_config()
        async with self.db.scoped(user_id) as conn:
            row = await conn.fetchrow("SELECT * FROM google_calendar_connections WHERE user_id = $1", user_id)
        if not row or row["status"] != "connected":
            raise Problem(409, "calendar_reconnect_required", "Connect Google Calendar in Settings.")
        response = await self.request(
            "POST",
            "https://oauth2.googleapis.com/token",
            data={
                "client_id": self.settings.google_client_id,
                "client_secret": self.settings.google_client_secret.get_secret_value(),
                "grant_type": "refresh_token",
                "refresh_token": self.decrypt(row["refresh_token_enc"], user_id),
            },
        )
        data = self.data(response)
        if response.status_code == 400 and data.get("error") == "invalid_grant":
            async with self.db.scoped(user_id) as conn:
                await conn.execute(
                    """UPDATE google_calendar_connections SET status = 'reconnect_required'
                                      WHERE user_id = $1 AND refresh_token_enc = $2""",
                    user_id,
                    row["refresh_token_enc"],
                )
            raise Problem(409, "calendar_reconnect_required", "Google access expired. Reconnect in Settings.")
        if response.status_code != 200 or not data.get("access_token"):
            raise Problem(502, "google_unavailable", "Google Calendar is unavailable. Try again later.")
        if data.get("refresh_token"):
            async with self.db.scoped(user_id) as conn:
                await conn.execute(
                    """UPDATE google_calendar_connections SET refresh_token_enc = $2, updated_at = now()
                       WHERE user_id = $1 AND refresh_token_enc = $3""",
                    user_id,
                    self.encrypt(data["refresh_token"], user_id),
                    row["refresh_token_enc"],
                )
        return data["access_token"]

    async def calendar_request(self, user_id: UUID, method: str, path: str, **kwargs) -> httpx.Response:
        token = await self.access_token(user_id)
        response = await self.request(
            method,
            "https://www.googleapis.com/calendar/v3/" + path,
            headers={"Authorization": f"Bearer {token}"},
            **kwargs,
        )
        if response.status_code in (401, 403):
            async with self.db.scoped(user_id) as conn:
                await conn.execute(
                    "UPDATE google_calendar_connections SET status = 'reconnect_required' WHERE user_id = $1",
                    user_id,
                )
            raise Problem(409, "calendar_access_denied", "Google denied Calendar access. Reconnect in Settings.")
        return response
