"""Wishlist end to end against a real database (set AGORA_TEST_DATABASE_URL). Each test signs in fresh users,
so tests don't depend on each other or on the rest of the suite."""

import asyncio
import json
import uuid
from datetime import UTC, datetime, timedelta

import asyncpg

from tests.conftest import login


def idem() -> dict[str, str]:
    return {"Idempotency-Key": uuid.uuid4().hex}


async def fresh(client) -> dict[str, str]:
    return await login(client, f"w_{uuid.uuid4().hex[:12]}")


async def suggest(client, headers, title: str, **fields):
    body = {"title": title, "rationale": "You buy this every week.", "confidence": 0.8, **fields}
    return await client.post("/v1/wishlist/suggestions", headers={**headers, **idem()}, json=body)


async def me(client, headers) -> dict:
    return (await client.get("/v1/me", headers=headers)).json()


async def test_manual_add_and_priority_order(client):
    h = await fresh(client)
    household = (await me(client, h))["households"][0]["id"]

    plain = await client.post("/v1/wishlist", headers=h, json={"title": "Dish soap"})
    assert plain.status_code == 201, plain.text
    plain = plain.json()
    assert plain["source"] == "user" and plain["status"] == "active" and plain["quantity"] == 1
    assert plain["household_id"] == household and "Added by you" in plain["priority_reasons"]

    soon = (await client.post("/v1/wishlist", headers=h, json={
        "title": "Birthday candles", "needed_by": (datetime.now(UTC).date() + timedelta(days=1)).isoformat(),
        "target_price_cents": 499, "notes": "Blue ones", "category": "Party"})).json()
    high = (await client.post("/v1/wishlist", headers=h, json={"title": "Coffee beans", "priority": 5})).json()
    low = (await client.post("/v1/wishlist", headers=h, json={"title": "Fancy napkins", "priority": 1})).json()
    pinned = (await client.post("/v1/wishlist", headers=h, json={"title": "Batteries", "pinned": True,
                                                                  "priority": 1})).json()
    assert soon["category"] == "party"  # categories are normalized for learning
    assert "Needed in 1 day" in soon["priority_reasons"]

    ranked = (await client.get("/v1/wishlist", headers=h)).json()
    assert [i["title"] for i in ranked] == ["Batteries", "Coffee beans", "Birthday candles", "Dish soap",
                                            "Fancy napkins"]
    assert ranked[0]["priority_reasons"][0] == "Pinned by you"
    assert ranked[1]["priority_reasons"][0] == "You set priority highest"
    assert [i["score"] for i in ranked] == sorted((i["score"] for i in ranked), reverse=True)
    assert {pinned["id"], high["id"], low["id"]} <= {i["id"] for i in ranked}

    # A linked inventory item below its par level pushes the item up.
    inv = (await client.post("/v1/inventory", headers=h, json={
        "household_id": household, "display_name": "Paper towels", "category": "household", "par_level": 4,
        "quantity": 1})).json()
    towels = (await client.post("/v1/wishlist", headers=h, json={"title": "Paper towels",
                                                                  "inventory_item_id": inv["id"]})).json()
    assert towels["category"] == "household"  # borrowed from the inventory item
    assert "Running low: 1 left, you keep 4" in towels["priority_reasons"]
    assert towels["score"] > plain["score"]


async def test_manual_add_validation(client):
    h = await fresh(client)
    assert (await client.post("/v1/wishlist", headers=h, json={"title": ""})).status_code == 422
    assert (await client.post("/v1/wishlist", headers=h, json={"title": "x", "quantity": 0})).status_code == 422
    assert (await client.post("/v1/wishlist", headers=h, json={"title": "x", "priority": 6})).status_code == 422
    assert (await client.post("/v1/wishlist", headers=h, json={"title": "x", "source": "agent"})).status_code == 422
    assert (await client.post("/v1/wishlist", headers=h, json={"title": "x", "product_id": str(uuid.uuid4())})
            ).status_code == 404
    assert (await client.post("/v1/wishlist", headers=h, json={"title": "Olive oil"})).status_code == 201
    dup = await client.post("/v1/wishlist", headers=h, json={"title": "  olive OILS "})
    assert dup.status_code == 409 and dup.json()["title"] == "already_on_wishlist"
    assert dup.headers["content-type"] == "application/problem+json"


async def test_agent_suggestion_is_idempotent_and_audited(client):
    h = await fresh(client)
    body = {"title": "Oat milk", "rationale": "Down to one carton; you buy two a week.", "confidence": 0.9,
            "category": "dairy", "evidence": [{"kind": "inventory_low", "detail": "1 carton left"}],
            "target_price_cents": 450, "quantity": 2}

    no_key = await client.post("/v1/wishlist/suggestions", headers=h, json=body)
    assert no_key.status_code == 400 and no_key.json()["title"] == "idempotency_key_required"
    missing = await client.post("/v1/wishlist/suggestions", headers={**h, **idem()},
                                json={k: v for k, v in body.items() if k != "rationale"})
    assert missing.status_code == 422
    bad = await client.post("/v1/wishlist/suggestions", headers={**h, **idem()}, json={**body, "confidence": 1.5})
    assert bad.status_code == 422
    bad_evidence = await client.post("/v1/wishlist/suggestions", headers={**h, **idem()},
                                     json={**body, "evidence": [{"kind": "vibes", "detail": "x"}]})
    assert bad_evidence.status_code == 422

    key = idem()
    first = await client.post("/v1/wishlist/suggestions", headers={**h, **key}, json=body)
    assert first.status_code == 201, first.text
    item = first.json()
    assert item["source"] == "agent" and item["status"] == "suggested" and item["confidence"] == 0.9
    assert item["evidence"] == [{"kind": "inventory_low", "detail": "1 carton left"}]
    assert "Agent is 90% confident" in item["priority_reasons"]

    retry = await client.post("/v1/wishlist/suggestions", headers={**h, **key}, json=body)
    assert retry.status_code == 201 and retry.json()["id"] == item["id"]
    assert retry.headers["idempotent-replay"] == "true"
    reused = await client.post("/v1/wishlist/suggestions", headers={**h, **key}, json={**body, "quantity": 3})
    assert reused.status_code == 422 and reused.json()["title"] == "idempotency_key_reused"

    pending = (await client.get("/v1/wishlist/suggestions", headers=h)).json()
    assert [i["id"] for i in pending] == [item["id"]]
    assert (await client.get("/v1/wishlist", headers=h)).json() == []  # not on the wishlist until accepted

    trail = (await client.get("/v1/audit", headers=h)).json()
    suggested = [e for e in trail if e["action"] == "wishlist.suggested"]
    assert len(suggested) == 1 and suggested[0]["actor_type"] == "agent"
    assert suggested[0]["meta"] == {"confidence": 0.9, "evidence": 1}  # no titles or rationale in the trail

    dup = await suggest(client, h, "oat milk")
    assert dup.status_code == 409 and dup.json()["title"] == "already_on_wishlist"


async def test_accept_then_purchase(client):
    h = await fresh(client)
    item = (await suggest(client, h, "Sparkling water")).json()

    assert (await client.post(f"/v1/wishlist/{item['id']}/purchased", headers=h)).status_code == 409
    accepted = await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)
    assert accepted.status_code == 200 and accepted.json()["status"] == "active"
    assert accepted.json()["decided_at"] is not None
    again = await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)
    assert again.status_code == 409 and again.json()["title"] == "invalid_transition"
    assert [i["id"] for i in (await client.get("/v1/wishlist", headers=h)).json()] == [item["id"]]

    bought = await client.post(f"/v1/wishlist/{item['id']}/purchased", headers=h)
    assert bought.status_code == 200 and bought.json()["status"] == "purchased"
    assert bought.json()["completed_at"] is not None
    assert (await client.get("/v1/wishlist", headers=h)).json() == []
    history = (await client.get("/v1/wishlist?status=purchased&status=removed", headers=h)).json()
    assert [i["id"] for i in history] == [item["id"]]
    assert (await client.patch(f"/v1/wishlist/{item['id']}", headers=h, json={"quantity": 2})).status_code == 409


async def test_reject_requires_reason_and_is_final(client):
    h = await fresh(client)
    item = (await suggest(client, h, "Kombucha")).json()
    assert (await client.post(f"/v1/wishlist/{item['id']}/reject", headers=h, json={})).status_code == 422
    assert (await client.post(f"/v1/wishlist/{item['id']}/reject", headers=h,
                              json={"reason_code": "meh"})).status_code == 422
    rejected = await client.post(f"/v1/wishlist/{item['id']}/reject", headers=h,
                                 json={"reason_code": "not_interested", "comment": "Too sour"})
    assert rejected.status_code == 200
    assert rejected.json()["status"] == "rejected" and rejected.json()["reject_reason"] == "not_interested"
    assert rejected.json()["reject_comment"] == "Too sour"
    assert (await client.get("/v1/wishlist/suggestions", headers=h)).json() == []
    assert (await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)).status_code == 409
    assert (await client.post(f"/v1/wishlist/{item['id']}/snooze", headers=h,
                              json={"days": 3})).status_code == 409
    trail = (await client.get("/v1/audit", headers=h)).json()
    assert any(e["action"] == "wishlist.rejected" and e["meta"] == {"reason_code": "not_interested"}
               and e["actor_type"] == "user" for e in trail)


async def test_snooze_hides_until_it_expires(app, client):
    h = await fresh(client)
    item = (await suggest(client, h, "Sunscreen")).json()
    url = f"/v1/wishlist/{item['id']}/snooze"

    assert (await client.post(url, headers=h, json={})).status_code == 422
    assert (await client.post(url, headers=h, json={"days": 2, "until": "2030-01-01T00:00:00Z"})).status_code == 422
    past = (datetime.now(UTC) - timedelta(hours=1)).isoformat()
    assert (await client.post(url, headers=h, json={"until": past})).json()["title"] == "invalid_snooze"
    naive = (datetime.now(UTC) + timedelta(days=1)).replace(tzinfo=None).isoformat()
    assert (await client.post(url, headers=h, json={"until": naive})).status_code == 422
    assert (await client.post(url, headers=h, json={"days": 181})).status_code == 422

    snoozed = await client.post(url, headers=h, json={"days": 7})
    assert snoozed.status_code == 200 and snoozed.json()["status"] == "snoozed"
    assert snoozed.json()["snoozed_until"] is not None
    assert (await client.get("/v1/wishlist/suggestions", headers=h)).json() == []
    with_snoozed = (await client.get("/v1/wishlist/suggestions?include_snoozed=true", headers=h)).json()
    assert [i["id"] for i in with_snoozed] == [item["id"]]
    assert (await client.delete(f"/v1/wishlist/{item['id']}", headers=h)).status_code == 409
    resnooze = await client.post(url, headers=h, json={"until": (datetime.now(UTC) + timedelta(days=1)).isoformat()})
    assert resnooze.status_code == 200

    # Once the snooze passes, it's a suggestion again with no background job involved.
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE wishlist_items SET snoozed_until = now() - interval '1 minute' WHERE id = $1",
                           uuid.UUID(item["id"]))
    back = (await client.get("/v1/wishlist/suggestions", headers=h)).json()
    assert [i["id"] for i in back] == [item["id"]]
    assert back[0]["status"] == "suggested" and back[0]["snoozed_until"] is None
    assert (await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)).json()["status"] == "active"


async def test_edit_and_remove(client):
    h = await fresh(client)
    item = (await client.post("/v1/wishlist", headers=h, json={"title": "Tea"})).json()
    url = f"/v1/wishlist/{item['id']}"

    edited = await client.patch(url, headers=h, json={
        "title": "Green tea", "notes": "Loose leaf", "quantity": 3, "target_price_cents": 1299,
        "priority": 4, "pinned": True, "category": "Drinks"})
    assert edited.status_code == 200, edited.text
    e = edited.json()
    assert (e["title"], e["notes"], e["quantity"], e["target_price_cents"], e["priority"], e["pinned"],
            e["category"]) == ("Green tea", "Loose leaf", 3, 1299, 4, True, "drinks")
    assert e["priority_reasons"][:2] == ["Pinned by you", "You set priority high"]

    cleared = (await client.patch(url, headers=h, json={"priority": None, "pinned": False})).json()
    assert cleared["priority"] is None and cleared["pinned"] is False and cleared["score"] < e["score"]
    assert (await client.patch(url, headers=h, json={"title": None})).status_code == 422
    assert (await client.patch(url, headers=h, json={"status": "purchased"})).status_code == 422
    assert (await client.patch(url, headers=h, json={})).status_code == 200

    removed = await client.delete(url, headers=h)
    assert removed.status_code == 200 and removed.json()["status"] == "removed"
    assert (await client.delete(url, headers=h)).status_code == 409
    assert (await client.patch(url, headers=h, json={"quantity": 1})).status_code == 409
    assert (await client.get(url, headers=h)).json()["status"] == "removed"  # kept for history
    trail = (await client.get("/v1/audit", headers=h)).json()
    updates = [e for e in trail if e["action"] == "wishlist.item_updated"]
    assert any("title" in e["meta"]["fields"] for e in updates)
    assert "Green tea" not in json.dumps(updates) and "Loose leaf" not in json.dumps(updates)


async def test_feedback_is_one_per_user_and_separate_from_decisions(app, client):
    h = await fresh(client)
    item = (await suggest(client, h, "Granola", category="breakfast")).json()
    url = f"/v1/wishlist/{item['id']}/feedback"

    up = await client.post(url, headers=h, json={"rating": "up"})
    assert up.status_code == 200 and up.json()["rating"] == "up"
    down = await client.post(url, headers=h, json={"rating": "down", "reason_code": "too_expensive",
                                                   "comment": "Pricey brand"})
    assert down.status_code == 200 and down.json()["rating"] == "down"
    assert (await client.post(url, headers=h, json={"rating": "meh"})).status_code == 422
    fetched = (await client.get(f"/v1/wishlist/{item['id']}", headers=h)).json()
    assert fetched["my_feedback"] == "down" and fetched["status"] == "suggested"  # thumbs never move the item

    async with app.state.db.system() as conn:
        rows = await conn.fetch("SELECT rating, reason_code FROM wishlist_feedback WHERE wishlist_item_id = $1",
                                uuid.UUID(item["id"]))
    assert [(r["rating"], r["reason_code"]) for r in rows] == [("down", "too_expensive")]

    # Allowed on a suggestion whatever its status.
    await client.post(f"/v1/wishlist/{item['id']}/reject", headers=h, json={"reason_code": "already_have"})
    assert (await client.post(url, headers=h, json={"rating": "up"})).status_code == 200

    cleared = await client.delete(url, headers=h)
    assert cleared.status_code == 204
    assert (await client.get(f"/v1/wishlist/{item['id']}", headers=h)).json()["my_feedback"] is None

    mine = (await client.post("/v1/wishlist", headers=h, json={"title": "Bread"})).json()
    not_agent = await client.post(f"/v1/wishlist/{mine['id']}/feedback", headers=h, json={"rating": "up"})
    assert not_agent.status_code == 409 and not_agent.json()["title"] == "not_a_suggestion"


async def test_household_members_cannot_overwrite_each_others_feedback(app, client):
    owner, partner = await fresh(client), await fresh(client)
    owner_me, partner_me = await me(client, owner), await me(client, partner)
    household = uuid.UUID(owner_me["households"][0]["id"])
    async with app.state.db.system() as conn:
        await conn.execute("INSERT INTO household_members (household_id, user_id) VALUES ($1, $2)",
                           household, uuid.UUID(partner_me["id"]))

    item = (await suggest(client, owner, "Hot sauce", household_id=str(household))).json()
    await client.post(f"/v1/wishlist/{item['id']}/feedback", headers=owner, json={"rating": "up"})
    partner_fb = await client.post(f"/v1/wishlist/{item['id']}/feedback", headers=partner, json={"rating": "down"})
    assert partner_fb.status_code == 200
    assert (await client.get(f"/v1/wishlist/{item['id']}", headers=owner)).json()["my_feedback"] == "up"
    assert (await client.get(f"/v1/wishlist/{item['id']}", headers=partner)).json()["my_feedback"] == "down"

    # Row-level security: the partner can read the owner's thumbs but not change or delete them.
    async with app.state.db.scoped(uuid.UUID(partner_me["id"])) as conn:
        assert await conn.fetchval("SELECT count(*) FROM wishlist_feedback") == 2
        assert await conn.execute("UPDATE wishlist_feedback SET rating = 'down' WHERE user_id = $1",
                                  uuid.UUID(owner_me["id"])) == "UPDATE 0"
        assert await conn.execute("DELETE FROM wishlist_feedback WHERE user_id = $1",
                                  uuid.UUID(owner_me["id"])) == "DELETE 0"
        try:
            async with conn.transaction():
                await conn.execute(
                    """INSERT INTO wishlist_feedback (wishlist_item_id, household_id, user_id, rating)
                       VALUES ($1, $2, $3, 'down')""", uuid.UUID(item["id"]), household, uuid.UUID(owner_me["id"]))
            raise AssertionError("inserted feedback as another user")
        except asyncpg.InsufficientPrivilegeError:
            pass


async def test_resuggesting_a_recent_rejection_is_refused(app, client):
    h = await fresh(client)
    chips = (await suggest(client, h, "Potato chips", category="snacks")).json()
    await client.post(f"/v1/wishlist/{chips['id']}/reject", headers=h, json={"reason_code": "not_interested"})

    again = await suggest(client, h, "potato  chip!")  # same item after normalization
    assert again.status_code == 409 and again.json()["title"] == "recently_rejected"
    trail = (await client.get("/v1/audit", headers=h)).json()
    blocked = next(e for e in trail if e["action"] == "wishlist.suggestion_blocked")
    assert blocked["actor_type"] == "agent"
    assert blocked["meta"] == {"reason": "recently_rejected", "reject_reason": "not_interested"}

    # "Too expensive" can come back, but only cheaper than before.
    tv = (await suggest(client, h, "Air fryer", target_price_cents=12000)).json()
    await client.post(f"/v1/wishlist/{tv['id']}/reject", headers=h, json={"reason_code": "too_expensive"})
    assert (await suggest(client, h, "Air fryer", target_price_cents=12000)).status_code == 409
    assert (await suggest(client, h, "Air fryer")).status_code == 409
    cheaper = await suggest(client, h, "Air fryer", target_price_cents=8999)
    assert cheaper.status_code == 201

    # After the 30-day window the agent may try again.
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE wishlist_items SET decided_at = now() - interval '31 days' WHERE id = $1",
                           uuid.UUID(chips["id"]))
    assert (await suggest(client, h, "Potato chips")).status_code == 201

    # A user can always add it themselves.
    other = await fresh(client)
    gum = (await suggest(client, other, "Gum")).json()
    await client.post(f"/v1/wishlist/{gum['id']}/reject", headers=other, json={"reason_code": "wrong_item"})
    assert (await client.post("/v1/wishlist", headers=other, json={"title": "Gum"})).status_code == 201


async def test_negative_feedback_down_weights_a_category(client):
    h = await fresh(client)
    for title in ("Cheese puffs", "Pretzels"):
        item = (await suggest(client, h, title, category="snacks")).json()
        await client.post(f"/v1/wishlist/{item['id']}/feedback", headers=h, json={"rating": "down"})
        await client.post(f"/v1/wishlist/{item['id']}/reject", headers=h, json={"reason_code": "not_interested"})
    liked = (await suggest(client, h, "Yogurt", category="dairy")).json()
    await client.post(f"/v1/wishlist/{liked['id']}/feedback", headers=h, json={"rating": "up"})
    await client.post(f"/v1/wishlist/{liked['id']}/accept", headers=h)

    snack = (await suggest(client, h, "Popcorn", category="Snacks", confidence=0.8)).json()
    dairy = (await suggest(client, h, "Butter", category="dairy", confidence=0.8)).json()
    neutral = (await suggest(client, h, "Rice", category="grains", confidence=0.8)).json()
    assert snack["score"] < neutral["score"] < dairy["score"]
    assert "You turned down 4 similar suggestions in snacks" in snack["priority_reasons"]
    assert "You liked 2 similar suggestions in dairy" in dairy["priority_reasons"]

    queue = (await client.get("/v1/wishlist/suggestions", headers=h)).json()
    assert [i["title"] for i in queue] == ["Butter", "Rice", "Popcorn"]


async def test_agent_context_summarizes_reactions(client):
    h = await fresh(client)
    for title, category in (("Almond milk", "dairy"), ("Kefir", "dairy")):
        item = (await suggest(client, h, title, category=category)).json()
        await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)
    chips = (await suggest(client, h, "Chips", category="snacks")).json()
    await client.post(f"/v1/wishlist/{chips['id']}/reject", headers=h,
                      json={"reason_code": "not_interested", "comment": "Cutting back"})
    blender = (await suggest(client, h, "Blender", category="kitchen", target_price_cents=9900)).json()
    await client.post(f"/v1/wishlist/{blender['id']}/reject", headers=h, json={"reason_code": "too_expensive"})
    await client.post(f"/v1/wishlist/{blender['id']}/feedback", headers=h, json={"rating": "down"})
    pending = (await suggest(client, h, "Limes", category="produce")).json()
    await client.post(f"/v1/wishlist/{pending['id']}/snooze", headers=h, json={"days": 3})
    await client.post("/v1/wishlist", headers=h, json={"title": "Light bulbs"})

    response = await client.get("/v1/wishlist/agent-context", headers=h)
    assert response.status_code == 200
    ctx = response.json()
    assert ctx["window_days"] == 30
    assert ctx["suggestions"] == {"accepted": 2, "rejected": 2, "pending": 1, "acceptance_rate": 0.5}
    assert ctx["liked_categories"] == [{"category": "dairy", "count": 2}]
    assert ctx["disliked_categories"] == [{"category": "kitchen", "count": 2}, {"category": "snacks", "count": 1}]
    rejected = {r["title"]: r for r in ctx["recently_rejected"]}
    assert rejected["Chips"]["reason_code"] == "not_interested" and rejected["Chips"]["comment"] == "Cutting back"
    assert rejected["Blender"]["reason_code"] == "too_expensive"
    blocked = {d["title"]: d for d in ctx["do_not_suggest"]}
    assert blocked["Chips"]["reason"] == "rejected:not_interested" and "until" in blocked["Chips"]
    assert blocked["Blender"]["unless_price_below_cents"] == 9900
    assert blocked["Limes"]["reason"] == "already_snoozed"
    assert blocked["Light bulbs"]["reason"] == "already_on_wishlist"
    assert blocked["Almond milk"]["reason"] == "already_on_wishlist"
    assert "Accepted 2 of 4" in ctx["summary"] and "Avoid: kitchen (2)" in ctx["summary"]

    empty = (await client.get("/v1/wishlist/agent-context", headers=await fresh(client))).json()
    assert empty["suggestions"]["acceptance_rate"] is None and empty["do_not_suggest"] == []


async def test_wishlists_are_isolated_between_households(app, client):
    alice, mallory = await fresh(client), await fresh(client)
    alice_household = (await me(client, alice))["households"][0]["id"]
    item = (await suggest(client, alice, "Saffron")).json()
    mine = (await client.post("/v1/wishlist", headers=alice, json={"title": "Vanilla"})).json()
    inv = (await client.post("/v1/inventory", headers=alice, json={
        "household_id": alice_household, "display_name": "Flour"})).json()

    for method, path, body in (
            ("GET", f"/v1/wishlist/{item['id']}", None),
            ("PATCH", f"/v1/wishlist/{mine['id']}", {"quantity": 9}),
            ("DELETE", f"/v1/wishlist/{mine['id']}", None),
            ("POST", f"/v1/wishlist/{item['id']}/accept", None),
            ("POST", f"/v1/wishlist/{item['id']}/reject", {"reason_code": "other"}),
            ("POST", f"/v1/wishlist/{item['id']}/snooze", {"days": 1}),
            ("POST", f"/v1/wishlist/{mine['id']}/purchased", None),
            ("POST", f"/v1/wishlist/{item['id']}/feedback", {"rating": "down"}),
            ("DELETE", f"/v1/wishlist/{item['id']}/feedback", None),
            ("GET", f"/v1/wishlist?household_id={alice_household}", None),
            ("GET", f"/v1/wishlist/suggestions?household_id={alice_household}", None),
            ("GET", f"/v1/wishlist/agent-context?household_id={alice_household}", None)):
        response = await client.request(method, path, headers=mallory, json=body)
        assert response.status_code == 404, (method, path, response.status_code)

    # Can't plant items in someone else's household or link to their inventory.
    planted = await client.post("/v1/wishlist", headers=mallory, json={"title": "x", "household_id": alice_household})
    assert planted.status_code == 404
    assert (await suggest(client, mallory, "x", household_id=alice_household)).status_code == 404
    assert (await client.post("/v1/wishlist", headers=mallory, json={"title": "x", "inventory_item_id": inv["id"]})
            ).status_code == 404
    assert (await client.get("/v1/wishlist?status=suggested&status=active", headers=mallory)).json() == []

    unchanged = (await client.get(f"/v1/wishlist/{item['id']}", headers=alice)).json()
    assert unchanged["status"] == "suggested" and unchanged["my_feedback"] is None

    # Defense in depth: with no WHERE clause at all, RLS still hides the other household's rows.
    mallory_id = uuid.UUID((await me(client, mallory))["id"])
    async with app.state.db.scoped(mallory_id) as conn:
        assert await conn.fetchval("SELECT count(*) FROM wishlist_items") == 0
        assert await conn.fetchval("SELECT count(*) FROM wishlist_feedback") == 0
        assert await conn.execute("UPDATE wishlist_items SET title = 'pwned'") == "UPDATE 0"


async def test_request_role_cannot_hard_delete_wishlist_items(app, client):
    h = await fresh(client)
    await client.post("/v1/wishlist", headers=h, json={"title": "Matches"})
    async with app.state.db.scoped(uuid.UUID((await me(client, h))["id"])) as conn:
        try:
            async with conn.transaction():
                await conn.execute("DELETE FROM wishlist_items")
            raise AssertionError("request role deleted wishlist rows")
        except asyncpg.InsufficientPrivilegeError:
            pass


async def test_changes_are_broadcast_for_live_refresh(database_url, client):
    h = await fresh(client)
    household = (await me(client, h))["households"][0]["id"]
    events: asyncio.Queue = asyncio.Queue()
    listener = await asyncpg.connect(database_url)
    try:
        await listener.add_listener("agora_events", lambda *args: events.put_nowait(json.loads(args[3])))
        item = (await suggest(client, h, "Basil")).json()
        await client.post(f"/v1/wishlist/{item['id']}/accept", headers=h)
        seen = [await asyncio.wait_for(events.get(), 5) for _ in range(3)]
    finally:
        await listener.close()
    wishlist_events = [e for e in seen if e['type'] == 'wishlist.updated']
    assert len(wishlist_events) == 2
    assert all(e == {"household_id": household, "type": "wishlist.updated", "id": item["id"]}
               for e in wishlist_events)
    assert any(e['type'] == 'watch.updated' and e['household_id'] == household for e in seen)
