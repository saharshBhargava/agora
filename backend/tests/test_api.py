"""End-to-end tests against a real database (set AGORA_TEST_DATABASE_URL). Run in file order."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.seed import seed_catalog
from app.timeseries import daily_quantity
from tests.conftest import EGGS, MILK, MYSTERY, fridge_photo, login, write_fixture


def idem() -> dict[str, str]:
    return {"Idempotency-Key": uuid.uuid4().hex}


async def upload(client, headers, photo: bytes, key: dict | None = None, **form):
    return await client.post("/v1/scans", headers={**headers, **(key or idem())},
                             files=[("files", ("fridge.jpg", photo, "image/jpeg"))], data=form)


@pytest.fixture(scope="module")
async def catalog(app):
    await seed_catalog(app.state.db)


async def test_login_creates_personal_household(client):
    headers = await login(client, "alice")
    me = (await client.get("/v1/me", headers=headers)).json()
    assert me["handle"] == "alice"
    assert me["settings"]["media_retention"] == "delete_after_review"
    assert {loc["name"] for loc in me["households"][0]["locations"]} == {"Fridge", "Pantry"}


async def test_requests_without_valid_token_are_rejected(client):
    assert (await client.get("/v1/me")).status_code == 401
    assert (await client.get("/v1/me", headers={"Authorization": "Bearer nope"})).status_code == 401


async def test_scan_review_flow(app, client, replay_dir, catalog):
    headers = await login(client, "alice")
    photo = fridge_photo(1)
    write_fixture(replay_dir, photo, [MILK, EGGS, MYSTERY])

    created = await upload(client, headers, photo)
    assert created.status_code == 202, created.text
    scan = created.json()
    assert scan["status"] == "uploaded" and scan["frame_count"] == 1

    assert await app.state.worker.drain() >= 1
    scan = (await client.get(f"/v1/scans/{scan['id']}", headers=headers)).json()
    assert scan["status"] == "needs_review" and scan["provider"] == "replay"
    by_label = {d["label"]: d for d in scan["detections"]}
    assert by_label["2% milk"]["quantity"] == 1.5 and by_label["2% milk"]["product_id"]  # matched the catalog
    assert all(d["review"] == "proposed" for d in scan["detections"])  # nothing new is auto-accepted

    frame = await client.get(f"/v1/scans/{scan['id']}/frames/0", headers=headers)
    assert frame.status_code == 200 and frame.headers["cache-control"] == "private, no-store"
    assert b"SecretPhoneMaker" not in frame.content  # EXIF stripped on ingest

    review = await client.post(f"/v1/scans/{scan['id']}/review", headers=headers, json={
        "decisions": [
            {"detection_id": by_label["2% milk"]["id"], "action": "accept"},
            {"detection_id": by_label["large eggs"]["id"], "action": "correct", "quantity": 8},
            {"detection_id": by_label["unlabeled jar"]["id"], "action": "reject"},
        ]})
    assert review.status_code == 200, review.text
    assert review.json()["items_updated"] == 2 and review.json()["scan"]["status"] == "confirmed"

    items = {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=headers)).json()}
    assert set(items) == {"2% milk", "large eggs"}
    assert items["large eggs"]["quantity"] == 8 and items["large eggs"]["source"] == "scan"

    # Retention: default setting deletes raw frames as soon as the review is done.
    await app.state.worker.drain()
    gone = await client.get(f"/v1/scans/{scan['id']}/frames/0", headers=headers)
    assert gone.status_code == 410

    detail = (await client.get(f"/v1/inventory/{items['2% milk']['id']}", headers=headers)).json()
    assert detail["observations"][0]["scan_id"] == scan["id"]  # provenance back to the scan
    assert detail["daily"][-1]["quantity"] == 1.5


async def test_rescan_of_known_items_is_auto_accepted(app, client, replay_dir):
    headers = await login(client, "alice")
    photo = fridge_photo(2)
    write_fixture(replay_dir, photo, [{**MILK, "count": 1, "fill_fraction": 0.25}, EGGS])
    scan = (await upload(client, headers, photo)).json()
    await app.state.worker.drain()
    scan = (await client.get(f"/v1/scans/{scan['id']}", headers=headers)).json()
    assert scan["status"] == "confirmed"
    assert all(d["auto_accepted"] for d in scan["detections"])
    items = {i["display_name"]: i for i in (await client.get("/v1/inventory", headers=headers)).json()}
    assert items["2% milk"]["quantity"] == 0.25


async def test_households_are_isolated(app, client):
    alice, bob = await login(client, "alice"), await login(client, "bob")
    alice_items = (await client.get("/v1/inventory", headers=alice)).json()
    alice_household = alice_items[0]["household_id"]
    item_id = alice_items[0]["id"]
    scans = (await client.get("/v1/scans", headers=alice)).json()

    assert (await client.get(f"/v1/inventory?household_id={alice_household}", headers=bob)).status_code == 404
    assert (await client.get(f"/v1/inventory/{item_id}", headers=bob)).status_code == 404
    assert (await client.get(f"/v1/scans/{scans[0]['id']}", headers=bob)).status_code == 404
    assert (await client.post(f"/v1/inventory/{item_id}/observations", headers=bob,
                              json={"quantity": 0})).status_code == 404
    assert (await client.get("/v1/inventory", headers=bob)).json() == []

    # Defense in depth: even a raw query with no WHERE clause sees nothing across the boundary.
    db = app.state.db
    async with db.system() as conn:
        bob_id = await conn.fetchval("SELECT id FROM users WHERE handle = 'bob'")
    async with db.scoped(bob_id) as conn:
        assert await conn.fetchval("SELECT count(*) FROM inventory_items") == 0
        assert await conn.fetchval("SELECT count(*) FROM inventory_observations") == 0
        assert await conn.fetchval("SELECT count(*) FROM scans") == 0


async def test_idempotent_upload(client, replay_dir):
    headers = await login(client, "alice")
    photo = fridge_photo(3)
    key = idem()
    first = await upload(client, headers, photo, key)
    again = await upload(client, headers, photo, key)
    assert again.status_code == 202 and again.json()["id"] == first.json()["id"]
    assert again.headers.get("idempotent-replay") == "true"
    other = await upload(client, headers, fridge_photo(4), key)
    assert other.status_code == 422 and other.json()["title"] == "idempotency_key_reused"


async def test_upload_validation(client):
    headers = await login(client, "alice")
    bad = await client.post("/v1/scans", headers={**headers, **idem()},
                            files=[("files", ("x.jpg", b"%PDF-1.4 definitely not an image", "image/jpeg"))])
    assert bad.status_code == 415
    no_key = await client.post("/v1/scans", headers=headers,
                               files=[("files", ("x.jpg", fridge_photo(5), "image/jpeg"))])
    assert no_key.status_code == 400


async def test_scan_without_fixture_fails_cleanly(app, client):
    headers = await login(client, "carol")
    scan = (await upload(client, headers, fridge_photo(99))).json()
    await app.state.worker.drain()
    scan = (await client.get(f"/v1/scans/{scan['id']}", headers=headers)).json()
    assert scan["status"] == "failed" and scan["error_code"] == "no_replay_fixture"


async def test_manual_observation_and_daily_series(app, client):
    headers = await login(client, "dave")
    item = (await client.post("/v1/inventory", headers=headers, json={
        "household_id": (await client.get("/v1/me", headers=headers)).json()["households"][0]["id"],
        "display_name": "oat milk", "quantity": 2})).json()
    three_days_ago = (datetime.now(UTC) - timedelta(days=3)).isoformat()
    response = await client.post(f"/v1/inventory/{item['id']}/observations", headers=headers,
                                 json={"quantity": 3, "time": three_days_ago})
    assert response.status_code == 201
    detail = (await client.get(f"/v1/inventory/{item['id']}?days=5", headers=headers)).json()
    series = [p["quantity"] for p in detail["daily"]]
    assert series[-1] == 2 and series[-4] == 3 and series[0] is None  # carried forward, gap before first value

    db = app.state.db
    if db.timescale:  # the Timescale and plain-Postgres implementations must agree exactly
        async with db.system() as conn:
            end = datetime.now(UTC).replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
            start = end - timedelta(days=5)
            fast = await daily_quantity(conn, uuid.UUID(item["id"]), start, end, timescale=True)
            plain = await daily_quantity(conn, uuid.UUID(item["id"]), start, end, timescale=False)
            assert fast == plain


async def test_audit_chain_detects_tampering(app, client):
    headers = await login(client, "alice")
    trail = (await client.get("/v1/audit", headers=headers)).json()
    assert {"user.created", "scan.created", "scan.reviewed", "scan.confirmed", "media.deleted"} <= {
        e["action"] for e in trail}
    assert (await client.get("/v1/audit/verify", headers=headers)).json()["ok"] is True

    target = trail[-1]["id"]
    async with app.state.db.system() as conn:
        original = await conn.fetchval("SELECT meta FROM audit_log WHERE id = $1", target)
        await conn.execute("UPDATE audit_log SET meta = '{\"forged\": true}' WHERE id = $1", target)
    result = (await client.get("/v1/audit/verify", headers=headers)).json()
    assert result == {"ok": False, "rows_checked": result["rows_checked"], "first_broken_id": target}
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE audit_log SET meta = $2 WHERE id = $1", target, original)
    assert (await client.get("/v1/audit/verify", headers=headers)).json()["ok"] is True


async def test_request_role_cannot_rewrite_history(app):
    async with app.state.db.system() as conn:
        user_id = await conn.fetchval("SELECT id FROM users WHERE handle = 'alice'")
    with pytest.raises(Exception, match="permission denied"):
        async with app.state.db.scoped(user_id) as conn:
            await conn.execute("DELETE FROM audit_log")
