"""Disposable API/worker for the native shared-browser fallback integration test."""
import asyncio
import os
import uuid
from contextlib import asynccontextmanager

import asyncpg
import uvicorn

from app.config import Settings
from app.main import create_app
from app.migrate import migrate


async def main():
    admin_url = os.environ['AGORA_TEST_DATABASE_URL']
    base, _, _ = admin_url.rpartition('/')
    name = 'agora_browser_live_' + uuid.uuid4().hex[:10]
    admin = await asyncpg.connect(admin_url)
    await admin.execute(f'CREATE DATABASE "{name}"')
    try:
        url = f'{base}/{name}'
        await migrate(url)
        settings = Settings(_env_file=None, env='test', auth_mode='dev', database_url=url,
                            run_worker_in_process=True, seed_new_users=False, vision_provider='replay',
                            gemini_api_key=None, watch_search_api_key=None, watch_search_providers=[],
                            apns_enabled=False)
        app = create_app(settings)
        lifespan = app.router.lifespan_context

        @asynccontextmanager
        async def fixture_lifespan(application):
            async with lifespan(application):
                provider = application.state.watches.provider
                # Real research controller and worker; only external discovery/page responses are fixtures.
                provider.settings = settings.model_copy(update={'watch_search_providers': ['keenable']})
                provider.router.settings = provider.settings

                async def sources(*args, **kwargs):
                    return [{'url': 'https://retailer.example/console', 'title': 'Xbox Series X'}]

                async def fetch(*args, **kwargs):
                    html = '<main><h1>Xbox Series X</h1><p>Loading price…</p></main>'
                    return 'https://retailer.example/console', html

                provider.search_sources = sources
                provider.fetcher.fetch = fetch
                yield

        app.router.lifespan_context = fixture_lifespan
        await uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=18768)).serve()
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


if __name__ == '__main__':
    asyncio.run(main())
