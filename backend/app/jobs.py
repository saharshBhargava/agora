"""Postgres-backed job queue: no Redis, and enqueueing joins the caller's transaction, so a job exists iff the
work that created it committed."""

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any

import asyncpg

from app.db import Database

log = logging.getLogger("agora.jobs")
LEASE = "5 minutes"


class PermanentJobError(Exception):
    """Raise from a handler to fail a job immediately instead of retrying."""


Handler = Callable[[dict[str, Any], int], Awaitable[None]]  # (payload, attempt)


async def enqueue(conn: asyncpg.Connection, kind: str, payload: dict[str, Any], *,
                  run_at: datetime | None = None, max_attempts: int = 5) -> None:
    await conn.execute(
        "INSERT INTO jobs (kind, payload, run_at, max_attempts) VALUES ($1, $2, coalesce($3, now()), $4)",
        kind, payload, run_at, max_attempts)
    await conn.execute("SELECT pg_notify('agora_jobs', $1)", kind)


class Worker:
    def __init__(self, db: Database, handlers: dict[str, Handler], concurrency: int = 2):
        self.db, self.handlers, self.concurrency = db, handlers, concurrency
        self._wake = asyncio.Event()
        self._stop = asyncio.Event()

    async def claim(self) -> asyncpg.Record | None:
        async with self.db.system() as conn:
            return await conn.fetchrow(
                f"""UPDATE jobs SET status = 'running', attempts = attempts + 1,
                                    locked_until = now() + interval '{LEASE}'
                    WHERE id = (SELECT id FROM jobs
                                WHERE (status = 'queued' AND run_at <= now())
                                   OR (status = 'running' AND locked_until < now())
                                ORDER BY run_at FOR UPDATE SKIP LOCKED LIMIT 1)
                    RETURNING id, kind, payload, attempts, max_attempts""")

    async def run_one(self) -> bool:
        job = await self.claim()
        if job is None:
            return False
        handler = self.handlers.get(job["kind"])
        try:
            if handler is None:
                raise PermanentJobError(f"no handler for {job['kind']}")
            await handler(job["payload"], job["attempts"])
        except Exception as error:  # noqa: BLE001 - every failure is recorded on the job
            permanent = isinstance(error, PermanentJobError) or job["attempts"] >= job["max_attempts"]
            code = type(error).__name__ if not isinstance(error, PermanentJobError) else str(error)[:200]
            log.warning("job.failed id=%s kind=%s attempt=%s permanent=%s error=%s",
                        job["id"], job["kind"], job["attempts"], permanent, code)
            async with self.db.system() as conn:
                if permanent:
                    await conn.execute("UPDATE jobs SET status = 'failed', last_error = $2, finished_at = now(), "
                                       "locked_until = NULL WHERE id = $1", job["id"], code)
                else:
                    backoff = min(5 * 2 ** (job["attempts"] - 1), 300)
                    await conn.execute(
                        "UPDATE jobs SET status = 'queued', last_error = $2, locked_until = NULL, "
                        "run_at = now() + make_interval(secs => $3) WHERE id = $1", job["id"], code, backoff)
            return True
        async with self.db.system() as conn:
            await conn.execute("UPDATE jobs SET status = 'done', finished_at = now(), locked_until = NULL "
                               "WHERE id = $1", job["id"])
        return True

    async def drain(self) -> int:
        """Run jobs until none are ready. Used by tests and the seed script."""
        count = 0
        while await self.run_one():
            count += 1
        return count

    async def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                if await self.run_one():
                    continue
            except Exception:  # noqa: BLE001 - e.g. database briefly unreachable; keep the worker alive
                log.exception("worker.loop_error")
            self._wake.clear()
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=2.0)
            except TimeoutError:
                pass

    async def run(self) -> None:
        def wake(*_: Any) -> None:
            self._wake.set()

        async with self.db.raw() as listener:
            await listener.add_listener("agora_jobs", wake)
            try:
                await asyncio.gather(*(self._loop() for _ in range(self.concurrency)))
            finally:
                await listener.remove_listener("agora_jobs", wake)

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
