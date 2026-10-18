"""Scan processing: frames → vision → merged detections → matches → review or auto-commit → retention."""

import logging
from datetime import timedelta
from typing import Any
from uuid import UUID

import asyncpg

from app import media
from app.config import Settings
from app.core.detections import auto_accept, merge_frames
from app.db import Database, audit, notify
from app.errors import Problem
from app.inventory_ops import commit_scan, match, sync_purchase_origins
from app.jobs import PermanentJobError, enqueue
from app.storage import Storage
from app.vision.base import VisionError
from app.vision.service import VisionService

log = logging.getLogger("agora.pipeline")

RETENTION = {"delete_after_review": timedelta(0), "24h": timedelta(hours=24), "7d": timedelta(days=7)}
FAILED_SCAN_RETENTION = timedelta(hours=24)


def frame_key(household_id: UUID, scan_id: UUID, index: int) -> str:
    return f"households/{household_id}/scans/{scan_id}/frame_{index:02d}.jpg"


def video_key(household_id: UUID, scan_id: UUID) -> str:
    return f"households/{household_id}/scans/{scan_id}/raw_video"


class Pipeline:
    def __init__(self, settings: Settings, db: Database, storage: Storage, vision: VisionService):
        self.settings, self.db, self.storage, self.vision = settings, db, storage, vision

    @property
    def handlers(self) -> dict[str, Any]:
        return {"scan.process": self.process_scan, "media.purge": self.purge_media}

    async def _fail(self, scan_id: UUID, user_id: UUID, household_id: UUID, code: str) -> None:
        async with self.db.scoped(user_id) as conn:
            await conn.execute("UPDATE scans SET status = 'failed', error_code = $2, processed_at = now() "
                               "WHERE id = $1", scan_id, code)
            await enqueue(conn, "media.purge", {"scan_id": str(scan_id)},
                          run_at=await conn.fetchval("SELECT now() + $1::interval", FAILED_SCAN_RETENTION))
            await audit(conn, "scan.failed", actor_type="system", household_id=household_id, target_type="scan",
                        target_id=scan_id, meta={"error": code})
            await notify(conn, household_id, "scan.updated", scan_id)

    async def _ensure_frames(self, scan: asyncpg.Record) -> tuple[list[str], list[str]]:
        """For video scans, extract and sanitize keyframes once, then delete the original video."""
        if scan["frame_keys"]:
            return list(scan["frame_keys"]), list(scan["frame_hashes"])
        if not scan["raw_video_key"]:
            raise PermanentJobError("scan_has_no_media")
        video = await self.storage.get(scan["raw_video_key"])
        frames = [media.sanitize_image(f, self.settings.max_image_side)
                  for f in await media.extract_frames(video, self.settings.max_frames)]
        keys = [frame_key(scan["household_id"], scan["id"], i) for i in range(len(frames))]
        for key, frame in zip(keys, frames, strict=True):
            await self.storage.put(key, frame, "image/jpeg")
        hashes = [media.sha256(f) for f in frames]
        async with self.db.scoped(scan["user_id"]) as conn:
            await conn.execute("UPDATE scans SET frame_keys = $2, frame_hashes = $3, raw_video_key = NULL "
                               "WHERE id = $1", scan["id"], keys, hashes)
        await self.storage.delete(scan["raw_video_key"])
        return keys, hashes

    async def process_scan(self, payload: dict[str, Any], attempt: int) -> None:
        scan_id, user_id = UUID(payload["scan_id"]), UUID(payload["user_id"])
        # The worker runs as the scan's owner, so row-level security bounds it exactly like an API request.
        async with self.db.scoped(user_id) as conn:
            scan = await conn.fetchrow(
                "UPDATE scans SET status = 'processing' WHERE id = $1 AND status IN ('uploaded', 'processing') "
                "RETURNING *", scan_id)
            if scan is None:
                return  # already processed, deleted, or not visible to this user
            await notify(conn, scan["household_id"], "scan.updated", scan_id)
        household_id = scan["household_id"]

        try:
            keys, digests = await self._ensure_frames(scan)
        except Problem as error:
            await self._fail(scan_id, user_id, household_id, error.code)
            return
        frames = [await self.storage.get(k) for k in keys]

        async with self.db.scoped(user_id) as conn:
            cached = await self.vision.lookup(conn, household_id, digests)
        try:
            run = await self.vision.detect(frames, cached)  # no transaction held during provider calls
        except VisionError as error:
            if error.retryable and attempt < 3:
                raise
            await self._fail(scan_id, user_id, household_id, error.code)
            return

        merged = merge_frames(run.frames)
        async with self.db.scoped(user_id) as conn:
            await self.vision.store(conn, household_id, digests, run)
            accepted = 0
            for m in merged:
                item_id, product_id, score = await match(conn, household_id, m.label, m.brand)
                auto = auto_accept(m.confidence, score, item_id is not None,
                                   self.settings.auto_accept_confidence, self.settings.auto_accept_match)
                accepted += auto
                await conn.execute(
                    """INSERT INTO scan_detections (scan_id, household_id, label, brand, category, product_id,
                         inventory_item_id, match_score, confidence, count, fill_fraction, quantity, bbox,
                         frame_index, review, auto_accepted)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)""",
                    scan_id, household_id, m.label, m.brand, m.category, product_id, item_id, score, m.confidence,
                    m.count, m.fill_fraction, m.quantity, {"grid": 1000, "box": m.box} if m.box else None,
                    m.frame_index, "accepted" if auto else "proposed", auto)
            await conn.execute(
                "UPDATE scans SET provider = $2, model = $3, latency_ms = $4, processed_at = now(), "
                "status = 'needs_review' WHERE id = $1", scan_id, run.provider, run.model, run.latency_ms)
            await audit(conn, "scan.processed", actor_type="system", household_id=household_id, target_type="scan",
                        target_id=scan_id, meta={"detections": len(merged), "auto_accepted": accepted,
                                                 "provider": run.provider, "latency_ms": run.latency_ms})
            if merged and accepted == len(merged):
                scan = await conn.fetchrow("SELECT * FROM scans WHERE id = $1", scan_id)
                await self.finalize(conn, scan, user_id, actor_type="system")
            else:
                await notify(conn, household_id, "scan.updated", scan_id)

    async def finalize(self, conn: asyncpg.Connection, scan: asyncpg.Record, user_id: UUID, *,
                       actor_type: str = "user") -> int:
        """Commit accepted detections to inventory and schedule raw media deletion per the user's setting."""
        updated = await commit_scan(conn, scan, user_id)
        await conn.execute("UPDATE scans SET status = 'confirmed', confirmed_at = now() WHERE id = $1", scan["id"])
        await sync_purchase_origins(conn, scan["id"], user_id)
        retention = await conn.fetchval("SELECT media_retention FROM user_settings WHERE user_id = $1", user_id)
        delay = RETENTION.get(retention or "delete_after_review", timedelta(0))
        await enqueue(conn, "media.purge", {"scan_id": str(scan["id"])},
                      run_at=await conn.fetchval("SELECT now() + $1::interval", delay))
        await audit(conn, "scan.confirmed", actor_type=actor_type, actor_id=user_id if actor_type == "user" else None,
                    household_id=scan["household_id"], target_type="scan", target_id=scan["id"],
                    meta={"items_updated": updated, "media_retention": retention})
        await notify(conn, scan["household_id"], "scan.updated", scan["id"])
        await notify(conn, scan["household_id"], "inventory.updated", scan["id"])
        return updated

    async def purge_media(self, payload: dict[str, Any], attempt: int) -> None:
        scan_id = UUID(payload["scan_id"])
        async with self.db.system() as conn:
            scan = await conn.fetchrow("SELECT id, household_id, frame_keys, raw_video_key FROM scans "
                                       "WHERE id = $1 AND media_deleted_at IS NULL FOR UPDATE", scan_id)
            if scan is None:
                return
            keys = [*scan["frame_keys"], *([scan["raw_video_key"]] if scan["raw_video_key"] else [])]
            for key in keys:
                await self.storage.delete(key)
            await conn.execute("UPDATE scans SET media_deleted_at = now(), frame_keys = '{}', raw_video_key = NULL "
                               "WHERE id = $1", scan_id)
            await audit(conn, "media.deleted", actor_type="system", household_id=scan["household_id"],
                        target_type="scan", target_id=scan_id, meta={"objects": len(keys)})
