"""Database side of agent commerce: loading the policy engine's inputs, budget usage, and recording orders.

Every function takes the caller's scoped connection, so row-level security applies and everything happens in
the caller's transaction.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

import asyncpg

from app.core.policy import UNSETTLED, AgentSettings, Budget, Mandate, PastIntent, period_start, zone

RECENT_WINDOW = timedelta(days=35)  # covers the longest period (a month) plus the duplicate window


@dataclass(frozen=True)
class BudgetUsage:
    row: asyncpg.Record
    period_started_at: datetime
    spent_cents: int  # recorded in spend_entries
    pending_cents: int  # agent purchases approved or in flight, not yet recorded

    @property
    def remaining_cents(self) -> int:
        return self.row["limit_cents"] - self.spent_cents - self.pending_cents


async def agent_settings(conn: asyncpg.Connection, user_id: UUID, lock: bool = False) -> AgentSettings:
    """``lock`` holds the settings row until commit, so a decision and the kill switch can't interleave: a pause
    either lands first (and the decision sees it) or waits and then cancels what the decision created."""
    row = await conn.fetchrow("SELECT autonomy_level, timezone, agent_paused_at FROM user_settings WHERE user_id = $1"
                              + (" FOR UPDATE" if lock else ""), user_id)
    return AgentSettings(autonomy_level=row["autonomy_level"], paused=row["agent_paused_at"] is not None,
                         timezone=row["timezone"])


async def budget_usage(conn: asyncpg.Connection, household_id: UUID, timezone: str, now: datetime,
                       include_archived: bool = False) -> list[BudgetUsage]:
    tz = zone(timezone)
    rows = await conn.fetch(
        """SELECT * FROM budgets WHERE household_id = $1 AND (status = 'active' OR $2)
           ORDER BY status, period, category NULLS FIRST, created_at""", household_id, include_archived)
    usages = []
    for row in rows:
        start = period_start(now, row["period"], tz)
        spent = await conn.fetchval(
            """SELECT coalesce(sum(amount_cents), 0) FROM spend_entries
               WHERE household_id = $1 AND time >= $2 AND ($3::text IS NULL OR category = $3)""",
            household_id, start, row["category"])
        pending = await conn.fetchval(
            """SELECT coalesce(sum(coalesce(final_amount_cents, amount_cents)), 0) FROM agent_intents
               WHERE household_id = $1 AND kind = 'purchase' AND status = ANY($2) AND created_at >= $3
                 AND ($4::text IS NULL OR category = $4)""",
            household_id, sorted(UNSETTLED), start, row["category"])
        usages.append(BudgetUsage(row, start, spent, pending))
    return usages


async def policy_inputs(conn: asyncpg.Connection, user_id: UUID, household_id: UUID, settings: AgentSettings,
                        now: datetime) -> tuple[list[Mandate], list[Budget], list[PastIntent]]:
    mandates = [
        Mandate(id=str(r["id"]), label=r["label"], max_per_txn_cents=r["max_per_txn_cents"],
                expires_at=r["expires_at"], period=r["period"], max_per_period_cents=r["max_per_period_cents"],
                require_confirm_above_cents=r["require_confirm_above_cents"],
                merchant_ids=frozenset(map(str, r["merchant_ids"])) if r["merchant_ids"] is not None else None,
                categories=frozenset(r["categories"]) if r["categories"] is not None else None, status=r["status"])
        for r in await conn.fetch(
            """SELECT * FROM agent_mandates WHERE user_id = $1 AND household_id = $2 AND status = 'active'
               ORDER BY created_at, id""", user_id, household_id)]
    # Recorded spend only; the engine adds unsettled agent purchases from the intents itself.
    budgets = [Budget(id=str(u.row["id"]), period=u.row["period"], limit_cents=u.row["limit_cents"],
                      spent_cents=u.spent_cents, category=u.row["category"])
               for u in await budget_usage(conn, household_id, settings.timezone, now)]
    recent = [
        PastIntent(id=str(r["id"]), kind=r["kind"], status=r["status"], decision=r["decision"],
                   created_at=r["created_at"], item_key=r["item_key"], amount_cents=r["amount"],
                   mandate_id=str(r["mandate_id"]) if r["mandate_id"] else None, category=r["category"],
                   mine=r["user_id"] == user_id)
        for r in await conn.fetch(
            """SELECT id, user_id, kind, status, decision, created_at, item_key, mandate_id, category,
                      coalesce(final_amount_cents, amount_cents) AS amount
               FROM agent_intents WHERE household_id = $1 AND created_at > $2 ORDER BY created_at, id""",
            household_id, now - RECENT_WINDOW)]
    return mandates, budgets, recent


async def record_order(conn: asyncpg.Connection, intent: asyncpg.Record, total_cents: int, *, provider: str,
                       payment_ref: str | None = None, brand: str | None = None,
                       last4: str | None = None) -> tuple[UUID, bool]:
    """Record the order and its spend for a completed purchase intent. Returns (order_id, created).

    ``orders.agent_intent_id`` is unique, so however often this runs for one intent there is one order and one
    spend entry.
    """
    order_id = await conn.fetchval(
        """INSERT INTO orders (household_id, user_id, merchant_id, merchant_name, title, category, channel,
                               total_cents, currency, payment_provider, payment_ref, payment_brand, payment_last4,
                               agent_intent_id)
           VALUES ($1, $2, $3, $4, $5, $6, 'agent', $7, $8, $9, $10, $11, $12, $13)
           ON CONFLICT (agent_intent_id) DO NOTHING RETURNING id""",
        intent["household_id"], intent["user_id"], intent["merchant_id"], intent["merchant_name"], intent["title"],
        intent["category"], total_cents, intent["currency"], provider, payment_ref, brand, last4, intent["id"])
    if order_id is None:
        return await conn.fetchval("SELECT id FROM orders WHERE agent_intent_id = $1", intent["id"]), False
    if total_cents > 0:
        await conn.execute(
            """INSERT INTO spend_entries (time, household_id, user_id, amount_cents, currency, category, merchant_id,
                                          order_id)
               VALUES (now(), $1, $2, $3, $4, $5, $6, $7)""",
            intent["household_id"], intent["user_id"], total_cents, intent["currency"], intent["category"],
            intent["merchant_id"], order_id)
    return order_id, True
