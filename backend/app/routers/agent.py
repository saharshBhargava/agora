"""Agent commerce: intents, mandates and the kill switch.

The on-device agent registers what it wants to do as an intent and gets a decision back from the policy engine
(app/core/policy.py). It acts only on ``approved`` intents: either the user approved it, or the policy allowed
it within a mandate. The agent calls with the user's own token, so the intent endpoints are what mark actions as
``actor_type='agent'`` in the audit trail; approvals, mandates and the kill switch are the user's.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from app import idempotency
from app.auth import CurrentUser, Principal
from app.commerce import agent_settings, policy_inputs, record_order
from app.core.policy import COMMITTED, ProposedIntent, decide, period_start, zone
from app.core.wishlist import category_key, title_key
from app.db import audit, notify
from app.demo_account import is_demo_user
from app.errors import Problem, not_found
from app.payments import (
    SIMULATED_DEFAULT_METHOD,
    ChargeRequest,
    PaymentOutcomeUnknown,
    intent_charge_key,
    propose_charge_key,
)
from app.routers.account import require_household
from app.schemas import (
    AgentState,
    IntentIn,
    IntentOut,
    IntentOutcomeIn,
    IntentRejectIn,
    IntentStatus,
    MandateIn,
    MandateOut,
    PauseOut,
)

router = APIRouter(prefix="/v1/agent", tags=["agent"])

APPROVAL_TTL = timedelta(hours=24)
MAX_MANDATE_DAYS = 365
DEFAULT_MANDATE_DAYS = 30
TERMINAL = ("rejected", "cancelled", "succeeded", "failed")
# Outcomes the device may report, from each status. outcome_unknown can be resolved once someone checks.
DEVICE_TRANSITIONS = {
    "approved": {"executing", "succeeded", "failed", "outcome_unknown"},
    "executing": {"succeeded", "failed", "outcome_unknown"},
    "outcome_unknown": {"succeeded", "failed"},
}

_SELECT = """
SELECT i.*, o.id AS order_id FROM agent_intents i LEFT JOIN orders o ON o.agent_intent_id = i.id
"""


# ---------------------------------------------------------------- helpers

def _intent(row: asyncpg.Record, user_id: UUID) -> IntentOut:
    fields = {k: row[k] for k in IntentOut.model_fields if k in row.keys()}
    expires = row["created_at"] + APPROVAL_TTL if row["status"] == "proposed" else None
    return IntentOut(**fields, mine=row["user_id"] == user_id, approval_expires_at=expires)


async def _load(conn: asyncpg.Connection, intent_id: UUID, user_id: UUID) -> IntentOut:
    row = await conn.fetchrow(_SELECT + "WHERE i.id = $1", intent_id)
    if row is None:
        raise not_found("intent")
    return _intent(row, user_id)


async def _locked(conn: asyncpg.Connection, intent_id: UUID, user_id: UUID) -> asyncpg.Record:
    # Household members can see each other's intents but only the owner can lock (RLS applies UPDATE policies
    # to FOR UPDATE), so check ownership first to say why.
    owner = await conn.fetchval("SELECT user_id FROM agent_intents WHERE id = $1", intent_id)
    if owner is None:
        raise not_found("intent")
    if owner != user_id:
        raise Problem(403, "not_your_intent", "Only the person whose agent made this request can act on it.")
    return await conn.fetchrow("SELECT * FROM agent_intents WHERE id = $1 FOR UPDATE", intent_id)


async def _lock_household(conn: asyncpg.Connection, household_id: UUID) -> None:
    """Serialize decisions per household so concurrent requests can't both slip under a cap or velocity limit."""
    await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", f"agent:{household_id}")


async def _set_status(conn: asyncpg.Connection, intent_id: UUID, status: str, **fields) -> asyncpg.Record:
    fields = {"status": status, **fields}
    columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(fields, start=2))  # names are fixed
    terminal = ", completed_at = now()" if status in (*TERMINAL, "outcome_unknown") else ""
    return await conn.fetchrow(
        f"UPDATE agent_intents SET {columns}, updated_at = now(){terminal} WHERE id = $1 RETURNING *",
        intent_id, *fields.values())


async def _execute_checkout(request: Request, conn: asyncpg.Connection, intent: asyncpg.Record, actor_type: str,
                            user_id: UUID, *, provider_idempotency_key: str | None = None) -> asyncpg.Record:
    """Agora-native checkout through the configured PaymentProvider.

    The provider idempotency key must be stable across retries of the *same client attempt*. For propose→allow
    it is derived from the client Idempotency-Key (the intent row may roll back after a successful charge); for
    approve it defaults to the intent ID (the row already exists). Demo checkout uses the app-scoped simulator
    so those keys actually dedupe across requests; it never calls a real provider.
    """
    provider = request.app.state.payments
    if await is_demo_user(conn, user_id):
        provider = request.app.state.demo_payments
    elif provider.name == "simulated":
        raise Problem(503, "payments_unavailable", "Checkout is not available yet. No payment was taken.")
    intent = await _set_status(conn, intent["id"], "executing")
    charge = ChargeRequest(
        idempotency_key=provider_idempotency_key or intent_charge_key(intent["id"]),
        amount_cents=intent["amount_cents"], currency=intent["currency"], description=intent["title"],
        payment_method_ref=intent["payload"].get("payment_method_ref") or SIMULATED_DEFAULT_METHOD)
    meta: dict = {"provider": provider.name}
    try:
        result = await provider.charge(charge)
    except PaymentOutcomeUnknown:
        intent = await _set_status(conn, intent["id"], "outcome_unknown", error_code="provider_timeout")
    else:
        if result.status == "succeeded":
            order_id, _ = await record_order(conn, intent, intent["amount_cents"], provider=provider.name,
                                             payment_ref=result.provider_ref, brand=result.brand, last4=result.last4)
            intent = await _set_status(conn, intent["id"], "succeeded", final_amount_cents=intent["amount_cents"])
            await audit(conn, "order.placed", actor_type=actor_type, actor_id=user_id,
                        household_id=intent["household_id"], target_type="order", target_id=order_id,
                        meta={"intent_id": str(intent["id"]), "provider": provider.name})
            await notify(conn, intent["household_id"], "spend.updated", order_id)
            meta["order_id"] = str(order_id)
        else:
            intent = await _set_status(conn, intent["id"], "failed", error_code=result.decline_code or "declined")
    await audit(conn, f"agent.intent_{intent['status']}", actor_type=actor_type, actor_id=user_id,
                household_id=intent["household_id"], target_type="agent_intent", target_id=intent["id"],
                meta={**meta, "error_code": intent["error_code"]} if intent["error_code"] else meta)
    return intent


# ---------------------------------------------------------------- state and kill switch

@router.get("/state", response_model=AgentState)
async def get_state(request: Request, user: Principal = CurrentUser) -> AgentState:
    """Autonomy level, whether the agent is paused, and what is waiting on the user."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(
            """SELECT s.autonomy_level, s.agent_paused_at,
                      (SELECT count(*) FROM agent_mandates m
                       WHERE m.user_id = s.user_id AND m.status = 'active' AND m.expires_at > now()) AS mandates,
                      (SELECT count(*) FROM agent_intents i
                       WHERE i.user_id = s.user_id AND i.status = 'proposed' AND i.created_at > $2) AS pending
               FROM user_settings s WHERE s.user_id = $1""", user.user_id, datetime.now(UTC) - APPROVAL_TTL)
    return AgentState(autonomy_level=row["autonomy_level"], paused=row["agent_paused_at"] is not None,
                      paused_at=row["agent_paused_at"], active_mandates=row["mandates"],
                      pending_approvals=row["pending"])


@router.post("/pause", response_model=PauseOut)
async def pause(request: Request, user: Principal = CurrentUser) -> PauseOut:
    """Kill switch. In one transaction: pause the agent, revoke every mandate and cancel every intent that hasn't
    started. Anything already executing on a device can't be recalled; it's counted in ``in_flight``."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        paused_at = await conn.fetchval(
            """UPDATE user_settings SET agent_paused_at = coalesce(agent_paused_at, now()), updated_at = now()
               WHERE user_id = $1 RETURNING agent_paused_at""", user.user_id)
        revoked = await conn.fetch(
            """UPDATE agent_mandates SET status = 'revoked', revoked_at = now(), revoked_reason = 'kill_switch'
               WHERE user_id = $1 AND status = 'active' RETURNING id, household_id""", user.user_id)
        cancelled = await conn.fetch(
            """UPDATE agent_intents SET status = 'cancelled', decided_by = 'kill_switch', decided_at = now(),
                      updated_at = now(), completed_at = now()
               WHERE user_id = $1 AND status IN ('proposed', 'approved') RETURNING id, household_id""", user.user_id)
        in_flight = await conn.fetchval(
            "SELECT count(*) FROM agent_intents WHERE user_id = $1 AND status = 'executing'", user.user_id)
        household_id = await require_household(conn, None, user.user_id)
        await audit(conn, "agent.paused", actor_id=user.user_id, household_id=household_id, target_type="user",
                    target_id=user.user_id, meta={"mandates_revoked": len(revoked), "intents_cancelled": len(cancelled),
                                                  "in_flight": in_flight})
        await notify(conn, household_id, "agent.updated", user.user_id)
        for row in [*revoked, *cancelled]:
            await notify(conn, row["household_id"], "agent.updated", row["id"])
    return PauseOut(paused=True, paused_at=paused_at, mandates_revoked=len(revoked), intents_cancelled=len(cancelled),
                    in_flight=in_flight)


@router.post("/resume", response_model=PauseOut)
async def resume(request: Request, user: Principal = CurrentUser) -> PauseOut:
    """Lift the pause. Revoked mandates stay revoked: the user grants new ones deliberately."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        was_paused = await conn.fetchval(
            """UPDATE user_settings SET agent_paused_at = NULL, updated_at = now()
               WHERE user_id = $1 AND agent_paused_at IS NOT NULL RETURNING true""", user.user_id)
        if was_paused:
            household_id = await require_household(conn, None, user.user_id)
            await audit(conn, "agent.resumed", actor_id=user.user_id, household_id=household_id, target_type="user",
                        target_id=user.user_id)
            await notify(conn, household_id, "agent.updated", user.user_id)
    return PauseOut(paused=False, paused_at=None, mandates_revoked=0, intents_cancelled=0, in_flight=0)


# ---------------------------------------------------------------- intents

@router.post("/intents", response_model=IntentOut, status_code=201)
async def propose_intent(body: IntentIn, request: Request, user: Principal = CurrentUser) -> JSONResponse:
    """The agent asks to do something and gets the policy decision back. Requires an ``Idempotency-Key``: a
    retry with the same key returns the same intent (its current state) and never decides or charges again.

    ``decision: allow`` comes back as status ``approved`` (or, for Agora checkout, already ``succeeded``);
    ``needs_approval`` waits as ``proposed``; ``deny`` is recorded as ``rejected``.
    """
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("agent.intent", body.model_dump(mode="json"))
    now = datetime.now(UTC)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        await _lock_household(conn, household_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            current = (await _load(conn, UUID(previous["id"]), user.user_id)).model_dump(mode="json")
            return JSONResponse(current, status_code=201, headers={"Idempotent-Replay": "true"})

        merchant_name = body.merchant_name
        if body.merchant_id is not None:
            merchant = await conn.fetchval("SELECT name FROM merchants WHERE id = $1", body.merchant_id)
            if merchant is None:
                raise not_found("merchant")
            merchant_name = merchant_name or merchant
        category = body.category
        if body.product_id is not None:
            product_category = await conn.fetchval("SELECT category FROM products WHERE id = $1", body.product_id)
            if product_category is None:
                raise not_found("product")
            category = category or product_category
        category = category_key(category)
        item_key = f"product:{body.product_id}" if body.product_id else title_key(body.title)

        settings = await agent_settings(conn, user.user_id, lock=True)
        mandates, budgets, recent = await policy_inputs(conn, user.user_id, household_id, settings, now)
        verdict = decide(ProposedIntent(kind=body.kind, title=body.title.strip(), item_key=item_key,
                                        amount_cents=body.amount_cents,
                                        merchant_id=str(body.merchant_id) if body.merchant_id else None,
                                        merchant_name=merchant_name, category=category),
                         settings, mandates, budgets, recent, now)
        status = {"allow": "approved", "needs_approval": "proposed", "deny": "rejected"}[verdict.decision]
        payload = {"quantity": body.quantity, "product_id": str(body.product_id) if body.product_id else None,
                   "url": body.url, "payment_method_ref": body.payment_method_ref, "details": body.details}
        row = await conn.fetchrow(
            """INSERT INTO agent_intents (user_id, household_id, kind, execution, title, item_key, payload,
                                          amount_cents, currency, merchant_id, merchant_name, category, rationale,
                                          evidence, decision, decision_reasons, reason_codes, mandate_id, status,
                                          decided_by, decided_at, completed_at, idempotency_key)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19::text,
                       CASE WHEN $19 = 'proposed' THEN NULL ELSE 'policy' END,
                       CASE WHEN $19 = 'proposed' THEN NULL ELSE now() END,
                       CASE WHEN $19 = 'rejected' THEN now() END, $20)
               RETURNING *""",
            user.user_id, household_id, body.kind, body.execution, body.title.strip(), item_key,
            {k: v for k, v in payload.items() if v not in (None, {})}, body.amount_cents, body.currency,
            body.merchant_id, merchant_name, category, body.rationale.strip(), [e.model_dump() for e in body.evidence],
            verdict.decision, verdict.messages, verdict.codes,
            UUID(verdict.mandate_id) if verdict.mandate_id else None, status, key)
        await audit(conn, "agent.intent_proposed", actor_type="agent", actor_id=user.user_id,
                    household_id=household_id, target_type="agent_intent", target_id=row["id"],
                    meta={"kind": body.kind, "execution": body.execution, "decision": verdict.decision,
                          "reasons": verdict.codes, "evidence": len(body.evidence),
                          "mandate_id": verdict.mandate_id})
        if verdict.decision == "allow" and body.execution == "agora":
            await _execute_checkout(request, conn, row, "agent", user.user_id,
                                    provider_idempotency_key=propose_charge_key(user.user_id, key))
        await notify(conn, household_id, "agent.updated", row["id"])
        result = (await _load(conn, row["id"], user.user_id)).model_dump(mode="json")
        if not await idempotency.claim(conn, user.user_id, key, digest, 201, {"id": result["id"]}):
            raise Problem(409, "duplicate_request", "This request is already being processed; retry shortly.")
    return JSONResponse(result, status_code=201)


@router.get("/intents", response_model=list[IntentOut])
async def list_intents(request: Request, household_id: UUID | None = None,
                       status: list[IntentStatus] | None = Query(default=None),
                       limit: int = Query(default=50, ge=1, le=200),
                       user: Principal = CurrentUser) -> list[IntentOut]:
    """The household's agent activity, newest first. Filter with repeated ``status`` (e.g. ``status=proposed``
    for the approval inbox)."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(
            _SELECT + """WHERE i.household_id = $1 AND ($2::text[] IS NULL OR i.status = ANY($2))
                         ORDER BY i.created_at DESC, i.id LIMIT $3""",
            household_id, sorted(set(status)) if status else None, limit)
    return [_intent(r, user.user_id) for r in rows]


@router.get("/intents/{intent_id}", response_model=IntentOut)
async def get_intent(intent_id: UUID, request: Request, user: Principal = CurrentUser) -> IntentOut:
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await _load(conn, intent_id, user.user_id)


@router.post("/intents/{intent_id}/approve", response_model=IntentOut)
async def approve_intent(intent_id: UUID, request: Request, user: Principal = CurrentUser) -> IntentOut:
    """The user says yes to an escalated intent. Agora checkouts are charged right away; device intents become
    ``approved`` and the on-device agent may go ahead. Repeating an approval is a no-op."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, intent_id, user.user_id)
        if row["status"] in ("approved", "executing", "succeeded", "failed", "outcome_unknown"):
            return await _load(conn, intent_id, user.user_id)  # already approved, by the user or by policy
        if row["status"] != "proposed":
            raise Problem(409, "invalid_transition", f"Can't approve a request that is {row['status']}.")
        if datetime.now(UTC) - row["created_at"] > APPROVAL_TTL:
            raise Problem(409, "approval_expired", "This request is more than a day old. Ask the agent again.")
        row = await _set_status(conn, intent_id, "approved", decided_by="user", decided_at=datetime.now(UTC))
        await audit(conn, "agent.intent_approved", actor_id=user.user_id, household_id=row["household_id"],
                    target_type="agent_intent", target_id=intent_id, meta={"kind": row["kind"]})
        if row["execution"] == "agora":
            await _execute_checkout(request, conn, row, "user", user.user_id)
        await notify(conn, row["household_id"], "agent.updated", intent_id)
        return await _load(conn, intent_id, user.user_id)


@router.post("/intents/{intent_id}/reject", response_model=IntentOut)
async def reject_intent(intent_id: UUID, body: IntentRejectIn, request: Request,
                        user: Principal = CurrentUser) -> IntentOut:
    """The user says no, before anything started. Also withdraws an approval the device hasn't acted on yet."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, intent_id, user.user_id)
        if row["status"] == "rejected" and row["decided_by"] == "user":
            return await _load(conn, intent_id, user.user_id)
        if row["status"] not in ("proposed", "approved"):
            raise Problem(409, "invalid_transition", f"Can't reject a request that is {row['status']}.")
        await _set_status(conn, intent_id, "rejected", decided_by="user", decided_at=datetime.now(UTC),
                          reject_reason=body.reason_code)
        await audit(conn, "agent.intent_rejected", actor_id=user.user_id, household_id=row["household_id"],
                    target_type="agent_intent", target_id=intent_id,
                    meta={"kind": row["kind"], "reason_code": body.reason_code, "was": row["status"]})
        await notify(conn, row["household_id"], "agent.updated", intent_id)
        return await _load(conn, intent_id, user.user_id)


@router.post("/intents/{intent_id}/outcome", response_model=IntentOut)
async def report_outcome(intent_id: UUID, body: IntentOutcomeIn, request: Request,
                         user: Principal = CurrentUser) -> IntentOut:
    """The on-device agent reports progress on an approved intent: ``executing`` right before it acts, then
    ``succeeded``, ``failed`` or ``outcome_unknown``. A succeeded purchase records an order and its spend.
    Reporting the same status again is a no-op, so retries are safe."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, intent_id, user.user_id)
        if row["execution"] != "device":
            raise Problem(409, "server_executed", "Agora checkout reports its own outcome.")
        if row["status"] == body.status:
            return await _load(conn, intent_id, user.user_id)
        if body.status not in DEVICE_TRANSITIONS.get(row["status"], set()):
            hint = " It needs approval first." if row["status"] == "proposed" else ""
            raise Problem(409, "invalid_transition",
                          f"Can't move a request from {row['status']} to {body.status}.{hint}")
        fields: dict = {"error_code": body.error_code} if body.error_code else {}
        meta: dict = {"kind": row["kind"], "from": row["status"]}
        if body.status == "succeeded" and row["kind"] == "purchase":
            final = body.final_amount_cents if body.final_amount_cents is not None else row["amount_cents"]
            fields["final_amount_cents"] = final
            order_id, _ = await record_order(conn, row, final, provider="merchant_site")
            meta["order_id"] = str(order_id)
            if final > row["amount_cents"]:
                meta["over_authorization"] = True  # the user approved less than was charged: surface it
            await audit(conn, "order.placed", actor_type="agent", actor_id=user.user_id,
                        household_id=row["household_id"], target_type="order", target_id=order_id,
                        meta={"intent_id": str(intent_id), "provider": "merchant_site"})
            await notify(conn, row["household_id"], "spend.updated", order_id)
        await _set_status(conn, intent_id, body.status, **fields)
        await audit(conn, f"agent.intent_{body.status}", actor_type="agent", actor_id=user.user_id,
                    household_id=row["household_id"], target_type="agent_intent", target_id=intent_id,
                    meta={**meta, "error_code": body.error_code} if body.error_code else meta)
        await notify(conn, row["household_id"], "agent.updated", intent_id)
        return await _load(conn, intent_id, user.user_id)


# ---------------------------------------------------------------- mandates

async def _mandates(conn: asyncpg.Connection, user_id: UUID, household_id: UUID, now: datetime,
                    mandate_id: UUID | None = None, include_inactive: bool = True) -> list[MandateOut]:
    tz = zone((await agent_settings(conn, user_id)).timezone)
    rows = await conn.fetch(
        """SELECT * FROM agent_mandates WHERE user_id = $1 AND household_id = $2 AND ($3::uuid IS NULL OR id = $3)
             AND ($4 OR (status = 'active' AND expires_at > $5))
           ORDER BY status, created_at DESC""", user_id, household_id, mandate_id, include_inactive, now)
    out = []
    for r in rows:
        start = period_start(now, r["period"], tz)
        spent = await conn.fetchval(
            """SELECT coalesce(sum(coalesce(final_amount_cents, amount_cents)), 0) FROM agent_intents
               WHERE mandate_id = $1 AND status = ANY($2) AND created_at >= $3""", r["id"], sorted(COMMITTED), start)
        status = r["status"] if r["status"] == "revoked" or r["expires_at"] > now else "expired"
        out.append(MandateOut(**{k: r[k] for k in MandateOut.model_fields if k in r.keys()} | {
            "status": status, "period_started_at": start, "spent_this_period_cents": spent}))
    return out


@router.get("/mandates", response_model=list[MandateOut])
async def list_mandates(request: Request, household_id: UUID | None = None, include_inactive: bool = False,
                        user: Principal = CurrentUser) -> list[MandateOut]:
    """Your spending mandates in a household with what's been spent under each this period. Only you see them."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        return await _mandates(conn, user.user_id, household_id, datetime.now(UTC),
                               include_inactive=include_inactive)


@router.post("/mandates", response_model=MandateOut, status_code=201)
async def create_mandate(body: MandateIn, request: Request, user: Principal = CurrentUser) -> MandateOut:
    """Grant the agent spending authority. Takes effect when autonomy is ``buy_within_mandate`` and the agent
    isn't paused. Always expires: default 30 days, at most a year."""
    now = datetime.now(UTC)
    expires_at = body.expires_at or now + timedelta(days=body.expires_in_days or DEFAULT_MANDATE_DAYS)
    if not now < expires_at <= now + timedelta(days=MAX_MANDATE_DAYS):
        raise Problem(422, "invalid_expiry", "A mandate must expire within the next year.")
    categories = sorted({key for c in body.categories if (key := category_key(c))}) if body.categories else None
    if body.categories and not categories:
        raise Problem(422, "invalid_request", "Invalid fields: categories")
    merchant_ids = sorted(set(body.merchant_ids)) if body.merchant_ids else None
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        if merchant_ids and await conn.fetchval("SELECT count(*) FROM merchants WHERE id = ANY($1)",
                                                merchant_ids) != len(merchant_ids):
            raise not_found("merchant")
        mandate_id = await conn.fetchval(
            """INSERT INTO agent_mandates (user_id, household_id, label, merchant_ids, categories, max_per_txn_cents,
                                           max_per_period_cents, period, require_confirm_above_cents, expires_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id""",
            user.user_id, household_id, body.label.strip(), merchant_ids, categories, body.max_per_txn_cents,
            body.max_per_period_cents, body.period, body.require_confirm_above_cents, expires_at)
        await audit(conn, "agent.mandate_created", actor_id=user.user_id, household_id=household_id,
                    target_type="agent_mandate", target_id=mandate_id,
                    meta={"period": body.period, "merchants": len(merchant_ids or []),
                          "categories": len(categories or []), "days": (expires_at - now).days})
        await notify(conn, household_id, "agent.updated", mandate_id)
        return (await _mandates(conn, user.user_id, household_id, now, mandate_id))[0]


@router.delete("/mandates/{mandate_id}", response_model=MandateOut)
async def revoke_mandate(mandate_id: UUID, request: Request, user: Principal = CurrentUser) -> MandateOut:
    """Revoke a mandate. It's kept (status ``revoked``) so past decisions still point at it. Repeating is a no-op."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow("SELECT id, household_id, status FROM agent_mandates WHERE id = $1 FOR UPDATE",
                                  mandate_id)
        if row is None:
            raise not_found("mandate")
        if row["status"] == "active":
            await conn.execute("""UPDATE agent_mandates SET status = 'revoked', revoked_at = now(),
                                         revoked_reason = 'user' WHERE id = $1""", mandate_id)
            await audit(conn, "agent.mandate_revoked", actor_id=user.user_id, household_id=row["household_id"],
                        target_type="agent_mandate", target_id=mandate_id, meta={"reason": "user"})
            await notify(conn, row["household_id"], "agent.updated", mandate_id)
        return (await _mandates(conn, user.user_id, row["household_id"], datetime.now(UTC), mandate_id))[0]
