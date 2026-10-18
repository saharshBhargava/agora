"""Isolated API with real jobs for WatchLiveTests. Deletes its own database on shutdown.

AGORA_TEST_DATABASE_URL=postgresql://localhost/postgres uv run python -m tests.support.ios_watch_server
"""
import asyncio
import os
import uuid

import asyncpg
import uvicorn

from app.config import Settings
from app.main import create_app
from app.migrate import migrate


async def main():
    admin_url = os.environ["AGORA_TEST_DATABASE_URL"]
    base, _, _ = admin_url.rpartition("/")
    name = "agora_watch_live_" + uuid.uuid4().hex[:10]
    admin = await asyncpg.connect(admin_url)
    await admin.execute(f'CREATE DATABASE "{name}"')
    try:
        url = f"{base}/{name}"
        await migrate(url)
        settings = Settings(_env_file=None, env="test", auth_mode="dev", database_url=url,
                            vision_provider="replay", vision_fallback="none", run_worker_in_process=True,
                            seed_new_users=False, gemini_api_key=None, watch_search_api_key=None,
                            apns_enabled=False)
        app = create_app(settings)
        # Lifespan creates the worker; /dev/login ensures the isolated designated demo account.
        server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=18767))
        await server.serve()
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


if __name__ == "__main__":
    asyncio.run(main())
