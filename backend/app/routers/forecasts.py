"""Run-out forecasts: what's about to run out, when, and why we think so."""

import re
from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request

from app import forecasting
from app.auth import CurrentUser, Principal
from app.core.forecast import as_of, suggested_quantity
from app.errors import Problem
from app.merchants import MERCHANT_REF, ref
from app.routers.account import require_household
from app.routers.inventory import ITEM_SELECT, item_fields
from app.schemas import ItemOut, Runout, RunoutsOut

router = APIRouter(prefix="/v1/forecasts", tags=["forecasts"])

MAX_WITHIN_DAYS = 90


def parse_within(value: str) -> int:
    match = re.fullmatch(r"(\d{1,3})d", value)
    days = int(match.group(1)) if match else 0
    if not 1 <= days <= MAX_WITHIN_DAYS:
        raise Problem(422, "invalid_within", f"within must look like '7d', between 1d and {MAX_WITHIN_DAYS}d.")
    return days


async def upcoming(conn: asyncpg.Connection, household_id: UUID, user_id: UUID, within: timedelta,
                   now: datetime) -> list[Runout]:
    """Active items whose latest forecast says they run out before ``now + within`` (already-out ones first),
    each with a suggested store: the item's preferred merchant, else wherever it was last bought."""
    ids = [r["id"] for r in await conn.fetch(
        "SELECT id FROM inventory_items WHERE household_id = $1 AND status = 'active'", household_id)]
    stored = await forecasting.latest(conn, ids)
    tz = await forecasting.user_timezone(conn, user_id)
    rows = {r["id"]: r for r in await conn.fetch(ITEM_SELECT + "WHERE i.id = ANY ($1)", list(stored))}
    preferred = {r["m_id"]: r for r in await conn.fetch(
        f"SELECT {MERCHANT_REF} FROM merchants m WHERE m.id = ANY ($1)",
        [r["preferred_merchant_id"] for r in rows.values() if r["preferred_merchant_id"]])}
    on_list = {r["inventory_item_id"]: r["list_id"] for r in await conn.fetch(
        """SELECT DISTINCT ON (li.inventory_item_id) li.inventory_item_id, li.list_id
           FROM shopping_list_items li JOIN shopping_lists l ON l.id = li.list_id
           WHERE li.household_id = $1 AND l.status = 'open' AND NOT li.checked AND li.inventory_item_id IS NOT NULL
           ORDER BY li.inventory_item_id, li.created_at""", household_id)}

    out = []
    for item_id, f in stored.items():
        row = rows.get(item_id)
        if row is None:
            continue
        forecast = forecasting.to_out(f, row["display_name"], row["unit"], now, tz)
        if forecast.runout_at is None or forecast.runout_at > now + within:
            continue
        if row["preferred_merchant_id"] in preferred:
            merchant, basis = ref(preferred[row["preferred_merchant_id"]], "m_"), "preferred"
        else:
            merchant = ref(row, "m_")
            basis = "last_purchase" if merchant else None
        out.append(Runout(item=ItemOut(**item_fields(row)), forecast=forecast,
                          suggested_quantity=suggested_quantity(as_of(forecasting.from_row(f), now),
                                                                row["par_level"]),
                          suggested_merchant=merchant, merchant_basis=basis, on_list_id=on_list.get(item_id)))
    return sorted(out, key=lambda r: (r.forecast.runout_at, r.item.display_name))


@router.get("/runouts", response_model=RunoutsOut)
async def runouts(request: Request, within: str = Query(default="7d", max_length=4,
                                                        description="Horizon such as '3d', '7d' or '14d'"),
                  household_id: UUID | None = None, user: Principal = CurrentUser) -> RunoutsOut:
    """What runs out in the next ``within`` days, soonest first. Items that have probably already run out
    come first. Each carries its forecast, a plain-language explanation and a suggested store."""
    days = parse_within(within)
    now = datetime.now(UTC)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        items = await upcoming(conn, household_id, user.user_id, timedelta(days=days), now)
    return RunoutsOut(household_id=household_id, within_days=days, as_of=now, runouts=items)
