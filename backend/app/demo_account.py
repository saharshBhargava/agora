"""The demo account: one designated account, pre-filled with realistic history for every feature.

How you get in (all map to the same account):
- iOS: use the username/password form; Google is an optional alternative.
- curl / desktop / API docs: POST /v1/dev/login {"handle": "demo", "password": <AGORA_DEMO_PASSWORD>}.

Isolation rules:
- The only marker is ``users.is_demo``, set here and nowhere else. It's never returned by the API, so the
  account looks exactly like a real one.
- Anything mocked for the demo (simulated payments, for example) must check ``is_demo_user`` and apply to this
  account only. Real accounts never get mock data or mock behaviour, and the demo account never reaches real
  external effects such as real payments.

Keeping it current: when you add a household- or user-scoped table, add realistic demo rows for it in
``_seed`` below. tests/test_demo_account.py fails until you do. See CLAUDE.md.
"""

import math
import random
from datetime import UTC, date, datetime, timedelta
from uuid import UUID

import asyncpg

from app.auth import ensure_user
from app.commerce import record_order
from app.config import Settings
from app.core.wishlist import title_key
from app.db import Database, audit
from app.forecasting import refresh
from app.inventory_ops import sync_purchase_origins
from app.seed import seed_catalog, seed_household

DEMO_SUBJECT = "demo:primary"
DEMO_HANDLE = "demo"  # dev-login alias; the account's visible handle is realistic
VISIBLE_HANDLE = "alexrivera"


async def is_demo_user(conn: asyncpg.Connection, user_id: UUID) -> bool:
    return bool(await conn.fetchval("SELECT is_demo FROM users WHERE id = $1", user_id))


async def demo_user_id(db: Database) -> UUID | None:
    async with db.system() as conn:
        return await conn.fetchval("SELECT id FROM users WHERE auth_subject = $1 AND is_demo", DEMO_SUBJECT)


async def ensure_demo_account(db: Database, settings: Settings) -> UUID:
    """Create and fill the demo account if it doesn't exist yet. Safe to call on every boot and sign-in."""
    async with db.system() as conn:
        existing = await conn.fetchval("SELECT id FROM users WHERE auth_subject = $1", DEMO_SUBJECT)
    if existing:
        await _forecasts_and_lists(db, existing)
        await _manual_lists(db, existing)
        await _commerce(db, existing)
        await _calendar(db, existing)
        await _trips(db, existing)
        await _shopping_refresh(db, existing)
        await _price_watches(db, existing)
        return existing
    user_id = await ensure_user(db, DEMO_SUBJECT, VISIBLE_HANDLE, settings.demo_display_name)
    async with db.system() as conn:
        await conn.execute("UPDATE users SET is_demo = true WHERE id = $1", user_id)
    await seed_catalog(db)
    await _seed(db, user_id)
    return user_id


async def reset_demo_account(db: Database, settings: Settings) -> UUID:
    """Delete the demo account and everything in its household, then recreate it fresh. Touches nothing else."""
    async with db.system() as conn:
        user_id = await conn.fetchval("SELECT id FROM users WHERE auth_subject = $1 AND is_demo", DEMO_SUBJECT)
        if user_id:
            households = [r["household_id"] for r in await conn.fetch(
                """SELECT household_id FROM household_members m WHERE user_id = $1
                   AND NOT EXISTS (SELECT 1 FROM household_members o
                                   WHERE o.household_id = m.household_id AND o.user_id <> $1)""", user_id)]
            await conn.execute("DELETE FROM households WHERE id = ANY($1)", households)  # cascades household data
            await conn.execute("DELETE FROM users WHERE id = $1 AND is_demo", user_id)
    return await ensure_demo_account(db, settings)


async def _seed(db: Database, user_id: UUID) -> None:
    rng = random.Random("agora-demo")  # noqa: S311 - demo data, not security
    await seed_household(db, user_id, "agora-demo", days=28, provider="perceptron", model="perceptron-mk1.5")
    now = datetime.now(UTC)
    async with db.scoped(user_id) as conn:
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        await conn.execute(
            """UPDATE user_settings SET household_size = 2, autonomy_level = 'buy_with_approval',
                      home_geohash5 = 'c23nb' WHERE user_id = $1""", user_id)
        await conn.executemany(
            "INSERT INTO consents (user_id, scope, policy_version, granted_at) VALUES ($1, $2, '2026-10', $3)",
            [(user_id, scope, now - timedelta(days=29)) for scope in ("vision", "calendar", "location")])
        await conn.execute("INSERT INTO storage_locations (household_id, name, kind) VALUES ($1, 'Freezer', 'freezer')",
                           household_id)

        merchants = {r["name"]: r["id"]
                     for r in await conn.fetch("SELECT id, name FROM merchants WHERE household_id IS NULL")}
        market = await conn.fetchval(
            """INSERT INTO merchants (name, locality, kind, is_small_business, household_id, created_by)
               VALUES ('Ballard Farmers Market', 'Ballard', 'local', true, $1, $2) RETURNING id""",
            household_id, user_id)
        stores = [merchants["PCC Community Markets"], merchants["Safeway"], merchants["QFC"], market]

        await _detections_and_purchases(conn, household_id, user_id, stores, rng)
        # Include recent reviewed captures from both supported client model connections.
        captures = await conn.fetch(
            "SELECT id FROM scans WHERE household_id = $1 ORDER BY captured_at DESC LIMIT 2", household_id)
        for capture, (provider, model) in zip(captures, (
                ("gemini-client", "gemini-flash-latest"),
                ("openai-compatible-client", "Qwen2.5-VL-7B-Instruct")), strict=False):
            capture_id = capture["id"]
            await conn.execute(
                """UPDATE scans SET provider = $2, model = $3,
                          frame_keys = '{}', frame_hashes = '{}', raw_video_key = NULL,
                          media_deleted_at = now() WHERE id = $1""", capture_id, provider, model)
            await conn.execute(
                """UPDATE scan_detections SET bbox = NULL, frame_index = NULL, count = 1,
                          fill_fraction = NULL, auto_accepted = false WHERE scan_id = $1""", capture_id)
        items = {r["display_name"]: r["id"] for r in await conn.fetch(
            "SELECT id, display_name FROM inventory_items WHERE household_id = $1", household_id)}
        for name, store in (("2% milk", stores[0]), ("large eggs", stores[3]), ("coffee beans", stores[0]),
                            ("sparkling water", stores[1])):
            await conn.execute("UPDATE inventory_items SET preferred_merchant_id = $2, par_level = 1 WHERE id = $1",
                               items[name], store)

        await _wishlist(conn, household_id, user_id, items, now)
        await audit(conn, "demo.ready", actor_type="system", household_id=household_id, target_type="user",
                    target_id=user_id)
    await _forecasts_and_lists(db, user_id)
    await _manual_lists(db, user_id)
    await _commerce(db, user_id)
    await _calendar(db, user_id)
    await _trips(db, user_id)
    await _shopping_refresh(db, user_id)
    await _price_watches(db, user_id)


async def _commerce(db: Database, user_id: UUID) -> None:
    """Realistic spending history and approval inbox, exclusively for the designated demo account."""
    now = datetime.now(UTC)
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.features'), hashtext($1))", str(user_id))
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        if await conn.fetchval("SELECT 1 FROM agent_intents WHERE user_id = $1 LIMIT 1", user_id):
            return
        await conn.execute(
            """INSERT INTO budgets (household_id, period, limit_cents, created_by)
               VALUES ($1, 'month', 60000, $2) ON CONFLICT DO NOTHING""", household_id, user_id)
        await conn.execute(
            """INSERT INTO agent_mandates (user_id, household_id, label, categories, max_per_txn_cents,
                 max_per_period_cents, require_confirm_above_cents, expires_at)
               VALUES ($1, $2, 'Weekly groceries', ARRAY['dairy', 'produce', 'pantry'], 2500, 20000, 1500, $3)""",
            user_id, household_id, now + timedelta(days=21))
        for days, title, category, amount in ((8, 'Coffee beans', 'pantry', 1499),
                                               (4, 'Milk and eggs', 'dairy', 1298),
                                               (2, 'Apples and spinach', 'produce', 1125)):
            when = now - timedelta(days=days)
            intent = await conn.fetchrow(
                """INSERT INTO agent_intents (user_id, household_id, kind, title, item_key, amount_cents,
                     merchant_name, category, rationale, decision, decision_reasons, reason_codes, status,
                     decided_by, decided_at, completed_at, created_at, updated_at, idempotency_key)
                   VALUES ($1, $2, 'purchase', $3, $4, $5, 'PCC Community Markets', $6,
                     'Restocked after running low.', 'needs_approval', ARRAY['Waiting for your approval.'],
                     ARRAY['approval_required'], 'succeeded', 'user', $7, $7, $7, $7, $8) RETURNING *""",
                user_id, household_id, title, title_key(title), amount, category, when, f"history-{days}-{user_id}")
            order_id, _ = await record_order(conn, intent, amount, provider="simulated", brand="visa", last4="4242",
                                             placed_at=when)
            await audit(conn, "order.placed", actor_type="agent", actor_id=user_id, household_id=household_id,
                        target_type="order", target_id=order_id, meta={"provider": "simulated"})
        await conn.execute(
            """INSERT INTO agent_intents (user_id, household_id, kind, title, item_key, amount_cents,
                 merchant_name, category, rationale, decision, decision_reasons, reason_codes, status,
                 idempotency_key)
               VALUES ($1, $2, 'purchase', 'Extra virgin olive oil', 'extra virgin olive oil', 1899,
                 'PCC Community Markets', 'pantry', 'Your current bottle should run out this week.',
                 'needs_approval', ARRAY['Please approve this purchase.'], ARRAY['approval_required'],
                 'proposed', $3)""",
            user_id, household_id, f"olive-oil-{user_id}")


async def _forecasts_and_lists(db: Database, user_id: UUID) -> None:
    """Backfill newly shipped features for an existing demo without resetting rehearsed data."""
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.features'), hashtext($1))", str(user_id))
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        if not await conn.fetchval("SELECT 1 FROM consumption_forecasts WHERE household_id = $1 LIMIT 1", household_id):
            await refresh(conn, household_id, user_id, timescale=db.timescale)
        if await conn.fetchval("SELECT 1 FROM shopping_lists WHERE household_id = $1 LIMIT 1", household_id):
            return
        merchant = await conn.fetchval("SELECT id FROM merchants WHERE name = 'PCC Community Markets' LIMIT 1")
        list_id = await conn.fetchval(
            """INSERT INTO shopping_lists (household_id, name, merchant_id, source, created_by)
               VALUES ($1, 'Saturday groceries', $2, 'user', $3) RETURNING id""", household_id, merchant, user_id)
        await conn.executemany(
            """INSERT INTO shopping_list_items (list_id, household_id, title, quantity, reason, added_by,
                 merchant_id, created_by) VALUES ($1, $2, $3, $4, 'manual', 'user', $5, $6)""",
            [(list_id, household_id, 'Sourdough bread', 1, merchant, user_id),
             (list_id, household_id, 'Honeycrisp apples', 4, merchant, user_id)])


async def _manual_lists(db: Database, user_id: UUID) -> None:
    """Show a hand-written list with quantities and notes; preserve edits on subsequent sign-ins."""
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.features'), hashtext($1))", str(user_id))
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        # The audit marker survives list renames/archiving, so backfills do not recreate it.
        if await conn.fetchval("SELECT 1 FROM audit_log WHERE household_id = $1 AND action = 'demo.manual_list'",
                               household_id):
            return
        merchant = await conn.fetchval("SELECT id FROM merchants WHERE name = 'Target' LIMIT 1")
        list_id = await conn.fetchval(
            """INSERT INTO shopping_lists (household_id, name, merchant_id, source, created_by)
               VALUES ($1, 'Household essentials', $2, 'user', $3) RETURNING id""", household_id, merchant, user_id)
        await conn.executemany(
            """INSERT INTO shopping_list_items (list_id, household_id, title, quantity, unit, note, reason,
                 added_by, merchant_id, created_by) VALUES ($1, $2, $3, $4, $5, $6, 'manual', 'user', $7, $8)""",
            [(list_id, household_id, 'Dish soap', 2, 'bottles', 'Unscented refill bottles', merchant, user_id),
             (list_id, household_id, 'Kitchen sponges', 1, 'pack', 'Non-scratch for the pans', merchant, user_id)])
        await audit(conn, 'demo.manual_list', actor_type='system', household_id=household_id,
                    target_type='shopping_list', target_id=list_id)


async def _detections_and_purchases(conn: asyncpg.Connection, household_id: UUID, user_id: UUID,
                                    stores: list[UUID], rng: random.Random) -> None:
    """Give every seeded scan the detections a real scan would have. Scans where something was restocked
    become shopping hauls with a store and a purchase date, which fills purchase history."""
    rows = await conn.fetch(
        """SELECT o.scan_id, o.inventory_item_id, o.quantity::float8 AS qty, o.confidence, o.time, i.display_name,
                  i.category, i.product_id,
                  lag(o.quantity::float8) OVER (PARTITION BY o.inventory_item_id ORDER BY o.time) AS previous
           FROM inventory_observations o JOIN inventory_items i ON i.id = o.inventory_item_id
           WHERE o.household_id = $1 ORDER BY o.time""", household_id)
    hauls: dict[UUID, date] = {}
    for r in rows:
        count = max(1, math.ceil(r["qty"]))  # e.g. 1.4 units = 2 containers, the second 40% full
        fill = None if float(r["qty"]).is_integer() else round(r["qty"] - (count - 1), 3)
        x, y = rng.randint(40, 700), rng.randint(40, 700)
        await conn.execute(
            """INSERT INTO scan_detections (scan_id, household_id, label, category, product_id, inventory_item_id,
                 match_score, confidence, count, fill_fraction, quantity, bbox, frame_index, review, auto_accepted)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 0, 'accepted', true)""",
            r["scan_id"], household_id, r["display_name"], r["category"], r["product_id"], r["inventory_item_id"],
            round(rng.uniform(0.86, 0.99), 3), r["confidence"] or 0.9, count, fill, r["qty"],
            {"grid": 1000, "box": [x, y, x + rng.randint(80, 250), y + rng.randint(80, 250)]})
        if r["previous"] is not None and r["qty"] > r["previous"] + 0.5:
            hauls.setdefault(r["scan_id"], (r["time"] - timedelta(hours=rng.randint(1, 20))).date())
    for i, (scan_id, bought) in enumerate(sorted(hauls.items(), key=lambda h: h[1])):
        await conn.execute("UPDATE scans SET purchased_from_merchant_id = $2, purchased_on = $3 WHERE id = $1",
                           scan_id, stores[i % len(stores)], bought)
        await sync_purchase_origins(conn, scan_id, user_id)


async def _wishlist(conn: asyncpg.Connection, household_id: UUID, user_id: UUID, items: dict[str, UUID],
                    now: datetime) -> None:
    async def add(title: str, *, source: str, status: str, category: str | None = None, days_ago: float = 1,
                  **extra) -> UUID:
        columns = {"household_id": household_id, "title": title, "normalized_title": title_key(title),
                   "category": category, "source": source, "status": status, "created_by": user_id,
                   "created_at": now - timedelta(days=days_ago), **extra}
        if source == "agent" and status != "suggested":
            columns |= {"decided_by": user_id, "decided_at": now - timedelta(days=days_ago / 2)}
        if source == "agent" and status in ("active", "purchased"):
            columns["accepted_at"] = now - timedelta(days=days_ago / 2)
        if status == "purchased":
            columns.setdefault("completed_at", now - timedelta(days=days_ago / 3))
        names = ", ".join(columns)
        marks = ", ".join(f"${i}" for i in range(1, len(columns) + 1))
        return await conn.fetchval(f"INSERT INTO wishlist_items ({names}) VALUES ({marks}) RETURNING id",
                                   *columns.values())

    await add("Sourdough starter kit", source="user", status="active", category="bakery", days_ago=6, pinned=True)
    await add("Birthday candles", source="user", status="active", category="household", days_ago=2,
              needed_by=(now + timedelta(days=2)).date())
    await add("Cast iron skillet", source="user", status="active", category="household", days_ago=9, priority=2,
              target_price_cents=3999, notes="10 or 12 inch")
    await add("Cold brew concentrate", source="user", status="purchased", category="beverages", days_ago=12)
    oat = await add("Oat milk", source="agent", status="suggested", category="dairy", days_ago=0.5, confidence=0.82,
                    rationale="You finish 2% milk about every 6 days; oat milk keeps 3x longer and is on sale at PCC.",
                    evidence=[{"type": "consumption", "item": "2% milk", "days_per_unit": 6}],
                    target_price_cents=449, inventory_item_id=items.get("2% milk"))
    await add("Greek yogurt (big tub)", source="agent", status="active", category="dairy", days_ago=4,
              confidence=0.77, rationale="You buy two small tubs a week; the 32 oz tub costs 30% less per ounce.",
              inventory_item_id=items.get("greek yogurt"))
    strawberries = await add("Organic strawberries", source="agent", status="snoozed", category="produce",
                             days_ago=3, confidence=0.64, rationale="Back in season at Ballard Farmers Market.",
                             snoozed_until=now + timedelta(days=2))
    chips = await add("Family-size tortilla chips", source="agent", status="rejected", category="snacks", days_ago=5,
                      confidence=0.58, rationale="Frequently bought alongside salsa.", reject_reason="not_interested",
                      reject_comment="Trying to cut back on snacks")
    await add("Fancy olive oil", source="agent", status="rejected", category="pantry", days_ago=8, confidence=0.6,
              rationale="Your olive oil is running low.", reject_reason="too_expensive", target_price_cents=2499)
    for item_id, rating, reason in ((oat, "up", None), (strawberries, "up", None), (chips, "down", "not_interested")):
        await conn.execute(
            """INSERT INTO wishlist_feedback (wishlist_item_id, household_id, user_id, rating, reason_code)
               VALUES ($1, $2, $3, $4, $5)""", item_id, household_id, user_id, rating, reason)


async def _calendar(db: Database, user_id: UUID) -> None:
    """Backfill a private calendar without changing existing rehearsed events."""
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.calendar'), hashtext($1))", str(user_id))
        if await conn.fetchval("SELECT 1 FROM calendar_events WHERE user_id = $1 LIMIT 1", user_id):
            return
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        tomorrow = (datetime.now(UTC) + timedelta(days=1)).replace(hour=17, minute=0, second=0, microsecond=0)
        for offset, title, duration in ((0, "Team planning", 1), (3, "Lunch with Maya", 1),
                                         (24, "Weekly grocery trip", 1)):
            start = tomorrow + timedelta(hours=offset)
            await conn.execute(
                """INSERT INTO calendar_events (user_id, household_id, title, starts_at, ends_at, timezone)
                   VALUES ($1,$2,$3,$4,$5,'Etc/UTC')""", user_id, household_id, title,
                start, start + timedelta(hours=duration))


async def _trips(db: Database, user_id: UUID) -> None:
    """Link a real shopping list to its private Calendar event without rewriting history."""
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.trips'), hashtext($1))", str(user_id))
        if await conn.fetchval("SELECT 1 FROM replenishment_trips WHERE user_id = $1", user_id):
            return
        lst = await conn.fetchrow(
            """SELECT * FROM shopping_lists WHERE household_id = ANY(app_household_ids())
               AND status = 'open' ORDER BY created_at LIMIT 1""")
        if lst is None:
            return
        event = await conn.fetchrow(
            """SELECT * FROM calendar_events WHERE user_id = $1 AND household_id = $2
               AND title = 'Weekly grocery trip' ORDER BY starts_at DESC LIMIT 1""", user_id, lst["household_id"])
        if event is None:
            start = (datetime.now(UTC) + timedelta(days=2)).replace(hour=18, minute=0, second=0, microsecond=0)
            event = await conn.fetchrow(
                """INSERT INTO calendar_events (user_id, household_id, title, description, location,
                     starts_at, ends_at, timezone)
                   VALUES ($1,$2,'Weekly grocery trip','Pick up bread and apples.','PCC Community Markets',
                     $3,$4,'Etc/UTC') RETURNING *""", user_id, lst["household_id"], start, start + timedelta(hours=1))
        await conn.execute(
            """INSERT INTO replenishment_trips (household_id, list_id, user_id, list_name, list_updated_at,
                 starts_at, ends_at, start_text, end_text, timezone, title, description, location, status, event_id)
               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,'scheduled',$14)""",
            lst["household_id"], lst["id"], user_id, lst["name"], lst["updated_at"],
            event["starts_at"], event["ends_at"], event["starts_at"].isoformat(), event["ends_at"].isoformat(),
            event["timezone"], event["title"], event["description"], event["location"], str(event["id"]))


async def _shopping_refresh(db: Database, user_id: UUID) -> None:
    from app.shopping import next_refresh

    now = datetime.now(UTC)
    async with db.scoped(user_id) as conn:
        household_id = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id = $1", user_id)
        await conn.execute(
            """INSERT INTO wishlist_refresh_state (household_id, last_refreshed_at, next_refresh_at, generated_count)
               VALUES ($1, $2, $3, 1) ON CONFLICT (household_id) DO NOTHING""",
            household_id, now - timedelta(hours=1), next_refresh(now))
        # Bring earlier demo evidence into the same readable shape as new suggestions.
        await conn.execute(
            """UPDATE wishlist_items SET rationale = 'Try an alternative to the milk already in your inventory.',
                      evidence = '[{"kind":"other","detail":"You keep milk in the fridge."}]'::jsonb
               WHERE household_id = $1 AND title = 'Oat milk' AND evidence @> '[{"type":"consumption"}]'::jsonb""",
            household_id)


async def _price_watches(db: Database, user_id: UUID) -> None:
    """Backfill a confirmed skillet watch and its previous observation without external effects."""
    from app.price_search import Offer
    from app.watch_schemas import WatchCriteria

    now = datetime.now(UTC)
    async with db.scoped(user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('demo.watches'), hashtext($1))", str(user_id))
        if await conn.fetchval('SELECT 1 FROM price_watches WHERE created_by=$1', user_id):
            return
        item = await conn.fetchrow("SELECT * FROM wishlist_items WHERE title='Cast iron skillet' "
                                   "AND status='active' ORDER BY created_at LIMIT 1")
        if not item:
            return
        household_id = item['household_id']
        checked = now-timedelta(hours=1)
        criteria = WatchCriteria(query='Lodge 12 inch cast iron skillet',
                                 required_terms=['Lodge', '12 inch', 'skillet'],
                                 excluded_terms=['lid only'], target_price_cents=3999, quantity=1,
                                 product_url='https://www.lodgecastiron.com/product/round-cast-iron-classic-skillet',
                                 fulfillment='delivery', location='Seattle, WA 98107').model_dump(mode='json')
        watch_id = await conn.fetchval(
            """INSERT INTO price_watches(household_id,wishlist_item_id,created_by,criteria,confirmed_at,
               last_checked_at,last_successful_at,next_check_at,last_result)
               VALUES($1,$2,$3,$4,$5,$5,$5,$6,'matched') RETURNING id""",
            household_id, item['id'], user_id, criteria, checked, now+timedelta(hours=5))
        await conn.execute(
            """INSERT INTO watch_subscriptions(watch_id,household_id,user_id,push_enabled,quiet_start_hour,
               quiet_end_hour,timezone,last_notified_at) VALUES($1,$2,$3,true,22,8,'America/Los_Angeles',$4)""",
            watch_id, household_id, user_id, checked)
        run_id = await conn.fetchval(
            """INSERT INTO watch_runs(household_id,watch_id,user_id,criteria_version,status,trigger,created_at,
               started_at,finished_at,offer_count,match_count) VALUES($1,$2,$3,1,'succeeded','scheduled',$4,$4,$4,1,1)
               RETURNING id""", household_id, watch_id, user_id, checked)
        listing_id = await conn.fetchval(
            """INSERT INTO watch_listings(household_id,watch_id,url,merchant)
               VALUES($1,$2,$3,'Lodge Cast Iron') RETURNING id""", household_id, watch_id, criteria['product_url'])
        offer = Offer(url=criteria['product_url'], title=criteria['query'], merchant='Lodge Cast Iron',
                      price_cents=2999, available=True, available_quantity=12, shipping_cents=0, tax_cents=300,
                      fees_cents=0, condition='new', fulfillment='delivery', location=criteria['location'],
                      observed_at=checked, arrives_by=now+timedelta(days=2),
                      evidence='Product page: 12 inch skillet, in stock, $29.99.').model_dump(mode='json')
        observation_id = await conn.fetchval(
            """INSERT INTO watch_observations(household_id,watch_id,listing_id,run_id,criteria_version,
               offer,observed_at,eligible,reason) VALUES($1,$2,$3,$4,1,$5,$6,true,'confirmed_criteria_met')
               RETURNING id""",
            household_id, watch_id, listing_id, run_id, offer, checked)
        match_id = await conn.fetchval(
            """INSERT INTO watch_matches(household_id,watch_id,observation_id,criteria_version,fingerprint,title,
               url,merchant,unit_price_cents,total_price_cents,currency,quantity,shipping_cents,tax_cents,
               fulfillment,location,condition,observed_at,matched_at,evidence,reason)
               VALUES($1,$2,$3,1,'skillet-2999',$4,$5,'Lodge Cast Iron',2999,3299,'USD',1,0,300,'delivery',
                 $6,'new',$7,$7,$8,'Matches your confirmed size, price and delivery preferences.') RETURNING id""",
            household_id, watch_id, observation_id, criteria['query'], criteria['product_url'], criteria['location'],
            checked, ['12 inch cast iron skillet; new; in stock.'])
        notification_id = await conn.fetchval(
            """INSERT INTO notifications(household_id,user_id,watch_id,match_id,title,body,created_at)
               VALUES($1,$2,$3,$4,'Your skillet meets your target',
                 'Lodge 12 inch cast iron skillet is $29.99, below your $39.99 target. Review the offer.',$5)
               RETURNING id""", household_id, user_id, watch_id, match_id, checked)
        await conn.execute(
            """INSERT INTO notification_outbox(household_id,user_id,notification_id,status,attempts,delivered_at)
               VALUES($1,$2,$3,'sent',1,$4)""", household_id, user_id, notification_id, checked)
        await conn.execute(
            """INSERT INTO push_devices(user_id,token,environment) VALUES($1,$2,'sandbox')
               ON CONFLICT(token,environment) DO NOTHING""", user_id, 'a'*64)
