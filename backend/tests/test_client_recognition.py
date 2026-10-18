"""Client-side Gemini recognition: reviewed JSON only, atomic and idempotent."""

import asyncio
from datetime import UTC, datetime
from uuid import UUID, uuid4

from app.seed import seed_catalog
from tests.conftest import login


async def context(client, handle):
    headers = await login(client, handle)
    me = (await client.get("/v1/me", headers=headers)).json()
    return headers, me["households"][0]["id"], me["id"]


def payload(household):
    return {
        "household_id": household,
        "captured_at": datetime.now(UTC).isoformat(),
        "media_kind": "photos",
        "model": "gemini-flash-latest",
        "items": [
            {"display_name": "Milk", "category": "dairy", "unit": "cartons", "quantity": 1.5, "confidence": 0.92}
        ],
    }


async def test_metadata_only_save_purchase_history_and_concurrent_retry(app, client):
    await seed_catalog(app.state.db)
    headers, household, user = await context(client, "client_recognition")
    body = payload(household)
    merchant = (
        await client.post(
            "/v1/merchants", headers=headers, json={"name": "Recognition market", "household_id": household}
        )
    ).json()["merchant"]
    body["purchased_from_merchant_id"] = merchant["id"]
    body["purchased_on"] = datetime.now(UTC).date().isoformat()
    headers["Idempotency-Key"] = str(uuid4())
    replies = await asyncio.gather(
        *(client.post("/v1/inventory/recognitions", headers=headers, json=body) for _ in range(3))
    )
    assert all(r.status_code == 201 for r in replies), [r.text for r in replies]
    assert replies[0].json() == replies[1].json() == replies[2].json()
    saved = replies[0].json()
    assert len(saved["items"]) == 1
    item = saved["items"][0]
    assert item["unit"] == "cartons" and item["quantity"] == 1.5
    assert item["last_purchased_from"]["id"] == merchant["id"]
    detail = (await client.get(f"/v1/inventory/{item['id']}", headers=headers)).json()
    assert len(detail["observations"]) == len(detail["purchase_history"]) == 1
    assert detail["purchase_history"][0]["quantity"] == 1.5
    async with app.state.db.scoped(UUID(user)) as conn:
        scan = await conn.fetchrow("SELECT * FROM scans WHERE id = $1", UUID(saved["recognition_id"]))
        assert scan["provider"] == "gemini-client" and scan["status"] == "confirmed"
        assert scan["frame_keys"] == scan["frame_hashes"] == []
        assert scan["raw_video_key"] is None and scan["media_deleted_at"] is not None
        assert await conn.fetchval("SELECT count(*) FROM scans WHERE household_id = $1", UUID(household)) == 1
    async with app.state.db.system() as conn:
        jobs = await conn.fetch(
            "SELECT payload FROM jobs WHERE kind = 'forecast.refresh' AND payload->>'household_id' = $1",
            household,
        )
        assert len(jobs) == 1
        assert jobs[0]["payload"]["item_ids"] == [item["id"]]
        assert (
            await conn.fetchval("SELECT count(*) FROM jobs WHERE payload->>'scan_id' = $1", saved["recognition_id"])
            == 0
        )
    body["items"][0]["quantity"] = 9
    assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    assert (await client.get(f"/v1/inventory/{item['id']}", headers=headers)).json()["quantity"] == 1.5
    body["items"][0]["inventory_item_id"] = item["id"]
    body["captured_at"] = datetime.now(UTC).isoformat()
    headers["Idempotency-Key"] = str(uuid4())
    updated = await client.post("/v1/inventory/recognitions", headers=headers, json=body)
    assert updated.status_code == 201, updated.text
    assert updated.json()["items"][0]["quantity"] == 9
    assert len((await client.get("/v1/inventory", headers=headers)).json()) == 1


async def test_invalid_entries_roll_back_whole_batch_and_isolate_households(app, client):
    headers, household, user = await context(client, "recognition_atomic")
    outsider, other_household, _ = await context(client, "recognition_other")
    other_item = (
        await client.post(
            "/v1/inventory", headers=outsider, json={"household_id": other_household, "display_name": "Private milk"}
        )
    ).json()
    body = payload(household)
    body["items"].append({**body["items"][0], "inventory_item_id": other_item["id"]})
    headers["Idempotency-Key"] = str(uuid4())
    assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 404
    assert (await client.get("/v1/inventory", headers=headers)).json() == []
    async with app.state.db.scoped(UUID(user)) as conn:
        assert await conn.fetchval("SELECT count(*) FROM scans WHERE household_id = $1", UUID(household)) == 0
    body["items"].pop()
    result = await client.post("/v1/inventory/recognitions", headers=headers, json=body)
    assert result.status_code == 201, result.text
    item = result.json()["items"][0]
    body["items"][0]["inventory_item_id"] = item["id"]
    body["items"][0]["unit"] = "liters"
    headers["Idempotency-Key"] = str(uuid4())
    assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    body["items"][0]["unit"] = "cartons"
    body["items"].append(body["items"][0].copy())
    assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    assert (
        await client.post(
            "/v1/inventory/recognitions", headers={**outsider, "Idempotency-Key": str(uuid4())}, json=body
        )
    ).status_code == 404


async def test_reject_media_references_empty_lists_and_invalid_values(client):
    headers, household, _ = await context(client, "recognition_validation")
    headers["Idempotency-Key"] = str(uuid4())
    for field, value in [
        ("file", "bytes"),
        ("frame_keys", ["secret.jpg"]),
        ("file_uri", "https://example.com/video"),
        ("image_base64", "AAAA"),
    ]:
        body = payload(household)
        body[field] = value
        assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    for field, value in [
        ("quantity", -1),
        ("quantity", 10001),
        ("confidence", 1.1),
        ("unit", " "),
        ("display_name", " "),
        ("image", "AAAA"),
    ]:
        body = payload(household)
        body["items"][0][field] = value
        assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    body = payload(household)
    body["items"] = []
    assert (await client.post("/v1/inventory/recognitions", headers=headers, json=body)).status_code == 422
    assert (await client.get("/v1/inventory", headers=headers)).json() == []
    assert (await client.post("/v1/inventory/recognitions", json=payload(household))).status_code == 401
