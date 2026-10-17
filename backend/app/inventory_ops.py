"""Database operations shared by the API and the worker. Every function takes a connection that is already
scoped to a user (row-level security on), so none of them can reach another household's rows."""

from collections import defaultdict
from datetime import datetime
from uuid import UUID

import asyncpg

ITEM_MATCH_MIN = 0.45
PRODUCT_MATCH_MIN = 0.35


async def match(conn: asyncpg.Connection, household_id: UUID, label: str,
                brand: str | None) -> tuple[UUID | None, UUID | None, float | None]:
    """Find what a detection refers to: the household's own items first, then the global catalog.
    Returns (inventory_item_id, product_id, score)."""
    item = await conn.fetchrow(
        """SELECT id, product_id, similarity(display_name, $2) AS score FROM inventory_items
           WHERE household_id = $1 AND status = 'active' ORDER BY score DESC LIMIT 1""", household_id, label)
    if item and item["score"] >= ITEM_MATCH_MIN:
        return item["id"], item["product_id"], round(float(item["score"]), 3)
    query = f"{brand} {label}" if brand else label
    product = await conn.fetchrow(
        """SELECT id, similarity(coalesce(brand, '') || ' ' || name, $1) AS score FROM products
           ORDER BY score DESC LIMIT 1""", query)
    if product and product["score"] >= PRODUCT_MATCH_MIN:
        return None, product["id"], round(float(product["score"]), 3)
    return None, None, None


async def create_item(conn: asyncpg.Connection, household_id: UUID, user_id: UUID | None, display_name: str, *,
                      product_id: UUID | None = None, category: str | None = None, location_id: UUID | None = None,
                      unit: str = "unit", par_level: float | None = None, tracking: str = "scan") -> UUID:
    return await conn.fetchval(
        """INSERT INTO inventory_items (household_id, product_id, display_name, category, location_id, unit,
                                        par_level, tracking, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id""",
        household_id, product_id, display_name[:120], category, location_id, unit, par_level, tracking, user_id)


async def record_observation(conn: asyncpg.Connection, household_id: UUID, item_id: UUID, time: datetime,
                             quantity: float, source: str, *, scan_id: UUID | None = None,
                             confidence: float | None = None, user_id: UUID | None = None) -> None:
    await conn.execute(
        """INSERT INTO inventory_observations (time, household_id, inventory_item_id, quantity, source, scan_id,
                                               confidence, recorded_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (inventory_item_id, time, source)
           DO UPDATE SET quantity = EXCLUDED.quantity, scan_id = EXCLUDED.scan_id, confidence = EXCLUDED.confidence""",
        time, household_id, item_id, quantity, source, scan_id, confidence, user_id)


async def commit_scan(conn: asyncpg.Connection, scan: asyncpg.Record, user_id: UUID | None) -> int:
    """Write observations for every accepted/corrected detection, creating items for new products.
    Returns the number of items updated."""
    detections = await conn.fetch(
        "SELECT * FROM scan_detections WHERE scan_id = $1 AND review IN ('accepted', 'corrected')", scan["id"])
    totals: dict[UUID, float] = defaultdict(float)
    confidence: dict[UUID, float] = {}
    for d in detections:
        item_id = d["inventory_item_id"]
        if item_id is None:
            item_id = await create_item(conn, scan["household_id"], user_id, d["label"], product_id=d["product_id"],
                                        category=d["category"], location_id=scan["location_id"])
            await conn.execute("UPDATE scan_detections SET inventory_item_id = $2 WHERE id = $1", d["id"], item_id)
        totals[item_id] += float(d["quantity"])  # two labels resolving to one item add up
        confidence[item_id] = max(confidence.get(item_id, 0.0), float(d["confidence"]))
    for item_id, qty in totals.items():
        await record_observation(conn, scan["household_id"], item_id, scan["captured_at"], qty, "scan",
                                 scan_id=scan["id"], confidence=confidence[item_id], user_id=user_id)
    return len(totals)
