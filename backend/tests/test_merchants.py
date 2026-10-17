"""'Purchased from' support: merchant find-or-create, scan/detection store association, purchase history."""

import uuid

import asyncpg
import pytest

from app.seed import seed_catalog
from tests.conftest import EGGS, MILK, MYSTERY, fridge_photo, login, write_fixture


def idem() -> dict[str, str]:
    return {"Idempotency-Key": str(uuid.uuid4())}


@pytest.fixture(scope="module")
async def catalog(app):
    await seed_catalog(app.state.db)


async def create(client, headers, **body):
    return await client.post("/v1/merchants", headers=headers, json=body)


async def test_find_or_create_handles_duplicates(client, catalog):
    erin = await login(client, "erin")
    found = (await client.get("/v1/merchants?q=safe", headers=erin)).json()
    assert found[0]["name"] == "Safeway" and found[0]["scope"] == "global"

    # Same name as a global store (any case/punctuation) returns the global one instead of a duplicate.
    again = await create(client, erin, name="  SAFEWAY ")
    assert again.status_code == 200 and again.json() == {"merchant": found[0], "created": False}

    tj = await create(client, erin, name="Trader Joe's", kind="grocery")
    assert tj.status_code == 201 and tj.json()["created"] is True
    assert tj.json()["merchant"]["scope"] == "household"
    same = await create(client, erin, name="trader joes")
    assert same.status_code == 200 and same.json()["merchant"]["id"] == tj.json()["merchant"]["id"]

    # Same chain, different branch: a separate store, disambiguated by locality.
    ballard = await create(client, erin, name="Safeway", locality="Ballard")
    assert ballard.status_code == 201
    names = [(m["name"], m["locality"]) for m in (await client.get("/v1/merchants?q=safeway", headers=erin)).json()]
    assert ("Safeway", None) in names and ("Safeway", "Ballard") in names

    bad = await create(client, erin, name="!!!")
    assert bad.status_code == 422


async def test_household_merchants_are_private_and_catalog_is_read_only(app, client, catalog):
    erin, frank = await login(client, "erin"), await login(client, "frank")
    tj_id = (await create(client, erin, name="Trader Joe's")).json()["merchant"]["id"]

    assert (await client.get(f"/v1/merchants/{tj_id}", headers=frank)).status_code == 404
    assert all(m["id"] != tj_id for m in (await client.get("/v1/merchants?q=trader", headers=frank)).json())
    attach = await client.post("/v1/scans", headers={**frank, **idem()},
                               files=[("files", ("a.jpg", fridge_photo(20), "image/jpeg"))],
                               data={"purchased_from_merchant_id": tj_id})
    assert attach.status_code == 404 and attach.json()["detail"] == "No such merchant."

    # Frank creating his own "Trader Joe's" gets a separate, private record.
    mine = await create(client, frank, name="Trader Joe's")
    assert mine.status_code == 201 and mine.json()["merchant"]["id"] != tj_id

    async with app.state.db.system() as conn:
        frank_id = await conn.fetchval("SELECT id FROM users WHERE handle = 'frank'")
    with pytest.raises(asyncpg.InsufficientPrivilegeError):  # RLS: no writing global rows from a request
        async with app.state.db.scoped(frank_id) as conn:
            await conn.execute("INSERT INTO merchants (name, kind) VALUES ('Totally Official Store', 'grocery')")
    with pytest.raises(asyncpg.InsufficientPrivilegeError):  # no grant: global catalog can't be edited
        async with app.state.db.scoped(frank_id) as conn:
            await conn.execute("UPDATE merchants SET name = 'Hijacked' WHERE name = 'Safeway'")


async def test_store_flows_from_upload_to_purchase_history(app, client, replay_dir, catalog):
    erin = await login(client, "erin")
    tj = (await create(client, erin, name="Trader Joe's")).json()["merchant"]
    ballard = (await create(client, erin, name="Safeway", locality="Ballard")).json()["merchant"]
    photo = fridge_photo(21)
    write_fixture(replay_dir, photo, [MILK, EGGS, MYSTERY])

    created = await client.post("/v1/scans", headers={**erin, **idem()},
                                files=[("files", ("haul.jpg", photo, "image/jpeg"))],
                                data={"purchased_from_merchant_id": tj["id"]})
    assert created.status_code == 202
    scan = created.json()
    assert scan["purchased_from_merchant_id"] == tj["id"] and scan["purchased_from"]["name"] == "Trader Joe's"

    await app.state.worker.drain()
    scan = (await client.get(f"/v1/scans/{scan['id']}", headers=erin)).json()
    d = {x["label"]: x for x in scan["detections"]}
    assert all(x["purchased_from_merchant_id"] == tj["id"] and not x["merchant_override"] for x in d.values())

    # Mixed-store haul: eggs came from Safeway Ballard; the jar's store is unknown.
    review = await client.post(f"/v1/scans/{scan['id']}/review", headers=erin, json={"decisions": [
        {"detection_id": d["2% milk"]["id"], "action": "accept"},
        {"detection_id": d["large eggs"]["id"], "action": "accept", "purchased_from_merchant_id": ballard["id"]},
        {"detection_id": d["unlabeled jar"]["id"], "action": "accept", "purchased_from_merchant_id": None},
    ]})
    assert review.status_code == 200, review.text
    d = {x["label"]: x for x in review.json()["scan"]["detections"]}
    assert d["large eggs"]["purchased_from"]["locality"] == "Ballard" and d["large eggs"]["merchant_override"]
    assert d["unlabeled jar"]["purchased_from"] is None and d["unlabeled jar"]["merchant_override"]

    items = {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=erin)).json()}
    assert items["2% milk"]["last_purchased_from"]["id"] == tj["id"]
    assert items["large eggs"]["last_purchased_from"]["id"] == ballard["id"]
    assert items["unlabeled jar"]["last_purchased_from"] is None

    async def history(name):
        detail = (await client.get(f"/v1/inventory/{items[name]['id']}", headers=erin)).json()
        return [h["merchant"]["id"] for h in detail["purchase_history"]]

    assert await history("2% milk") == [tj["id"]]

    # Preferred store is independent of where it was bought.
    patched = await client.patch(f"/v1/inventory/{items['2% milk']['id']}", headers=erin,
                                 json={"preferred_merchant_id": ballard["id"]})
    assert patched.json()["preferred_merchant_id"] == ballard["id"]
    assert patched.json()["last_purchased_from"]["id"] == tj["id"]

    # Clearing the upload's store drops inherited history but keeps per-item overrides.
    cleared = await client.patch(f"/v1/scans/{scan['id']}", headers=erin, json={"purchased_from_merchant_id": None})
    assert cleared.status_code == 200 and cleared.json()["purchased_from"] is None
    assert await history("2% milk") == [] and await history("large eggs") == [ballard["id"]]

    # Per-item: send eggs back to inheriting (now no store), then give the jar a store after the fact.
    url = f"/v1/scans/{scan['id']}/detections"
    assert (await client.patch(f"{url}/{d['large eggs']['id']}", headers=erin,
                               json={"inherit": ["purchased_from"]})).status_code == 200
    assert await history("large eggs") == []
    assert (await client.patch(f"{url}/{d['unlabeled jar']['id']}", headers=erin,
                               json={"purchased_from_merchant_id": tj["id"]})).status_code == 200
    assert await history("unlabeled jar") == [tj["id"]]

    restored = await client.patch(f"/v1/scans/{scan['id']}", headers=erin,
                                  json={"purchased_from_merchant_id": ballard["id"]})
    assert restored.status_code == 200
    assert await history("2% milk") == [ballard["id"]] and await history("large eggs") == [ballard["id"]]
    assert await history("unlabeled jar") == [tj["id"]]  # its override survives scan-level changes

    both = await client.patch(f"{url}/{d['large eggs']['id']}", headers=erin,
                              json={"inherit": ["purchased_from"], "purchased_from_merchant_id": None})
    neither = await client.patch(f"{url}/{d['large eggs']['id']}", headers=erin, json={})
    assert both.status_code == 422 and neither.status_code == 422

    frank = await login(client, "frank")
    assert (await client.patch(f"/v1/scans/{scan['id']}", headers=frank,
                               json={"purchased_from_merchant_id": None})).status_code == 404


async def test_purchased_on_date_flows_like_the_store(app, client, replay_dir, catalog):
    from datetime import UTC, datetime, timedelta

    gina = await login(client, "gina")
    today = datetime.now(UTC).date()
    monday, tuesday = (today - timedelta(days=3)).isoformat(), (today - timedelta(days=2)).isoformat()
    photo = fridge_photo(30)
    write_fixture(replay_dir, photo, [MILK, EGGS])

    future = await client.post("/v1/scans", headers={**gina, **idem()},
                               files=[("files", ("a.jpg", photo, "image/jpeg"))],
                               data={"purchased_on": (today + timedelta(days=5)).isoformat()})
    assert future.status_code == 422 and future.json()["title"] == "invalid_purchased_on"

    scan = (await client.post("/v1/scans", headers={**gina, **idem()},
                              files=[("files", ("a.jpg", photo, "image/jpeg"))],
                              data={"purchased_on": monday})).json()
    assert scan["purchased_on"] == monday and scan["purchased_from"] is None
    await app.state.worker.drain()
    d = {x["label"]: x for x in (await client.get(f"/v1/scans/{scan['id']}", headers=gina)).json()["detections"]}
    assert all(x["purchased_on"] == monday and not x["purchased_on_override"] for x in d.values())

    # Eggs were bought the next day; the date alone (no store) is enough to record purchase history.
    review = await client.post(f"/v1/scans/{scan['id']}/review", headers=gina, json={
        "remaining": "accept",
        "decisions": [{"detection_id": d["large eggs"]["id"], "action": "accept", "purchased_on": tuesday}]})
    assert review.status_code == 200, review.text
    items = {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=gina)).json()}
    assert items["2% milk"]["last_purchased_on"] == monday and items["large eggs"]["last_purchased_on"] == tuesday
    detail = (await client.get(f"/v1/inventory/{items['large eggs']['id']}", headers=gina)).json()
    assert detail["purchase_history"][0]["purchased_on"] == tuesday
    assert detail["purchase_history"][0]["merchant"] is None

    # Changing only the date leaves the store alone, and per-item overrides survive.
    store = (await create(client, gina, name="PCC Community Markets")).json()["merchant"]
    both = await client.patch(f"/v1/scans/{scan['id']}", headers=gina,
                              json={"purchased_from_merchant_id": store["id"], "purchased_on": today.isoformat()})
    assert both.status_code == 200 and both.json()["purchased_on"] == today.isoformat()
    date_only = await client.patch(f"/v1/scans/{scan['id']}", headers=gina, json={"purchased_on": monday})
    assert date_only.json()["purchased_from"]["id"] == store["id"]
    d = {x["label"]: x for x in date_only.json()["detections"]}
    assert d["2% milk"]["purchased_on"] == monday and d["large eggs"]["purchased_on"] == tuesday

    reset = await client.patch(f"/v1/scans/{scan['id']}/detections/{d['large eggs']['id']}", headers=gina,
                               json={"inherit": ["purchased_on"]})
    eggs = next(x for x in reset.json()["detections"] if x["label"] == "large eggs")
    assert eggs["purchased_on"] == monday and not eggs["purchased_on_override"]
    assert eggs["purchased_from"]["id"] == store["id"]

    cleared = await client.patch(f"/v1/scans/{scan['id']}", headers=gina, json={"purchased_on": None})
    assert cleared.json()["purchased_on"] is None
    items = {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=gina)).json()}
    assert items["large eggs"]["last_purchased_on"] is None
    assert items["large eggs"]["last_purchased_from"]["id"] == store["id"]  # store still recorded

    assert (await client.patch(f"/v1/scans/{scan['id']}", headers=gina, json={})).status_code == 422
    bad = await client.patch(f"/v1/scans/{scan['id']}", headers=gina, json={"purchased_on": "2001-01-01"})
    assert bad.status_code == 422
