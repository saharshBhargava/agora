"""Agent commerce end to end against a real database (set AGORA_TEST_DATABASE_URL): mandates, intents, the
kill switch, Agora checkout, budgets and spend. Each test signs in fresh users."""

import asyncio
import uuid

import asyncpg
import pytest

from tests.conftest import login


@pytest.fixture(autouse=True)
async def restore_demo_flags(app):
    async with app.state.db.system() as conn:
        original = await conn.fetch("SELECT id FROM users WHERE is_demo")
    yield
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE users SET is_demo = false WHERE is_demo")
        await conn.execute("UPDATE users SET is_demo = true WHERE id = ANY($1::uuid[])",
                           [row["id"] for row in original])


def idem() -> dict[str, str]:
    return {"Idempotency-Key": uuid.uuid4().hex}


async def fresh(client, autonomy: str = "buy_within_mandate") -> dict[str, str]:
    headers = await login(client, f"a_{uuid.uuid4().hex[:12]}")
    response = await client.patch("/v1/me/settings", headers=headers,
                                  json={"autonomy_level": autonomy})  # default time zone: America/Los_Angeles
    assert response.status_code == 200, response.text
    return headers


async def household(client, headers) -> str:
    return (await client.get("/v1/me", headers=headers)).json()["households"][0]["id"]


async def flag_demo(app, client, headers):
    """Only explicit simulated-checkout test accounts receive the server-only marker."""
    user_id = uuid.UUID((await client.get("/v1/me", headers=headers)).json()["id"])
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE users SET is_demo = false WHERE is_demo")
        await conn.execute("UPDATE users SET is_demo = true WHERE id = $1", user_id)


async def test_real_account_checkout_never_simulates_payments(client):
    headers = await fresh(client)
    await mandate(client, headers)
    result = await propose(client, headers, execution="agora")
    assert result.status_code == 503 and result.json()["title"] == "payments_unavailable"
    assert (await client.get("/v1/spend", headers=headers)).json()["total_cents"] == 0
    assert (await client.get("/v1/agent/intents", headers=headers)).json() == []


async def test_demo_checkout_never_calls_external_provider(client, app):
    class ExternalProvider:
        name = "external"

        async def charge(self, request):
            raise AssertionError("The demo account reached an external payment provider")

    headers = await fresh(client)
    await flag_demo(app, client, headers)
    await mandate(client, headers)
    original = app.state.payments
    app.state.payments = ExternalProvider()
    try:
        result = await propose(client, headers, execution="agora")
        assert result.status_code == 201 and result.json()["status"] == "succeeded"
    finally:
        app.state.payments = original


async def mandate(client, headers, **fields) -> dict:
    body = {"label": "Groceries", "categories": ["Dairy", "produce"], "max_per_txn_cents": 5000,
            "max_per_period_cents": 20000, "period": "month", **fields}
    response = await client.post("/v1/agent/mandates", headers=headers, json=body)
    assert response.status_code == 201, response.text
    return response.json()


async def propose(client, headers, title: str = "Oat milk", key: dict | None = None, **fields):
    body = {"kind": "purchase", "title": title, "amount_cents": 899, "category": "dairy",
            "merchant_name": "Ballard Market", "rationale": "One carton left; you use about two a week.",
            "evidence": [{"kind": "inventory_low", "detail": "1 carton left in the fridge"}], **fields}
    return await client.post("/v1/agent/intents", headers={**headers, **(key or idem())}, json=body)


async def outcome(client, headers, intent_id: str, status: str, **fields):
    return await client.post(f"/v1/agent/intents/{intent_id}/outcome", headers=headers,
                             json={"status": status, **fields})


async def trail(client, headers) -> list[dict]:
    return (await client.get("/v1/audit", headers=headers, params={"limit": 200})).json()


async def test_allow_within_mandate_device_checkout(client):
    h = await fresh(client)
    m = await mandate(client, h)
    assert m["status"] == "active" and m["categories"] == ["dairy", "produce"]
    assert m["spent_this_period_cents"] == 0

    response = await propose(client, h)
    assert response.status_code == 201, response.text
    intent = response.json()
    assert intent["decision"] == "allow" and intent["status"] == "approved"
    assert intent["mandate_id"] == m["id"] and intent["decided_by"] == "policy" and intent["mine"]
    assert intent["decision_reasons"] == [
        "Within your 'Groceries' mandate: $8.99 of $50.00 allowed per purchase.",
        "$191.01 left on 'Groceries' this month after this."]
    assert intent["reason_codes"] == ["within_mandate", "mandate_period_left"]
    assert intent["evidence"] == [{"kind": "inventory_low", "detail": "1 carton left in the fridge"}]
    assert intent["approval_expires_at"] is None

    # The device marks it executing before acting, then reports the result. Retrying a report is harmless.
    assert (await outcome(client, h, intent["id"], "executing")).json()["status"] == "executing"
    done = await outcome(client, h, intent["id"], "succeeded", final_amount_cents=949)
    assert done.status_code == 200, done.text
    done = done.json()
    assert done["status"] == "succeeded" and done["final_amount_cents"] == 949 and done["order_id"]
    again = await outcome(client, h, intent["id"], "succeeded", final_amount_cents=949)
    assert again.status_code == 200 and again.json()["order_id"] == done["order_id"]
    late = await outcome(client, h, intent["id"], "failed")
    assert late.status_code == 409 and late.json()["title"] == "invalid_transition"

    spend = (await client.get("/v1/spend", headers=h)).json()
    assert spend["total_cents"] == 949
    assert spend["groups"] == [{"key": "dairy", "label": "dairy", "amount_cents": 949, "entries": 1}]
    by_merchant = (await client.get("/v1/spend", headers=h, params={"group": "merchant"})).json()
    assert by_merchant["groups"][0]["label"] == "Ballard Market"
    m = (await client.get("/v1/agent/mandates", headers=h)).json()[0]
    assert m["spent_this_period_cents"] == 949  # the final amount counts against the period cap

    actions = {(e["action"], e["actor_type"]) for e in await trail(client, h)}
    assert {("agent.mandate_created", "user"), ("agent.intent_proposed", "agent"),
            ("agent.intent_executing", "agent"), ("agent.intent_succeeded", "agent"),
            ("order.placed", "agent")} <= actions
    succeeded = next(e for e in await trail(client, h) if e["action"] == "agent.intent_succeeded")
    assert succeeded["meta"]["over_authorization"] is True  # charged $9.49 against $8.99 approved
    assert (await client.get("/v1/audit/verify", headers=h)).json()["ok"]

    # Non-purchases are allowed by autonomy alone.
    listed = (await propose(client, h, "Paper towels", kind="list_add", amount_cents=None)).json()
    assert listed["decision"] == "allow" and listed["reason_codes"] == ["autonomy_allows"]


async def test_escalates_over_cap_and_user_decides(client):
    h = await fresh(client)
    await mandate(client, h)

    over = (await propose(client, h, "Olive oil, 3L", amount_cents=6000, category="pantry")).json()
    assert over["decision"] == "needs_approval" and over["status"] == "proposed" and over["mandate_id"] is None
    assert over["decision_reasons"] == ["None of your mandates cover 'Olive oil, 3L' at Ballard Market (pantry)."]
    assert over["approval_expires_at"]

    big = (await propose(client, h, "Cheese wheel", amount_cents=6000)).json()
    assert big["decision"] == "needs_approval"
    assert big["decision_reasons"][0] == ("$60.00 is over the $50.00 per-purchase limit in your 'Groceries' "
                                          "mandate.")

    # The device can't act on something the user hasn't approved.
    early = await outcome(client, h, big["id"], "executing")
    assert early.status_code == 409 and "needs approval first" in early.json()["detail"]

    inbox = (await client.get("/v1/agent/intents", headers=h, params={"status": "proposed"})).json()
    assert {i["id"] for i in inbox} == {over["id"], big["id"]}
    state = (await client.get("/v1/agent/state", headers=h)).json()
    assert state == {"autonomy_level": "buy_within_mandate", "paused": False, "paused_at": None,
                     "active_mandates": 1, "pending_approvals": 2}

    approved = await client.post(f"/v1/agent/intents/{big['id']}/approve", headers=h)
    assert approved.status_code == 200, approved.text
    assert approved.json()["status"] == "approved" and approved.json()["decided_by"] == "user"
    assert (await client.post(f"/v1/agent/intents/{big['id']}/approve", headers=h)).json()["status"] == "approved"

    rejected = await client.post(f"/v1/agent/intents/{over['id']}/reject", headers=h,
                                 json={"reason_code": "too_expensive"})
    assert rejected.json()["status"] == "rejected" and rejected.json()["reject_reason"] == "too_expensive"
    assert (await client.post(f"/v1/agent/intents/{over['id']}/approve", headers=h)).status_code == 409

    # An approved device intent can still be withdrawn until the device starts.
    withdrawn = await client.post(f"/v1/agent/intents/{big['id']}/reject", headers=h, json={})
    assert withdrawn.json()["status"] == "rejected"

    actions = [(e["action"], e["actor_type"]) for e in await trail(client, h)]
    assert ("agent.intent_approved", "user") in actions and ("agent.intent_rejected", "user") in actions

    # Lower autonomy levels always ask; Inform never acts.
    await client.patch("/v1/me/settings", headers=h, json={"autonomy_level": "buy_with_approval"})
    asks = (await propose(client, h, "Yogurt")).json()
    assert asks["decision"] == "needs_approval" and asks["reason_codes"][0] == "autonomy_requires_approval"
    await client.patch("/v1/me/settings", headers=h, json={"autonomy_level": "inform"})
    never = (await propose(client, h, "Butter")).json()
    assert never["decision"] == "deny" and never["status"] == "rejected"


async def test_agora_checkout_after_approval(client, app):
    h = await fresh(client, autonomy="buy_with_approval")
    await flag_demo(app, client, h)
    intent = (await propose(client, h, "Sourdough loaf", execution="agora", amount_cents=750,
                            category="bakery")).json()
    assert intent["status"] == "proposed" and intent["order_id"] is None
    assert (await outcome(client, h, intent["id"], "succeeded")).json()["title"] == "server_executed"

    paid = (await client.post(f"/v1/agent/intents/{intent['id']}/approve", headers=h)).json()
    assert paid["status"] == "succeeded" and paid["final_amount_cents"] == 750 and paid["order_id"]
    # Approving again returns the same order rather than charging again.
    again = (await client.post(f"/v1/agent/intents/{intent['id']}/approve", headers=h)).json()
    assert again["order_id"] == paid["order_id"]
    assert (await client.get("/v1/spend", headers=h)).json()["total_cents"] == 750

    unknown = (await propose(client, h, "Bagels", execution="agora", payment_method_ref="sim_visa_timeout",
                             category="bakery")).json()
    unknown = (await client.post(f"/v1/agent/intents/{unknown['id']}/approve", headers=h)).json()
    assert unknown["status"] == "outcome_unknown" and unknown["error_code"] == "provider_timeout"
    # Never replayed automatically: asking for the same thing again flags the uncertain order.
    retry = (await propose(client, h, "Bagels", category="bakery")).json()
    assert "duplicate_unknown" in retry["reason_codes"]

    assert (await client.get("/v1/spend", headers=h)).json()["total_cents"] == 750
    actions = [(e["action"], e["actor_type"]) for e in await trail(client, h)]
    assert ("order.placed", "user") in actions and ("agent.intent_outcome_unknown", "user") in actions

    other = await fresh(client, autonomy="buy_with_approval")
    await flag_demo(app, client, other)
    declined = (await propose(client, other, "Croissants", execution="agora", payment_method_ref="sim_visa_declined",
                              category="bakery")).json()
    declined = (await client.post(f"/v1/agent/intents/{declined['id']}/approve", headers=other)).json()
    assert declined["status"] == "failed" and declined["error_code"] == "card_declined"
    assert declined["order_id"] is None
    assert (await client.get("/v1/spend", headers=other)).json()["total_cents"] == 0

    bad = await client.post("/v1/agent/intents", headers={**h, **idem()}, json={
        "kind": "list_add", "title": "x", "rationale": "y", "execution": "agora"})
    assert bad.status_code == 422
    no_price = await client.post("/v1/agent/intents", headers={**h, **idem()}, json={
        "kind": "purchase", "title": "x", "rationale": "y"})
    assert no_price.status_code == 422


async def test_pause_revokes_cancels_and_denies(client):
    h = await fresh(client)
    m = await mandate(client, h)
    approved = (await propose(client, h, "Eggs")).json()
    pending = (await propose(client, h, "Steak", amount_cents=8000, category="meat")).json()
    assert approved["status"] == "approved" and pending["status"] == "proposed"
    executing = (await propose(client, h, "Spinach", category="produce")).json()
    await outcome(client, h, executing["id"], "executing")

    paused = await client.post("/v1/agent/pause", headers=h)
    assert paused.status_code == 200, paused.text
    body = paused.json()
    assert (body["paused"], body["mandates_revoked"], body["intents_cancelled"], body["in_flight"]) == (
        True, 1, 2, 1)

    for intent in (approved, pending):
        current = (await client.get(f"/v1/agent/intents/{intent['id']}", headers=h)).json()
        assert current["status"] == "cancelled" and current["decided_by"] == "kill_switch"
    assert (await client.post(f"/v1/agent/intents/{pending['id']}/approve", headers=h)).status_code == 409
    assert (await outcome(client, h, approved["id"], "executing")).status_code == 409
    assert (await client.get("/v1/agent/mandates", headers=h)).json() == []
    revoked = (await client.get("/v1/agent/mandates", headers=h, params={"include_inactive": True})).json()
    assert revoked[0]["id"] == m["id"] and revoked[0]["status"] == "revoked"
    assert revoked[0]["revoked_reason"] == "kill_switch"

    denied = (await propose(client, h, "Milk")).json()
    assert denied["decision"] == "deny" and denied["status"] == "rejected"
    assert denied["decision_reasons"] == ["You paused your agent. Resume it to let it act again."]
    assert (await propose(client, h, "Milk", kind="list_add", amount_cents=None)).json()["decision"] == "deny"
    assert (await client.get("/v1/agent/state", headers=h)).json()["paused"] is True
    assert (await client.post("/v1/agent/pause", headers=h)).json()["mandates_revoked"] == 0  # idempotent

    assert (await client.post("/v1/agent/resume", headers=h)).json()["paused"] is False
    after = (await propose(client, h, "Cream")).json()
    assert after["decision"] == "needs_approval" and after["reason_codes"] == ["no_mandate"]  # still revoked

    actions = [(e["action"], e["actor_type"]) for e in await trail(client, h)]
    assert ("agent.paused", "user") in actions and ("agent.resumed", "user") in actions
    first_pause = [e for e in await trail(client, h) if e["action"] == "agent.paused"][-1]  # trail is newest first
    assert first_pause["meta"] == {"mandates_revoked": 1, "intents_cancelled": 2, "in_flight": 1}


async def test_approve_holds_household_lock_during_checkout(client, app):
    """Approve takes the same household lock as propose for the whole checkout transaction.

    Without it, a concurrent auto-allow propose can read budgets before the approve transaction
    commits spend and both charge under the same cap.
    """
    h = await fresh(client, autonomy="buy_with_approval")
    await flag_demo(app, client, h)
    await mandate(client, h)
    created = await client.post("/v1/budgets", headers=h, json={"period": "month", "limit_cents": 1500})
    assert created.status_code == 201, created.text
    pending = (await propose(client, h, "Milk", execution="agora", amount_cents=899)).json()
    assert pending["status"] == "proposed"
    await client.patch("/v1/me/settings", headers=h, json={"autonomy_level": "buy_within_mandate"})

    charge_started, release_charge = asyncio.Event(), asyncio.Event()
    real_charge = app.state.demo_payments.charge

    async def gated_charge(request):
        charge_started.set()
        await release_charge.wait()
        return await real_charge(request)

    app.state.demo_payments.charge = gated_charge
    try:
        approve_task = asyncio.create_task(
            client.post(f"/v1/agent/intents/{pending['id']}/approve", headers=h))
        await asyncio.wait_for(charge_started.wait(), timeout=5)
        propose_task = asyncio.create_task(propose(client, h, "Eggs", execution="agora", amount_cents=899))
        await asyncio.sleep(0.2)  # propose should block on the household lock held by approve
        assert not propose_task.done(), "propose must wait while approve holds the household lock"
        release_charge.set()
        approve, auto = await asyncio.gather(approve_task, propose_task)
    finally:
        release_charge.set()
        app.state.demo_payments.charge = real_charge

    assert approve.status_code == 200, approve.text
    assert auto.status_code == 201, auto.text
    assert approve.json()["status"] == "succeeded"
    assert auto.json()["status"] != "succeeded"
    assert auto.json()["decision"] in ("deny", "needs_approval")
    assert (await client.get("/v1/spend", headers=h)).json()["total_cents"] == 899


async def test_idempotent_retries_never_double_charge(client, database_url, app):
    h = await fresh(client)
    await flag_demo(app, client, h)
    await mandate(client, h)
    key = idem()
    first = await propose(client, h, "Butter", key=key, execution="agora")
    assert first.status_code == 201, first.text
    intent = first.json()
    assert intent["decision"] == "allow" and intent["status"] == "succeeded" and intent["order_id"]

    retries = await asyncio.gather(*[propose(client, h, "Butter", key=key, execution="agora") for _ in range(5)])
    assert {r.status_code for r in retries} == {201}
    assert {r.json()["id"] for r in retries} == {intent["id"]}
    assert all(r.headers["idempotent-replay"] == "true" for r in retries)
    assert {r.json()["order_id"] for r in retries} == {intent["order_id"]}

    reused = await propose(client, h, "Butter", key=key, execution="agora", amount_cents=999)
    assert reused.status_code == 422 and reused.json()["title"] == "idempotency_key_reused"
    no_key = await client.post("/v1/agent/intents", headers=h, json={"kind": "list_add", "title": "x",
                                                                     "rationale": "y"})
    assert no_key.status_code == 400 and no_key.json()["title"] == "idempotency_key_required"

    # Concurrent first attempts with one fresh key also produce one intent.
    key2 = idem()
    racing = await asyncio.gather(*[propose(client, h, "Ghee", key=key2, execution="agora") for _ in range(4)])
    assert {r.status_code for r in racing} <= {201, 409}
    assert len({r.json()["id"] for r in racing if r.status_code == 201}) == 1

    conn = await asyncpg.connect(database_url)
    try:
        user_id = await conn.fetchval("SELECT user_id FROM agent_intents WHERE id = $1", uuid.UUID(intent["id"]))
        counts = await conn.fetchrow(
            """SELECT (SELECT count(*) FROM agent_intents WHERE user_id = $1) AS intents,
                      (SELECT count(*) FROM orders WHERE user_id = $1) AS orders,
                      (SELECT count(*) FROM spend_entries WHERE user_id = $1) AS spend,
                      (SELECT sum(amount_cents) FROM spend_entries WHERE user_id = $1) AS total""", user_id)
        order = await conn.fetchrow("SELECT * FROM orders WHERE id = $1", uuid.UUID(intent["order_id"]))
    finally:
        await conn.close()
    assert (counts["intents"], counts["orders"], counts["spend"], counts["total"]) == (2, 2, 2, 899 * 2)
    assert order["payment_provider"] == "simulated" and order["payment_brand"] == "visa"
    assert order["payment_last4"] == "4242" and order["payment_ref"].startswith("sim_ch_")
    assert order["channel"] == "agent"


async def test_propose_checkout_retry_after_post_charge_rollback_does_not_double_charge(client, app):
    """Charge keys for propose→agora must outlive a rolled-back request transaction.

    The provider is called inside ``db.scoped``'s transaction. If anything fails after a successful charge
    (claim, crash, etc.), the intent INSERT rolls back. Binding the provider key to the DB intent ID would
    mint a new key on retry and double-charge; binding it to the client Idempotency-Key does not.
    """
    from unittest.mock import patch

    from app import idempotency

    h = await fresh(client)
    await flag_demo(app, client, h)
    await mandate(client, h)

    seen_keys: list[str] = []
    real_charge = app.state.demo_payments.charge

    async def tracking_charge(request):
        seen_keys.append(request.idempotency_key)
        return await real_charge(request)

    app.state.demo_payments.charge = tracking_charge
    real_claim = idempotency.claim
    calls = {"n": 0}

    async def boom_once_claim(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("simulated failure after provider charge, before commit")
        return await real_claim(*args, **kwargs)

    key = idem()
    try:
        with patch.object(idempotency, "claim", boom_once_claim):
            first = await propose(client, h, "Butter", key=key, execution="agora")
        assert first.status_code == 500
        retry = await propose(client, h, "Butter", key=key, execution="agora")
    finally:
        app.state.demo_payments.charge = real_charge

    assert retry.status_code == 201, retry.text
    body = retry.json()
    assert body["status"] == "succeeded" and body["order_id"]
    assert len(seen_keys) == 2 and len(set(seen_keys)) == 1
    assert seen_keys[0].startswith("agora-propose-")
    intents = (await client.get("/v1/agent/intents", headers=h)).json()
    assert len(intents) == 1 and intents[0]["id"] == body["id"]

    # An identical request while one is still pending is refused outright.
    await client.patch("/v1/me/settings", headers=h, json={"autonomy_level": "buy_with_approval"})
    assert (await propose(client, h, "Jam")).json()["decision"] == "needs_approval"
    dup = (await propose(client, h, "jam!")).json()
    assert dup["decision"] == "deny" and dup["reason_codes"] == ["duplicate_pending"]


async def test_velocity_limit(client):
    h = await fresh(client)
    await mandate(client, h)
    for title in ("Apples", "Pears", "Plums"):
        assert (await propose(client, h, title, category="produce")).json()["decision"] == "allow"
    fourth = (await propose(client, h, "Grapes", category="produce")).json()
    assert fourth["decision"] == "deny" and fourth["reason_codes"] == ["velocity_limit"]


async def test_budgets_feed_the_policy(client):
    h = await fresh(client)
    await mandate(client, h)
    created = await client.post("/v1/budgets", headers=h, json={"period": "month", "category": "Dairy",
                                                                "limit_cents": 1500})
    assert created.status_code == 201, created.text
    budget = created.json()
    assert (budget["category"], budget["spent_cents"], budget["remaining_cents"]) == ("dairy", 0, 1500)
    dup = await client.post("/v1/budgets", headers=h, json={"period": "month", "category": "dairy",
                                                            "limit_cents": 100})
    assert dup.status_code == 409 and dup.json()["title"] == "budget_exists"
    overall = (await client.post("/v1/budgets", headers=h, json={"period": "week", "limit_cents": 100000})).json()

    first = (await propose(client, h, "Milk")).json()
    assert first["decision"] == "allow" and "within_budget" in first["reason_codes"]
    budgets = {b["id"]: b for b in (await client.get("/v1/budgets", headers=h)).json()}
    assert budgets[budget["id"]]["pending_cents"] == 899 and budgets[budget["id"]]["remaining_cents"] == 601
    await outcome(client, h, first["id"], "succeeded")
    budgets = {b["id"]: b for b in (await client.get("/v1/budgets", headers=h)).json()}
    assert (budgets[budget["id"]]["spent_cents"], budgets[budget["id"]]["pending_cents"]) == (899, 0)
    assert budgets[overall["id"]]["spent_cents"] == 899

    second = (await propose(client, h, "Cheddar", amount_cents=700)).json()
    assert second["decision"] == "needs_approval"
    assert second["decision_reasons"][0] == "This would take your monthly dairy budget to $15.99 of $15.00."

    raised = await client.patch(f"/v1/budgets/{budget['id']}", headers=h, json={"limit_cents": 3000})
    assert raised.status_code == 200 and raised.json()["remaining_cents"] == 2101
    third = (await propose(client, h, "Gouda", amount_cents=700)).json()
    assert third["decision"] == "allow"

    archived = (await client.patch(f"/v1/budgets/{budget['id']}", headers=h, json={"status": "archived"})).json()
    assert archived["status"] == "archived"
    assert budget["id"] not in {b["id"] for b in (await client.get("/v1/budgets", headers=h)).json()}
    spend = (await client.get("/v1/spend", headers=h, params={"period": "week", "group": "none"})).json()
    assert spend["total_cents"] == 899 and spend["groups"][0]["label"] == "All spending"
    assert [b["id"] for b in spend["budgets"]] == [overall["id"]]

    actions = {e["action"] for e in await trail(client, h)}
    assert {"budget.created", "budget.updated"} <= actions


async def test_mandate_validation_and_revoke(client):
    h = await fresh(client)
    bad = [{"max_per_txn_cents": 0}, {"max_per_period_cents": 100}, {"expires_in_days": 400},
           {"expires_at": "2030-01-01T00:00:00"}, {"period": "year"}, {"merchant_ids": []}, {"categories": [" "]}]
    for fields in bad:
        response = await client.post("/v1/agent/mandates", headers=h, json={
            "label": "x", "max_per_txn_cents": 500, **fields})
        assert response.status_code == 422, (fields, response.text)
    far = await client.post("/v1/agent/mandates", headers=h, json={
        "label": "x", "max_per_txn_cents": 500, "expires_at": "2099-01-01T00:00:00Z"})
    assert far.status_code == 422 and far.json()["title"] == "invalid_expiry"
    unknown = await client.post("/v1/agent/mandates", headers=h, json={
        "label": "x", "max_per_txn_cents": 500, "merchant_ids": [str(uuid.uuid4())]})
    assert unknown.status_code == 404

    store = (await client.post("/v1/merchants", headers=h, json={"name": "Ballard Market", "kind": "grocery"}))
    store = store.json()["merchant"]
    m = await mandate(client, h, merchant_ids=[store["id"]], categories=None, expires_in_days=7)
    allowed = (await propose(client, h, merchant_id=store["id"], merchant_name=None)).json()
    assert allowed["decision"] == "allow" and allowed["merchant_name"] == "Ballard Market"
    elsewhere = (await propose(client, h, "Bread", merchant_name="Safeway")).json()
    assert elsewhere["reason_codes"] == ["outside_mandate"]

    gone = await client.delete(f"/v1/agent/mandates/{m['id']}", headers=h)
    assert gone.status_code == 200 and gone.json()["status"] == "revoked" and gone.json()["revoked_reason"] == "user"
    assert (await client.delete(f"/v1/agent/mandates/{m['id']}", headers=h)).json()["status"] == "revoked"
    assert (await propose(client, h, "Rolls", merchant_id=store["id"])).json()["reason_codes"] == ["no_mandate"]
    assert ("agent.mandate_revoked", "user") in [(e["action"], e["actor_type"]) for e in await trail(client, h)]


async def test_household_isolation(client, database_url):
    a, b = await fresh(client), await fresh(client)
    home_a = await household(client, a)
    m = await mandate(client, a)
    intent = (await propose(client, a, "Truffles", amount_cents=9000)).json()
    budget = (await client.post("/v1/budgets", headers=a, json={"period": "month", "limit_cents": 5000})).json()
    store = (await client.post("/v1/merchants", headers=a, json={"name": "Corner Shop", "kind": "local"}))
    store = store.json()["merchant"]
    await outcome(client, a, (await propose(client, a, "Milk")).json()["id"], "succeeded")

    # Another household sees none of it and can't touch it.
    assert (await client.get(f"/v1/agent/intents/{intent['id']}", headers=b)).status_code == 404
    assert (await client.post(f"/v1/agent/intents/{intent['id']}/approve", headers=b)).status_code == 404
    assert (await client.post(f"/v1/agent/intents/{intent['id']}/reject", headers=b, json={})).status_code == 404
    assert (await outcome(client, b, intent["id"], "succeeded")).status_code == 404
    assert (await client.delete(f"/v1/agent/mandates/{m['id']}", headers=b)).status_code == 404
    assert (await client.patch(f"/v1/budgets/{budget['id']}", headers=b, json={"limit_cents": 1})).status_code == 404
    for path in ("/v1/agent/intents", "/v1/agent/mandates", "/v1/budgets", "/v1/spend"):
        assert (await client.get(path, headers=b, params={"household_id": home_a})).status_code == 404, path
        response = (await client.get(path, headers=b)).json()
        assert response == [] or response.get("total_cents") == 0, path
    sneaky = await propose(client, b, "Truffles", household_id=home_a)
    assert sneaky.status_code == 404
    borrowed = await propose(client, b, "Bread", merchant_id=store["id"])
    assert borrowed.status_code == 404
    assert (await client.post("/v1/agent/mandates", headers=b, json={
        "label": "x", "max_per_txn_cents": 500, "merchant_ids": [store["id"]]})).status_code == 404
    assert (await client.post("/v1/budgets", headers=b, json={
        "household_id": home_a, "period": "month", "limit_cents": 1})).status_code == 404
    # B's kill switch is B's own.
    assert (await client.post("/v1/agent/pause", headers=b)).json()["intents_cancelled"] == 0
    assert (await client.get(f"/v1/agent/intents/{intent['id']}", headers=a)).json()["status"] == "proposed"

    # Same household, different person: they can see the agent's requests but not act on them, and mandates
    # stay personal.
    conn = await asyncpg.connect(database_url)
    try:
        b_id = await conn.fetchval("SELECT user_id FROM household_members WHERE household_id = $1",
                                   uuid.UUID(await household(client, b)))
        await conn.execute("INSERT INTO household_members (household_id, user_id) VALUES ($1, $2)",
                           uuid.UUID(home_a), b_id)
    finally:
        await conn.close()
    shared = (await client.get(f"/v1/agent/intents/{intent['id']}", headers=b)).json()
    assert shared["id"] == intent["id"] and shared["mine"] is False
    blocked = await client.post(f"/v1/agent/intents/{intent['id']}/approve", headers=b)
    assert blocked.status_code == 403 and blocked.json()["title"] == "not_your_intent"
    assert (await client.get("/v1/agent/mandates", headers=b, params={"household_id": home_a})).json() == []
    assert (await client.get("/v1/spend", headers=b, params={"household_id": home_a})).json()["total_cents"] == 899
