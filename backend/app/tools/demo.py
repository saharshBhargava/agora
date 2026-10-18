"""Manage the demo account: ``uv run python -m app.tools.demo ensure|reset [--database-url URL]``.

ensure: create and fill it if missing (also runs on every boot via app.seed).
reset:  wipe the demo account's household and recreate it fresh, e.g. after rehearsals and before presenting.
        Only the demo account is touched; real accounts are never read or changed.
"""

import argparse
import asyncio
import os

from app.config import get_settings
from app.db import Database
from app.demo_account import ensure_demo_account, reset_demo_account
from app.migrate import migrate


async def run(action: str, dsn: str) -> None:
    await migrate(dsn)
    settings = get_settings()
    db = Database(dsn)
    await db.connect()
    try:
        user_id = await (reset_demo_account if action == "reset" else ensure_demo_account)(db, settings)
        print(f"demo account {'reset' if action == 'reset' else 'ready'} ({user_id})")
    finally:
        await db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["ensure", "reset"])
    parser.add_argument("--database-url", default=os.environ.get("AGORA_DATABASE_URL"))
    args = parser.parse_args()
    dsn = args.database_url or get_settings().database_url.get_secret_value()
    asyncio.run(run(args.action, dsn))


if __name__ == "__main__":
    main()
