"""Minimal SQL-file migration runner.

Files in ``migrations/`` run in name order, each in its own transaction, under an advisory lock so concurrent
deploys can't race. ``*.timescale.sql`` files run only when TimescaleDB can be enabled. They are not recorded
when skipped, so they apply automatically once the database gains the extension.
"""

import asyncio
import hashlib
import logging
from pathlib import Path

import asyncpg

from app.config import get_settings

log = logging.getLogger("agora.migrate")
MIGRATIONS = Path(__file__).resolve().parent.parent / "migrations"
LOCK_ID = 0x4A6F7261  # arbitrary, constant


async def enable_timescale(conn: asyncpg.Connection) -> bool:
    try:
        async with conn.transaction():
            await conn.execute("CREATE EXTENSION IF NOT EXISTS timescaledb")
        return True
    except asyncpg.PostgresError as error:
        log.warning("timescaledb unavailable, using plain Postgres: %s", error.__class__.__name__)
        return False


def checksum(sql: str) -> str:
    # Hash lines, not raw bytes, so a Windows (CRLF) checkout and a Linux container agree.
    return hashlib.sha256("\n".join(sql.splitlines()).encode()).hexdigest()


async def migrate(dsn: str) -> list[str]:
    conn = await asyncpg.connect(dsn)
    applied: list[str] = []
    try:
        await conn.execute("SELECT pg_advisory_lock($1)", LOCK_ID)
        await conn.execute(
            """CREATE TABLE IF NOT EXISTS schema_migrations (
                 name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"""
        )
        done = {r["name"]: r["checksum"] for r in await conn.fetch("SELECT name, checksum FROM schema_migrations")}
        timescale = await enable_timescale(conn)
        for path in sorted(MIGRATIONS.glob("*.sql")):
            sql = path.read_text(encoding="utf-8")
            digest = checksum(sql)
            if path.name in done:
                if done[path.name] != digest:
                    raise RuntimeError(f"{path.name} changed after it was applied; add a new migration instead")
                continue
            if path.name.endswith(".timescale.sql") and not timescale:
                log.info("skipping %s (no timescaledb)", path.name)
                continue
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute("INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)",
                                   path.name, digest)
            applied.append(path.name)
            log.info("applied %s", path.name)
    finally:
        await conn.execute("SELECT pg_advisory_unlock($1)", LOCK_ID)
        await conn.close()
    return applied


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    asyncio.run(migrate(get_settings().database_url.get_secret_value()))


if __name__ == "__main__":
    main()
