from datetime import UTC, date, datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
from fastapi import APIRouter, File, Form, Query, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, Response

from app import idempotency, media
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import Problem, not_found
from app.inventory_ops import match, sync_purchase_origins
from app.jobs import enqueue
from app.merchants import MERCHANT_REF, ref, require_merchant
from app.pipeline import frame_key, video_key
from app.routers.account import require_household
from app.schemas import (
    Detection,
    DetectionPatch,
    ReviewDecision,
    ReviewIn,
    ReviewOut,
    ScanOut,
    ScanPatch,
    plausible_purchase_date,
)

router = APIRouter(prefix="/v1/scans", tags=["scans"])


async def _apply_overrides(conn: asyncpg.Connection, body: DetectionPatch | ReviewDecision, detection_id: UUID,
                           household_id: UUID) -> None:
    """Write per-product store/date overrides for the fields the client actually sent."""
    sent = body.model_fields_set
    if "purchased_from_merchant_id" in sent:
        if body.purchased_from_merchant_id is not None:
            await require_merchant(conn, body.purchased_from_merchant_id, household_id)
        await conn.execute("UPDATE scan_detections SET purchased_from_merchant_id = $2, merchant_override = true "
                           "WHERE id = $1", detection_id, body.purchased_from_merchant_id)
    if "purchased_on" in sent:
        await conn.execute("UPDATE scan_detections SET purchased_on = $2, purchased_on_override = true "
                           "WHERE id = $1", detection_id, body.purchased_on)


async def _read_capped(upload: UploadFile, limit: int) -> bytes:
    data = await upload.read(limit + 1)
    if len(data) > limit:
        raise Problem(413, "file_too_large", f"Each file must be under {limit // (1024 * 1024)} MB.")
    return data


def _r(value: float | None) -> float | None:
    """Model scores are stored as real; round away float noise like 0.9300000071525574."""
    return round(value, 3) if value is not None else None


async def load_scan(conn: asyncpg.Connection, scan_id: UUID) -> ScanOut:
    scan = await conn.fetchrow(
        f"""SELECT s.*, {MERCHANT_REF} FROM scans s
            LEFT JOIN merchants m ON m.id = s.purchased_from_merchant_id WHERE s.id = $1""", scan_id)
    if scan is None:
        raise not_found("scan")
    detections = await conn.fetch(
        f"""SELECT d.*, d.quantity::float8 AS qty, i.display_name AS item_name, e.merchant_id AS effective_merchant,
                   e.purchased_on AS effective_purchased_on, {MERCHANT_REF}
            FROM scan_detections d
            JOIN scans s ON s.id = d.scan_id
            CROSS JOIN LATERAL (SELECT CASE WHEN d.merchant_override THEN d.purchased_from_merchant_id
                                            ELSE s.purchased_from_merchant_id END AS merchant_id,
                                       CASE WHEN d.purchased_on_override THEN d.purchased_on
                                            ELSE s.purchased_on END AS purchased_on) e
            LEFT JOIN merchants m ON m.id = e.merchant_id
            LEFT JOIN inventory_items i ON i.id = d.inventory_item_id
            WHERE d.scan_id = $1 ORDER BY d.confidence DESC, d.label""", scan_id)
    return ScanOut(
        id=scan["id"], household_id=scan["household_id"], location_id=scan["location_id"],
        captured_at=scan["captured_at"], media_kind=scan["media_kind"], frame_count=len(scan["frame_keys"]),
        media_deleted=scan["media_deleted_at"] is not None, status=scan["status"], provider=scan["provider"],
        model=scan["model"], latency_ms=scan["latency_ms"], error_code=scan["error_code"],
        created_at=scan["created_at"], purchased_from_merchant_id=scan["purchased_from_merchant_id"],
        purchased_from=ref(scan, "m_"), purchased_on=scan["purchased_on"],
        detections=[Detection(
            id=d["id"], label=d["label"], brand=d["brand"], category=d["category"], count=d["count"],
            fill_fraction=_r(d["fill_fraction"]), quantity=d["qty"], confidence=_r(d["confidence"]),
            match_score=_r(d["match_score"]), inventory_item_id=d["inventory_item_id"],
            inventory_item_name=d["item_name"],
            product_id=d["product_id"], bbox=d["bbox"], frame_index=d["frame_index"], review=d["review"],
            auto_accepted=d["auto_accepted"], purchased_from_merchant_id=d["effective_merchant"],
            purchased_from=ref(d, "m_"), merchant_override=d["merchant_override"],
            purchased_on=d["effective_purchased_on"], purchased_on_override=d["purchased_on_override"])
            for d in detections])


@router.post("", response_model=ScanOut, status_code=202)
async def create_scan(
    request: Request,
    files: list[UploadFile] = File(..., description="Up to 12 photos, or one MP4/MOV video"),
    household_id: UUID | None = Form(default=None),
    location_id: UUID | None = Form(default=None),
    captured_at: datetime | None = Form(default=None),
    purchased_from_merchant_id: UUID | None = Form(default=None, description="Store these items came from"),
    purchased_on: date | None = Form(default=None, description="Purchase (receipt) date, YYYY-MM-DD"),
    user: Principal = CurrentUser,
) -> JSONResponse:
    """Upload a scan. Returns immediately; processing happens in the background and is pushed over /v1/events."""
    state = request.app.state
    settings, db, storage = state.settings, state.db, state.storage
    key = idempotency.key_from(request)
    # Hash what the client sent, before defaults, so a retry matches its original request.
    digest_fields = (str(household_id), str(location_id), captured_at.isoformat() if captured_at else None,
                     str(purchased_from_merchant_id), str(purchased_on))
    if purchased_on is not None:
        try:
            plausible_purchase_date(purchased_on)
        except ValueError as error:
            raise Problem(422, "invalid_purchased_on", str(error)) from error
    now = datetime.now(UTC)
    captured_at = captured_at or now
    if captured_at.tzinfo is None:
        raise Problem(422, "invalid_captured_at", "captured_at must include a time zone offset.")
    if not now - timedelta(days=30) <= captured_at <= now + timedelta(minutes=5):
        raise Problem(422, "invalid_captured_at", "captured_at must be within the last 30 days.")
    if not 1 <= len(files) <= settings.max_frames:
        raise Problem(422, "invalid_file_count", f"Send between 1 and {settings.max_frames} files.")

    raw = [await _read_capped(f, settings.max_video_bytes) for f in files]
    is_video = len(raw) == 1 and media.looks_like_video(raw[0])
    digest = idempotency.request_hash(*digest_fields, [media.sha256(r) for r in raw])

    async with db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        if location_id and not await conn.fetchval(
                "SELECT 1 FROM storage_locations WHERE id = $1 AND household_id = $2", location_id, household_id):
            raise not_found("location")
        if purchased_from_merchant_id:
            await require_merchant(conn, purchased_from_merchant_id, household_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return JSONResponse(previous, status_code=202, headers={"Idempotent-Replay": "true"})

    scan_id = uuid4()
    if is_video:
        if not media.ffmpeg_available():
            raise Problem(503, "video_unsupported", "Video processing isn't available here; upload photos instead.")
        keys, hashes = [], []
        await storage.put(video_key(household_id, scan_id), raw[0], "application/octet-stream")
    else:
        if any(len(r) > settings.max_image_bytes for r in raw):
            raise Problem(413, "file_too_large", "Each photo must be under 10 MB.")
        frames = [await run_in_threadpool(media.sanitize_image, r, settings.max_image_side) for r in raw]
        keys = [frame_key(household_id, scan_id, i) for i in range(len(frames))]
        hashes = [media.sha256(f) for f in frames]
        for k, f in zip(keys, frames, strict=True):
            await storage.put(k, f, "image/jpeg")

    async with db.scoped(user.user_id) as conn:
        await conn.execute(
            """INSERT INTO scans (id, household_id, user_id, location_id, captured_at, media_kind, frame_keys,
                                  frame_hashes, raw_video_key, purchased_from_merchant_id, purchased_on)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)""",
            scan_id, household_id, user.user_id, location_id, captured_at, "video" if is_video else "photos",
            keys, hashes, video_key(household_id, scan_id) if is_video else None, purchased_from_merchant_id,
            purchased_on)
        scan = await load_scan(conn, scan_id)
        body = scan.model_dump(mode="json")
        if not await idempotency.claim(conn, user.user_id, key, digest, 202, body):
            raise Problem(409, "duplicate_request", "This request is already being processed; retry shortly.")
        await enqueue(conn, "scan.process", {"scan_id": str(scan_id), "user_id": str(user.user_id)})
        await audit(conn, "scan.created", actor_id=user.user_id, household_id=household_id, target_type="scan",
                    target_id=scan_id, meta={"media_kind": scan.media_kind, "files": len(raw)})
        await notify(conn, household_id, "scan.updated", scan_id)
    return JSONResponse(body, status_code=202)


@router.get("", response_model=list[ScanOut])
async def list_scans(request: Request, household_id: UUID | None = None,
                     limit: int = Query(default=20, ge=1, le=100), user: Principal = CurrentUser) -> list[ScanOut]:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        ids = await conn.fetch("SELECT id FROM scans WHERE household_id = $1 ORDER BY captured_at DESC LIMIT $2",
                               household_id, limit)
        return [await load_scan(conn, r["id"]) for r in ids]


@router.get("/{scan_id}", response_model=ScanOut)
async def get_scan(scan_id: UUID, request: Request, user: Principal = CurrentUser) -> ScanOut:
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await load_scan(conn, scan_id)


@router.get("/{scan_id}/frames/{index}", responses={200: {"content": {"image/jpeg": {}}}})
async def get_frame(scan_id: UUID, index: int, request: Request, user: Principal = CurrentUser) -> Response:
    """Serve a sanitized frame for the review screen. Authorized per request, never cached."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        scan = await conn.fetchrow("SELECT frame_keys, media_deleted_at FROM scans WHERE id = $1", scan_id)
    if scan is None:
        raise not_found("scan")
    if scan["media_deleted_at"] is not None:
        raise Problem(410, "media_deleted", "Photos from this scan were deleted under your retention setting.")
    if not 0 <= index < len(scan["frame_keys"]):
        raise not_found("frame")
    data = await request.app.state.storage.get(scan["frame_keys"][index])
    return Response(data, media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


@router.post("/{scan_id}/review", response_model=ReviewOut)
async def review_scan(scan_id: UUID, body: ReviewIn, request: Request, user: Principal = CurrentUser) -> ReviewOut:
    """Accept, correct or reject what the model saw. Only accepted and corrected detections reach inventory."""
    state = request.app.state
    async with state.db.scoped(user.user_id) as conn:
        scan = await conn.fetchrow("SELECT * FROM scans WHERE id = $1 FOR UPDATE", scan_id)
        if scan is None:
            raise not_found("scan")
        if scan["status"] != "needs_review":
            raise Problem(409, "not_reviewable", f"Scan is {scan['status']}, not waiting for review.")
        household_id = scan["household_id"]
        known = {r["id"]: r for r in await conn.fetch("SELECT * FROM scan_detections WHERE scan_id = $1", scan_id)}
        counts = {"accept": 0, "reject": 0, "correct": 0}
        decided: set[UUID] = set()
        for decision in body.decisions:
            detection = known.get(decision.detection_id)
            if detection is None or decision.detection_id in decided:
                raise Problem(422, "unknown_detection", "A decision refers to a detection not in this scan.")
            decided.add(decision.detection_id)
            counts[decision.action] += 1
            if decision.action != "reject":
                await _apply_overrides(conn, decision, decision.detection_id, household_id)
            if decision.action != "correct":
                await conn.execute("UPDATE scan_detections SET review = $2 WHERE id = $1", decision.detection_id,
                                   "accepted" if decision.action == "accept" else "rejected")
                continue
            label = (decision.label or detection["label"]).strip().lower()
            item_id, product_id = detection["inventory_item_id"], detection["product_id"]
            if decision.inventory_item_id is not None:
                if not await conn.fetchval("SELECT 1 FROM inventory_items WHERE id = $1 AND household_id = $2",
                                           decision.inventory_item_id, household_id):
                    raise not_found("inventory item")
                item_id = decision.inventory_item_id
            elif decision.label is not None:
                item_id, product_id, _ = await match(conn, household_id, label, detection["brand"])
            await conn.execute(
                """UPDATE scan_detections SET review = 'corrected', label = $2, quantity = $3,
                          inventory_item_id = $4, product_id = $5 WHERE id = $1""",
                decision.detection_id, label,
                decision.quantity if decision.quantity is not None else detection["quantity"], item_id, product_id)
        remaining = "accepted" if body.remaining == "accept" else "rejected"
        await conn.execute("UPDATE scan_detections SET review = $2 WHERE scan_id = $1 AND review = 'proposed'",
                           scan_id, remaining)
        await audit(conn, "scan.reviewed", actor_id=user.user_id, household_id=household_id, target_type="scan",
                    target_id=scan_id, meta={**counts, "remaining": remaining})
        updated = await state.pipeline.finalize(conn, scan, user.user_id)
        return ReviewOut(scan=await load_scan(conn, scan_id), items_updated=updated)


@router.patch("/{scan_id}", response_model=ScanOut)
async def update_scan(scan_id: UUID, body: ScanPatch, request: Request, user: Principal = CurrentUser) -> ScanOut:
    """Change or clear the store and/or purchase date for a whole upload, before or after review. Products with
    their own override keep it; everything else follows, including purchase history for confirmed scans."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        scan = await conn.fetchrow("SELECT id, household_id, status FROM scans WHERE id = $1 FOR UPDATE", scan_id)
        if scan is None:
            raise not_found("scan")
        sent = body.model_fields_set
        if "purchased_from_merchant_id" in sent:
            if body.purchased_from_merchant_id is not None:
                await require_merchant(conn, body.purchased_from_merchant_id, scan["household_id"])
            await conn.execute("UPDATE scans SET purchased_from_merchant_id = $2 WHERE id = $1", scan_id,
                               body.purchased_from_merchant_id)
        if "purchased_on" in sent:
            await conn.execute("UPDATE scans SET purchased_on = $2 WHERE id = $1", scan_id, body.purchased_on)
        if scan["status"] == "confirmed":
            await sync_purchase_origins(conn, scan_id, user.user_id)
        await audit(conn, "scan.purchase_details_changed", actor_id=user.user_id, household_id=scan["household_id"],
                    target_type="scan", target_id=scan_id,
                    meta={"fields": sorted(sent), "cleared": sorted(f for f in sent if getattr(body, f) is None)})
        await notify(conn, scan["household_id"], "scan.updated", scan_id)
        await notify(conn, scan["household_id"], "inventory.updated", scan_id)
        return await load_scan(conn, scan_id)


@router.patch("/{scan_id}/detections/{detection_id}", response_model=ScanOut)
async def update_detection(scan_id: UUID, detection_id: UUID, body: DetectionPatch, request: Request,
                           user: Principal = CurrentUser) -> ScanOut:
    """Set, clear or reset the store and/or purchase date for one product, e.g. when a haul came from two
    stores on different days."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        scan = await conn.fetchrow("SELECT id, household_id, status FROM scans WHERE id = $1 FOR UPDATE", scan_id)
        if scan is None:
            raise not_found("scan")
        if scan["status"] not in ("needs_review", "confirmed"):
            raise Problem(409, "not_editable", f"Scan is {scan['status']}; stores can be set once detections exist.")
        if not await conn.fetchval("SELECT 1 FROM scan_detections WHERE id = $1 AND scan_id = $2",
                                   detection_id, scan_id):
            raise not_found("detection")
        await _apply_overrides(conn, body, detection_id, scan["household_id"])
        if "purchased_from" in body.inherit:
            await conn.execute("UPDATE scan_detections SET purchased_from_merchant_id = NULL, "
                               "merchant_override = false WHERE id = $1", detection_id)
        if "purchased_on" in body.inherit:
            await conn.execute("UPDATE scan_detections SET purchased_on = NULL, purchased_on_override = false "
                               "WHERE id = $1", detection_id)
        if scan["status"] == "confirmed":
            await sync_purchase_origins(conn, scan_id, user.user_id)
        sent = body.model_fields_set - {"inherit"}
        await audit(conn, "scan.detection_purchase_details_changed", actor_id=user.user_id,
                    household_id=scan["household_id"], target_type="scan_detection", target_id=detection_id,
                    meta={"set": sorted(sent), "inherit": sorted(body.inherit),
                          "cleared": sorted(f for f in sent if getattr(body, f) is None)})
        await notify(conn, scan["household_id"], "scan.updated", scan_id)
        await notify(conn, scan["household_id"], "inventory.updated", scan_id)
        return await load_scan(conn, scan_id)
