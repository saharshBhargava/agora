"""The demo account: one account, realistic data in every feature, isolated from real accounts.

If ``test_demo_account_covers_every_feature_table`` fails after you add a table, add realistic demo rows for it
in app/demo_account.py (or, if it can never hold demo data, add it to NO_DEMO_DATA with the reason).
"""

import time
from types import SimpleNamespace
from uuid import UUID, uuid4

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth import DEV_AUDIENCE, DEV_ISSUER
from app.config import Settings
from app.demo_account import DEMO_SUBJECT, ensure_demo_account, reset_demo_account
from app.main import create_app

CLIENT_ID = "123-native.apps.googleusercontent.com"
DEMO_EMAIL = "alex.rivera.agora@gmail.com"
PASSWORD = "correct-horse-battery-staple"

# Tables that are household/user scoped but can never hold seeded demo rows, and why.
NO_DEMO_DATA = {
    "vision_cache": "filled only by real vision provider calls",
    "idempotency_keys": "request bookkeeping",
    "google_oauth_states": "transient OAuth handshake state (legacy server-side flow)",
    "app_sessions": "issued only by the legacy server-side Google flow",
    "google_calendar_connections": "needs a real Google refresh token; the iOS app talks to Calendar directly",
}


@pytest.fixture(scope="module")
def signing_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def google_token(key, **claims):
    now = int(time.time())
    return jwt.encode({"iss": "https://accounts.google.com", "aud": CLIENT_ID, "sub": uuid4().hex, "iat": now,
                       "exp": now + 3600, **claims}, key, algorithm="RS256")


@pytest.fixture(scope="module")
async def demo_app(database_url, tmp_path_factory, signing_key):
    settings = Settings(env="demo", auth_mode="google", google_ios_client_id=CLIENT_ID, database_url=database_url,
                        storage_dir=tmp_path_factory.mktemp("demo-media"), run_worker_in_process=False,
                        dev_jwt_secret="a-real-random-secret-for-the-demo-0123456789",
                        demo_password=PASSWORD, demo_google_emails=f" {DEMO_EMAIL.upper()} ,other@example.com")
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        public_key = signing_key.public_key()
        app.state.verifier._jwks = SimpleNamespace(get_signing_key_from_jwt=lambda _: SimpleNamespace(key=public_key))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://test") as client:
            yield app, client


async def demo_headers(client) -> dict[str, str]:
    response = await client.post("/v1/dev/login", json={"handle": "demo", "password": PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


async def test_demo_account_covers_every_feature_table(demo_app):
    app, _ = demo_app
    user_id = await ensure_demo_account(app.state.db, app.state.settings)
    async with app.state.db.system() as conn:
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        scoped = await conn.fetch(
            """SELECT table_name, bool_or(column_name = 'household_id') AS by_household,
                      bool_or(column_name = 'user_id') AS by_user
               FROM information_schema.columns
               WHERE table_schema = 'public' AND column_name IN ('household_id', 'user_id')
               GROUP BY table_name ORDER BY table_name""")
        missing = []
        for t in scoped:
            if t["table_name"] in NO_DEMO_DATA:
                continue
            column, value = ("household_id", household_id) if t["by_household"] else ("user_id", user_id)
            if not await conn.fetchval(f'SELECT EXISTS (SELECT 1 FROM "{t["table_name"]}" WHERE {column} = $1)', value):
                missing.append(t["table_name"])
    assert not missing, (f"demo account has no rows in {missing}: add realistic demo data in app/demo_account.py "
                         "(see CLAUDE.md), or list the table in NO_DEMO_DATA with a reason")


async def test_demo_account_looks_real_and_is_full(demo_app):
    _, client = demo_app
    headers = await demo_headers(client)
    me = (await client.get("/v1/me", headers=headers)).json()
    assert me["display_name"] == "Alex Rivera" and me["handle"] == "alexrivera"
    assert "demo" not in str(me).lower() and "is_demo" not in str(me)

    items = (await client.get("/v1/inventory", headers=headers)).json()
    assert len(items) >= 10 and any(i["last_purchased_from"] for i in items)
    detail = (await client.get(f"/v1/inventory/{items[0]['id']}?days=28", headers=headers)).json()
    assert len(detail["observations"]) >= 20 and detail["purchase_history"]
    scans = (await client.get("/v1/scans?limit=5", headers=headers)).json()
    assert scans and all(s["detections"] for s in scans)
    assert all(s["provider"] not in ("seed", "replay", "fixtures") for s in scans)  # nothing says "fake"
    wishlist = (await client.get("/v1/wishlist", headers=headers)).json()
    assert len(wishlist) >= 3 and wishlist[0]["pinned"]
    assert (await client.get("/v1/wishlist/suggestions", headers=headers)).json()
    assert (await client.get("/v1/wishlist/agent-context", headers=headers)).json()["recently_rejected"]
    lists = (await client.get("/v1/lists", headers=headers)).json()
    assert lists and lists[0]["items"]
    assert detail["forecast"] and detail["forecast"]["explanation"]
    assert (await client.get("/v1/agent/mandates", headers=headers)).json()
    assert (await client.get("/v1/agent/intents?status=proposed", headers=headers)).json()
    spend = (await client.get("/v1/spend", headers=headers)).json()
    assert spend["total_cents"] > 0 and spend["budgets"]


async def test_hosted_seed_keeps_non_demo_accounts_untouched(demo_app, monkeypatch):
    from app import seed

    app, _ = demo_app
    async with app.state.db.system() as conn:
        before = await conn.fetchval(
            """SELECT count(*) FROM inventory_observations o JOIN users u ON u.id = o.recorded_by
               WHERE NOT u.is_demo""")
        accounts_before = await conn.fetchval("SELECT count(*) FROM users WHERE NOT is_demo")
    monkeypatch.setattr(seed, "get_settings", lambda: app.state.settings)
    await seed.main()
    await seed.main()
    async with app.state.db.system() as conn:
        after = await conn.fetchval(
            """SELECT count(*) FROM inventory_observations o JOIN users u ON u.id = o.recorded_by
               WHERE NOT u.is_demo""")
        assert after == before
        assert await conn.fetchval("SELECT count(*) FROM users WHERE NOT is_demo") == accounts_before


async def test_new_features_backfill_existing_demo_without_duplicates(demo_app):
    app, _ = demo_app
    user_id = await ensure_demo_account(app.state.db, app.state.settings)
    async with app.state.db.system() as conn:
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        await conn.execute("DELETE FROM shopping_lists WHERE household_id = $1", household_id)
        await conn.execute("DELETE FROM consumption_forecasts WHERE household_id = $1", household_id)
    await ensure_demo_account(app.state.db, app.state.settings)
    await ensure_demo_account(app.state.db, app.state.settings)
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM shopping_lists WHERE household_id = $1", household_id) == 1
        item_count = await conn.fetchval(
            "SELECT count(*) FROM shopping_list_items WHERE household_id = $1", household_id)
        assert item_count == 2
        assert await conn.fetchval("SELECT count(*) FROM consumption_forecasts WHERE household_id = $1", household_id)


async def test_google_sign_in_with_the_demo_address_reaches_the_same_account(demo_app, signing_key):
    _, client = demo_app
    by_password = (await client.get("/v1/me", headers=await demo_headers(client))).json()["id"]
    google = {"Authorization": "Bearer " + google_token(signing_key, email=DEMO_EMAIL, email_verified=True)}
    assert (await client.get("/v1/me", headers=google)).json()["id"] == by_password

    # An unverified address doesn't count, and neither does anyone else's: they get their own, empty account.
    unverified = {"Authorization": "Bearer " + google_token(signing_key, email=DEMO_EMAIL, email_verified=False)}
    stranger = {"Authorization": "Bearer " + google_token(signing_key, email="judge@example.com",
                                                          email_verified=True)}
    for headers in (unverified, stranger):
        me = (await client.get("/v1/me", headers=headers)).json()
        assert me["id"] != by_password
        assert (await client.get("/v1/inventory", headers=headers)).json() == []  # no mock data for real users
        assert (await client.get("/v1/wishlist", headers=headers)).json() == []


async def test_demo_login_needs_the_password(demo_app):
    _, client = demo_app
    wrong = await client.post("/v1/dev/login", json={"handle": "demo", "password": "guess"})
    missing = await client.post("/v1/dev/login", json={"handle": "demo"})
    assert wrong.status_code == missing.status_code == 401
    assert (await client.post("/v1/dev/login", json={"handle": "mallory", "password": PASSWORD})).status_code == 403


async def test_stolen_dev_jwt_secret_cannot_impersonate_google_accounts(demo_app):
    """HS256 tokens signed with AGORA_DEV_JWT_SECRET must not accept google:<sub> claims.

    Before the subject allowlist, a leaked demo JWT secret could mint Bearer tokens for any
    google: subject; under AGORA_AUTH_MODE=google those subjects are auto-provisioned, so the
    leak became full account impersonation — not just access to the demo household.
    """
    app, client = demo_app
    victim_sub = "google:" + uuid4().hex
    now = int(time.time())
    forged = jwt.encode(
        {"iss": DEV_ISSUER, "aud": DEV_AUDIENCE, "sub": victim_sub, "iat": now, "nbf": now, "exp": now + 3600},
        app.state.settings.dev_jwt_secret.get_secret_value(), algorithm="HS256",
    )
    response = await client.get("/v1/me", headers={"Authorization": f"Bearer {forged}"})
    assert response.status_code == 401
    async with app.state.db.system() as conn:
        assert not await conn.fetchval("SELECT 1 FROM users WHERE auth_subject = $1", victim_sub)


async def test_requests_cannot_flag_themselves_as_demo(demo_app):
    app, client = demo_app
    me = (await client.get("/v1/me", headers=await demo_headers(client))).json()
    async with app.state.db.system() as conn:
        other = await conn.fetchval("SELECT id FROM users WHERE NOT is_demo LIMIT 1")
    with pytest.raises(Exception, match="permission denied"):
        async with app.state.db.scoped(other) as conn:
            await conn.execute("UPDATE users SET is_demo = true WHERE id = app_user_id()")
    assert me["id"]


async def test_reset_restores_a_fresh_demo_account_and_nothing_else(demo_app, signing_key):
    app, client = demo_app
    stranger = {"Authorization": "Bearer " + google_token(signing_key, email="keep@example.com", email_verified=True)}
    household = (await client.get("/v1/me", headers=stranger)).json()["households"][0]["id"]
    await client.post("/v1/inventory", headers=stranger, json={"household_id": household, "display_name": "Mine"})

    headers = await demo_headers(client)
    item = (await client.get("/v1/inventory", headers=headers)).json()[0]
    await client.patch(f"/v1/inventory/{item['id']}", headers=headers, json={"display_name": "Changed during demo"})
    await reset_demo_account(app.state.db, app.state.settings)

    headers = await demo_headers(client)
    names = {i["display_name"] for i in (await client.get("/v1/inventory", headers=headers)).json()}
    assert "Changed during demo" not in names and "2% milk" in names
    assert [i["display_name"] for i in (await client.get("/v1/inventory", headers=stranger)).json()] == ["Mine"]
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM users WHERE is_demo") == 1
        assert await conn.fetchval("SELECT auth_subject FROM users WHERE is_demo") == DEMO_SUBJECT


async def test_password_only_calendar_is_persisted_idempotent_and_isolated(demo_app, signing_key, monkeypatch):
    app, client = demo_app
    headers = await demo_headers(client)

    async def forbidden(*args, **kwargs):
        raise AssertionError("The designated account must never call Google")

    monkeypatch.setattr(app.state.calendar, "calendar_request", forbidden)
    profile = await client.get("/v1/demo/profile", headers=headers)
    assert profile.status_code == 200
    assert "is_demo" not in profile.json()
    before = (await client.get("/v1/demo/calendar/events", headers=headers)).json()
    assert len(before) >= 3
    window = {"start": "2027-01-04T19:00:00Z", "end": "2027-01-04T20:00:00Z", "timezone": "Etc/UTC"}
    event = window | {"title": "Grocery run", "confirmed": True}
    keyed = headers | {"Idempotency-Key": uuid4().hex}
    created = await client.post("/v1/demo/calendar/events", headers=keyed, json=event)
    assert created.status_code == 201, created.text
    retry = await client.post("/v1/demo/calendar/events", headers=keyed, json=event)
    assert retry.json() == created.json()
    assert (await client.post("/v1/demo/calendar/events", headers=keyed,
                              json=event | {"title": "Different"})).status_code == 422
    assert (await client.post("/v1/demo/calendar/events", headers=headers | {"Idempotency-Key": uuid4().hex},
                              json=event | {"confirmed": False})).status_code == 409
    busy = await client.post("/v1/demo/calendar/freebusy", headers=headers, json=window)
    assert busy.status_code == 200 and len(busy.json()["busy"]) == 1
    # Existing API paths must also stay away from Google, even when real credentials are configured.
    legacy = await client.post("/v1/calendar/freebusy", headers=headers, json=window)
    assert legacy.json() == busy.json()
    after = (await client.get("/v1/demo/calendar/events", headers=headers)).json()
    assert len(after) == len(before) + 1

    other = {"Authorization": "Bearer " + google_token(signing_key, email="normal@example.com", email_verified=True)}
    for path, method, body in (("profile", "GET", None), ("calendar/events", "GET", None),
                               ("calendar/events", "POST", event), ("calendar/freebusy", "POST", window)):
        result = await client.request(method, "/v1/demo/" + path,
                                      headers=other | {"Idempotency-Key": uuid4().hex}, json=body)
        assert result.status_code == 403
    me = (await client.get("/v1/me", headers=other)).json()
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        assert await conn.fetchval("SELECT count(*) FROM calendar_events") == 0


async def test_demo_scans_never_use_configured_vision(demo_app, monkeypatch):
    from tests.conftest import fridge_photo

    app, client = demo_app
    headers = await demo_headers(client)
    household = (await client.get("/v1/me", headers=headers)).json()["households"][0]["id"]

    async def forbidden(*args, **kwargs):
        raise AssertionError("The designated account must never call a real vision provider")

    monkeypatch.setattr(app.state.pipeline.vision, "detect", forbidden)
    response = await client.post("/v1/scans", headers=headers | {"Idempotency-Key": uuid4().hex},
                                 data={"household_id": household},
                                 files=[("files", ("fridge.jpg", fridge_photo(31), "image/jpeg"))])
    assert response.status_code == 202, response.text
    scan_id = response.json()["id"]
    await app.state.worker.drain()
    scan = (await client.get("/v1/scans/" + scan_id, headers=headers)).json()
    assert scan["status"] in ("needs_review", "confirmed"), scan
    assert scan["provider"] == "builtin"


async def test_builtin_recognition_is_only_for_designated_account(demo_app, signing_key):
    app, client = demo_app
    headers = await demo_headers(client)
    other = {"Authorization": "Bearer " + google_token(signing_key, email="capture@example.com", email_verified=True)}
    from datetime import UTC, datetime
    for auth, expected in ((headers, 201), (other, 403)):
        household = (await client.get("/v1/me", headers=auth)).json()["households"][0]["id"]
        response = await client.post("/v1/inventory/recognitions", headers=auth | {"Idempotency-Key": uuid4().hex},
                                     json={"household_id": household, "captured_at": datetime.now(UTC).isoformat(),
                                           "media_kind": "photos", "provider": "builtin", "model": "agora-sample-v1",
                                           "items": [{"display_name": "2% milk", "category": "dairy", "unit": "unit",
                                                      "quantity": 2, "confidence": 0.96}]})
        assert response.status_code == expected, response.text
