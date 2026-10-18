"""Demo data: ``python -m app.seed``. Idempotent per user: households that already have items are skipped.

Creates a small product catalog, a few merchants (two local), and for each demo user three weeks of daily
fridge/pantry scans with realistic depletion and restocks, so every chart has data on the first click. Seeded
scans are marked ``provider = 'seed'`` so they're never mistaken for real model output.
"""

import asyncio
import random
from datetime import UTC, datetime, timedelta

from app.auth import ensure_user
from app.config import get_settings
from app.db import Database
from app.forecasting import refresh
from app.migrate import migrate

PRODUCTS = [
    # name, brand, category, unit, size_value, size_unit
    ("2% milk", "Darigold", "dairy", "unit", 0.5, "gal"),
    ("oat milk", "Oatly", "dairy", "unit", 64, "fl oz"),
    ("large eggs", "Vital Farms", "dairy", "unit", 12, "ct"),
    ("greek yogurt", "Fage", "dairy", "unit", 32, "oz"),
    ("cheddar cheese", "Tillamook", "dairy", "unit", 8, "oz"),
    ("butter", "Kerrygold", "dairy", "unit", 8, "oz"),
    ("baby spinach", "Organic Girl", "produce", "unit", 5, "oz"),
    ("bananas", None, "produce", "unit", 1, "ea"),
    ("apples", None, "produce", "unit", 1, "ea"),
    ("avocados", None, "produce", "unit", 1, "ea"),
    ("strawberries", "Driscoll's", "produce", "unit", 16, "oz"),
    ("carrots", None, "produce", "unit", 2, "lb"),
    ("chicken breast", "Foster Farms", "meat", "unit", 1.5, "lb"),
    ("ground beef", None, "meat", "unit", 1, "lb"),
    ("salmon fillet", None, "seafood", "unit", 1, "lb"),
    ("sourdough bread", "Macrina", "bakery", "unit", 24, "oz"),
    ("tortillas", "Mission", "bakery", "unit", 10, "ct"),
    ("orange juice", "Tropicana", "beverages", "unit", 52, "fl oz"),
    ("sparkling water", "LaCroix", "beverages", "unit", 12, "ct"),
    ("coffee beans", "Stumptown", "pantry", "unit", 12, "oz"),
    ("rolled oats", "Bob's Red Mill", "pantry", "unit", 32, "oz"),
    ("pasta", "Barilla", "pantry", "unit", 16, "oz"),
    ("rice", "Lundberg", "pantry", "unit", 2, "lb"),
    ("black beans", "Goya", "pantry", "unit", 15, "oz"),
    ("peanut butter", "Adams", "pantry", "unit", 16, "oz"),
    ("olive oil", "California Olive Ranch", "pantry", "unit", 16.9, "fl oz"),
    ("granola", "Nature's Path", "pantry", "unit", 11, "oz"),
    ("tomato sauce", "Rao's", "pantry", "unit", 24, "oz"),
    ("ketchup", "Heinz", "condiments", "unit", 20, "oz"),
    ("hot sauce", "Cholula", "condiments", "unit", 5, "fl oz"),
    ("frozen peas", "Birds Eye", "frozen", "unit", 12, "oz"),
    ("ice cream", "Tillamook", "frozen", "unit", 48, "fl oz"),
    ("tortilla chips", "Late July", "snacks", "unit", 11, "oz"),
    ("dish soap", "Dawn", "household", "unit", 19.4, "fl oz"),
    ("paper towels", "Bounty", "household", "unit", 6, "ct"),
    ("toothpaste", "Crest", "personal_care", "unit", 4.1, "oz"),
]

MERCHANTS = [
    # name, kind, is_small_business, website, lat, lng
    ("Safeway", "grocery", False, "https://www.safeway.com", 47.6612, -122.3134),
    ("QFC", "grocery", False, "https://www.qfc.com", 47.6634, -122.2993),
    ("Target", "big_box", False, "https://www.target.com", 47.6609, -122.3166),
    ("PCC Community Markets", "local", True, "https://www.pccmarkets.com", 47.6687, -122.3008),
    ("Ballard Corner Grocery", "local", True, None, 47.6686, -122.3843),
]

# item name, location, daily use, restock-to level, restock-below level
TRACKED = [
    ("2% milk", "Fridge", 0.18, 2.0, 0.4),
    ("large eggs", "Fridge", 0.35, 12.0, 3.0),
    ("greek yogurt", "Fridge", 0.25, 2.0, 0.3),
    ("baby spinach", "Fridge", 0.3, 2.0, 0.3),
    ("cheddar cheese", "Fridge", 0.08, 1.0, 0.2),
    ("strawberries", "Fridge", 0.35, 2.0, 0.3),
    ("orange juice", "Fridge", 0.15, 1.0, 0.2),
    ("coffee beans", "Pantry", 0.09, 2.0, 0.3),
    ("rolled oats", "Pantry", 0.06, 1.0, 0.2),
    ("pasta", "Pantry", 0.2, 3.0, 1.0),
    ("peanut butter", "Pantry", 0.05, 1.0, 0.25),
    ("sparkling water", "Pantry", 1.4, 12.0, 3.0),
]

DEMO_USERS = [("kedar", "Kedar"), ("saharsh", "Saharsh")]


async def seed_catalog(db: Database) -> None:
    async with db.system() as conn:
        if await conn.fetchval("SELECT count(*) FROM products") == 0:
            await conn.executemany(
                "INSERT INTO products (name, brand, category, unit, size_value, size_unit) "
                "VALUES ($1, $2, $3, $4, $5, $6)",
                PRODUCTS)
        if await conn.fetchval("SELECT count(*) FROM merchants") == 0:
            await conn.executemany(
                "INSERT INTO merchants (name, kind, is_small_business, website, lat, lng) "
                "VALUES ($1, $2, $3, $4, $5, $6)",
                MERCHANTS)


async def seed_history(db: Database, handle: str, display_name: str, days: int = 21, rng_seed: int = 7) -> bool:
    user_id = await ensure_user(db, f"dev:{handle}", handle, display_name)
    return await seed_household(db, user_id, f"{rng_seed}:{handle}", days)


async def seed_new_user(db: Database, user_id) -> bool:
    """Sample history for a freshly created (demo) account. Skips households that already have items."""
    await seed_catalog(db)
    return await seed_household(db, user_id, str(user_id))


async def seed_household(db: Database, user_id, rng_key: str, days: int = 21) -> bool:
    rng = random.Random(rng_key)  # noqa: S311 - demo data, not security
    async with db.scoped(user_id) as conn:
        household_id = await conn.fetchval(
            "SELECT household_id FROM household_members WHERE user_id = $1 ORDER BY joined_at LIMIT 1", user_id)
        if await conn.fetchval("SELECT count(*) FROM inventory_items WHERE household_id = $1", household_id):
            return False
        locations = {r["name"]: r["id"] for r in await conn.fetch(
            "SELECT id, name FROM storage_locations WHERE household_id = $1", household_id)}
        products = {r["name"]: r for r in await conn.fetch("SELECT id, name, category FROM products")}
        items = {}
        for name, location, *_ in TRACKED:
            items[name] = await conn.fetchval(
                """INSERT INTO inventory_items (household_id, product_id, display_name, category, location_id,
                                                created_by) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
                household_id, products[name]["id"], name, products[name]["category"], locations[location], user_id)

        level = {name: top * rng.uniform(0.5, 1.0) for name, _, _, top, _ in TRACKED}
        start = datetime.now(UTC).replace(hour=19, minute=30, second=0, microsecond=0) - timedelta(days=days)
        for day in range(days):
            for location_name, location_id in locations.items():
                when = start + timedelta(days=day, minutes=rng.randint(-90, 90))
                scan_id = await conn.fetchval(
                    """INSERT INTO scans (household_id, user_id, location_id, captured_at, media_kind, status,
                                          provider, model, media_deleted_at, processed_at, confirmed_at)
                       VALUES ($1, $2, $3, $4, 'photos', 'confirmed', 'seed', 'synthetic', $4, $4, $4)
                       RETURNING id""", household_id, user_id, location_id, when)
                for name, location, rate, top, low in TRACKED:
                    if location != location_name:
                        continue
                    level[name] = max(0.0, level[name] - rate * rng.uniform(0.6, 1.4))
                    if level[name] < low and rng.random() < 0.7:
                        level[name] = top  # grocery run
                    seen = round(level[name] * rng.uniform(0.95, 1.05), 2)  # model estimates are a little noisy
                    await conn.execute(
                        """INSERT INTO inventory_observations (time, household_id, inventory_item_id, quantity,
                                                               source, scan_id, confidence, recorded_by)
                           VALUES ($1, $2, $3, $4, 'scan', $5, $6, $7)""",
                        when, household_id, items[name], seen, scan_id, round(rng.uniform(0.82, 0.97), 2), user_id)
        # Forecast straight away so run-outs show on the first click, without waiting for the worker.
        await refresh(conn, household_id, user_id, timescale=db.timescale)
    return True


async def main() -> None:
    settings = get_settings()
    dsn = settings.database_url.get_secret_value()
    await migrate(dsn)
    db = Database(dsn)
    await db.connect()
    try:
        await seed_catalog(db)
        for handle, name in DEMO_USERS:
            created = await seed_history(db, handle, name)
            print(f"{handle}: {'seeded' if created else 'already had data'}")
    finally:
        await db.close()


if __name__ == "__main__":
    asyncio.run(main())
