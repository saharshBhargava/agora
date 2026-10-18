import asyncio
import logging
import time
from dataclasses import dataclass, field
from uuid import UUID

import asyncpg

from app.vision.base import PROMPT_VERSION, RawDetection, VisionError, VisionProvider, parse_items

log = logging.getLogger("agora.vision")


def cache_version(provider: VisionProvider) -> str:
    return getattr(provider, "cache_version", PROMPT_VERSION)


@dataclass
class CachedFrame:
    detections: list[RawDetection]
    provider: str
    model: str


@dataclass
class VisionRun:
    frames: list[list[RawDetection]]
    fresh: dict[int, VisionProvider] = field(default_factory=dict)  # frame index -> provider that answered
    latency_ms: int = 0
    cached_sources: list[tuple[str, str]] = field(default_factory=list)

    @property
    def provider(self) -> str:
        return "+".join(sorted({p.name for p in self.fresh.values()} | {p for p, _ in self.cached_sources})) or "cache"

    @property
    def model(self) -> str:
        models = {p.model for p in self.fresh.values()} | {m for _, m in self.cached_sources}
        return "+".join(sorted(models)) or PROMPT_VERSION


class VisionService:
    """Primary provider with one fallback attempt per frame, plus a per-household result cache.

    The three steps are separate so callers never hold a database transaction open across network calls:
    ``lookup`` (short transaction) → ``detect`` (no transaction) → ``store`` (short transaction).
    """

    def __init__(self, primary: VisionProvider, fallback: VisionProvider | None = None, concurrency: int = 4):
        self.primary, self.fallback = primary, fallback
        self.semaphore = asyncio.Semaphore(concurrency)

    async def lookup(self, conn: asyncpg.Connection, household_id: UUID,
                     digests: list[str]) -> list[CachedFrame | None]:
        providers = [p for p in (self.primary, self.fallback) if p is not None]
        rows = await conn.fetch(
            """SELECT c.frame_sha256, c.result, c.provider, c.model FROM vision_cache c
               JOIN unnest($3::text[], $4::text[], $5::text[]) WITH ORDINALITY
                    AS p(provider, model, prompt_version, priority)
                 ON (c.provider, c.model, c.prompt_version) = (p.provider, p.model, p.prompt_version)
               WHERE c.household_id = $1 AND c.frame_sha256 = ANY($2)
               ORDER BY p.priority""",
            household_id, digests, [p.name for p in providers], [p.model for p in providers],
            [cache_version(p) for p in providers])
        cached = {}
        for row in rows:
            cached.setdefault(row["frame_sha256"],
                              CachedFrame(parse_items(row["result"]), row["provider"], row["model"]))
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

    async def detect(self, frames: list[bytes], cached: list[CachedFrame | None]) -> VisionRun:
        started = time.perf_counter()
        misses = [i for i, c in enumerate(cached) if c is None]
        answers = await asyncio.gather(*(self._one(frames[i]) for i in misses))
        run = VisionRun(frames=[c.detections if c else [] for c in cached],
                        cached_sources=[(c.provider, c.model) for c in cached if c is not None])
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
                household_id, digests[i], provider.name, provider.model, cache_version(provider),
                {"items": [d.to_json() for d in run.frames[i]]})
