"""Automatic, evidence-based shopping lists. No model credentials or open app are required.

Use the existing six-hour sweep and forecast-update events. Model-facing context can explain these
persisted decisions; the stock/store evidence and list mutations stay deterministic and user-scoped.
"""
import math
from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg

from app import forecasting, idempotency
from app.core.forecast import as_of, suggested_quantity
from app.db import audit, notify
from app.merchants import MERCHANT_REF, ref


async def lock(conn: asyncpg.Connection, household_id: UUID) -> None:
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('lists.generate'), hashtext($1))", str(household_id))


async def enqueue(conn: asyncpg.Connection, household_id: UUID, user_id: UUID) -> None:
    await conn.execute(
        """INSERT INTO jobs (kind, payload) VALUES ('lists.replenish', $1)
           ON CONFLICT DO NOTHING""",
        {"household_id": str(household_id), "user_id": str(user_id)})
    await conn.execute("SELECT pg_notify('agora_jobs', 'lists.replenish')")


async def dismiss(conn: asyncpg.Connection, household_id: UUID, item_ids: list[UUID]) -> None:
    """Record current evidence, not wall-clock time, so a later observation can establish a new need."""
    await conn.execute(
        """INSERT INTO replenishment_dismissals (household_id, inventory_item_id, observed_at)
           SELECT i.household_id, i.id, o.time FROM inventory_items i
           JOIN LATERAL (SELECT time FROM inventory_observations WHERE inventory_item_id = i.id
                         ORDER BY time DESC LIMIT 1) o ON true
           WHERE i.household_id = $1 AND i.id = ANY($2::uuid[])
           ON CONFLICT (inventory_item_id) DO UPDATE
             SET observed_at = EXCLUDED.observed_at, decided_at = now()""", household_id, item_ids)


async def synchronize(conn: asyncpg.Connection, household_id: UUID, user_id: UUID,
                      now: datetime | None = None) -> int:
    # Runtime imports avoid router initialization cycles; both paths share limits and list persistence.
    from app.routers.inventory import ITEM_SELECT
    from app.routers.lists import MAX_ITEMS_PER_LIST, MAX_OPEN_LISTS, _create_list, _touch

    now = now or datetime.now(UTC)
    await lock(conn, household_id)
    # Lock the owner's settings until commit so pause and generation have a definite ordering.
    settings = await conn.fetchrow("SELECT agent_paused_at FROM user_settings WHERE user_id = $1 FOR SHARE", user_id)
    if settings is None or settings['agent_paused_at'] is not None:
        return 0
    if not await conn.fetchval("SELECT 1 FROM households WHERE id = $1", household_id):
        return 0
    rows = await conn.fetch(ITEM_SELECT + "WHERE i.household_id = $1 ORDER BY i.id", household_id)
    stored = await forecasting.latest(conn, [r['id'] for r in rows])
    tz = await forecasting.user_timezone(conn, user_id)
    merchants = {r['m_id']: ref(r, 'm_') for r in await conn.fetch(
        f"SELECT {MERCHANT_REF} FROM merchants m WHERE m.id = ANY($1::uuid[]) "
        "AND (m.household_id IS NULL OR m.household_id = $2)",
        [r['preferred_merchant_id'] for r in rows if r['preferred_merchant_id']], household_id)}
    dismissed = {r['inventory_item_id']: r['observed_at'] for r in await conn.fetch(
        "SELECT inventory_item_id, observed_at FROM replenishment_dismissals WHERE household_id = $1", household_id)}
    candidates = {}
    for row in rows:
        observed, quantity = row['observed_at'], row['quantity']
        if (row['status'] != 'active' or observed is None or quantity is None
                or not now - timedelta(days=30) <= observed <= now):
            continue
        f = stored.get(row['id'])
        fresh = f is not None and f['last_observed_at'] == observed and f['last_quantity'] == quantity
        low = quantity == 0 or (row['par_level'] is not None and quantity < row['par_level'])
        soon = fresh and f['runout_at'] is not None and f['runout_at'] <= now + timedelta(days=7)
        if not low and not soon:
            continue
        if low:
            why = f"Last recorded stock: {quantity:g} {row['unit']} on {observed:%b %d}."
            if row['par_level'] is not None:
                why += f" Your restock level is {row['par_level']:g}."
            needed = observed
        else:
            prediction = forecasting.to_out(f, row['display_name'], row['unit'], now, tz)
            why = f"{prediction.explanation} Confidence: {prediction.confidence}."
            needed = f['runout_at']
        if low and row['par_level'] is not None:
            amount = max(1, math.ceil(row['par_level'] - quantity))
        else:
            amount = suggested_quantity(as_of(forecasting.from_row(f), now), None) if fresh else 1
        merchant = merchants.get(row['preferred_merchant_id']) or ref(row, 'm_')
        basis = ('preferred' if row['preferred_merchant_id'] in merchants else 'last_purchase') if merchant else None
        if merchant:
            why += f" {'Your usual store is' if basis == 'preferred' else 'Last bought at'} {merchant.name}."
        else:
            why += " No preferred or previous purchase store is recorded."
        candidates[row['id']] = (row, merchant, basis, min(1000, max(1, amount)), why[:500], needed)

    # Keep machine-owned lines current. User edits transfer ownership back to the user.
    automatic = await conn.fetch(
        """SELECT li.* FROM shopping_list_items li JOIN shopping_lists l ON li.list_id = l.id
           WHERE l.household_id = $1 AND l.status = 'open' AND li.auto_replenished AND NOT li.checked""",
        household_id)
    touched = set()
    removed = 0
    for line in automatic:
        candidate = candidates.get(line['inventory_item_id'])
        merchant_id = candidate[1].id if candidate and candidate[1] else None
        if candidate is None or line['merchant_id'] != merchant_id:
            await conn.execute("DELETE FROM shopping_list_items WHERE id = $1", line['id'])
            touched.add(line['list_id'])
            removed += 1
        else:
            _, _, basis, amount, why, needed = candidate
            if (line['quantity'], line['explanation'], line['needed_by'], line['merchant_basis']) != (
                    amount, why, needed, basis):
                await conn.execute(
                    """UPDATE shopping_list_items SET quantity=$2, explanation=$3, needed_by=$4,
                         merchant_basis=$5, updated_at=now() WHERE id=$1""",
                    line['id'], amount, why, needed, basis)
                touched.add(line['list_id'])
    existing = await conn.fetch(
        """SELECT li.inventory_item_id, li.title FROM shopping_list_items li
           JOIN shopping_lists l ON l.id = li.list_id WHERE l.household_id = $1 AND l.status = 'open'
             AND NOT li.checked""", household_id)
    linked = {r['inventory_item_id'] for r in existing}
    names = {idempotency.item_name_key(r['title']) for r in existing}
    lists = await conn.fetch(
        """SELECT l.id, l.merchant_id, l.source, count(li.id) AS size FROM shopping_lists l
           LEFT JOIN shopping_list_items li ON li.list_id = l.id
           WHERE l.household_id = $1 AND l.status = 'open' GROUP BY l.id ORDER BY l.created_at DESC""", household_id)
    open_count = len(lists)
    destinations = {}
    for lst in lists:
        if lst['source'] == 'generated' and lst['size'] < MAX_ITEMS_PER_LIST:
            destinations.setdefault(lst['merchant_id'], [lst['id'], lst['size']])
    added = 0
    for item_id, (row, merchant, basis, amount, why, needed) in candidates.items():
        name = idempotency.item_name_key(row['display_name'])
        if (item_id in linked or name in names
                or dismissed.get(item_id, datetime.min.replace(tzinfo=UTC)) >= row['observed_at']):
            continue
        # Preserve rejected/snoozed/recently purchased wishlist decisions too.
        if await conn.fetchval(
            """SELECT 1 FROM wishlist_items WHERE household_id = $1
               AND (inventory_item_id = $2 OR normalized_title = $3)
               AND ((status = 'snoozed' AND snoozed_until > $4)
                    OR (status = 'rejected' AND decided_at > $4 - interval '30 days')
                    OR (status IN ('purchased', 'removed') AND completed_at > $4 - interval '7 days')) LIMIT 1""",
            household_id, item_id, name, now):
            continue
        merchant_id = merchant.id if merchant else None
        destination = destinations.get(merchant_id)
        if destination is None or destination[1] >= MAX_ITEMS_PER_LIST:
            if open_count >= MAX_OPEN_LISTS:
                continue
            title = (f"{merchant.name} ({merchant.locality})" if merchant and merchant.locality
                     else merchant.name if merchant else 'Groceries')
            list_id = await _create_list(conn, household_id, user_id, title, merchant_id, 'generated')
            destination = destinations[merchant_id] = [list_id, 0]
            open_count += 1
        list_id = destination[0]
        await conn.execute(
            """INSERT INTO shopping_list_items (list_id, household_id, title, inventory_item_id, product_id,
                 quantity, unit, reason, added_by, explanation, merchant_id, merchant_basis, needed_by,
                 created_by, auto_replenished)
               VALUES ($1,$2,$3,$4,$5,$6,$7,'runout','system',$8,$9,$10,$11,$12,true)""",
            list_id, household_id, row['display_name'], item_id, row['product_id'], amount,
            row['unit'] if row['unit'] != 'unit' else None, why, merchant_id, basis, needed, user_id)
        destination[1] += 1
        linked.add(item_id)
        names.add(name)
        touched.add(list_id)
        added += 1
    for list_id in touched:
        await _touch(conn, household_id, list_id)
    if touched:
        await audit(conn, 'list.auto_replenished', actor_type='agent', actor_id=user_id, household_id=household_id,
                    target_type='household', target_id=household_id,
                    meta={'added': added, 'removed': removed, 'lists': len(touched)})
        await notify(conn, household_id, 'list.updated', household_id)
    return added
