from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request

from app import forecasting
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import Problem, not_found
from app.inventory_ops import create_item, record_observation
from app.merchants import MERCHANT_REF, ref, require_merchant
from app.routers.account import require_household
from app.schemas import DailyPoint, ItemDetail, ItemIn, ItemOut, ItemPatch, Observation, ObservationIn, PurchaseOrigin
from app.timeseries import daily_quantity

router = APIRouter(prefix="/v1/inventory", tags=["inventory"])

ITEM_SELECT = """
SELECT i.id, i.household_id, i.display_name, i.category, i.location_id, i.unit, i.par_level::float8 AS par_level,
       i.status, i.product_id, i.preferred_merchant_id, o.quantity::float8 AS quantity, o.time AS observed_at,
       o.source, pd.purchased_on AS last_purchased_on, {MERCHANT_REF}
FROM inventory_items i
LEFT JOIN LATERAL (SELECT quantity, time, source FROM inventory_observations
                   WHERE inventory_item_id = i.id ORDER BY time DESC LIMIT 1) o ON true
LEFT JOIN LATERAL (SELECT merchant_id FROM inventory_purchase_origins
                   WHERE inventory_item_id = i.id AND merchant_id IS NOT NULL
                   ORDER BY coalesce(purchased_on, observed_at::date) DESC, observed_at DESC LIMIT 1) po ON true
LEFT JOIN LATERAL (SELECT purchased_on FROM inventory_purchase_origins
                   WHERE inventory_item_id = i.id AND purchased_on IS NOT NULL
                   ORDER BY purchased_on DESC, observed_at DESC LIMIT 1) pd ON true
LEFT JOIN merchants m ON m.id = po.merchant_id
""".replace("{MERCHANT_REF}", MERCHANT_REF)

ITEM_FIELDS = [f for f in ItemOut.model_fields if f != "last_purchased_from"]


def item_fields(row: asyncpg.Record) -> dict:
    return {**{k: row[k] for k in ITEM_FIELDS}, "last_purchased_from": ref(row, "m_")}


async def _location_ok(conn: asyncpg.Connection, household_id: UUID, location_id: UUID | None) -> None:
    if location_id is not None and not await conn.fetchval(
            "SELECT 1 FROM storage_locations WHERE id = $1 AND household_id = $2", location_id, household_id):
        raise not_found("location")


@router.get("", response_model=list[ItemOut])
async def list_items(request: Request, household_id: UUID | None = None, location_id: UUID | None = None,
                     include_archived: bool = False, user: Principal = CurrentUser) -> list[ItemOut]:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(
            ITEM_SELECT + """WHERE i.household_id = $1 AND ($2::uuid IS NULL OR i.location_id = $2)
                              AND ($3 OR i.status = 'active') ORDER BY i.category NULLS LAST, i.display_name""",
            household_id, location_id, include_archived)
    return [ItemOut(**item_fields(r)) for r in rows]


@router.post("", response_model=ItemOut, status_code=201)
async def add_item(body: ItemIn, request: Request, user: Principal = CurrentUser) -> ItemOut:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        await _location_ok(conn, household_id, body.location_id)
        if body.preferred_merchant_id:
            await require_merchant(conn, body.preferred_merchant_id, household_id)
        item_id = await create_item(conn, household_id, user.user_id, body.display_name, category=body.category,
                                    location_id=body.location_id, unit=body.unit, par_level=body.par_level,
                                    tracking="manual")
        if body.preferred_merchant_id:
            await conn.execute("UPDATE inventory_items SET preferred_merchant_id = $2 WHERE id = $1", item_id,
                               body.preferred_merchant_id)
        if body.quantity is not None:
            await record_observation(conn, household_id, item_id, datetime.now(UTC), body.quantity, "manual",
                                     user_id=user.user_id)
            await forecasting.request_refresh(conn, household_id, user.user_id, [item_id])
        await audit(conn, "inventory.item_created", actor_id=user.user_id, household_id=household_id,
                    target_type="inventory_item", target_id=item_id, meta={"source": "manual"})
        await notify(conn, household_id, "inventory.updated", item_id)
        row = await conn.fetchrow(ITEM_SELECT + "WHERE i.id = $1", item_id)
    return ItemOut(**item_fields(row))


@router.get("/{item_id}", response_model=ItemDetail)
async def item_detail(item_id: UUID, request: Request, days: int = Query(default=30, ge=1, le=365),
                      user: Principal = CurrentUser) -> ItemDetail:
    db = request.app.state.db
    end = datetime.now(UTC).replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    async with db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(ITEM_SELECT + "WHERE i.id = $1", item_id)
        if row is None:
            raise not_found("inventory item")
        daily = await daily_quantity(conn, item_id, end - timedelta(days=days), end, timescale=db.timescale)
        observations = await conn.fetch(
            """SELECT time, quantity::float8 AS quantity, source, scan_id, confidence FROM inventory_observations
               WHERE inventory_item_id = $1 ORDER BY time DESC LIMIT 50""", item_id)
        stored = (await forecasting.latest(conn, [item_id])).get(item_id)
        tz = await forecasting.user_timezone(conn, user.user_id) if stored else None
        origins = await conn.fetch(
            f"""SELECT po.observed_at, po.purchased_on, po.quantity::float8 AS quantity, po.scan_id,
                       po.scan_detection_id, {MERCHANT_REF}
                FROM inventory_purchase_origins po LEFT JOIN merchants m ON m.id = po.merchant_id
                WHERE po.inventory_item_id = $1
                ORDER BY coalesce(po.purchased_on, po.observed_at::date) DESC, po.observed_at DESC
                LIMIT 50""", item_id)
    return ItemDetail(**item_fields(row), daily=[DailyPoint(day=d, quantity=q) for d, q in daily],
                      observations=[Observation(**dict(o)) for o in observations],
                      purchase_history=[PurchaseOrigin(merchant=ref(o, "m_"), purchased_on=o["purchased_on"],
                                                       observed_at=o["observed_at"],
                                                       quantity=o["quantity"], scan_id=o["scan_id"],
                                                       detection_id=o["scan_detection_id"]) for o in origins],
                      series_engine="timescale" if db.timescale else "postgres",
                      forecast=forecasting.to_out(stored, row["display_name"], row["unit"], datetime.now(UTC), tz)
                      if stored else None)


@router.patch("/{item_id}", response_model=ItemOut)
async def update_item(item_id: UUID, body: ItemPatch, request: Request, user: Principal = CurrentUser) -> ItemOut:
    changes = body.model_dump(exclude_unset=True)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await conn.fetchval("SELECT household_id FROM inventory_items WHERE id = $1", item_id)
        if household_id is None:
            raise not_found("inventory item")
        if "location_id" in changes:
            await _location_ok(conn, household_id, changes["location_id"])
        if changes.get("preferred_merchant_id") is not None:
            await require_merchant(conn, changes["preferred_merchant_id"], household_id)
        if changes.get("display_name", "") is None or changes.get("status", "") is None:
            raise Problem(422, "invalid_request", "display_name and status cannot be null.")
        if changes:
            columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
            await conn.execute(f"UPDATE inventory_items SET {columns} WHERE id = $1", item_id, *changes.values())
            await audit(conn, "inventory.item_updated", actor_id=user.user_id, household_id=household_id,
                        target_type="inventory_item", target_id=item_id, meta={"fields": sorted(changes)})
            await notify(conn, household_id, "inventory.updated", item_id)
        row = await conn.fetchrow(ITEM_SELECT + "WHERE i.id = $1", item_id)
    return ItemOut(**item_fields(row))


@router.post("/{item_id}/observations", response_model=Observation, status_code=201)
async def add_observation(item_id: UUID, body: ObservationIn, request: Request,
                          user: Principal = CurrentUser) -> Observation:
    now = datetime.now(UTC)
    when = body.time or now
    if when > now + timedelta(minutes=5):
        raise Problem(422, "future_observation", "Observations can't be in the future.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await conn.fetchval("SELECT household_id FROM inventory_items WHERE id = $1", item_id)
        if household_id is None:
            raise not_found("inventory item")
        await record_observation(conn, household_id, item_id, when, body.quantity, "manual", user_id=user.user_id)
        await forecasting.request_refresh(conn, household_id, user.user_id, [item_id])
        await audit(conn, "inventory.observation_manual", actor_id=user.user_id, household_id=household_id,
                    target_type="inventory_item", target_id=item_id)
        await notify(conn, household_id, "inventory.updated", item_id)
    return Observation(time=when, quantity=body.quantity, source="manual", scan_id=None, confidence=None)
