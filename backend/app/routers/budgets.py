"""Household budgets and spend. Budgets feed the agent policy engine: the agent can't spend a budget you've used
up without asking. Periods are calendar weeks (Monday) and months in the requesting user's time zone."""

from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request

from app.auth import CurrentUser, Principal
from app.commerce import BudgetUsage, agent_settings, budget_usage
from app.core.policy import period_start, zone
from app.core.wishlist import category_key
from app.db import audit, notify
from app.errors import Problem, not_found
from app.routers.account import require_household
from app.schemas import BudgetIn, BudgetOut, BudgetPatch, SpendGroup, SpendOut

router = APIRouter(prefix="/v1", tags=["spend"])


def _budget(usage: BudgetUsage) -> BudgetOut:
    fields = {k: usage.row[k] for k in BudgetOut.model_fields if k in usage.row.keys()}
    return BudgetOut(**fields, period_started_at=usage.period_started_at, spent_cents=usage.spent_cents,
                     pending_cents=usage.pending_cents, remaining_cents=usage.remaining_cents)


async def _budgets(conn: asyncpg.Connection, user_id: UUID, household_id: UUID,
                   include_archived: bool = False) -> list[BudgetOut]:
    timezone = (await agent_settings(conn, user_id)).timezone
    return [_budget(u) for u in await budget_usage(conn, household_id, timezone, datetime.now(UTC), include_archived)]


async def _one(conn: asyncpg.Connection, user_id: UUID, household_id: UUID, budget_id: UUID) -> BudgetOut:
    return next(b for b in await _budgets(conn, user_id, household_id, True) if b.id == budget_id)


@router.get("/budgets", response_model=list[BudgetOut])
async def list_budgets(request: Request, household_id: UUID | None = None, include_archived: bool = False,
                       user: Principal = CurrentUser) -> list[BudgetOut]:
    """Budgets with this period's recorded spend, agent purchases still pending, and what's left."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        return await _budgets(conn, user.user_id, household_id, include_archived)


@router.post("/budgets", response_model=BudgetOut, status_code=201)
async def create_budget(body: BudgetIn, request: Request, user: Principal = CurrentUser) -> BudgetOut:
    """One active budget per period and category (``category: null`` covers all spending)."""
    category = category_key(body.category)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        try:
            budget_id = await conn.fetchval(
                """INSERT INTO budgets (household_id, period, category, limit_cents, created_by)
                   VALUES ($1, $2, $3, $4, $5) RETURNING id""",
                household_id, body.period, category, body.limit_cents, user.user_id)
        except asyncpg.UniqueViolationError as error:
            raise Problem(409, "budget_exists", "There's already a budget for that period and category. "
                                                "Change its limit instead.") from error
        await audit(conn, "budget.created", actor_id=user.user_id, household_id=household_id, target_type="budget",
                    target_id=budget_id, meta={"period": body.period, "has_category": category is not None})
        await notify(conn, household_id, "budget.updated", budget_id)
        return await _one(conn, user.user_id, household_id, budget_id)


@router.patch("/budgets/{budget_id}", response_model=BudgetOut)
async def update_budget(budget_id: UUID, body: BudgetPatch, request: Request,
                        user: Principal = CurrentUser) -> BudgetOut:
    """Change the limit, or archive (``status: "archived"``) / restore a budget."""
    changes = body.model_dump(exclude_none=True)
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow("SELECT id, household_id FROM budgets WHERE id = $1 FOR UPDATE", budget_id)
        if row is None:
            raise not_found("budget")
        if changes:
            columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
            try:
                await conn.execute(f"UPDATE budgets SET {columns}, updated_at = now() WHERE id = $1",
                                   budget_id, *changes.values())
            except asyncpg.UniqueViolationError as error:
                raise Problem(409, "budget_exists", "Another active budget already covers that period and "
                                                    "category.") from error
            await audit(conn, "budget.updated", actor_id=user.user_id, household_id=row["household_id"],
                        target_type="budget", target_id=budget_id, meta={"fields": sorted(changes)})
            await notify(conn, row["household_id"], "budget.updated", budget_id)
        return await _one(conn, user.user_id, row["household_id"], budget_id)


_GROUPS = {
    "category": ("s.category", "coalesce(s.category, 'uncategorized')"),
    "merchant": ("s.merchant_id::text", "coalesce(m.name, o.merchant_name, 'Unknown merchant')"),
    "none": ("NULL::text", "'All spending'"),
}


@router.get("/spend", response_model=SpendOut)
async def get_spend(request: Request, period: Literal["week", "month"] = "month",
                    group: Literal["category", "merchant", "none"] = "category", household_id: UUID | None = None,
                    user: Principal = CurrentUser) -> SpendOut:
    """This week's or month's recorded spend, grouped, plus every active budget's headroom."""
    now = datetime.now(UTC)
    key, label = _GROUPS[group]
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        tz = zone((await agent_settings(conn, user.user_id)).timezone)
        start = period_start(now, period, tz)
        # The start of the next period: step past this one (at least 7 days) and snap back to its start.
        end = period_start(start + timedelta(days=32 if period == "month" else 7), period, tz)
        rows = await conn.fetch(
            f"""SELECT {key} AS key, min({label}) AS label, sum(s.amount_cents) AS amount, count(*) AS entries
                FROM spend_entries s
                LEFT JOIN merchants m ON m.id = s.merchant_id
                LEFT JOIN orders o ON o.id = s.order_id
                WHERE s.household_id = $1 AND s.time >= $2 AND s.time < $3
                GROUP BY 1 ORDER BY amount DESC, label""", household_id, start, end)
        budgets = await _budgets(conn, user.user_id, household_id)
    groups = [SpendGroup(key=r["key"], label=r["label"], amount_cents=r["amount"], entries=r["entries"])
              for r in rows]
    return SpendOut(household_id=household_id, period=period, group=group, start=start, end=end, currency="USD",
                    total_cents=sum(g.amount_cents for g in groups), groups=groups, budgets=budgets)
