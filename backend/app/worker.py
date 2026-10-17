"""Standalone worker process: ``python -m app.worker``. Use with AGORA_RUN_WORKER_IN_PROCESS=false on the API."""

import asyncio
import logging
import signal

import httpx

from app.config import get_settings
from app.db import Database
from app.jobs import Worker
from app.main import build_pipeline

log = logging.getLogger("agora.worker")


async def main() -> None:
    settings = get_settings()
    db = Database(settings.database_url.get_secret_value(), 1, settings.worker_concurrency + 2,
                  pgbouncer=settings.db_pgbouncer)
    await db.connect()
    async with httpx.AsyncClient(follow_redirects=False) as client:
        worker = Worker(db, build_pipeline(settings, db, client).handlers, settings.worker_concurrency)
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, worker.stop)
            except NotImplementedError:  # Windows
                pass
        log.info("worker started concurrency=%s", settings.worker_concurrency)
        try:
            await worker.run()
        finally:
            await db.close()


if __name__ == "__main__":
    asyncio.run(main())
