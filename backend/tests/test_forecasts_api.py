"""Run-out forecasts and shopping lists end to end, against the seeded three-week history (set
AGORA_TEST_DATABASE_URL). Each test signs in fresh users, so tests don't depend on each other."""

import uuid
from datetime import UTC, date, datetime, timedelta

import asyncpg
import pytest

from app.forecasting import next_nightly, schedule_nightly
from app.seed import TRACKED, seed_catalog, seed_household
from app.timeseries import daily_levels
from tests.conftest import MILK, fridge_photo, login, write_fixture

TRUE_RATE = {name: rate for name, _, rate, *_ in TRACKED}


def idem() -> dict[str, str]:
    return {"Idempotency-Key": uuid.uuid4().hex}


@pytest.fixture(scope="module")
async def catalog(app):
    await seed_catalog(app.state.db)


async def fresh(client) -> tuple[dict[str, str], dict]:
    headers = await login(client, f"f_{uuid.uuid4().hex[:12]}")
    return headers, (await client.get("/v1/me", headers=headers)).json()


async def seeded(app, client) -> tuple[dict[str, str], dict]:
    """A new user with the demo history: 12 items, 21 daily scans each, with restocks."""
    headers, me = await fresh(client)
    assert await seed_household(app.state.db, uuid.UUID(me["id"]), "7:kedar")
    return headers, me


async def items_by_name(client, headers) -> dict[str, dict]:
    return {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=headers)).json()}


async def merchant_id(client, headers, name: str) -> str:
    found = (await client.get("/v1/merchants", headers=headers, params={"q": name})).json()
    return next(m["id"] for m in found if m["name"] == name)


# ---------------------------------------------------------------- forecasts

async def test_seeded_history_gets_accurate_forecasts(app, client, catalog):
    headers, me = await seeded(app, client)
    items = await items_by_name(client, headers)
    assert set(items) == set(TRUE_RATE)
    now = datetime.now(UTC)
    for name, item in items.items():
        detail = (await client.get(f"/v1/inventory/{item['id']}", headers=headers)).json()
        f = detail["forecast"]
        assert f is not None, name
        assert f["method"] == "theil_sen" and f["n_obs"] == 21 and f["n_segments"] >= 1
        # The seed's true daily use, with ±40% per-day jitter and ±5% reading noise, is recovered closely.
        assert f["rate_per_day"] == pytest.approx(TRUE_RATE[name], rel=0.3), name
        assert f["rate_lo"] <= f["rate_per_day"] <= f["rate_hi"]
        assert f["confidence"] in ("medium", "high")
        assert "Based on 21 scans over 20 days" in f["explanation"]
        assert f["explanation"].lower().startswith(name.lower())
        if f["status"] == "runs_out":
            assert f["runout_lo"] <= f["runout_at"] <= f["runout_hi"]
            assert datetime.fromisoformat(f["runout_at"]) > now
            assert " will run out " in f["explanation"]
        assert f["qty_now"] <= f["last_quantity"]  # projected forward from the last scan


async def test_runouts_lists_what_runs_out_soonest_first(app, client, catalog):
    headers, me = await seeded(app, client)
    week = await client.get("/v1/forecasts/runouts", headers=headers, params={"within": "7d"})
    assert week.status_code == 200, week.text
    body = week.json()
    assert body["within_days"] == 7 and body["household_id"] == me["households"][0]["id"]
    soon = body["runouts"]
    assert soon, "the seeded history always has something running low"
    horizon = datetime.fromisoformat(body["as_of"]) + timedelta(days=7)
    dates = [datetime.fromisoformat(r["forecast"]["runout_at"]) for r in soon]
    assert dates == sorted(dates) and all(d <= horizon for d in dates)
    for r in soon:
        assert r["forecast"]["status"] in ("out", "runs_out") and r["forecast"]["explanation"]
        assert r["suggested_quantity"] >= 1 and r["on_list_id"] is None
        assert r["suggested_merchant"] is None and r["merchant_basis"] is None  # the seed records no stores

    # Exactly the items whose stored forecast falls inside the window.
    async with app.state.db.scoped(uuid.UUID(me["id"])) as conn:
        expected = await conn.fetchval(
            """SELECT count(*) FROM inventory_items i
               CROSS JOIN LATERAL (SELECT runout_at FROM consumption_forecasts f WHERE f.inventory_item_id = i.id
                                   ORDER BY computed_at DESC LIMIT 1) f
               WHERE i.household_id = $1 AND f.runout_at <= $2""", uuid.UUID(body["household_id"]), horizon)
    assert len(soon) == expected

    longer = (await client.get("/v1/forecasts/runouts", headers=headers, params={"within": "90d"})).json()
    assert len(longer["runouts"]) >= len(soon)
    assert {r["item"]["id"] for r in soon} <= {r["item"]["id"] for r in longer["runouts"]}
    default = (await client.get("/v1/forecasts/runouts", headers=headers)).json()
    assert default["within_days"] == 7


@pytest.mark.parametrize("within", ["0d", "7", "91d", "7w", "-1d", "1000d"])
async def test_runouts_rejects_bad_windows(client, within):
    headers, _ = await fresh(client)
    response = await client.get("/v1/forecasts/runouts", headers=headers, params={"within": within})
    assert response.status_code == 422 and response.json()["title"] in ("invalid_within", "invalid_request")


async def test_confirmed_scan_queues_a_forecast_refresh(app, client, replay_dir, catalog):
    headers, me = await fresh(client)
    photo = fridge_photo(41)
    write_fixture(replay_dir, photo, [MILK])
    scan = (await client.post("/v1/scans", headers={**headers, **idem()},
                              files=[("files", ("fridge.jpg", photo, "image/jpeg"))])).json()
    await app.state.worker.drain()
    reviewed = await client.post(f"/v1/scans/{scan['id']}/review", headers=headers,
                                 json={"decisions": [], "remaining": "accept"})
    assert reviewed.status_code == 200, reviewed.text
    async with app.state.db.system() as conn:
        queued = await conn.fetch("SELECT payload FROM jobs WHERE kind = 'forecast.refresh' AND status = 'queued' "
                                  "AND payload->>'user_id' = $1", me["id"])
    assert len(queued) == 1 and len(queued[0]["payload"]["item_ids"]) == 1
    await app.state.worker.drain()

    milk = (await items_by_name(client, headers))["2% milk"]
    f = (await client.get(f"/v1/inventory/{milk['id']}", headers=headers)).json()["forecast"]
    assert f["method"] == "prior" and f["confidence"] == "low"  # one reading: a dairy guess until more scans
    assert f["last_quantity"] == 1.5 and f["runout_at"] is not None
    assert f["explanation"].endswith("Scan it a few more times to personalize this.")


async def test_manual_readings_refresh_too_and_new_items_start_empty(app, client):
    headers, me = await fresh(client)
    household = me["households"][0]["id"]
    bare = (await client.post("/v1/inventory", headers=headers, json={
        "household_id": household, "display_name": "Jam", "category": "condiments"})).json()
    assert (await client.get(f"/v1/inventory/{bare['id']}", headers=headers)).json()["forecast"] is None

    item = (await client.post("/v1/inventory", headers=headers, json={
        "household_id": household, "display_name": "Olive oil", "category": "pantry", "quantity": 3})).json()
    for days_ago, qty in ((6, 3.0), (4, 2.5), (2, 2.0)):
        when = (datetime.now(UTC) - timedelta(days=days_ago)).isoformat()
        assert (await client.post(f"/v1/inventory/{item['id']}/observations", headers=headers,
                                  json={"quantity": qty, "time": when})).status_code == 201
    await app.state.worker.drain()
    f = (await client.get(f"/v1/inventory/{item['id']}", headers=headers)).json()["forecast"]
    assert f["method"] in ("blended", "theil_sen") and f["n_obs"] == 4
    async with app.state.db.system() as conn:
        history = await conn.fetchval("SELECT count(*) FROM consumption_forecasts WHERE inventory_item_id = $1",
                                      uuid.UUID(item["id"]))
    assert history >= 2  # every recompute is kept, for "forecast vs actual"


async def test_nightly_refresh_fans_out_and_reschedules_once(app, client, catalog):
    headers, me = await seeded(app, client)
    household = uuid.UUID(me["households"][0]["id"])
    async with app.state.db.system() as conn:
        before = await conn.fetchval("SELECT count(*) FROM consumption_forecasts WHERE household_id = $1", household)

    forecaster = app.state.pipeline.forecaster
    await forecaster.nightly_job({}, 1)
    await forecaster.nightly_job({}, 1)  # a retried night doesn't book tomorrow twice
    async with app.state.db.system() as conn:
        nightly = await conn.fetch("SELECT run_at FROM jobs WHERE kind = 'forecast.nightly' AND status = 'queued'")
        assert len(nightly) == 1 and nightly[0]["run_at"] > datetime.now(UTC)
        assert nightly[0]["run_at"].astimezone(UTC).hour == 10
        assert not await schedule_nightly(conn, None)  # already booked
    await forecaster.start()  # a worker restarting doesn't add another either
    await app.state.worker.drain()
    async with app.state.db.system() as conn:
        assert await conn.fetchval(
            "SELECT count(*) FROM jobs WHERE kind = 'forecast.nightly' AND status = 'queued'") == 1
        after = await conn.fetchval("SELECT count(*) FROM consumption_forecasts WHERE household_id = $1", household)
    assert after >= before + 2 * len(TRUE_RATE)


def test_next_nightly_is_the_next_10_utc():
    assert next_nightly(datetime(2026, 10, 17, 9, 59, tzinfo=UTC)) == datetime(2026, 10, 17, 10, tzinfo=UTC)
    assert next_nightly(datetime(2026, 10, 17, 10, 0, tzinfo=UTC)) == datetime(2026, 10, 18, 10, tzinfo=UTC)


async def test_daily_levels_count_readings(app, client, catalog):
    headers, me = await seeded(app, client)
    milk = (await items_by_name(client, headers))["2% milk"]
    db = app.state.db
    end = datetime.now(UTC).replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    start = end - timedelta(days=30)
    async with db.system() as conn:
        plain = await daily_levels(conn, uuid.UUID(milk["id"]), start, end, timescale=False)
        assert sum(n for _, _, n in plain) == 21 and len(plain) == 30
        assert all(q is None for _, q, n in plain[:5])  # before the history starts
        if db.timescale:  # the Timescale and plain-Postgres implementations must agree exactly
            assert await daily_levels(conn, uuid.UUID(milk["id"]), start, end, timescale=True) == plain


# ---------------------------------------------------------------- lists

async def test_shopping_list_crud(client, catalog):
    headers, me = await fresh(client)
    household = me["households"][0]["id"]
    safeway = await merchant_id(client, headers, "Safeway")
    created = await client.post("/v1/lists", headers=headers, json={"merchant_id": safeway})
    assert created.status_code == 201, created.text
    lst = created.json()
    assert lst["name"] == "Safeway" and lst["merchant"]["id"] == safeway and lst["source"] == "user"
    assert lst["status"] == "open" and lst["items"] == [] and lst["open_count"] == 0

    plain = await client.post(f"/v1/lists/{lst['id']}/items", headers=headers,
                              json={"title": " Birthday candles ", "quantity": 2, "note": "blue"})
    assert plain.status_code == 201, plain.text
    plain = plain.json()
    assert plain["title"] == "Birthday candles" and plain["reason"] == "manual" and plain["added_by"] == "user"
    assert plain["merchant"]["id"] == safeway and plain["merchant_basis"] == "list"

    inv = (await client.post("/v1/inventory", headers=headers, json={
        "household_id": household, "display_name": "Paper towels", "unit": "roll"})).json()
    linked = (await client.post(f"/v1/lists/{lst['id']}/items", headers=headers,
                                json={"inventory_item_id": inv["id"], "quantity": 6})).json()
    assert linked["title"] == "Paper towels" and linked["unit"] == "roll" and linked["quantity"] == 6
    again = await client.post(f"/v1/lists/{lst['id']}/items", headers=headers, json={"inventory_item_id": inv["id"]})
    assert again.status_code == 409 and again.json()["title"] == "already_on_list"

    no_reason = await client.post(f"/v1/lists/{lst['id']}/items", headers=headers,
                                  json={"title": "Ice cream", "added_by": "agent"})
    assert no_reason.status_code == 422
    agent = (await client.post(f"/v1/lists/{lst['id']}/items", headers=headers, json={
        "title": "Ice cream", "added_by": "agent", "explanation": "It's on sale and you buy it every week."})).json()
    assert agent["reason"] == "agent" and agent["added_by"] == "agent" and agent["explanation"]
    for bad in ({}, {"title": "   "}, {"title": "x", "quantity": 0}, {"title": "x", "reason": "runout"},
                {"title": "x", "quantity": 1001}):
        assert (await client.post(f"/v1/lists/{lst['id']}/items", headers=headers, json=bad)).status_code == 422
    assert (await client.post(f"/v1/lists/{lst['id']}/items", headers=headers,
                              json={"inventory_item_id": str(uuid.uuid4())})).status_code == 404

    ticked = await client.patch(f"/v1/lists/{lst['id']}/items/{plain['id']}", headers=headers,
                                json={"checked": True})
    assert ticked.status_code == 200 and ticked.json()["checked"] and ticked.json()["checked_at"]
    assert (await client.patch(f"/v1/lists/{lst['id']}/items/{plain['id']}", headers=headers,
                               json={"checked": None})).status_code == 422
    assert (await client.patch(f"/v1/lists/{lst['id']}/items/{plain['id']}", headers=headers,
                               json={"price": 3})).status_code == 422
    view = (await client.get(f"/v1/lists/{lst['id']}", headers=headers)).json()
    assert view["open_count"] == 2 and view["items"][-1]["id"] == plain["id"]  # ticked lines sink

    assert (await client.delete(f"/v1/lists/{lst['id']}/items/{agent['id']}", headers=headers)).status_code == 204
    assert (await client.delete(f"/v1/lists/{lst['id']}/items/{agent['id']}", headers=headers)).status_code == 404

    done = (await client.patch(f"/v1/lists/{lst['id']}", headers=headers, json={"status": "done"})).json()
    assert done["status"] == "done" and done["completed_at"]
    closed = await client.post(f"/v1/lists/{lst['id']}/items", headers=headers, json={"title": "Eggs"})
    assert closed.status_code == 409 and closed.json()["title"] == "list_closed"
    assert (await client.get("/v1/lists", headers=headers)).json() == []
    assert [x["id"] for x in (await client.get("/v1/lists?status=done", headers=headers)).json()] == [lst["id"]]
    assert (await client.get("/v1/lists?status=deleted", headers=headers)).status_code == 422
    reopened = (await client.patch(f"/v1/lists/{lst['id']}", headers=headers,
                                   json={"status": "open", "name": "Weekend run"})).json()
    assert reopened["status"] == "open" and reopened["completed_at"] is None and reopened["name"] == "Weekend run"

    blank = (await client.post("/v1/lists", headers=headers, json={})).json()
    assert blank["name"] == "Shopping list" and blank["merchant"] is None


async def test_generate_builds_per_store_lists_from_runouts(app, client, catalog):
    headers, me = await seeded(app, client)
    user_id, household = uuid.UUID(me["id"]), uuid.UUID(me["households"][0]["id"])
    soon = (await client.get("/v1/forecasts/runouts", headers=headers, params={"within": "7d"})).json()["runouts"]
    assert len(soon) >= 2
    first, second = soon[0]["item"], soon[1]["item"]

    # One item has a preferred store; another was last bought somewhere (a confirmed scan with a store).
    safeway, qfc = await merchant_id(client, headers, "Safeway"), await merchant_id(client, headers, "QFC")
    assert (await client.patch(f"/v1/inventory/{first['id']}", headers=headers,
                               json={"preferred_merchant_id": safeway})).status_code == 200
    async with app.state.db.scoped(user_id) as conn:
        when = datetime.now(UTC) - timedelta(days=4)
        scan_id = await conn.fetchval(
            """INSERT INTO scans (household_id, user_id, captured_at, media_kind, status, provider, model,
                                  confirmed_at, purchased_from_merchant_id)
               VALUES ($1, $2, $3, 'photos', 'confirmed', 'seed', 'synthetic', $3, $4) RETURNING id""",
            household, user_id, when, uuid.UUID(qfc))
        detection = await conn.fetchval(
            """INSERT INTO scan_detections (scan_id, household_id, label, confidence, count, quantity,
                                            inventory_item_id, review)
               VALUES ($1, $2, $3, 0.9, 1, 1, $4, 'accepted') RETURNING id""",
            scan_id, household, second["display_name"], uuid.UUID(second["id"]))
        await conn.execute(
            """INSERT INTO inventory_purchase_origins (scan_detection_id, household_id, inventory_item_id,
                                                      merchant_id, purchased_on, scan_id, observed_at, quantity)
               VALUES ($1, $2, $3, $4, $5, $6, $7, 1)""",
            detection, household, uuid.UUID(second["id"]), uuid.UUID(qfc), date.today(), scan_id, when)

    assert (await client.post("/v1/lists/generate", headers=headers, json={})).status_code == 400  # no key
    key = idem()
    response = await client.post("/v1/lists/generate", headers={**headers, **key}, json={"within_days": 7})
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["added"] == len(soon) and result["skipped"] == []
    by_store = {(lst["merchant"] or {}).get("name"): lst for lst in result["lists"]}
    assert {"Safeway", "QFC"} <= set(by_store)
    assert all(lst["source"] == "generated" and lst["status"] == "open" for lst in result["lists"])

    line = next(i for i in by_store["Safeway"]["items"] if i["inventory_item_id"] == first["id"])
    assert line["reason"] == "runout" and line["added_by"] == "system" and line["merchant_basis"] == "preferred"
    assert line["explanation"].endswith("Your usual store is Safeway.") and "Based on 21 scans" in line["explanation"]
    assert line["needed_by"] == soon[0]["forecast"]["runout_at"] and line["quantity"] >= 1
    assert by_store["Safeway"]["needed_by"] == line["needed_by"]
    line = next(i for i in by_store["QFC"]["items"] if i["inventory_item_id"] == second["id"])
    assert line["merchant_basis"] == "last_purchase" and line["explanation"].endswith("Last bought at QFC.")
    if len(soon) > 2:
        assert by_store[None]["name"] == "Groceries"
    assert sum(len(lst["items"]) for lst in result["lists"]) == len(soon)

    replay = await client.post("/v1/lists/generate", headers={**headers, **key}, json={"within_days": 7})
    assert replay.json() == result and replay.headers["idempotent-replay"] == "true"
    reused = await client.post("/v1/lists/generate", headers={**headers, **key}, json={"within_days": 3})
    assert reused.status_code == 422 and reused.json()["title"] == "idempotency_key_reused"

    # Generating again with a new key adds nothing: everything is already on an open list.
    again = (await client.post("/v1/lists/generate", headers={**headers, **idem()}, json={})).json()
    assert again["added"] == 0 and again["lists"] == []
    assert {s["inventory_item_id"] for s in again["skipped"]} == {r["item"]["id"] for r in soon}
    assert all(s["reason"] == "already_on_list" for s in again["skipped"])
    marked = (await client.get("/v1/forecasts/runouts", headers=headers)).json()["runouts"]
    assert all(r["on_list_id"] for r in marked)

    # Ticking a line off frees the item to be generated again, onto the same store's open list.
    safeway_list = by_store["Safeway"]
    tick = next(i for i in safeway_list["items"] if i["inventory_item_id"] == first["id"])
    await client.patch(f"/v1/lists/{safeway_list['id']}/items/{tick['id']}", headers=headers, json={"checked": True})
    regen = (await client.post("/v1/lists/generate", headers={**headers, **idem()}, json={})).json()
    assert regen["added"] == 1 and [lst["id"] for lst in regen["lists"]] == [safeway_list["id"]]

    lists = (await client.get("/v1/lists", headers=headers)).json()
    assert {lst["id"] for lst in lists} == {lst["id"] for lst in result["lists"]}

    async with app.state.db.system() as conn:
        actions = [r["action"] for r in await conn.fetch(
            "SELECT action FROM audit_log WHERE household_id = $1 ORDER BY id", household)]
    assert actions.count("list.generated") == 3  # the replay did no work, so it isn't audited again


async def test_generate_without_unassigned_skips_storeless_items(app, client, catalog):
    headers, _ = await seeded(app, client)
    result = (await client.post("/v1/lists/generate", headers={**headers, **idem()},
                                json={"include_unassigned": False})).json()
    assert result["added"] == 0 and result["lists"] == []
    assert result["skipped"] and all(s["reason"] == "no_store" for s in result["skipped"])
    bad = await client.post("/v1/lists/generate", headers={**headers, **idem()}, json={"within_days": 31})
    assert bad.status_code == 422


# ---------------------------------------------------------------- isolation

async def test_other_households_cannot_see_or_touch_forecasts_and_lists(app, client, catalog):
    owner, owner_me = await seeded(app, client)
    intruder, intruder_me = await fresh(client)
    victim_household = owner_me["households"][0]["id"]
    item = next(iter((await items_by_name(client, owner)).values()))
    lst = (await client.post("/v1/lists", headers=owner, json={"name": "Private"})).json()
    line = (await client.post(f"/v1/lists/{lst['id']}/items", headers=owner, json={"title": "Secret"})).json()

    assert (await client.get(f"/v1/inventory/{item['id']}", headers=intruder)).status_code == 404
    assert (await client.get(f"/v1/lists/{lst['id']}", headers=intruder)).status_code == 404
    assert (await client.get("/v1/lists", headers=intruder)).json() == []
    assert (await client.get("/v1/forecasts/runouts", headers=intruder)).json()["runouts"] == []
    assert (await client.get("/v1/forecasts/runouts", headers=intruder,
                             params={"household_id": victim_household})).status_code == 404
    assert (await client.get("/v1/lists", headers=intruder,
                             params={"household_id": victim_household})).status_code == 404
    assert (await client.post("/v1/lists", headers=intruder,
                              json={"household_id": victim_household})).status_code == 404
    assert (await client.post("/v1/lists/generate", headers={**intruder, **idem()},
                              json={"household_id": victim_household})).status_code == 404
    assert (await client.post(f"/v1/lists/{lst['id']}/items", headers=intruder,
                              json={"title": "x"})).status_code == 404
    assert (await client.patch(f"/v1/lists/{lst['id']}/items/{line['id']}", headers=intruder,
                               json={"checked": True})).status_code == 404
    assert (await client.delete(f"/v1/lists/{lst['id']}/items/{line['id']}", headers=intruder)).status_code == 404
    assert (await client.patch(f"/v1/lists/{lst['id']}", headers=intruder,
                               json={"status": "archived"})).status_code == 404
    # The owner's own list can't be filled with the intruder's inventory either.
    theirs = (await client.post("/v1/inventory", headers=intruder, json={
        "household_id": intruder_me["households"][0]["id"], "display_name": "Mine"})).json()
    assert (await client.post(f"/v1/lists/{lst['id']}/items", headers=owner,
                              json={"inventory_item_id": theirs["id"]})).status_code == 404

    # Row-level security holds below the API too.
    async with app.state.db.scoped(uuid.UUID(intruder_me["id"])) as conn:
        for table in ("consumption_forecasts", "shopping_lists", "shopping_list_items"):
            assert await conn.fetchval(f"SELECT count(*) FROM {table} WHERE household_id = $1",  # noqa: S608
                                       uuid.UUID(victim_household)) == 0
    with pytest.raises(asyncpg.InsufficientPrivilegeError):
        async with app.state.db.scoped(uuid.UUID(intruder_me["id"])) as conn:
            await conn.execute(
                """INSERT INTO consumption_forecasts (computed_at, household_id, inventory_item_id, method, n_obs)
                   VALUES (now(), $1, $2, 'insufficient', 0)""", uuid.UUID(victim_household), uuid.UUID(item["id"]))
    with pytest.raises(asyncpg.InsufficientPrivilegeError):  # forecast history is append-only for requests
        async with app.state.db.scoped(uuid.UUID(owner_me["id"])) as conn:
            await conn.execute("DELETE FROM consumption_forecasts WHERE household_id = $1",
                               uuid.UUID(victim_household))
