"""Real Postgres reservation, concurrency, isolation and device outcome contracts."""

import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import asyncpg
import pytest

from app import idempotency
from app.routers.trips import TripIn
from tests.conftest import login


def keyed(headers):
    return headers | {"Idempotency-Key": uuid4().hex}


async def fresh(client):
    headers = await login(client, f"trip_{uuid4().hex[:12]}")
    me = (await client.get("/v1/me", headers=headers)).json()
    return headers, me


async def shopping_list(client, headers, *, empty=False):
    created = await client.post("/v1/lists", headers=headers, json={"name": "PCC groceries"})
    assert created.status_code == 201, created.text
    list_id = created.json()["id"]
    if not empty:
        response = await client.post(f"/v1/lists/{list_id}/items", headers=headers,
                                     json={"title": "Milk", "quantity": 1})
        assert response.status_code == 201, response.text
    return (await client.get(f"/v1/lists/{list_id}", headers=headers)).json()


def payload(lst, *, days=3):
    start = (datetime.now(UTC) + timedelta(days=days)).astimezone(ZoneInfo("America/Los_Angeles"))
    return {"list_id": lst["id"], "list_updated_at": lst["updated_at"], "start": start.isoformat(),
            "end": (start + timedelta(minutes=45)).isoformat(), "timezone": "America/Los_Angeles",
            "title": "Groceries at PCC", "description": "Pick up milk and the items on the shopping list.",
            "location": "PCC Community Markets"}


async def reserve(client, headers, body):
    response = await client.post("/v1/trips", headers=keyed(headers), json=body)
    assert response.status_code == 201, response.text
    return response.json()


@pytest.mark.parametrize("kind", ["trip", "calendar"])
async def test_cross_operation_key_race_rolls_back_the_entire_write(app, client, monkeypatch, kind):
    if kind == "calendar":
        headers = await login(client, "demo")
        me = (await client.get("/v1/me", headers=headers)).json()
    else:
        headers, me = await fresh(client)
    user_id = UUID(me["id"])
    body = payload(await shopping_list(client, headers))
    path, table, action = "/v1/trips", "replenishment_trips", "trip.reserved"
    if kind == "calendar":
        body = {k: v for k, v in body.items() if k not in ("list_id", "list_updated_at")} | {"confirmed": True}
        path, table, action = "/v1/demo/calendar/events", "calendar_events", "calendar.event_created"
    async with app.state.db.scoped(user_id) as conn:
        before = await conn.fetchval(f"SELECT count(*) FROM {table}")
        audits_before = await conn.fetchval("SELECT count(*) FROM audit_log WHERE action = $1", action)
    original_claim = idempotency.claim
    competing_digest = idempotency.request_hash("competing-operation")

    async def competing_claim(conn, owner, key, digest, status, response, **kwargs):
        # A different route can win after lookup: its transaction uses a different route lock.
        async with app.state.db.scoped(owner) as competing:
            assert await original_claim(competing, owner, key, competing_digest, 200, {"winner": True},
                                        operation="other")
        return await original_claim(conn, owner, key, digest, status, response, **kwargs)

    monkeypatch.setattr(idempotency, "claim", competing_claim)
    request_headers = keyed(headers)
    response = await client.post(path, headers=request_headers, json=body)
    assert response.status_code == 409, response.text
    assert response.json()["title"] == "duplicate_request"
    async with app.state.db.scoped(user_id) as conn:
        assert await conn.fetchval(f"SELECT count(*) FROM {table}") == before
        assert await conn.fetchval("SELECT count(*) FROM audit_log WHERE action = $1", action) == audits_before
        assert await conn.fetchval("SELECT request_hash FROM idempotency_keys WHERE user_id = $1 AND key = $2",
                                   user_id, request_headers["Idempotency-Key"]) == competing_digest
    retry = await client.post(path, headers=request_headers, json=body)
    assert retry.status_code == 422
    assert retry.json()["title"] == "idempotency_key_reused"


async def test_reservation_round_trip_replay_and_no_calendar_effects(app, client, monkeypatch):
    headers, me = await fresh(client)
    lst = await shopping_list(client, headers)
    body, request_headers = payload(lst), keyed(headers)

    async def forbidden(*args, **kwargs):
        raise AssertionError("Trip persistence must not call an external integration")

    monkeypatch.setattr(app.state.calendar, "calendar_request", forbidden)
    response = await client.post("/v1/trips", headers=request_headers, json=body)
    assert response.status_code == 201, response.text
    trip = response.json()
    assert trip["status"] == "reserved" and trip["event_id"] is None and trip["event_url"] is None
    assert trip["list_name"] == lst["name"] and trip["user_id"] == me["id"] and trip["mine"]
    assert trip["start"] == body["start"] and trip["end"] == body["end"]
    replay = await client.post("/v1/trips", headers=request_headers, json=body)
    assert replay.json() == trip and replay.headers["Idempotent-Replay"] == "true"
    changed = await client.post("/v1/trips", headers=request_headers, json=body | {"title": "Another trip"})
    assert changed.status_code == 422 and changed.json()["title"] == "idempotency_key_reused"
    conflict = await client.post("/v1/trips", headers=keyed(headers), json=body)
    assert conflict.status_code == 409 and conflict.json()["title"] == "trip_exists"
    loaded = await client.get("/v1/trips", headers=headers, params={"household_id": trip["household_id"]})
    assert loaded.json() == [trip]
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        assert await conn.fetchval("SELECT count(*) FROM calendar_events") == 0
        log = await conn.fetchrow("SELECT * FROM audit_log WHERE action = 'trip.reserved'")
        assert log["target_id"] == trip["id"] and log["meta"] == {}


@pytest.mark.parametrize("patch", [
    {"start": "2026-10-20T11:00:00"},
    {"start": "2026-10-20T11:00:00-05:00"},
    {"timezone": "Mars/Olympus"},
    {"title": "   "},
    {"status": "scheduled"},
    {"list_updated_at": "2026-10-20T11:00:00"},
])
async def test_reservation_strict_validation(client, patch):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers)) | patch
    response = await client.post("/v1/trips", headers=keyed(headers), json=body)
    assert response.status_code == 422, response.text


@pytest.mark.parametrize("start_offset,duration", [(-1, 45), (31, 45), (3, 0), (3, -1), (3, 241)])
async def test_time_bounds(client, start_offset, duration):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    start = datetime.now(UTC) + timedelta(days=start_offset)
    body |= {"start": start.isoformat(), "end": (start + timedelta(minutes=duration)).isoformat(),
             "timezone": "Etc/UTC"}
    response = await client.post("/v1/trips", headers=keyed(headers), json=body)
    assert response.status_code == 422, response.text


async def test_horizon_includes_trip_end(client):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    start = datetime.now(UTC) + timedelta(days=30, minutes=-30)
    body |= {"start": start.isoformat(), "end": (start + timedelta(hours=1)).isoformat(), "timezone": "Etc/UTC"}
    response = await client.post("/v1/trips", headers=keyed(headers), json=body)
    assert response.status_code == 422 and response.json()["title"] == "invalid_trip_time"


def test_dst_transition_offsets_and_elapsed_duration():
    body = {"list_id": str(uuid4()), "list_updated_at": "2026-10-18T00:00:00Z", "title": "Groceries",
            "timezone": "America/Los_Angeles", "start": "2026-11-01T01:30:00-07:00",
            "end": "2026-11-01T01:30:00-08:00"}
    trip = TripIn.model_validate(body)
    assert trip.ends_at - trip.starts_at == timedelta(hours=1)
    with pytest.raises(ValueError, match="offset must agree"):
        TripIn.model_validate(body | {"end": "2026-11-01T03:00:00-07:00"})
    with pytest.raises(ValueError, match="offset must agree"):
        TripIn.model_validate(body | {"start": "2027-03-14T02:30:00-08:00", "end": "2027-03-14T04:00:00-07:00"})


async def test_list_validation_and_no_partial_writes(app, client):
    headers, me = await fresh(client)
    empty = await shopping_list(client, headers, empty=True)
    assert (await client.post("/v1/trips", headers=headers, json=payload(empty))).status_code == 400
    rejected = await client.post("/v1/trips", headers=keyed(headers), json=payload(empty))
    assert rejected.status_code == 409 and rejected.json()["title"] == "list_empty"
    lst = await shopping_list(client, headers)
    old = payload(lst)
    line = lst["items"][0]
    await client.patch(f"/v1/lists/{lst['id']}/items/{line['id']}", headers=headers, json={"quantity": 2})
    rejected = await client.post("/v1/trips", headers=keyed(headers), json=old)
    assert rejected.status_code == 409 and rejected.json()["title"] == "list_changed"
    latest = (await client.get(f"/v1/lists/{lst['id']}", headers=headers)).json()
    await client.patch(f"/v1/lists/{lst['id']}", headers=headers, json={"status": "archived"})
    rejected = await client.post("/v1/trips", headers=keyed(headers), json=payload(latest))
    assert rejected.status_code == 409 and rejected.json()["title"] == "list_closed"
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        assert await conn.fetchval("SELECT count(*) FROM replenishment_trips") == 0
        assert await conn.fetchval("SELECT count(*) FROM idempotency_keys") == 0


async def test_checked_list_is_empty(client):
    headers, _ = await fresh(client)
    lst = await shopping_list(client, headers)
    await client.patch(f"/v1/lists/{lst['id']}/items/{lst['items'][0]['id']}", headers=headers, json={"checked": True})
    lst = (await client.get(f"/v1/lists/{lst['id']}", headers=headers)).json()
    rejected = await client.post("/v1/trips", headers=keyed(headers), json=payload(lst))
    assert rejected.status_code == 409 and rejected.json()["title"] == "list_empty"


@pytest.mark.parametrize("same_key", [True, False])
async def test_concurrent_same_list_and_retry(client, same_key):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    first = keyed(headers)
    results = await asyncio.gather(*[
        client.post("/v1/trips", headers=first if same_key else keyed(headers), json=body) for _ in range(6)])
    if same_key:
        assert all(r.status_code == 201 for r in results)
        assert len({r.json()["id"] for r in results}) == 1
    else:
        assert sorted(r.status_code for r in results) == [201, 409, 409, 409, 409, 409]
    assert len((await client.get("/v1/trips", headers=headers)).json()) == 1


async def test_overlap_serialized_across_lists(client):
    headers, _ = await fresh(client)
    a, b = await shopping_list(client, headers), await shopping_list(client, headers)
    first = payload(a)
    second = payload(b) | {"start": first["start"], "end": first["end"]}
    results = await asyncio.gather(client.post("/v1/trips", headers=keyed(headers), json=first),
                                   client.post("/v1/trips", headers=keyed(headers), json=second))
    assert sorted(r.status_code for r in results) == [201, 409]
    rejected = next(r for r in results if r.status_code == 409)
    assert rejected.json()["title"] == "trip_overlap"
    # Adjacent windows are permitted.
    loser = second if results[0].status_code == 201 else first
    end = datetime.fromisoformat(first["end"])
    await reserve(client, headers, loser | {"start": first["end"], "end": (end + timedelta(minutes=45)).isoformat()})


async def test_household_sharing_owner_only_mutation_and_foreign_rls(app, client):
    owner, me = await fresh(client)
    member, member_me = await fresh(client)
    foreign, foreign_me = await fresh(client)
    household = UUID(me["households"][0]["id"])
    async with app.state.db.system() as conn:
        await conn.execute("INSERT INTO household_members (household_id, user_id, role) VALUES ($1,$2,'member')",
                           household, UUID(member_me["id"]))
    body = payload(await shopping_list(client, owner))
    results = await asyncio.gather(client.post("/v1/trips", headers=keyed(owner), json=body),
                                   client.post("/v1/trips", headers=keyed(member), json=body))
    assert sorted(r.status_code for r in results) == [201, 409]
    trip = next(r.json() for r in results if r.status_code == 201)
    other = member if trip["user_id"] == me["id"] else owner
    shared = await client.get("/v1/trips", headers=other, params={"household_id": str(household)})
    assert shared.json()[0]["mine"] is False
    assert (await client.patch(f"/v1/trips/{trip['id']}/outcome", headers=other,
                               json={"status": "failed"})).status_code == 404
    for method, path, request_body in (("GET", f"/v1/trips?household_id={household}", None),
                               ("PATCH", f"/v1/trips/{trip['id']}/outcome", {"status": "failed"}),
                               ("POST", "/v1/trips", body)):
        response = await client.request(method, path, headers=keyed(foreign), json=request_body)
        assert response.status_code == 404, response.text
    async with app.state.db.scoped(UUID(foreign_me["id"])) as conn:
        assert await conn.fetchval("SELECT count(*) FROM replenishment_trips") == 0
    async with app.state.db.scoped(UUID(member_me["id"] if trip["user_id"] == me["id"] else me["id"])) as conn:
        assert await conn.execute("UPDATE replenishment_trips SET status = 'failed' WHERE id = $1",
                                  UUID(trip["id"])) == "UPDATE 0"


async def test_outcome_unknown_can_schedule_or_release(client):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    trip = await reserve(client, headers, body)
    path = f"/v1/trips/{trip['id']}/outcome"
    unknown = await client.patch(path, headers=headers, json={"status": "outcome_unknown"})
    assert unknown.status_code == 200 and unknown.json()["status"] == "outcome_unknown"
    assert (await client.patch(path, headers=headers, json={"status": "outcome_unknown"})).json() == unknown.json()
    assert (await client.post("/v1/trips", headers=keyed(headers), json=body)).status_code == 409

    # Explicit release after the user confirms Calendar has no matching event.
    released = await client.patch(path, headers=headers, json={"status": "failed"})
    assert released.status_code == 200 and released.json()["status"] == "failed"
    replacement = await reserve(client, headers, body)
    assert replacement["id"] != trip["id"]

    unknown_again = await client.patch(f"/v1/trips/{replacement['id']}/outcome", headers=headers,
                                       json={"status": "outcome_unknown"})
    assert unknown_again.status_code == 200
    scheduled_body = {"status": "scheduled", "event_id": "verified-existing-event",
                      "event_url": "https://calendar.google.com/"}
    scheduled = await client.patch(f"/v1/trips/{replacement['id']}/outcome", headers=headers, json=scheduled_body)
    assert scheduled.status_code == 200 and scheduled.json()["event_id"] == scheduled_body["event_id"]
    assert (await client.patch(f"/v1/trips/{replacement['id']}/outcome", headers=headers,
                               json=scheduled_body)).json() == scheduled.json()
    for change in ({"status": "failed"}, {"status": "outcome_unknown"}, scheduled_body | {"event_id": "different"}):
        assert (await client.patch(f"/v1/trips/{replacement['id']}/outcome", headers=headers,
                                   json=change)).status_code == 409


async def test_past_unknown_trip_can_be_released(app, client):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    trip = await reserve(client, headers, body)
    await client.patch(f"/v1/trips/{trip['id']}/outcome", headers=headers, json={"status": "outcome_unknown"})
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE replenishment_trips SET starts_at = now() - interval '2 hours', "
                           "ends_at = now() - interval '1 hour' WHERE id = $1", UUID(trip["id"]))
    assert (await client.post("/v1/trips", headers=keyed(headers), json=body)).status_code == 409
    released = await client.patch(f"/v1/trips/{trip['id']}/outcome", headers=headers, json={"status": "failed"})
    assert released.status_code == 200 and released.json()["status"] == "failed"
    again = await reserve(client, headers, payload(
        (await client.get(f"/v1/lists/{body['list_id']}", headers=headers)).json(), days=4))
    assert again["id"] != trip["id"]


async def test_failed_release_and_terminal_state(client):
    headers, _ = await fresh(client)
    body = payload(await shopping_list(client, headers))
    trip = await reserve(client, headers, body)
    path = f"/v1/trips/{trip['id']}/outcome"
    failed = await client.patch(path, headers=headers, json={"status": "failed"})
    assert failed.status_code == 200 and failed.json()["status"] == "failed"
    assert (await client.patch(path, headers=headers, json={"status": "failed"})).json() == failed.json()
    assert (await client.patch(path, headers=headers,
                               json={"status": "scheduled", "event_id": "event"})).status_code == 409
    replacement = await reserve(client, headers, body)
    assert replacement["id"] != trip["id"]


@pytest.mark.parametrize("body", [{"status": "scheduled"}, {"status": "scheduled", "event_id": " "},
                                  {"status": "reserved"}, {"status": "failed", "event_id": "event"},
                                  {"status": "outcome_unknown", "event_url": "https://example.com/"},
                                  {"status": "scheduled", "event_id": "event", "event_url": "javascript:alert(1)"}])
async def test_outcome_validation(client, body):
    headers, _ = await fresh(client)
    trip = await reserve(client, headers, payload(await shopping_list(client, headers)))
    assert (await client.patch(f"/v1/trips/{trip['id']}/outcome", headers=headers, json=body)).status_code == 422


async def test_past_scheduled_trip_releases_list_but_unknown_remains_blocked(app, client):
    headers, me = await fresh(client)
    body = payload(await shopping_list(client, headers))
    trip = await reserve(client, headers, body)
    await client.patch(f"/v1/trips/{trip['id']}/outcome", headers=headers,
                       json={"status": "scheduled", "event_id": "completed-trip"})
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE replenishment_trips SET starts_at = now() - interval '2 hours', "
                           "ends_at = now() - interval '1 hour' WHERE id = $1", UUID(trip["id"]))
    replacement = await reserve(client, headers, body)
    await client.patch(f"/v1/trips/{replacement['id']}/outcome", headers=headers, json={"status": "outcome_unknown"})
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE replenishment_trips SET starts_at = now() - interval '2 hours', "
                           "ends_at = now() - interval '1 hour' WHERE id = $1", UUID(replacement["id"]))
    response = await client.post("/v1/trips", headers=keyed(headers), json=payload(
        (await client.get(f"/v1/lists/{body['list_id']}", headers=headers)).json(), days=4))
    assert response.status_code == 409 and response.json()["title"] == "trip_exists"
    # User deletion removes personal Calendar references, including the household-visible trip.
    async with app.state.db.system() as conn:
        await conn.execute("DELETE FROM users WHERE id = $1", UUID(me["id"]))
        assert not await conn.fetchval("SELECT 1 FROM replenishment_trips WHERE user_id = $1", UUID(me["id"]))


async def test_rls_insert_cannot_cross_households(app, client):
    headers, me = await fresh(client)
    other, other_me = await fresh(client)
    lst = await shopping_list(client, other)
    body = payload(lst)
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        with pytest.raises(asyncpg.InsufficientPrivilegeError):
            async with conn.transaction():
                await conn.execute(
                    """INSERT INTO replenishment_trips (household_id, list_id, user_id, list_name, list_updated_at,
                         starts_at, ends_at, start_text, end_text, timezone, title)
                       VALUES ($1,$2,$3,'List',now(),$4,$5,$6,$7,$8,'Groceries')""",
                    UUID(other_me["households"][0]["id"]), UUID(lst["id"]), UUID(me["id"]),
                    datetime.fromisoformat(body["start"]), datetime.fromisoformat(body["end"]),
                    body["start"], body["end"], body["timezone"])


async def test_database_constraints_require_owned_matching_list_and_confirmed_event(app, client):
    headers, me = await fresh(client)
    other, _ = await fresh(client)
    trip = await reserve(client, headers, payload(await shopping_list(client, headers)))
    foreign_list = await shopping_list(client, other)
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        with pytest.raises(asyncpg.InsufficientPrivilegeError):
            async with conn.transaction():
                await conn.execute("UPDATE replenishment_trips SET list_id = $2 WHERE id = $1",
                                   UUID(trip["id"]), UUID(foreign_list["id"]))
        for event_id in (None, "", "   "):
            with pytest.raises(asyncpg.CheckViolationError):
                async with conn.transaction():
                    await conn.execute("UPDATE replenishment_trips SET status = 'scheduled', event_id = $2 "
                                       "WHERE id = $1",
                                       UUID(trip["id"]), event_id)
