"""Export recorded vision results as replay fixtures: ``python -m app.tools.export_replay [--household ID]``.

Run a real scan once against Perceptron or Gemini, export, commit the JSON files, and AGORA_VISION_PROVIDER=replay
will reproduce those results offline. The fixtures contain only detected product labels, never images.
"""

import argparse
import asyncio
import json

import asyncpg

from app.config import get_settings


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--household", help="only export this household's cache")
    args = parser.parse_args()
    settings = get_settings()
    settings.replay_dir.mkdir(parents=True, exist_ok=True)
    conn = await asyncpg.connect(settings.database_url.get_secret_value())
    try:
        rows = await conn.fetch(
            "SELECT DISTINCT ON (frame_sha256) frame_sha256, result::text AS result FROM vision_cache "
            "WHERE provider <> 'replay' AND ($1::uuid IS NULL OR household_id = $1) ORDER BY frame_sha256, created_at",
            args.household)
    finally:
        await conn.close()
    for row in rows:
        path = settings.replay_dir / f"{row['frame_sha256']}.json"
        path.write_text(json.dumps(json.loads(row["result"]), indent=2) + "\n", encoding="utf-8")
    print(f"exported {len(rows)} fixture(s) to {settings.replay_dir}")


if __name__ == "__main__":
    asyncio.run(main())
