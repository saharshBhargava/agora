import base64
import json
import logging
from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs, urlencode
from uuid import UUID, uuid4

import httpx
import pytest
from pydantic import ValidationError

from app.config import Settings
from app.errors import Problem
from app.google_calendar import SCOPES, challenge, digest
from app.main import RedactAccessQuery, create_app
from app.routers.calendar import EventIn

WINDOW = {"start": "2026-10-18T17:00:00-07:00", "end": "2026-10-18T17:30:00-07:00", "timezone": "America/Los_Angeles"}
EVENT = {**WINDOW, "title": "Grocery run", "confirmed": True}


class GoogleStub:
    def __init__(self):
        self.events = {}
        self.insert_count = 0
        self.invalid_grant = False
        self.unknown_outcome = False
        self.busy_error = False
        self.scopes = SCOPES

    def __call__(self, request):
        if request.url.path == "/token":
            form = parse_qs(request.content.decode())
            if form["grant_type"] == ["refresh_token"]:
                if self.invalid_grant:
                    return httpx.Response(400, json={"error": "invalid_grant", "secret": "must-not-leak"})
                return httpx.Response(200, json={"access_token": form["refresh_token"][0]})
            # Different Google identities, not a client-provided Agora user ID.
            return httpx.Response(
                200,
                json={
                    "access_token": form["code"][0],
                    "refresh_token": form["code"][0],
                    "scope": " ".join(self.scopes),
                },
            )
        if request.url.path == "/v1/userinfo":
            sub = request.headers["authorization"].split()[1]
            return httpx.Response(200, json={"sub": sub, "email": f"{sub}@example.com", "email_verified": True})
        if request.url.path == "/revoke":
            return httpx.Response(200)
        identity = request.headers["authorization"]
        if request.url.path.endswith("/freeBusy"):
            primary = {"errors": [{"reason": "internalError"}]} if self.busy_error else {"busy": []}
            return httpx.Response(200, json={"calendars": {"primary": primary}})
        if request.method == "POST" and request.url.path.endswith("/events"):
            event = json.loads(request.content)
            key = identity, event["id"]
            if key in self.events:
                return httpx.Response(409)
            self.events[key] = {**event, "htmlLink": "https://www.google.com/calendar/event?eid=test"}
            self.insert_count += 1
            if self.unknown_outcome:
                raise httpx.ReadTimeout("provider-secret", request=request)
            return httpx.Response(201, json=self.events[key])
        if request.method == "GET" and "/events/" in request.url.path:
            return httpx.Response(200, json=self.events[(identity, request.url.path.rsplit("/", 1)[1])])
        raise AssertionError(f"Unexpected Google request: {request.method} {request.url.path}")


@pytest.fixture
async def calendar_app(database_url, tmp_path):
    settings = Settings(
        env="test",
        auth_mode="google",
        database_url=database_url,
        storage_dir=tmp_path,
        run_worker_in_process=False,
        google_client_id="test.apps.googleusercontent.com",
        google_client_secret="test-secret",
        google_redirect_uri="https://api.example.com/v1/integrations/google/callback",
        google_token_key=base64.b64encode(b"k" * 32).decode(),
    )
    app = create_app(settings)
    stub = GoogleStub()
    async with app.router.lifespan_context(app), httpx.AsyncClient(transport=httpx.MockTransport(stub)) as google:
        app.state.calendar.http = google
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://api.example.com"
        ) as client:
            yield app, client, stub


async def begin(client, headers=None):
    verifier = "v" * 43
    response = await client.post(
        "/v1/integrations/google/start", json={"code_challenge": challenge(verifier)}, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json(), verifier


async def connect(client, identity=None):
    start, verifier = await begin(client)
    response = await client.post(
        "/v1/integrations/google/exchange",
        json={"state": start["state"], "code_verifier": verifier, "code": identity or uuid4().hex},
    )
    assert response.status_code == 200, response.text
    return response.json(), {"Authorization": "Bearer " + response.json()["access_token"]}


async def test_onboarding_pkce_state_callback_and_replay(calendar_app):
    app, client, _ = calendar_app
    start, verifier = await begin(client)
    query = parse_qs(start["authorization_url"].split("?", 1)[1])
    assert query["code_challenge"] == [challenge(verifier)]
    assert query["access_type"] == ["offline"]
    assert query["redirect_uri"] == [app.state.settings.google_redirect_uri]
    assert "test-secret" not in start["authorization_url"]
    callback = await client.get("/v1/integrations/google/callback", params={"state": start["state"], "code": "user-a"})
    assert callback.status_code == 302
    assert callback.headers["location"].startswith("dev.agora.browserchat://google-callback?")
    body = {"state": start["state"], "code": "user-a", "code_verifier": "wrong" * 10}
    assert (await client.post("/v1/integrations/google/exchange", json=body)).status_code == 400
    body["code_verifier"] = verifier
    success = await client.post("/v1/integrations/google/exchange", json=body)
    assert success.status_code == 200, success.text
    assert (await client.post("/v1/integrations/google/exchange", json=body)).status_code == 400
    async with app.state.db.system() as conn:
        assert (
            await conn.fetchval(
                "SELECT count(*) FROM app_sessions WHERE token_hash = $1", digest(success.json()["access_token"])
            )
            == 1
        )
    assert (await client.get("/v1/integrations/google/callback", params={"state": "x" * 43})).status_code == 400


async def test_expired_state_and_partial_permissions(calendar_app):
    app, client, stub = calendar_app
    start, verifier = await begin(client)
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE google_oauth_states SET expires_at = now() - interval '1 second' WHERE state_hash = $1",
            digest(start["state"]),
        )
    body = {"state": start["state"], "code": uuid4().hex, "code_verifier": verifier}
    assert (await client.post("/v1/integrations/google/exchange", json=body)).status_code == 400
    start, verifier = await begin(client)
    stub.scopes = {"openid", "email"}
    body.update(state=start["state"], code_verifier=verifier)
    response = await client.post("/v1/integrations/google/exchange", json=body)
    assert response.status_code == 403
    assert response.json()["title"] == "calendar_permission_required"


async def test_connection_isolation_encryption_and_reconnect_identity(calendar_app):
    app, client, stub = calendar_app
    alice, ah = await connect(client)
    bob, bh = await connect(client)
    alice_id, bob_id = UUID(alice["user_id"]), UUID(bob["user_id"])
    async with app.state.db.scoped(alice_id) as conn:
        rows = await conn.fetch("SELECT * FROM google_calendar_connections")
        assert len(rows) == 1 and rows[0]["user_id"] == alice_id
        encrypted = rows[0]["refresh_token_enc"]
        assert encrypted.startswith("v1:")
        with pytest.raises(Problem):
            app.state.calendar.decrypt(encrypted, bob_id)
        with pytest.raises(Exception, match="permission denied"):
            await conn.fetch("SELECT * FROM app_sessions")
    assert (await client.get("/v1/integrations/google", headers=bh)).json()["email"] == bob["email"]
    start, verifier = await begin(client, ah)
    response = await client.post(
        "/v1/integrations/google/exchange",
        json={"state": start["state"], "code_verifier": verifier, "code": "different-google-account"},
    )
    assert response.status_code == 409
    assert response.json()["title"] == "google_account_mismatch"
    assert (await client.get("/v1/integrations/google", headers=ah)).json()["email"] == alice["email"]


async def test_event_approval_idempotency_and_user_isolation(calendar_app):
    _, client, stub = calendar_app
    _, ah = await connect(client)
    _, bh = await connect(client)
    headers = {**ah, "Idempotency-Key": "same-key-for-two-users"}
    assert (
        await client.post("/v1/calendar/events", headers=headers, json={**EVENT, "confirmed": False})
    ).status_code == 403
    assert stub.insert_count == 0
    assert (await client.post("/v1/calendar/events", headers=ah, json=EVENT)).status_code == 400
    first = await client.post("/v1/calendar/events", headers=headers, json=EVENT)
    again = await client.post("/v1/calendar/events", headers=headers, json=EVENT)
    assert first.status_code == again.status_code == 201
    assert first.json() == again.json()
    assert stub.insert_count == 1
    changed = await client.post("/v1/calendar/events", headers=headers, json={**EVENT, "title": "Different"})
    assert changed.status_code == 422
    other = await client.post(
        "/v1/calendar/events", headers={**bh, "Idempotency-Key": headers["Idempotency-Key"]}, json=EVENT
    )
    assert other.status_code == 201 and other.json()["id"] != first.json()["id"]
    assert stub.insert_count == 2


async def test_uncertain_create_is_recoverable_without_duplicates(calendar_app):
    _, client, stub = calendar_app
    _, headers = await connect(client)
    headers["Idempotency-Key"] = uuid4().hex
    stub.unknown_outcome = True
    result = await client.post("/v1/calendar/events", headers=headers, json=EVENT)
    assert result.status_code == 502 and result.json()["title"] == "outcome_unknown"
    assert "provider-secret" not in result.text
    retry = await client.post("/v1/calendar/events", headers=headers, json=EVENT)
    assert retry.status_code == 201 and stub.insert_count == 1


async def test_revocation_freebusy_errors_and_disconnect(calendar_app):
    _, client, stub = calendar_app
    _, headers = await connect(client)
    response = await client.post("/v1/calendar/freebusy", headers=headers, json=WINDOW)
    assert response.status_code == 200 and response.json()["busy"] == []
    stub.busy_error = True
    assert (await client.post("/v1/calendar/freebusy", headers=headers, json=WINDOW)).status_code == 502
    stub.invalid_grant = True
    response = await client.post("/v1/calendar/freebusy", headers=headers, json=WINDOW)
    assert response.status_code == 409 and "must-not-leak" not in response.text
    assert (await client.get("/v1/integrations/google", headers=headers)).json()["connected"] is False
    assert (await client.delete("/v1/integrations/google", headers=headers)).status_code == 200
    assert (await client.get("/v1/me", headers=headers)).status_code == 401


async def test_session_expiry_logout_and_dev_login_disabled(calendar_app):
    app, client, _ = calendar_app
    account, headers = await connect(client)
    assert (await client.get("/v1/me", headers=headers)).status_code == 200
    assert (await client.post("/v1/dev/login", json={"handle": "unauthorized"})).status_code == 404
    assert (await client.post("/v1/auth/logout", headers=headers)).status_code == 200
    assert (await client.get("/v1/me", headers=headers)).status_code == 401
    account, headers = await connect(client)
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE app_sessions SET expires_at = $1 WHERE token_hash = $2",
            datetime.now(UTC) - timedelta(seconds=1),
            digest(account["access_token"]),
        )
    assert (await client.get("/v1/me", headers=headers)).status_code == 401


@pytest.mark.parametrize(
    "changes",
    [
        {"start": "2026-10-18T17:00:00"},
        {"end": WINDOW["start"]},
        {"timezone": "Mars/Olympus"},
        {"start": "2026-10-18T17:00:00-08:00"},
        {"title": " "},
        {"attendees": ["someone@example.com"]},
    ],
)
def test_invalid_event_details(changes):
    with pytest.raises(ValidationError):
        EventIn(**{**EVENT, **changes})


def test_callback_query_not_in_access_log():
    path = "/v1/integrations/google/callback?" + urlencode({"code": "secret", "state": "secret"})
    record = logging.LogRecord(
        "uvicorn.access", logging.INFO, "", 0, "%s %s %s %s %s", ("client", "GET", path, "1.1", 302), None
    )
    RedactAccessQuery().filter(record)
    assert "secret" not in record.getMessage()


def test_production_google_configuration():
    with pytest.raises(ValidationError):
        Settings(env="prod", auth_mode="google")
