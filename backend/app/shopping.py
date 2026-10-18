"""Six-hour household replenishment suggestions, grounded in observed stock and forecasts."""
from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg

from app import replenishment
from app.core.wishlist import title_key
from app.db import Database, audit, notify
from app.errors import Problem
from app.schemas import Evidence, WishlistSuggestionIn
from app.wishlist_ops import lock_household, propose

INTERVAL = timedelta(hours=6)


def next_refresh(now: datetime) -> datetime:
    utc = now.astimezone(UTC)
    return utc.replace(hour=utc.hour // 6 * 6, minute=0, second=0, microsecond=0) + INTERVAL


async def state(conn: asyncpg.Connection, household_id: UUID) -> dict:
    row = await conn.fetchrow("SELECT * FROM wishlist_refresh_state WHERE household_id = $1", household_id)
    return dict(row) if row else {"household_id": household_id, "last_refreshed_at": None,
                                 "next_refresh_at": next_refresh(datetime.now(UTC)),
                                 "last_error": None, "generated_count": 0}


async def refresh(conn: asyncpg.Connection, household_id: UUID, user_id: UUID,
                  now: datetime | None = None) -> dict:
    now = now or datetime.now(UTC)
    await lock_household(conn, household_id)
    if await conn.fetchval("SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id = $1", user_id):
        raise Problem(409, "agent_paused", "Resume your agent before refreshing suggestions.")
    # Fresh observations are stronger evidence than a stale forecast. Unknown stock is not zero stock.
    rows = await conn.fetch(
        """SELECT i.id, i.display_name, i.category, i.unit, i.par_level::float8 AS par_level,
                  o.quantity::float8 AS quantity, o.time AS observed_at, f.runout_at
           FROM inventory_items i
           JOIN LATERAL (SELECT quantity, time FROM inventory_observations
                         WHERE inventory_item_id = i.id ORDER BY time DESC LIMIT 1) o ON true
           LEFT JOIN LATERAL (SELECT runout_at, last_observed_at FROM consumption_forecasts
                              WHERE inventory_item_id = i.id ORDER BY computed_at DESC LIMIT 1) f ON true
           WHERE i.household_id = $1 AND i.status = 'active' AND o.time >= $2
             AND (o.quantity < i.par_level OR o.quantity = 0
                  OR (f.runout_at <= $3 AND f.last_observed_at >= o.time))
           ORDER BY o.quantity = 0 DESC, f.runout_at NULLS LAST, i.id LIMIT 100""",
        household_id, now - timedelta(days=30), now + timedelta(days=7))
    count = 0
    for row in rows:
        if count >= 5:
            break
        # Suppress both identical titles and linked alternatives, including recent completed/removed items.
        if await conn.fetchval(
            """SELECT 1 FROM wishlist_items WHERE household_id = $1
               AND (inventory_item_id = $2 OR normalized_title = $3)
               AND (status IN ('active', 'suggested', 'snoozed') OR
                    (status = 'rejected' AND decided_at > $4) OR
                    (status IN ('purchased', 'removed') AND completed_at > $5)) LIMIT 1""",
            household_id, row["id"], title_key(row["display_name"]), now - timedelta(days=30),
            now - timedelta(days=7)):
            continue
        if await conn.fetchval(
            """SELECT 1 FROM shopping_list_items li JOIN shopping_lists l ON l.id = li.list_id
               WHERE li.household_id = $1 AND li.inventory_item_id = $2 AND NOT li.checked
                 AND l.status = 'open' LIMIT 1""", household_id, row["id"]):
            continue
        low = row["quantity"] == 0 or (row["par_level"] is not None and row["quantity"] < row["par_level"])
        if low:
            detail = f"Last recorded stock: {row['quantity']:g} {row['unit']} on {row['observed_at']:%b %d}."
            if row["par_level"] is not None:
                detail += f" Your restock level is {row['par_level']:g}."
            confidence = 0.9
        else:
            detail = f"Your inventory forecast estimates this will run out around {row['runout_at']:%b %d}."
            confidence = 0.65
        body = WishlistSuggestionIn(title=row["display_name"], category=row["category"], quantity=1,
                                    inventory_item_id=row["id"], confidence=confidence, rationale=detail,
                                    evidence=[Evidence(kind="inventory_low" if low else "other", detail=detail[:200])])
        try:
            item_id = await propose(conn, household_id, user_id, body, now)
        except Problem as error:
            if error.code == "too_many_suggestions":
                break
            if error.code == "already_on_wishlist":
                continue
            raise
        count += item_id is not None
    await conn.execute(
        """INSERT INTO wishlist_refresh_state
           (household_id, last_refreshed_at, next_refresh_at, last_error, generated_count)
           VALUES ($1, $2, $3, NULL, $4) ON CONFLICT (household_id) DO UPDATE SET
           last_refreshed_at = EXCLUDED.last_refreshed_at, next_refresh_at = EXCLUDED.next_refresh_at,
           last_error = NULL, generated_count = EXCLUDED.generated_count""",
        household_id, now, next_refresh(now), count)
    await audit(conn, "wishlist.refreshed", actor_type="agent", actor_id=user_id, household_id=household_id,
                meta={"generated": count})
    await notify(conn, household_id, "wishlist.updated", household_id)
    return await state(conn, household_id)


class ShoppingRefresher:
    def __init__(self, db: Database):
        self.db = db

    @property
    def handlers(self):
        return {"wishlist.sweep": self.sweep, "wishlist.refresh": self.refresh_job,
                "lists.replenish": self.replenish_job}

    async def replenish_job(self, payload: dict, attempt: int) -> None:
        user_id, household_id = UUID(payload['user_id']), UUID(payload['household_id'])
        async with self.db.scoped(user_id) as conn:
            await replenishment.synchronize(conn, household_id, user_id)

    async def queue_lists(self, conn: asyncpg.Connection) -> None:
        households = await conn.fetch(
            """SELECT h.id, m.user_id FROM households h CROSS JOIN LATERAL (
                 SELECT m.user_id FROM household_members m JOIN user_settings s ON s.user_id = m.user_id
                 WHERE m.household_id = h.id AND s.agent_paused_at IS NULL
                 ORDER BY m.role = 'owner' DESC, m.joined_at LIMIT 1) m""")
        for household in households:
            await replenishment.enqueue(conn, household['id'], household['user_id'])

    async def start(self) -> None:
        async with self.db.system() as conn:
            await self.queue_lists(conn)
            await conn.execute(
                """INSERT INTO jobs (kind, payload, run_at, max_attempts)
                   SELECT 'wishlist.sweep', '{}', now(), 100
                   WHERE NOT EXISTS (SELECT 1 FROM jobs WHERE kind = 'wishlist.sweep'
                                     AND status IN ('queued', 'running'))
                   ON CONFLICT (kind) WHERE kind = 'wishlist.sweep' AND status = 'queued' DO NOTHING""")

    async def sweep(self, payload: dict, attempt: int) -> None:
        async with self.db.system() as conn:
            await self.queue_lists(conn)
            # One transaction books the household work and the next sweep. Downtime is coalesced.
            await conn.execute(
                """INSERT INTO jobs (kind, payload)
                   SELECT 'wishlist.refresh', jsonb_build_object('household_id', h.id, 'user_id', m.user_id)
                   FROM households h CROSS JOIN LATERAL (
                       SELECT m.user_id FROM household_members m JOIN user_settings u ON u.user_id = m.user_id
                       WHERE m.household_id = h.id AND u.agent_paused_at IS NULL
                       ORDER BY role = 'owner' DESC, joined_at LIMIT 1) m
                   LEFT JOIN wishlist_refresh_state s ON s.household_id = h.id
                   WHERE s.next_refresh_at IS NULL OR s.next_refresh_at <= now()
                   ON CONFLICT ((payload->>'household_id')) WHERE kind = 'wishlist.refresh'
                     AND status IN ('queued', 'running') DO NOTHING""")
            await conn.execute(
                """INSERT INTO jobs (kind, payload, run_at, max_attempts) VALUES ('wishlist.sweep', '{}', $1, 100)
                   ON CONFLICT (kind) WHERE kind = 'wishlist.sweep' AND status = 'queued' DO NOTHING""",
                next_refresh(datetime.now(UTC)))

    async def refresh_job(self, payload: dict, attempt: int) -> None:
        household_id, user_id = UUID(payload["household_id"]), UUID(payload["user_id"])
        try:
            async with self.db.scoped(user_id) as conn:
                if not await conn.fetchval("SELECT 1 FROM households WHERE id = $1", household_id):
                    return
                if await conn.fetchval(
                        "SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id = $1", user_id):
                    return
                await refresh(conn, household_id, user_id)
        except Exception:
            # Persist the failure outside the rolled-back generation transaction. Never store provider text.
            async with self.db.scoped(user_id) as conn:
                if await conn.fetchval("SELECT 1 FROM households WHERE id = $1", household_id):
                    await conn.execute(
                        """INSERT INTO wishlist_refresh_state (household_id, next_refresh_at, last_error)
                           VALUES ($1, $2, 'refresh_failed') ON CONFLICT (household_id)
                           DO UPDATE SET last_error = 'refresh_failed'""",
                        household_id, next_refresh(datetime.now(UTC)))
                    await notify(conn, household_id, "wishlist.updated", household_id)
            raise
