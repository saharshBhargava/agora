import asyncio
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.notifications import NotificationService
from app.price_search import SearchResult
from tests.conftest import login
from tests.test_watches import new_watch, offer, run_watch


def _settings(watch_daily_alert_cap: int = 20):
    key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return SimpleNamespace(apns_enabled=True, apns_key_id="KEY123", apns_team_id="TEAM123",
                           watch_daily_alert_cap=watch_daily_alert_cap,
                           apns_private_key=key.decode(), apns_topic="dev.agora.browserchat")


async def _delivery_rows(client, app, handle: str, *, notification_count: int = 1) -> dict:
    headers = await login(client, handle)
    me = (await client.get("/v1/me", headers=headers)).json()
    household_id, user_id = me["households"][0]["id"], me["id"]
    wishlist = await client.post("/v1/wishlist", headers=headers,
                                 json={"household_id": household_id, "title": f"Coffee {handle}"})
    assert wishlist.status_code == 201, wishlist.text
    now = datetime.now(UTC)
    async with app.state.db.system() as conn:
        watch_id = await conn.fetchval(
            """INSERT INTO price_watches (household_id, wishlist_item_id, created_by, status, criteria,
                                            confirmed_at)
               VALUES ($1, $2, $3, 'active', '{}'::jsonb, $4) RETURNING id""",
            household_id, wishlist.json()["id"], user_id, now)
        listing_id = await conn.fetchval(
            """INSERT INTO watch_listings (household_id, watch_id, url, merchant)
               VALUES ($1, $2, $3, 'Market') RETURNING id""",
            household_id, watch_id, f"https://example.test/{handle}")
        run_id = await conn.fetchval(
            """INSERT INTO watch_runs (household_id, watch_id, user_id, criteria_version, status, trigger)
               VALUES ($1, $2, $3, 1, 'succeeded', 'manual') RETURNING id""",
            household_id, watch_id, user_id)
        observation_id = await conn.fetchval(
            """INSERT INTO watch_observations (household_id, watch_id, listing_id, run_id, criteria_version,
                                                offer, observed_at, eligible, reason)
               VALUES ($1, $2, $3, $4, 1, '{}'::jsonb, $5, true, 'matched') RETURNING id""",
            household_id, watch_id, listing_id, run_id, now)
        notification_ids = []
        for index in range(notification_count):
            match_id = await conn.fetchval(
                """INSERT INTO watch_matches (household_id, watch_id, observation_id, criteria_version, fingerprint,
                       title, url, merchant, unit_price_cents, currency, quantity, fulfillment, location, condition,
                       observed_at, evidence, reason)
                   VALUES ($1,$2,$3,1,$4,'Coffee','https://example.test/item','Market',800,'USD',1,'pickup',
                           'Seattle','new',$5,'[]'::jsonb,'below_target') RETURNING id""",
                household_id, watch_id, observation_id, f"{handle}-{index}", now)
            notification_id = await conn.fetchval(
                """INSERT INTO notifications (household_id, user_id, watch_id, match_id, title, body, created_at)
                   VALUES ($1,$2,$3,$4,'Coffee is on sale','Now $8 at Market',$5) RETURNING id""",
                household_id, user_id, watch_id, match_id, now)
            outbox_id = await conn.fetchval(
                """INSERT INTO notification_outbox (household_id, user_id, notification_id)
                   VALUES ($1,$2,$3) RETURNING id""",
                household_id, user_id, notification_id)
            notification_ids.append((notification_id, outbox_id))
        await conn.execute(
            """INSERT INTO watch_subscriptions (watch_id, household_id, user_id, push_enabled, timezone,
                                                daily_cap, cooldown_hours)
               VALUES ($1, $2, $3, true, 'UTC', 3, 24)""",
            watch_id, household_id, user_id)
        token = uuid4().hex * 2
        await conn.execute(
            "INSERT INTO push_devices (user_id, token, environment) VALUES ($1, $2, 'sandbox')", user_id, token)
    return {"headers": headers, "household_id": household_id, "user_id": user_id, "watch_id": watch_id,
            "notification_ids": notification_ids, "token": token}


async def _add_delivery_watch(client, app, rows: dict, suffix: str) -> tuple:
    wishlist = await client.post("/v1/wishlist", headers=rows["headers"],
                                 json={"household_id": rows["household_id"], "title": f"Tea {suffix}"})
    assert wishlist.status_code == 201, wishlist.text
    now = datetime.now(UTC)
    async with app.state.db.system() as conn:
        watch_id = await conn.fetchval(
            """INSERT INTO price_watches (household_id, wishlist_item_id, created_by, status, criteria, confirmed_at)
               VALUES ($1, $2, $3, 'active', '{}'::jsonb, $4) RETURNING id""",
            rows["household_id"], wishlist.json()["id"], rows["user_id"], now)
        listing_id = await conn.fetchval(
            "INSERT INTO watch_listings (household_id, watch_id, url, merchant) "
            "VALUES ($1, $2, $3, 'Market') RETURNING id",
            rows["household_id"], watch_id, f"https://example.test/{suffix}")
        run_id = await conn.fetchval(
            """INSERT INTO watch_runs (household_id, watch_id, user_id, criteria_version, status, trigger)
               VALUES ($1, $2, $3, 1, 'succeeded', 'manual') RETURNING id""",
            rows["household_id"], watch_id, rows["user_id"])
        observation_id = await conn.fetchval(
            """INSERT INTO watch_observations (household_id, watch_id, listing_id, run_id, criteria_version,
                                               offer, observed_at, eligible, reason)
               VALUES ($1, $2, $3, $4, 1, '{}'::jsonb, $5, true, 'matched') RETURNING id""",
            rows["household_id"], watch_id, listing_id, run_id, now)
        match_id = await conn.fetchval(
            """INSERT INTO watch_matches (household_id, watch_id, observation_id, criteria_version, fingerprint,
                   title, url, merchant, unit_price_cents, currency, quantity, fulfillment, location, condition,
                   observed_at, evidence, reason)
               VALUES ($1,$2,$3,1,$4,'Tea','https://example.test/tea','Market',500,'USD',1,'pickup',
                       'Seattle','new',$5,'[]'::jsonb,'below_target') RETURNING id""",
            rows["household_id"], watch_id, observation_id, suffix, now)
        notification_id = await conn.fetchval(
            """INSERT INTO notifications (household_id, user_id, watch_id, match_id, title, body)
               VALUES ($1,$2,$3,$4,'Tea is on sale','Now $5 at Market') RETURNING id""",
            rows["household_id"], rows["user_id"], watch_id, match_id)
        outbox_id = await conn.fetchval(
            "INSERT INTO notification_outbox (household_id, user_id, notification_id) VALUES ($1,$2,$3) RETURNING id",
            rows["household_id"], rows["user_id"], notification_id)
        await conn.execute(
            "INSERT INTO watch_subscriptions (watch_id, household_id, user_id, push_enabled, timezone) "
            "VALUES ($1,$2,$3,true,'UTC')", watch_id, rows["household_id"], rows["user_id"])
    return watch_id, notification_id, outbox_id


def _mock_apns(responses: list[int], requests: list[httpx.Request]) -> httpx.AsyncClient:
    async def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(responses.pop(0) if responses else 200)

    return httpx.AsyncClient(transport=httpx.MockTransport(respond), follow_redirects=False)


@pytest.mark.parametrize(("status", "expected"), [(200, None), (410, "invalidated"), (429, "retry:http_429"),
                                                     (503, "retry:http_503"), (400, "permanent:http_400")])
async def test_apns_transport_maps_delivery_results(status, expected):
    requests = []
    created_at = datetime.now(UTC)
    observed_at = created_at - timedelta(minutes=5)

    async def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(status)

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond), follow_redirects=False) as client:
        service = NotificationService(None, _settings(), client)
        result = await service._send(
            {"id": "device-id", "token": "a" * 64, "environment": "sandbox"},
            {"notification_id": "00000000-0000-0000-0000-000000000001", "watch_id": "watch-id",
             "title": "Coffee is on sale", "body": "Now $8 at Market",
             "created_at": created_at, "observed_at": observed_at},
        )

    assert result == expected
    request = requests[0]
    assert request.url.host == "api.sandbox.push.apple.com"
    assert request.url.path == f"/3/device/{'a' * 64}"
    assert request.headers["apns-topic"] == "dev.agora.browserchat"
    assert request.headers["apns-push-type"] == "alert"
    assert request.headers["apns-id"] == "00000000-0000-0000-0000-000000000001"
    assert int(request.headers["apns-expiration"]) == int((observed_at + timedelta(minutes=30)).timestamp())
    assert request.headers["authorization"].startswith("bearer ")
    assert request.read()


async def test_apns_transport_retries_network_errors():
    async def unavailable(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection failed", request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(unavailable)) as client:
        service = NotificationService(None, _settings(), client)
        result = await service._send(
            {"id": "device-id", "token": "a" * 64, "environment": "production"},
            {"notification_id": "00000000-0000-0000-0000-000000000001", "watch_id": "watch-id",
             "title": "Coffee is on sale", "body": "Now $8 at Market",
             "created_at": datetime.now(UTC), "observed_at": datetime.now(UTC)},
        )
    assert result == "retry:network_error"


async def test_push_device_registration_is_idempotent_and_hides_token(client):
    headers = await login(client, "notification_device")
    token = "ab" * 32
    first = await client.post("/v1/push-devices", headers=headers,
                              json={"token": token, "environment": "sandbox"})
    second = await client.post("/v1/push-devices", headers=headers,
                               json={"token": token.upper(), "environment": "sandbox"})

    assert first.status_code == second.status_code == 200, (first.text, second.text)
    assert first.json()["id"] == second.json()["id"]
    assert first.json()["delivery_status"] in {"available", "unavailable"}
    assert token not in first.text.lower()

    new_account = await login(client, "notification_device_switch")
    transferred = await client.post("/v1/push-devices", headers=new_account,
                                    json={"token": token, "environment": "sandbox"})
    assert transferred.status_code == 200, transferred.text
    assert transferred.json()["id"] == first.json()["id"]

    old_account_delete = await client.delete(f"/v1/push-devices/{first.json()['id']}", headers=headers)
    assert old_account_delete.status_code == 404
    deleted = await client.delete(f"/v1/push-devices/{first.json()['id']}", headers=new_account)
    assert deleted.status_code == 204, deleted.text
    missing = await client.delete(f"/v1/push-devices/{first.json()['id']}", headers=headers)
    assert missing.status_code == 404

    max_token = "cd" * 256
    at_limit = await client.post("/v1/push-devices", headers=new_account,
                                 json={"token": max_token, "environment": "production"})
    assert at_limit.status_code == 200, at_limit.text
    too_long = await client.post("/v1/push-devices", headers=new_account,
                                 json={"token": max_token + "ab", "environment": "production"})
    assert too_long.status_code == 422


async def test_notification_inbox_is_user_scoped_and_read_mutation_is_audited(client, app):
    first_headers = await login(client, "notification_owner")
    second_headers = await login(client, "notification_other")
    first_me = await client.get("/v1/me", headers=first_headers)
    household_id = first_me.json()["households"][0]["id"]
    first_user_id = first_me.json()["id"]
    wishlist = await client.post("/v1/wishlist", headers=first_headers,
                                 json={"household_id": household_id, "title": "Coffee"})
    assert wishlist.status_code == 201, wishlist.text
    wishlist_item_id = wishlist.json()["id"]
    second_me = await client.get("/v1/me", headers=second_headers)

    async with app.state.db.system() as conn:
        watch_id = await conn.fetchval(
            """INSERT INTO price_watches (household_id, wishlist_item_id, created_by, criteria)
               VALUES ($1, $2, $3, '{}'::jsonb) RETURNING id""",
            household_id, wishlist_item_id, first_user_id)
        assert watch_id is not None
        match_id = await conn.fetchval(
            """INSERT INTO watch_matches (household_id, watch_id, observation_id, criteria_version, fingerprint,
                                          title, url, merchant, unit_price_cents, currency, quantity,
                                          fulfillment, location, condition, observed_at, evidence, reason)
               SELECT $1, $2, o.id, 1, gen_random_uuid()::text, 'Coffee', 'https://example.test/coffee',
                      'Market', 800, 'USD', 1, 'pickup', 'Seattle', 'new', now(), '[]'::jsonb, 'below_target'
               FROM watch_observations o WHERE o.watch_id = $2 ORDER BY o.observed_at DESC LIMIT 1
               RETURNING id""", household_id, watch_id)
        if match_id is None:
            # The notification table's foreign keys make a realistic match necessary; no watch data is seeded
            # for ordinary accounts, so seed one minimal listing/run/observation chain for this test.
            listing_id = await conn.fetchval(
                "INSERT INTO watch_listings (household_id, watch_id, url, merchant) "
                "VALUES ($1, $2, 'https://example.test/coffee', 'Market') RETURNING id", household_id, watch_id)
            run_id = await conn.fetchval(
                "INSERT INTO watch_runs (household_id, watch_id, user_id, criteria_version, trigger) "
                "VALUES ($1, $2, $3, 1, 'manual') RETURNING id", household_id, watch_id, first_user_id)
            observation_id = await conn.fetchval(
                """INSERT INTO watch_observations (household_id, watch_id, listing_id, run_id,
                         criteria_version, offer, observed_at, eligible, reason)
                   VALUES ($1, $2, $3, $4, 1, '{}'::jsonb, now(), true, 'matched') RETURNING id""",
                household_id, watch_id, listing_id, run_id)
            match_id = await conn.fetchval(
                """INSERT INTO watch_matches (household_id, watch_id, observation_id, criteria_version, fingerprint,
                        title, url, merchant, unit_price_cents, currency, quantity, fulfillment, location, condition,
                        observed_at, evidence, reason)
                   VALUES ($1,$2,$3,1,gen_random_uuid()::text,'Coffee','https://example.test/coffee','Market',800,
                          'USD',1,'pickup','Seattle','new',now(),'[]'::jsonb,'below_target') RETURNING id""",
                household_id, watch_id, observation_id)
        notification_id = await conn.fetchval(
            """INSERT INTO notifications (household_id, user_id, watch_id, match_id, title, body)
               VALUES ($1, $2, $3, $4, 'Coffee is on sale', 'Now $8 at Market') RETURNING id""",
            household_id, first_user_id, watch_id, match_id)

    own = await client.get(f"/v1/notifications?household_id={household_id}", headers=first_headers)
    other_household_id = second_me.json()["households"][0]["id"]
    other = await client.get(f"/v1/notifications?household_id={other_household_id}", headers=second_headers)
    assert own.status_code == other.status_code == 200, (own.text, other.text)
    assert [item["id"] for item in own.json()] == [str(notification_id)]
    assert other.json() == []
    forbidden_read = await client.post(f"/v1/notifications/{notification_id}/read", headers=second_headers)
    assert forbidden_read.status_code == 404

    read = await client.post(f"/v1/notifications/{notification_id}/read", headers=first_headers)
    assert read.status_code == 200, read.text
    assert datetime.fromisoformat(read.json()["read_at"].replace("Z", "+00:00")).tzinfo == UTC
    unread = await client.get(f"/v1/notifications?household_id={household_id}&unread_only=true",
                              headers=first_headers)
    assert unread.json() == []
    async with app.state.db.system() as conn:
        audit_row = await conn.fetchrow(
            "SELECT action, target_type, target_id, meta FROM audit_log "
            "WHERE target_type = 'notification' AND target_id = $1 ORDER BY time DESC LIMIT 1",
            str(notification_id))
    assert audit_row["action"] == "notification.read"
    assert audit_row["meta"] == {}


async def test_outbox_retries_and_notification_job_delivers_when_due(client, app):
    rows = await _delivery_rows(client, app, "notification_retry")
    notification_id, outbox_id = rows["notification_ids"][0]
    requests = []
    async with _mock_apns([503, 200], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        claimed = await service.send_pending(notification_id=str(notification_id))
        assert claimed == 1
        async with app.state.db.system() as conn:
            retry = await conn.fetchrow(
                "SELECT status, attempts, last_error, run_at FROM notification_outbox WHERE id = $1", outbox_id)
            assert retry["status"] == "pending"
            assert retry["attempts"] == 1
            assert retry["last_error"] == "http_503"
            assert retry["run_at"] > datetime.now(UTC)
            await conn.execute("UPDATE notification_outbox SET run_at = now() WHERE id = $1", outbox_id)

        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 2)
        async with app.state.db.system() as conn:
            sent = await conn.fetchrow(
                "SELECT status, attempts, delivered_at FROM notification_outbox WHERE id = $1", outbox_id)
        assert sent["status"] == "sent"
        assert sent["attempts"] == 2
        assert sent["delivered_at"] is not None
    assert len(requests) == 2
    assert all(request.headers["apns-expiration"] for request in requests)


async def test_offer_valid_until_caps_apns_expiration(client, app):
    rows = await _delivery_rows(client, app, "notification_valid_until")
    notification_id, _outbox_id = rows["notification_ids"][0]
    valid_until = datetime.now(UTC) + timedelta(minutes=5)
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE watch_observations SET offer=jsonb_build_object('valid_until',$2::text) WHERE watch_id=$1",
            rows["watch_id"], valid_until.isoformat())

    requests = []
    async with _mock_apns([200], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))

    assert len(requests) == 1
    assert int(requests[0].headers["apns-expiration"]) == int(valid_until.timestamp())


async def test_expired_offer_revalidates_instead_of_sending(client, app):
    rows = await _delivery_rows(client, app, "notification_expired_offer")
    notification_id, outbox_id = rows["notification_ids"][0]
    expired = datetime.now(UTC) - timedelta(minutes=1)
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE watch_observations SET offer=jsonb_build_object('valid_until',$2::text) WHERE watch_id=$1",
            rows["watch_id"], expired.isoformat())

    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))

    assert requests == []
    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status, run_at FROM notification_outbox WHERE id=$1", outbox_id)
        run = await conn.fetchrow(
            "SELECT status, trigger FROM watch_runs WHERE watch_id=$1 ORDER BY created_at DESC LIMIT 1",
            rows["watch_id"])
    assert outbox["status"] == "pending"
    assert outbox["run_at"] > datetime.now(UTC)
    assert (run["status"], run["trigger"]) == ("queued", "scheduled")


async def test_each_device_is_revalidated_before_apns_request(client, app):
    rows = await _delivery_rows(client, app, "notification_device_freshness")
    notification_id, _outbox_id = rows["notification_ids"][0]
    valid_until = datetime.now(UTC) + timedelta(milliseconds=120)
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE watch_observations SET offer=jsonb_build_object('valid_until',$2::text) WHERE watch_id=$1",
            rows["watch_id"], valid_until.isoformat())
        await conn.execute(
            "INSERT INTO push_devices (user_id,token,environment) VALUES ($1,$2,'sandbox')",
            rows["user_id"], uuid4().hex * 2)

    requests = []

    async def slow_first_device(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        await asyncio.sleep(0.15)
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(slow_first_device)) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))

    assert len(requests) == 1


async def test_second_device_policy_suppression_is_not_overwritten_by_retry(client, app):
    rows = await _delivery_rows(client, app, "notify_pause_devices")
    notification_id, outbox_id = rows["notification_ids"][0]
    async with app.state.db.system() as conn:
        await conn.execute(
            "INSERT INTO push_devices (user_id,token,environment) VALUES ($1,$2,'sandbox')",
            rows["user_id"], uuid4().hex * 2)

    requests = []

    async def fail_first_then_pause(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        async with app.state.db.system() as conn:
            await conn.execute("UPDATE user_settings SET agent_paused_at=now() WHERE user_id=$1", rows["user_id"])
        return httpx.Response(429)

    async with httpx.AsyncClient(transport=httpx.MockTransport(fail_first_then_pause)) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))

    assert len(requests) == 1
    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status,last_error FROM notification_outbox WHERE id=$1", outbox_id)
    assert outbox["status"] == "suppressed"
    assert outbox["last_error"] == "delivery_no_longer_allowed"


async def test_delivery_timeout_releases_outbox_before_lease_expiry(client, app):
    rows = await _delivery_rows(client, app, "notify_delivery_timeout")
    notification_id, outbox_id = rows["notification_ids"][0]
    async with app.state.db.system() as conn:
        await conn.execute(
            "INSERT INTO push_devices (user_id,token,environment) VALUES ($1,$2,'sandbox')",
            rows["user_id"], uuid4().hex * 2)

    async def stalled(request: httpx.Request) -> httpx.Response:
        await asyncio.Event().wait()
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(stalled)) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        service.delivery_timeout_seconds = 0.02
        await service.send_pending(notification_id=str(notification_id))

    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow(
            "SELECT status,attempts,last_error,run_at,locked_until FROM notification_outbox WHERE id=$1", outbox_id)
    assert outbox["status"] == "pending"
    assert outbox["attempts"] == 1
    assert outbox["last_error"] == "delivery_timeout"
    assert outbox["run_at"] > datetime.now(UTC)
    assert outbox["locked_until"] is None


@pytest.mark.parametrize("mode", ["stale", "criteria_changed", "paused", "membership_removed"])
async def test_service_suppresses_stale_or_no_longer_allowed_matches(client, app, mode):
    rows = await _delivery_rows(client, app, f"ns_{mode}")
    notification_id, outbox_id = rows["notification_ids"][0]
    async with app.state.db.system() as conn:
        if mode == "stale":
            old = datetime.now(UTC) - timedelta(hours=25)
            await conn.execute("UPDATE notifications SET created_at = $2 WHERE id = $1", notification_id, old)
            await conn.execute("UPDATE watch_observations SET observed_at = $2 WHERE watch_id = $1",
                               rows["watch_id"], old)
            await conn.execute("UPDATE watch_matches SET observed_at = $2 WHERE watch_id = $1",
                               rows["watch_id"], old)
        elif mode == "criteria_changed":
            await conn.execute("UPDATE price_watches SET criteria_version = criteria_version + 1 "
                               "WHERE id = $1", rows["watch_id"])
        elif mode == "paused":
            await conn.execute("UPDATE user_settings SET agent_paused_at = now() WHERE user_id = $1",
                               rows["user_id"])
        else:
            await conn.execute("DELETE FROM household_members WHERE household_id = $1 AND user_id = $2",
                               rows["household_id"], rows["user_id"])

    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        assert await service.send_pending(notification_id=str(notification_id)) == 1
    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status, last_error FROM notification_outbox WHERE id = $1", outbox_id)
    assert outbox["status"] == "suppressed"
    assert outbox["last_error"]
    assert requests == []


async def test_quiet_hour_defers_then_job_sends_after_preferences_change(client, app):
    rows = await _delivery_rows(client, app, "notification_quiet")
    notification_id, outbox_id = rows["notification_ids"][0]
    hour = datetime.now(UTC).hour
    quiet_start, quiet_end = (hour - 1) % 24, (hour + 1) % 24
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE watch_subscriptions SET quiet_start_hour = $2, quiet_end_hour = $3 "
                           "WHERE watch_id = $1", rows["watch_id"], quiet_start, quiet_end)

    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            deferred = await conn.fetchrow(
                "SELECT status, run_at FROM notification_outbox WHERE id = $1", outbox_id)
            assert deferred["status"] == "pending"
            assert deferred["run_at"] > datetime.now(UTC)
            await conn.execute("UPDATE watch_subscriptions SET quiet_start_hour = NULL, quiet_end_hour = NULL "
                               "WHERE watch_id = $1", rows["watch_id"])
            await conn.execute("UPDATE notification_outbox SET run_at = now() WHERE id = $1", outbox_id)
        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 1)
    assert len(requests) == 1


async def test_overnight_notification_revalidates_then_sends_same_fresh_match(client, app):
    rows = await _delivery_rows(client, app, "notification_overnight")
    notification_id, outbox_id = rows["notification_ids"][0]
    old = datetime.now(UTC) - timedelta(hours=20)
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE notifications SET created_at = $2 WHERE id = $1", notification_id, old)
        await conn.execute("UPDATE watch_observations SET observed_at = $2 WHERE watch_id = $1",
                           rows["watch_id"], old)
        await conn.execute("UPDATE watch_matches SET observed_at = $2 WHERE watch_id = $1",
                           rows["watch_id"], old)

    requests = []
    async with _mock_apns([200], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            deferred = await conn.fetchrow(
                "SELECT status, run_at FROM notification_outbox WHERE id = $1", outbox_id)
            assert deferred["status"] == "pending"
            assert deferred["run_at"] > datetime.now(UTC)
            queued = await conn.fetchrow(
                "SELECT id, status, trigger FROM watch_runs WHERE watch_id = $1 ORDER BY created_at DESC LIMIT 1",
                rows["watch_id"])
            assert queued["status"] == "queued"
            assert queued["trigger"] == "scheduled"

            fresh = datetime.now(UTC)
            observation_id = await conn.fetchval(
                """INSERT INTO watch_observations (household_id, watch_id, listing_id, run_id, criteria_version,
                                                     offer, observed_at, eligible, reason)
                   SELECT household_id, watch_id, listing_id, $2, criteria_version, offer, $3, true, 'matched'
                   FROM watch_observations WHERE watch_id = $1 ORDER BY observed_at DESC LIMIT 1
                   RETURNING id""",
                rows["watch_id"], queued["id"], fresh)
            await conn.execute("UPDATE watch_runs SET status = 'succeeded', finished_at = now() WHERE id = $1",
                               queued["id"])
            await conn.execute("UPDATE watch_matches SET observation_id = $2, observed_at = $3 WHERE watch_id = $1",
                               rows["watch_id"], observation_id, fresh)
            await conn.execute("UPDATE notification_outbox SET run_at = now() WHERE id = $1", outbox_id)

        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 1)

    assert len(requests) == 1
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT status FROM notification_outbox WHERE id = $1", outbox_id) == "sent"


async def test_overnight_notification_suppresses_when_recheck_finds_unavailable_offer(client, app):
    rows = await _delivery_rows(client, app, "notify_overnight_unavail")
    notification_id, outbox_id = rows["notification_ids"][0]
    old = datetime.now(UTC) - timedelta(hours=20)
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE notifications SET created_at = $2 WHERE id = $1", notification_id, old)
        await conn.execute("UPDATE watch_observations SET observed_at = $2 WHERE watch_id = $1",
                           rows["watch_id"], old)
        await conn.execute("UPDATE watch_matches SET observed_at = $2 WHERE watch_id = $1",
                           rows["watch_id"], old)

    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            queued = await conn.fetchrow(
                "SELECT id FROM watch_runs WHERE watch_id = $1 ORDER BY created_at DESC LIMIT 1",
                rows["watch_id"])
            listing_id = await conn.fetchval(
                "SELECT listing_id FROM watch_observations WHERE watch_id = $1 ORDER BY observed_at DESC LIMIT 1",
                rows["watch_id"])
            await conn.execute(
                """INSERT INTO watch_observations (household_id, watch_id, listing_id, run_id, criteria_version,
                                                   offer, observed_at, eligible, reason)
                   VALUES ($1,$2,$3,$4,1,'{}'::jsonb,now(),false,'out_of_stock')""",
                rows["household_id"], rows["watch_id"], listing_id, queued["id"])
            await conn.execute("UPDATE watch_runs SET status = 'succeeded', finished_at = now() WHERE id = $1",
                               queued["id"])
            await conn.execute("UPDATE notification_outbox SET run_at = now() WHERE id = $1", outbox_id)
        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 1)

    assert requests == []
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT status FROM notification_outbox WHERE id = $1", outbox_id) == "suppressed"


async def test_overnight_higher_qualifying_price_coalesces_stale_pending_notification(client, app, monkeypatch):
    headers, me, _item, watch = await new_watch(
        client, "notify_coalesce", subscription={"push_enabled": True, "daily_cap": 1})

    async def search_initial(criteria, urls):
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, "search", search_initial)
    await run_watch(app, watch)
    async with app.state.db.system() as conn:
        await conn.execute("INSERT INTO push_devices (user_id,token,environment) VALUES ($1,$2,'sandbox')",
                           me["id"], uuid4().hex * 2)
        notification_id = await conn.fetchval("SELECT id FROM notifications WHERE watch_id=$1", watch["id"])
        outbox_id = await conn.fetchval("SELECT id FROM notification_outbox WHERE notification_id=$1", notification_id)
        old = datetime.now(UTC) - timedelta(hours=20)
        await conn.execute("UPDATE notifications SET created_at=$2 WHERE id=$1", notification_id, old)
        await conn.execute("UPDATE watch_observations SET observed_at=$2 WHERE watch_id=$1", watch["id"], old)
        await conn.execute("UPDATE watch_matches SET observed_at=$2 WHERE watch_id=$1", watch["id"], old)

    requests = []
    async with _mock_apns([200], requests) as transport:
        service = NotificationService(app.state.db, _settings(watch_daily_alert_cap=1), transport)
        await service.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            recheck = await conn.fetchrow(
                "SELECT id, watch_id, user_id FROM watch_runs WHERE watch_id=$1 ORDER BY created_at DESC LIMIT 1",
                watch["id"])

        async def search_current(criteria, urls):
            return SearchResult(offers=[
                offer(price_cents=3299, url="https://www.lodgecastiron.com/skillet/high"),
                offer(price_cents=3099, url="https://www.lodgecastiron.com/skillet/low"),
            ], checked_count=2)

        monkeypatch.setattr(app.state.watches.provider, "search", search_current)
        await app.state.watches.check_job(
            {"run_id": str(recheck["id"]), "watch_id": str(watch["id"]), "user_id": str(me["id"])}, 1)

        async with app.state.db.system() as conn:
            inbox = await conn.fetchrow(
                "SELECT match_id, body, created_at FROM notifications WHERE id=$1", notification_id)
            assert await conn.fetchval("SELECT count(*) FROM notifications WHERE watch_id=$1", watch["id"]) == 1
            assert await conn.fetchval(
                "SELECT count(*) FROM notification_outbox WHERE notification_id=$1", notification_id) == 1
            assert "$30.99" in inbox["body"]
            assert inbox["created_at"] == old
            fresh_observed_at = await conn.fetchval(
                "SELECT observed_at FROM watch_matches WHERE id=$1", inbox["match_id"])
            await conn.execute("UPDATE notification_outbox SET run_at=now() WHERE id=$1", outbox_id)

        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 1)

    assert len(requests) == 1
    assert b"$30.99" in requests[0].content
    assert int(requests[0].headers["apns-expiration"]) == int(
        (fresh_observed_at + timedelta(minutes=30)).timestamp())
    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status FROM notification_outbox WHERE id=$1", outbox_id)
    assert outbox["status"] == "sent"


async def test_expired_valid_until_pending_match_is_replaced_by_higher_qualifying_offer(client, app, monkeypatch):
    _headers, me, _item, watch = await new_watch(
        client, "notify_expired_validuntil", subscription={"push_enabled": True, "daily_cap": 1})

    async def search_initial(criteria, urls):
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, "search", search_initial)
    await run_watch(app, watch)
    async with app.state.db.system() as conn:
        await conn.execute("INSERT INTO push_devices (user_id,token,environment) VALUES ($1,$2,'sandbox')",
                           me["id"], uuid4().hex * 2)
        notification_id = await conn.fetchval("SELECT id FROM notifications WHERE watch_id=$1", watch["id"])
        outbox_id = await conn.fetchval("SELECT id FROM notification_outbox WHERE notification_id=$1", notification_id)
        old_observed_at = datetime.now(UTC) - timedelta(minutes=5)
        expired = datetime.now(UTC) - timedelta(minutes=1)
        await conn.execute(
            "UPDATE watch_observations SET observed_at=$2,offer=jsonb_build_object('valid_until',$3::text) "
            "WHERE watch_id=$1", watch["id"], old_observed_at, expired.isoformat())
        await conn.execute("UPDATE watch_matches SET observed_at=$2 WHERE watch_id=$1",
                           watch["id"], old_observed_at)

    requests = []
    async with _mock_apns([200], requests) as transport:
        service = NotificationService(app.state.db, _settings(watch_daily_alert_cap=1), transport)
        await service.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            recheck = await conn.fetchrow(
                "SELECT id FROM watch_runs WHERE watch_id=$1 ORDER BY created_at DESC LIMIT 1", watch["id"])

        async def search_current(criteria, urls):
            return SearchResult(offers=[offer(price_cents=3299)], checked_count=1)

        monkeypatch.setattr(app.state.watches.provider, "search", search_current)
        await app.state.watches.check_job(
            {"run_id": str(recheck["id"]), "watch_id": str(watch["id"]), "user_id": str(me["id"])}, 1)

        async with app.state.db.system() as conn:
            inbox = await conn.fetchrow("SELECT body FROM notifications WHERE id=$1", notification_id)
            assert "$32.99" in inbox["body"]
            await conn.execute("UPDATE notification_outbox SET run_at=now() WHERE id=$1", outbox_id)
        await service.handlers["notification.deliver"]({"notification_id": str(notification_id)}, 1)

    assert len(requests) == 1
    assert b"$32.99" in requests[0].content


async def test_concurrent_outbox_claims_obey_cooldown_and_daily_cap(client, app):
    rows = await _delivery_rows(client, app, "notification_cap", notification_count=2)
    ids = rows["notification_ids"]
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE watch_subscriptions SET daily_cap = 1 WHERE watch_id = $1", rows["watch_id"])

    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await asyncio.gather(*(service.send_pending(limit=1) for _ in range(2)))
        async with app.state.db.system() as conn:
            statuses = await conn.fetch(
                "SELECT notification_id, status, last_error FROM notification_outbox WHERE notification_id = ANY($1)",
                [item[0] for item in ids])
        assert sum(status["status"] == "sent" for status in statuses) == 1
        non_sent = next(status for status in statuses if status["status"] != "sent")
        pending_id = non_sent["notification_id"]
        if non_sent["status"] == "pending":
            async with app.state.db.system() as conn:
                await conn.execute("UPDATE notification_outbox SET run_at = now() WHERE notification_id = $1",
                                   pending_id)
            await service.handlers["notification.deliver"]({"notification_id": str(pending_id)}, 1)
            async with app.state.db.system() as conn:
                non_sent = await conn.fetchrow(
                    "SELECT status, last_error FROM notification_outbox WHERE notification_id = $1", pending_id)
        assert non_sent["status"] == "suppressed"
        assert non_sent["last_error"] == "cooldown_active"

        # After clearing the cooldown marker, the same pending inbox item still cannot exceed the daily cap.
        async with app.state.db.system() as conn:
            await conn.execute("UPDATE watch_subscriptions SET last_notified_at = NULL WHERE watch_id = $1",
                               rows["watch_id"])
            await conn.execute("UPDATE notification_outbox SET status = 'pending', last_error = NULL, run_at = now() "
                               "WHERE notification_id = $1", pending_id)
        await service.handlers["notification.deliver"]({"notification_id": str(pending_id)}, 1)

    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status, last_error FROM notification_outbox WHERE notification_id = $1",
                                     pending_id)
    assert outbox["status"] == "suppressed"
    assert outbox["last_error"] == "daily_cap_reached"
    assert len(requests) == 1


async def test_global_daily_cap_serializes_deliveries_across_watches(client, app):
    rows = await _delivery_rows(client, app, "notification_global_cap")
    second_watch, second_notification, second_outbox = await _add_delivery_watch(client, app, rows, "globalcap2")
    first_notification, first_outbox = rows["notification_ids"][0]
    requests = []
    async with _mock_apns([], requests) as transport:
        service = NotificationService(app.state.db, _settings(watch_daily_alert_cap=1), transport)
        await asyncio.gather(*(service.send_pending(limit=1) for _ in range(2)))
        # A concurrent claim can be deferred by the locked user_settings row. Once the first delivery is
        # committed, its retry sees the global cap and remains in the inbox without another push.
        await service.send_pending(notification_id=str(first_notification))
        await service.send_pending(notification_id=str(second_notification))

    async with app.state.db.system() as conn:
        statuses = await conn.fetch(
            "SELECT notification_id, status, last_error FROM notification_outbox WHERE id = ANY($1)",
            [first_outbox, second_outbox])
    assert sum(row["status"] == "sent" for row in statuses) == 1
    suppressed = next(row for row in statuses if row["status"] == "suppressed")
    assert suppressed["last_error"] == "user_daily_cap_reached"
    assert len(requests) == 1


async def test_demo_account_outbox_is_never_sent_with_or_without_apns_config(client, app):
    headers = await login(client, "demo")
    user_id = (await client.get("/v1/me", headers=headers)).json()["id"]
    async with app.state.db.system() as conn:
        notification_id, outbox_id = await conn.fetchrow(
            """SELECT n.id, o.id FROM notifications n JOIN notification_outbox o ON o.notification_id = n.id
               WHERE n.user_id = $1 ORDER BY n.created_at LIMIT 1""", user_id)
        await conn.execute("UPDATE notification_outbox SET status = 'pending', run_at = now(), delivered_at = NULL "
                           "WHERE id = $1", outbox_id)

    requests = []
    async with _mock_apns([], requests) as transport:
        configured = NotificationService(app.state.db, _settings(), transport)
        await configured.send_pending(notification_id=str(notification_id))
        async with app.state.db.system() as conn:
            status = await conn.fetchval("SELECT status FROM notification_outbox WHERE id = $1", outbox_id)
            await conn.execute("UPDATE notification_outbox SET status = 'pending', run_at = now(), delivered_at = NULL "
                               "WHERE id = $1", outbox_id)
        assert status == "sent"
        unconfigured = NotificationService(app.state.db, SimpleNamespace(apns_enabled=False))
        await unconfigured.send_pending(notification_id=str(notification_id))
    assert requests == []
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT status FROM notification_outbox WHERE id = $1", outbox_id) == "sent"


async def test_gone_device_is_deleted_and_outbox_is_failed(client, app):
    rows = await _delivery_rows(client, app, "notification_gone")
    notification_id, outbox_id = rows["notification_ids"][0]
    requests = []
    async with _mock_apns([410], requests) as transport:
        service = NotificationService(app.state.db, _settings(), transport)
        await service.send_pending(notification_id=str(notification_id))
    async with app.state.db.system() as conn:
        outbox = await conn.fetchrow("SELECT status, last_error FROM notification_outbox WHERE id = $1", outbox_id)
        device = await conn.fetchval("SELECT 1 FROM push_devices WHERE token = $1", rows["token"])
    assert outbox["status"] == "failed"
    assert outbox["last_error"] == "apns_rejected"
    assert device is None
