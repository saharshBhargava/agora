"""Temporary API/database for InventoryLiveTests; never uses the configured app database.

From backend/: AGORA_TEST_DATABASE_URL=postgresql://localhost/postgres \
    uv run python -m tests.support.ios_inventory_server
Then run AgoraTests/InventoryLiveTests in the iOS simulator. Ctrl-C drops the temporary database.
"""

import asyncio
import os
import tempfile
import uuid
from pathlib import Path

import asyncpg
import uvicorn

from app.config import Settings
from app.main import create_app
from app.migrate import migrate


async def main() -> None:
    admin_url = os.environ["AGORA_TEST_DATABASE_URL"]
    base, _, _ = admin_url.rpartition("/")
    name = "agora_ios_test_" + uuid.uuid4().hex[:10]
    admin = await asyncpg.connect(admin_url)
    await admin.execute(f'CREATE DATABASE "{name}"')
    try:
        url = f"{base}/{name}"
        await migrate(url)
        with tempfile.TemporaryDirectory(prefix="agora-ios-media-") as directory:
            settings = Settings(
                _env_file=None, env="test", auth_mode="dev", database_url=url,
                storage_backend="local", storage_dir=Path(directory), vision_provider="replay",
                vision_fallback="none", run_worker_in_process=True, seed_new_users=False,
                gemini_api_key=None, watch_search_api_key=None, watch_search_providers=[], apns_enabled=False,
            )
            print(f"Disposable database: {name}", flush=True)
            server = uvicorn.Server(uvicorn.Config(create_app(settings), host="127.0.0.1", port=18765))
            await server.serve()
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


if __name__ == "__main__":
    asyncio.run(main())
