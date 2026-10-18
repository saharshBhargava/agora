"""Household wishlist: things the user wants and things the agent suggests, ranked as one priority queue.

The on-device agent calls with the user's own token. There is no separate agent identity, so the suggestion
endpoint is what marks an item ``source='agent'`` and audits it with ``actor_type='agent'``.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse

from app import idempotency, shopping
from app.auth import CurrentUser, Principal
from app.core.wishlist import (
    FeedbackIndex,
    Outcome,
    ScoreInput,
    Tally,
    agent_context,
    category_key,
    rank_key,
    score,
    title_key,
)
from app.db import audit, notify
from app.errors import Problem, not_found, problem_response
from app.routers.account import require_household
from app.schemas import (
    FeedbackIn,
    FeedbackOut,
    RejectIn,
    SnoozeIn,
    WishlistItem,
    WishlistItemIn,
    WishlistPatch,
    WishlistRefreshIn,
    WishlistRefreshOut,
    WishlistStatus,
    WishlistSuggestionIn,
)
from app.wishlist_ops import _refuse_open_duplicate, _resolve_links, lock_household, propose

router = APIRouter(prefix="/v1/wishlist", tags=["wishlist"])

OPEN = ("suggested", "active", "snoozed")
PENDING = ("suggested", "snoozed")
MAX_SNOOZE = timedelta(days=180)

# A snooze ends by itself: once its time passes the item reads as a suggestion again, with no background job.
_STATUS = "CASE WHEN w.status = 'snoozed' AND w.snoozed_until <= now() THEN 'suggested' ELSE w.status END"

_SELECT = f"""
SELECT w.id, w.household_id, w.title, w.normalized_title, w.notes, w.category, w.quantity, w.target_price_cents,
       w.needed_by, w.product_id, w.inventory_item_id, w.source, {_STATUS} AS status, w.pinned, w.priority,
       w.confidence::float8 AS confidence, w.rationale, w.evidence,
       CASE WHEN w.status = 'snoozed' AND w.snoozed_until > now() THEN w.snoozed_until END AS snoozed_until,
       w.reject_reason, w.reject_comment, w.created_at, w.updated_at, w.decided_at, w.completed_at,
       inv.par_level::float8 AS par_level, o.quantity::float8 AS on_hand,
       (SELECT f.rating FROM wishlist_feedback f WHERE f.wishlist_item_id = w.id AND f.user_id = app_user_id())
         AS my_feedback
FROM wishlist_items w
LEFT JOIN inventory_items inv ON inv.id = w.inventory_item_id
LEFT JOIN LATERAL (SELECT quantity FROM inventory_observations
                   WHERE inventory_item_id = w.inventory_item_id ORDER BY time DESC LIMIT 1) o ON true
"""


# ---------------------------------------------------------------- helpers

async def _outcomes(conn: asyncpg.Connection, household_id: UUID) -> list[Outcome]:
    """Every agent suggestion in the household with its decision and thumbs counts: the learning signal."""
    rows = await conn.fetch(
        f"""SELECT w.id, w.title, w.normalized_title, w.category, {_STATUS} AS status,
                   w.accepted_at IS NOT NULL AS accepted, w.reject_reason, w.reject_comment, w.decided_at,
                   w.target_price_cents,
                   count(f.user_id) FILTER (WHERE f.rating = 'up') AS ups,
                   count(f.user_id) FILTER (WHERE f.rating = 'down') AS downs
            FROM wishlist_items w LEFT JOIN wishlist_feedback f ON f.wishlist_item_id = w.id
            WHERE w.household_id = $1 AND w.source = 'agent' GROUP BY w.id""", household_id)
    return [Outcome(item_id=str(r["id"]), title=r["title"], title_key=r["normalized_title"], category=r["category"],
                    status=r["status"], accepted=r["accepted"], reject_reason=r["reject_reason"],
                    reject_comment=r["reject_comment"], decided_at=r["decided_at"],
                    target_price_cents=r["target_price_cents"], thumbs_up=r["ups"], thumbs_down=r["downs"])
            for r in rows]


def _ranked(rows: list[asyncpg.Record], index: FeedbackIndex, now: datetime) -> list[WishlistItem]:
    items = []
    for r in rows:
        category_fb, title_fb = (index.similar(str(r["id"]), r["category"], r["normalized_title"])
                                 if r["source"] == "agent" else (Tally(), Tally()))
        result = score(ScoreInput(
            source=r["source"], created_at=r["created_at"], pinned=r["pinned"], priority=r["priority"],
            confidence=r["confidence"], needed_by=r["needed_by"], on_hand=r["on_hand"], par_level=r["par_level"],
            category=r["category"], category_feedback=category_fb, title_feedback=title_fb), now)
        fields = {k: r[k] for k in WishlistItem.model_fields if k not in ("score", "priority_reasons")}
        items.append(WishlistItem(**fields, score=result.value, priority_reasons=result.reasons))
    return sorted(items, key=lambda i: rank_key(i.score, i.created_at, str(i.id)))


async def _load(conn: asyncpg.Connection, item_id: UUID) -> WishlistItem:
    row = await conn.fetchrow(_SELECT + "WHERE w.id = $1", item_id)
    if row is None:
        raise not_found("wishlist item")
    index = FeedbackIndex(await _outcomes(conn, row["household_id"]))
    return _ranked([row], index, datetime.now(UTC))[0]


async def _locked(conn: asyncpg.Connection, item_id: UUID) -> asyncpg.Record:
    row = await conn.fetchrow(f"SELECT w.*, {_STATUS} AS effective FROM wishlist_items w WHERE w.id = $1 FOR UPDATE",
                              item_id)
    if row is None:
        raise not_found("wishlist item")
    return row


def _require(row: asyncpg.Record, allowed: tuple[str, ...], action: str, hint: str = "") -> None:
    if row["effective"] not in allowed:
        raise Problem(409, "invalid_transition", f"Can't {action} an item that is {row['effective']}.{hint}")


async def _changed(conn: asyncpg.Connection, row: asyncpg.Record, action: str, user: Principal,
                   meta: dict | None = None) -> WishlistItem:
    await audit(conn, action, actor_id=user.user_id, household_id=row["household_id"], target_type="wishlist_item",
                target_id=row["id"], meta=meta)
    await notify(conn, row["household_id"], "wishlist.updated", row["id"])
    return await _load(conn, row["id"])


# ---------------------------------------------------------------- reads

@router.get("", response_model=list[WishlistItem])
async def list_wishlist(request: Request, household_id: UUID | None = None,
                        status: list[WishlistStatus] = Query(default=["active"]),
                        limit: int = Query(default=100, ge=1, le=200),
                        user: Principal = CurrentUser) -> list[WishlistItem]:
    """The wishlist as a priority queue: highest score first, each with the reasons behind its rank."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(_SELECT + f"WHERE w.household_id = $1 AND {_STATUS} = ANY($2::text[])",
                                household_id, sorted(set(status)))
        index = FeedbackIndex(await _outcomes(conn, household_id))
    return _ranked(rows, index, datetime.now(UTC))[:limit]


@router.get("/suggestions", response_model=list[WishlistItem])
async def list_suggestions(request: Request, household_id: UUID | None = None, include_snoozed: bool = False,
                           user: Principal = CurrentUser) -> list[WishlistItem]:
    """Agent suggestions waiting for a decision, best first. Expired snoozes are back in this list."""
    wanted = list(PENDING) if include_snoozed else ["suggested"]
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(_SELECT + f"WHERE w.household_id = $1 AND {_STATUS} = ANY($2::text[])",
                                household_id, wanted)
        index = FeedbackIndex(await _outcomes(conn, household_id))
    return _ranked(rows, index, datetime.now(UTC))


@router.get("/agent-context")
async def get_agent_context(request: Request, household_id: UUID | None = None,
                            user: Principal = CurrentUser) -> dict:
    """What the household thinks of past suggestions, compact enough to put in the on-device model's prompt."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        outcomes = await _outcomes(conn, household_id)
        open_rows = await conn.fetch(
            f"""SELECT w.title, {_STATUS} AS status FROM wishlist_items w
                WHERE w.household_id = $1 AND w.status = ANY($2) ORDER BY w.created_at""",
            household_id, list(OPEN))
    context = agent_context(outcomes, [(r["title"], r["status"]) for r in open_rows], datetime.now(UTC))
    return {"household_id": str(household_id), **context}


@router.get("/refresh-status", response_model=WishlistRefreshOut)
async def refresh_status(request: Request, household_id: UUID | None = None,
                         user: Principal = CurrentUser) -> dict:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        return await shopping.state(conn, household_id)


@router.post("/refresh", response_model=WishlistRefreshOut)
async def refresh_suggestions(body: WishlistRefreshIn, request: Request,
                              user: Principal = CurrentUser) -> JSONResponse:
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("wishlist.refresh", body.model_dump(mode="json"))
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        await lock_household(conn, household_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return JSONResponse(previous, headers={"Idempotent-Replay": "true"})
        result = jsonable_encoder(await shopping.refresh(conn, household_id, user.user_id))
        await audit(conn, "wishlist.refresh_requested", actor_id=user.user_id, household_id=household_id)
        if not await idempotency.claim(conn, user.user_id, key, digest, 200, result):
            raise Problem(409, "duplicate_request", "This request is already being processed; retry shortly.")
        return JSONResponse(result)


# ---------------------------------------------------------------- the two ways in

@router.post("", response_model=WishlistItem, status_code=201)
async def add_item(body: WishlistItemIn, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    """The user adds something themselves. It goes straight onto the active wishlist."""
    if not body.title.strip():
        raise Problem(422, "invalid_request", "Title cannot be blank.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        request_key, digest, previous = await idempotency.begin_optional_add(
            conn, request, user.user_id, "wishlist.add", body.model_dump(mode="json"))
        if previous is not None:
            return WishlistItem.model_validate(previous)
        await lock_household(conn, household_id)
        category = await _resolve_links(conn, household_id, body.product_id, body.inventory_item_id, body.category)
        key = title_key(body.title)
        await _refuse_open_duplicate(conn, household_id, key)
        item_id = await conn.fetchval(
            """INSERT INTO wishlist_items (household_id, title, normalized_title, notes, category, quantity,
                                           target_price_cents, needed_by, priority, pinned, product_id,
                                           inventory_item_id, source, status, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'user', 'active', $13) RETURNING id""",
            household_id, body.title.strip(), key, body.notes, category, body.quantity, body.target_price_cents,
            body.needed_by, body.priority, body.pinned, body.product_id, body.inventory_item_id, user.user_id)
        await audit(conn, "wishlist.item_added", actor_id=user.user_id, household_id=household_id,
                    target_type="wishlist_item", target_id=item_id, meta={"source": "user"})
        await notify(conn, household_id, "wishlist.updated", item_id)
        result = await _load(conn, item_id)
        await idempotency.finish_optional_add(conn, user.user_id, request_key, digest, result.model_dump(mode="json"))
        return result


@router.post("/suggestions", response_model=WishlistItem, status_code=201)
async def suggest_item(body: WishlistSuggestionIn, request: Request, user: Principal = CurrentUser) -> JSONResponse:
    """The agent proposes an item. It waits as ``suggested`` until the user accepts, rejects or snoozes it.

    Refused with 409 ``recently_rejected`` if the user turned the same thing down in the last 30 days (unless
    it was too expensive and this target price is lower). Requires an ``Idempotency-Key`` header.
    """
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("wishlist.suggest", body.model_dump(mode="json"))
    now = datetime.now(UTC)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        await lock_household(conn, household_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return JSONResponse(previous, status_code=201, headers={"Idempotent-Replay": "true"})
        item_id = await propose(conn, household_id, user.user_id, body, now)
        if item_id is None:
            return problem_response(request, 409, "recently_rejected",
                                    "This was rejected in the last 30 days. Check /v1/wishlist/agent-context "
                                    "before suggesting.")
        result = (await _load(conn, item_id)).model_dump(mode="json")
        if not await idempotency.claim(conn, user.user_id, key, digest, 201, result):
            raise Problem(409, "duplicate_request", "This request is already being processed; retry shortly.")
    return JSONResponse(result, status_code=201)


# ---------------------------------------------------------------- one item

@router.get("/{item_id}", response_model=WishlistItem)
async def get_item(item_id: UUID, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await _load(conn, item_id)


@router.patch("/{item_id}", response_model=WishlistItem)
async def update_item(item_id: UUID, body: WishlistPatch, request: Request,
                      user: Principal = CurrentUser) -> WishlistItem:
    """Edit an open item. ``priority`` (1-5, null clears it) and ``pinned`` always outrank computed signals."""
    changes = body.model_dump(exclude_unset=True)
    if any(changes.get(name, "") is None for name in ("title", "quantity", "pinned")):
        raise Problem(422, "invalid_request", "title, quantity and pinned cannot be null.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, OPEN, "edit")
        if "title" in changes:
            changes["title"] = changes["title"].strip()
            if not changes["title"]:
                raise Problem(422, "invalid_request", "Title cannot be blank.")
            changes["normalized_title"] = title_key(changes["title"])
            await _refuse_open_duplicate(conn, row["household_id"], changes["normalized_title"], exclude_id=item_id)
        if "category" in changes:
            changes["category"] = category_key(changes["category"])
        if not changes:
            return await _load(conn, item_id)
        columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
        await conn.execute(f"UPDATE wishlist_items SET {columns}, updated_at = now() WHERE id = $1",
                           item_id, *changes.values())
        return await _changed(conn, row, "wishlist.item_updated", user,
                              {"fields": sorted(k for k in changes if k != "normalized_title")})


@router.delete("/{item_id}", response_model=WishlistItem)
async def remove_item(item_id: UUID, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    """Take an item off the active wishlist. It's kept (status ``removed``) for history, never hard-deleted."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, ("active",), "remove", " Reject or snooze a suggestion instead." if
                 row["effective"] in PENDING else "")
        await conn.execute("""UPDATE wishlist_items SET status = 'removed', completed_at = now(), updated_at = now()
                              WHERE id = $1""", item_id)
        return await _changed(conn, row, "wishlist.removed", user)


@router.post("/{item_id}/accept", response_model=WishlistItem)
async def accept(item_id: UUID, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    """Yes to an agent suggestion: it joins the active wishlist. Counts as a positive signal."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, PENDING, "accept")
        await conn.execute(
            """UPDATE wishlist_items SET status = 'active', snoozed_until = NULL, accepted_at = now(),
                      decided_at = now(), decided_by = $2, updated_at = now() WHERE id = $1""", item_id, user.user_id)
        return await _changed(conn, row, "wishlist.accepted", user)


@router.post("/{item_id}/reject", response_model=WishlistItem)
async def reject(item_id: UUID, body: RejectIn, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    """No to an agent suggestion, with a reason. A negative signal (except ``already_have``), and it blocks the
    agent from suggesting the same thing for 30 days."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, PENDING, "reject")
        await conn.execute(
            """UPDATE wishlist_items SET status = 'rejected', snoozed_until = NULL, reject_reason = $3,
                      reject_comment = $4, decided_at = now(), decided_by = $2, updated_at = now()
               WHERE id = $1""", item_id, user.user_id, body.reason_code, body.comment)
        return await _changed(conn, row, "wishlist.rejected", user, {"reason_code": body.reason_code})


@router.post("/{item_id}/snooze", response_model=WishlistItem)
async def snooze(item_id: UUID, body: SnoozeIn, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    """Not now. The suggestion comes back on its own after ``until`` (or ``days``). Not a negative signal."""
    now = datetime.now(UTC)
    if body.until is not None and body.until.tzinfo is None:
        raise Problem(422, "invalid_snooze", "until must include a time zone offset.")
    until = body.until or now + timedelta(days=body.days or 0)
    if not now < until <= now + MAX_SNOOZE:
        raise Problem(422, "invalid_snooze", "Snooze until a time in the next 180 days.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, PENDING, "snooze")
        await conn.execute(
            """UPDATE wishlist_items SET status = 'snoozed', snoozed_until = $3, decided_at = now(),
                      decided_by = $2, updated_at = now() WHERE id = $1""", item_id, user.user_id, until)
        return await _changed(conn, row, "wishlist.snoozed", user, {"days": max((until - now).days, 0)})


@router.post("/{item_id}/purchased", response_model=WishlistItem)
async def mark_purchased(item_id: UUID, request: Request, user: Principal = CurrentUser) -> WishlistItem:
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, item_id)
        _require(row, ("active",), "mark purchased")
        await conn.execute("""UPDATE wishlist_items SET status = 'purchased', completed_at = now(), updated_at = now()
                              WHERE id = $1""", item_id)
        return await _changed(conn, row, "wishlist.purchased", user)


# ---------------------------------------------------------------- thumbs feedback

@router.post("/{item_id}/feedback", response_model=FeedbackOut)
async def give_feedback(item_id: UUID, body: FeedbackIn, request: Request,
                        user: Principal = CurrentUser) -> FeedbackOut:
    """Thumbs up or down on an agent suggestion, whatever its status. One per user per item; sending again
    replaces it. Separate from accept/reject: it teaches the agent without moving the item."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        item = await conn.fetchrow("SELECT id, household_id, source FROM wishlist_items WHERE id = $1", item_id)
        if item is None:
            raise not_found("wishlist item")
        if item["source"] != "agent":
            raise Problem(409, "not_a_suggestion", "Thumbs feedback is for agent suggestions.")
        row = await conn.fetchrow(
            """INSERT INTO wishlist_feedback (wishlist_item_id, household_id, user_id, rating, reason_code, comment)
               VALUES ($1, $2, $3, $4, $5, $6)
               ON CONFLICT (wishlist_item_id, user_id) DO UPDATE
                 SET rating = EXCLUDED.rating, reason_code = EXCLUDED.reason_code, comment = EXCLUDED.comment,
                     updated_at = now()
               RETURNING wishlist_item_id, rating, reason_code, comment, updated_at""",
            item_id, item["household_id"], user.user_id, body.rating, body.reason_code, body.comment)
        await audit(conn, "wishlist.feedback", actor_id=user.user_id, household_id=item["household_id"],
                    target_type="wishlist_item", target_id=item_id,
                    meta={"rating": body.rating, "reason_code": body.reason_code})
        await notify(conn, item["household_id"], "wishlist.updated", item_id)
    return FeedbackOut(**dict(row))


@router.delete("/{item_id}/feedback", status_code=204)
async def clear_feedback(item_id: UUID, request: Request, user: Principal = CurrentUser) -> Response:
    """Withdraw your thumbs on an item (e.g. tapping an active thumb again)."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await conn.fetchval("SELECT household_id FROM wishlist_items WHERE id = $1", item_id)
        if household_id is None:
            raise not_found("wishlist item")
        if await conn.fetchval("""DELETE FROM wishlist_feedback WHERE wishlist_item_id = $1 AND user_id = $2
                                  RETURNING true""", item_id, user.user_id):
            await audit(conn, "wishlist.feedback_cleared", actor_id=user.user_id, household_id=household_id,
                        target_type="wishlist_item", target_id=item_id)
            await notify(conn, household_id, "wishlist.updated", item_id)
    return Response(status_code=204)
