import asyncio
import logging
import time
from dataclasses import dataclass, field
from uuid import UUID

import asyncpg

from app.vision.base import PROMPT_VERSION, RawDetection, VisionError, VisionProvider, parse_items

log = logging.getLogger("agora.vision")


@dataclass
class VisionRun:
    frames: list[list[RawDetection]]
    fresh: dict[int, VisionProvider] = field(default_factory=dict)  # frame index -> provider that answered
    latency_ms: int = 0

    @property
    def provider(self) -> str:
        return "+".join(sorted({p.name for p in self.fresh.values()})) or "cache"

    @property
    def model(self) -> str:
        return "+".join(sorted({p.model for p in self.fresh.values()})) or PROMPT_VERSION


class VisionService:
    """Primary provider with one fallback attempt per frame, plus a per-household result cache.

    The three steps are separate so callers never hold a database transaction open across network calls:
    ``lookup`` (short transaction) → ``detect`` (no transaction) → ``store`` (short transaction).
    """

    def __init__(self, primary: VisionProvider, fallback: VisionProvider | None = None, concurrency: int = 4):
        self.primary, self.fallback = primary, fallback
        self.semaphore = asyncio.Semaphore(concurrency)

    async def lookup(self, conn: asyncpg.Connection, household_id: UUID,
                     digests: list[str]) -> list[list[RawDetection] | None]:
        providers = [p for p in (self.primary, self.fallback) if p is not None]
        rows = await conn.fetch(
            """SELECT frame_sha256, result FROM vision_cache
               WHERE household_id = $1 AND frame_sha256 = ANY($2) AND prompt_version = $3
                 AND (provider, model) IN (SELECT * FROM unnest($4::text[], $5::text[]))""",
            household_id, digests, PROMPT_VERSION, [p.name for p in providers], [p.model for p in providers])
        cached = {r["frame_sha256"]: parse_items(r["result"]) for r in rows}
        return [cached.get(d) for d in digests]

    async def _one(self, frame: bytes) -> tuple[list[RawDetection], VisionProvider]:
        async with self.semaphore:
            try:
                return await self.primary.detect(frame), self.primary
            except VisionError as error:
                if self.fallback is None:
                    raise
                log.warning("vision.primary_failed code=%s fallback=%s", error.code, self.fallback.name)
                return await self.fallback.detect(frame), self.fallback

    async def detect(self, frames: list[bytes], cached: list[list[RawDetection] | None]) -> VisionRun:
        started = time.perf_counter()
        misses = [i for i, c in enumerate(cached) if c is None]
        answers = await asyncio.gather(*(self._one(frames[i]) for i in misses))
        run = VisionRun(frames=[c or [] for c in cached])
        for i, (detections, provider) in zip(misses, answers, strict=True):
            run.frames[i] = detections
            run.fresh[i] = provider
        run.latency_ms = int((time.perf_counter() - started) * 1000)
        return run

    async def store(self, conn: asyncpg.Connection, household_id: UUID, digests: list[str], run: VisionRun) -> None:
        for i, provider in run.fresh.items():
            await conn.execute(
                """INSERT INTO vision_cache (household_id, frame_sha256, provider, model, prompt_version, result)
                   VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING""",
                household_id, digests[i], provider.name, provider.model, PROMPT_VERSION,
                {"items": [d.to_json() for d in run.frames[i]]})
