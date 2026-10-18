"""The inventory lifecycle used by the iOS list, forms and detail screen."""

from app.seed import seed_catalog
from tests.conftest import login


async def test_inventory_create_edit_observe_archive_restore(app, client):
    await seed_catalog(app.state.db)
    headers = await login(client, "inventory_lifecycle")
    me = (await client.get("/v1/me", headers=headers)).json()
    household = me["households"][0]["id"]
    response = await client.post(f"/v1/households/{household}/locations", headers=headers,
                                json={"name": "Garage freezer", "kind": "freezer"})
    assert response.status_code == 201
    location = response.json()["id"]
    merchant = (await client.post("/v1/merchants", headers=headers,
                                  json={"name": "A&B + Market", "household_id": household})).json()["merchant"]
    response = await client.post("/v1/inventory", headers=headers, json={
        "household_id": household, "display_name": "Oat milk", "unit": "cartons", "category": "dairy",
        "quantity": 1.5, "par_level": 2, "location_id": location, "preferred_merchant_id": merchant["id"],
    })
    assert response.status_code == 201
    item = response.json()
    path = f"/v1/inventory/{item['id']}"
    assert item["quantity"] == 1.5 and item["source"] == "manual"
    filtered = await client.get("/v1/inventory", headers=headers,
                               params={"household_id": household, "location_id": location})
    assert [i["id"] for i in filtered.json()] == [item["id"]]

    response = await client.patch(path, headers=headers, json={
        "display_name": "Unsweetened oat milk", "location_id": None, "par_level": None,
        "preferred_merchant_id": None,
    })
    assert response.status_code == 200
    assert all(response.json()[field] is None for field in ("location_id", "par_level", "preferred_merchant_id"))
    assert response.json()["quantity"] == 1.5  # Metadata edits do not create observations.
    response = await client.post(path + "/observations", headers=headers, json={"quantity": 0})
    assert response.status_code == 201
    detail = (await client.get(path, headers=headers, params={"days": 7})).json()
    assert detail["quantity"] == 0 and len(detail["observations"]) == 2
    assert len(detail["daily"]) == 7 and detail["daily"][-1]["quantity"] == 0
    assert detail["purchase_history"] == []

    assert (await client.patch(path, headers=headers, json={"status": "archived"})).status_code == 200
    assert (await client.get("/v1/inventory", headers=headers)).json() == []
    archived = (await client.get("/v1/inventory", headers=headers, params={"include_archived": "true"})).json()
    assert len(archived) == 1 and archived[0]["status"] == "archived"
    assert (await client.patch(path, headers=headers, json={"status": "active"})).status_code == 200
    assert len((await client.get("/v1/inventory", headers=headers)).json()) == 1
    assert len((await client.get(path, headers=headers)).json()["observations"]) == 2

    # Other accounts cannot read or mutate this item, even with a known UUID.
    other = await login(client, "inventory_outsider")
    assert (await client.get(path, headers=other)).status_code == 404
    assert (await client.patch(path, headers=other, json={"status": "archived"})).status_code == 404
    assert (await client.post(path + "/observations", headers=other, json={"quantity": 99})).status_code == 404
    assert (await client.get("/v1/inventory", headers=other, params={"household_id": household})).status_code == 404
