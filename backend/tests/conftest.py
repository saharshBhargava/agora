import io
import json
import os
import uuid
from pathlib import Path

import asyncpg
import httpx
import pytest
from PIL import Image, ImageDraw

from app.config import Settings
from app.main import create_app
from app.media import sanitize_image, sha256
from app.migrate import migrate

ADMIN_URL = os.environ.get("AGORA_TEST_DATABASE_URL")


def _with_db(url: str, name: str) -> str:
    base, _, _ = url.rpartition("/")
    return f"{base}/{name}"


@pytest.fixture(scope="session")
async def database_url():
    if not ADMIN_URL:
        pytest.skip("set AGORA_TEST_DATABASE_URL to run database tests")
    name = f"agora_test_{uuid.uuid4().hex[:8]}"
    admin = await asyncpg.connect(ADMIN_URL)
    await admin.execute(f'CREATE DATABASE "{name}"')
    url = _with_db(ADMIN_URL, name)
    try:
        await migrate(url)
        yield url
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


@pytest.fixture(scope="session")
def replay_dir(tmp_path_factory) -> Path:
    return tmp_path_factory.mktemp("replay")


@pytest.fixture(scope="session")
async def app(database_url, replay_dir, tmp_path_factory):
    settings = Settings(env="test", database_url=database_url, storage_dir=tmp_path_factory.mktemp("media"),
                        replay_dir=replay_dir, vision_provider="replay", vision_fallback="none",
                        run_worker_in_process=False, watch_search_api_key=None,
                        gemini_api_key=None, watch_search_providers=[], apns_enabled=False)
    application = create_app(settings)
    async with application.router.lifespan_context(application):
        yield application


@pytest.fixture(scope="session")
async def client(app):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def login(client: httpx.AsyncClient, handle: str) -> dict[str, str]:
    response = await client.post("/v1/dev/login", json={"handle": handle})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def fridge_photo(seed: int = 0) -> bytes:
    """A synthetic 'photo' with EXIF attached, unique per seed so each gets its own fixture."""
    img = Image.new("RGB", (640, 480), (230 - seed % 50, 235, 240))
    draw = ImageDraw.Draw(img)
    draw.rectangle((80 + seed, 100, 200, 380), fill=(250, 250, 250))
    draw.rectangle((300, 200, 420 + seed, 300), fill=(240, 200, 60))
    exif = Image.Exif()
    exif[0x010F] = "SecretPhoneMaker"  # Make
    out = io.BytesIO()
    img.save(out, format="JPEG", exif=exif)
    return out.getvalue()


def write_fixture(replay_dir: Path, photo: bytes, items: list[dict], max_side: int = 1600) -> None:
    digest = sha256(sanitize_image(photo, max_side))
    (replay_dir / f"{digest}.json").write_text(json.dumps({"items": items}), encoding="utf-8")


MILK = {"name": "2% milk", "brand": "Darigold", "category": "dairy", "count": 2, "fill_fraction": 0.5,
        "box": [100, 120, 300, 700], "confidence": 0.93}
EGGS = {"name": "large eggs", "brand": None, "category": "dairy", "count": 9, "fill_fraction": None,
        "box": [400, 300, 700, 500], "confidence": 0.9}
MYSTERY = {"name": "unlabeled jar", "brand": None, "category": "other", "count": 1, "fill_fraction": None,
           "box": None, "confidence": 0.41}
