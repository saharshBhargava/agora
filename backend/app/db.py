import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

import asyncpg


async def _init_connection(conn: asyncpg.Connection) -> None:
    for name in ("json", "jsonb"):
        await conn.set_type_codec(name, encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


class Database:
    """Connection pool with two ways in.

    ``scoped(user_id)`` is for request work: it opens a transaction, drops to the ``agora_rw`` role and sets
    ``app.user_id``, so Postgres row-level security limits every statement to that user's households.
    ``system()`` keeps the connection's own privileges and is only for bootstrap, the job queue and
    cross-tenant maintenance.
    """

    def __init__(self, dsn: str, min_size: int = 1, max_size: int = 10):
        self.dsn, self.min_size, self.max_size = dsn, min_size, max_size
        self.pool: asyncpg.Pool | None = None
        self.timescale = False

    async def connect(self) -> None:
        self.pool = await asyncpg.create_pool(
            self.dsn, min_size=self.min_size, max_size=self.max_size, init=_init_connection,
            command_timeout=30, server_settings={"application_name": "agora-api"},
        )
        async with self.pool.acquire() as conn:
            self.timescale = bool(await conn.fetchval("SELECT 1 FROM pg_extension WHERE extname = 'timescaledb'"))

    async def close(self) -> None:
        if self.pool:
            await self.pool.close()

    @asynccontextmanager
    async def scoped(self, user_id: UUID) -> AsyncIterator[asyncpg.Connection]:
        assert self.pool is not None
        async with self.pool.acquire() as conn, conn.transaction():
            await conn.execute("SET LOCAL ROLE agora_rw")
            await conn.execute("SELECT set_config('app.user_id', $1, true)", str(user_id))
            yield conn

    @asynccontextmanager
    async def system(self) -> AsyncIterator[asyncpg.Connection]:
        assert self.pool is not None
        async with self.pool.acquire() as conn, conn.transaction():
            yield conn

    @asynccontextmanager
    async def raw(self) -> AsyncIterator[asyncpg.Connection]:
        """A pooled connection with no transaction, for LISTEN and health checks."""
        assert self.pool is not None
        async with self.pool.acquire() as conn:
            yield conn


async def notify(conn: asyncpg.Connection, household_id: UUID, event: str, resource_id: UUID | str) -> None:
    """Publish a change for live sync. Delivered at commit, so subscribers never see uncommitted state."""
    payload = json.dumps({"household_id": str(household_id), "type": event, "id": str(resource_id)})
    await conn.execute("SELECT pg_notify('agora_events', $1)", payload)


async def audit(
    conn: asyncpg.Connection, action: str, *, actor_type: str = "user", actor_id: UUID | None = None,
    household_id: UUID | None = None, target_type: str | None = None, target_id: UUID | str | None = None,
    meta: dict | None = None,
) -> None:
    """Append to the hash-chained audit log. ``meta`` must never contain personal content."""
    await conn.execute(
        """INSERT INTO audit_log (actor_type, actor_id, household_id, action, target_type, target_id, meta,
                                  prev_hash, hash)
           VALUES ($1, $2, $3, $4, $5, $6, $7, '', '')""",
        actor_type, actor_id, household_id, action, target_type,
        str(target_id) if target_id is not None else None, meta or {},
    )
