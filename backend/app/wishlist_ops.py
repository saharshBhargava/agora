"""Shared suggestion validation and persistence for device requests and scheduled work."""
from datetime import datetime
from uuid import UUID

import asyncpg

from app.core.wishlist import REJECTION_WINDOW, Rejection, blocking_rejection, category_key, title_key
from app.db import audit, notify
from app.errors import Problem, not_found
from app.schemas import WishlistSuggestionIn

OPEN = ("suggested", "active", "snoozed")
PENDING = ("suggested", "snoozed")
MAX_PENDING_SUGGESTIONS = 50


async def lock_household(conn: asyncpg.Connection, household_id: UUID) -> None:
    await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", "wishlist:" + str(household_id))


async def _resolve_links(conn: asyncpg.Connection, household_id: UUID, product_id: UUID | None,
                         inventory_item_id: UUID | None, category: str | None) -> str | None:
    """Check linked records belong to this household and borrow a category from them when none was given."""
    if inventory_item_id is not None:
        linked = await conn.fetchrow("SELECT category FROM inventory_items WHERE id = $1 AND household_id = $2",
                                     inventory_item_id, household_id)
        if linked is None:
            raise not_found("inventory item")
        category = category or linked["category"]
    if product_id is not None:
        product_category = await conn.fetchval("SELECT category FROM products WHERE id = $1", product_id)
        if product_category is None:
            raise not_found("product")
        category = category or product_category
    return category_key(category)


async def _refuse_open_duplicate(conn: asyncpg.Connection, household_id: UUID, key: str,
                                exclude_id: UUID | None = None) -> None:
    await lock_household(conn, household_id)
    if await conn.fetchval(
            """SELECT 1 FROM wishlist_items WHERE household_id = $1 AND normalized_title = $2 AND status = ANY($3)
               AND ($4::uuid IS NULL OR id <> $4)""",
            household_id, key, list(OPEN), exclude_id):
        raise Problem(409, "already_on_wishlist", "That's already on the wishlist or waiting as a suggestion.")


async def propose(conn: asyncpg.Connection, household_id: UUID, user_id: UUID,
                  body: WishlistSuggestionIn, now: datetime) -> UUID | None:
    await lock_household(conn, household_id)
    if not body.title.strip() or not body.rationale.strip():
        raise Problem(422, "invalid_request", "Title and rationale cannot be blank.")
    if await conn.fetchval("SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id = $1", user_id):
        raise Problem(409, "agent_paused", "Resume your agent before adding suggestions.")
    category = await _resolve_links(conn, household_id, body.product_id, body.inventory_item_id, body.category)
    tkey = title_key(body.title)

    rejections = await conn.fetch(
        """SELECT normalized_title, reject_reason, decided_at, target_price_cents FROM wishlist_items
           WHERE household_id = $1 AND normalized_title = $2 AND status = 'rejected' AND decided_at > $3""",
        household_id, tkey, now - REJECTION_WINDOW)
    blocked = blocking_rejection(tkey, body.target_price_cents, [
        Rejection(r["normalized_title"], r["reject_reason"], r["decided_at"], r["target_price_cents"])
        for r in rejections], now)
    if blocked is not None:
        # Recorded (the transaction commits), so the user can see the agent tried and was held back.
        await audit(conn, "wishlist.suggestion_blocked", actor_type="agent", actor_id=user_id,
                    household_id=household_id, meta={"reason": "recently_rejected",
                                                      "reject_reason": blocked.reason_code})
        return None
    await _refuse_open_duplicate(conn, household_id, tkey)
    pending = await conn.fetchval(
        "SELECT count(*) FROM wishlist_items WHERE household_id = $1 AND status = ANY($2)",
        household_id, list(PENDING))
    if pending >= MAX_PENDING_SUGGESTIONS:
        raise Problem(409, "too_many_suggestions", "Too many suggestions are waiting for a decision.")

    item_id = await conn.fetchval(
        """INSERT INTO wishlist_items (household_id, title, normalized_title, category, quantity,
                                       target_price_cents, needed_by, product_id, inventory_item_id, source,
                                       status, confidence, rationale, evidence, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'agent', 'suggested', $10, $11, $12, $13) RETURNING id""",
        household_id, body.title.strip(), tkey, category, body.quantity, body.target_price_cents, body.needed_by,
        body.product_id, body.inventory_item_id, body.confidence, body.rationale.strip(),
        [e.model_dump() for e in body.evidence], user_id)
    await audit(conn, "wishlist.suggested", actor_type="agent", actor_id=user_id, household_id=household_id,
                target_type="wishlist_item", target_id=item_id,
                meta={"confidence": round(body.confidence, 2), "evidence": len(body.evidence)})
    await notify(conn, household_id, "wishlist.updated", item_id)
    return item_id
