import asyncio
import base64
import binascii
import time
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Request, Response
from pydantic import Field, model_validator

from app import idempotency
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import Problem, not_found
from app.image_art import representative_png
from app.image_identity import ImageIdentity
from app.image_research import thumbnail
from app.item_images import descriptor, item_context
from app.jobs import enqueue
from app.price_search import SearchError
from app.schemas import Strict

router = APIRouter(prefix="/v1/item-images", tags=["item images"])
Kind = Literal["inventory", "wishlist", "list"]


class ImageSelection(Strict):
    mode: Literal["photo", "candidate", "representative", "automatic"]
    photo: str | None = Field(default=None, max_length=6_700_000)
    asset_id: UUID | None = None
    identity: ImageIdentity | None = None

    @model_validator(mode="after")
    def fields_for_mode(self):
        if (self.mode == "photo") != (self.photo is not None):
            raise ValueError("photo is required only in photo mode")
        if (self.mode == "candidate") != (self.asset_id is not None):
            raise ValueError("asset_id is required only in candidate mode")
        if self.identity is not None and self.mode != "automatic":
            raise ValueError("identity is accepted only in automatic mode")
        return self


@router.get("/fallback/{name}")
async def fallback_image(name: str):
    if name not in {"milk", "eggs", "produce", "bread", "drink", "cleaning", "cookware", "electronics", "food", "item"}:
        raise not_found("illustration")
    return Response(
        representative_png(name), media_type="image/png", headers={"Cache-Control": "public, max-age=86400"}
    )


@router.get("/assets/{asset_id}")
async def image_asset(asset_id: UUID, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        asset = await conn.fetchrow("SELECT data,attribution FROM item_image_assets WHERE id=$1", asset_id)
        if asset is None:
            raise not_found("image")
    # Authentication is rechecked even for cached private images; the native store owns its memory cache.
    return Response(
        asset["data"],
        media_type="image/png" if asset["data"].startswith(b"\x89PNG") else "image/jpeg",
        headers={"Cache-Control": "private, no-store"},
    )


@router.get("/{kind}/{item_id}")
async def get_image(kind: Kind, item_id: UUID, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await descriptor(conn, kind, item_id)


@router.put("/{kind}/{item_id}")
async def select_image(
    kind: Kind, item_id: UUID, body: ImageSelection, request: Request, user: Principal = CurrentUser
):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash(f"image.{kind}.{item_id}", body.model_dump(mode="json"))
    async with request.app.state.db.scoped(user.user_id) as conn:
        await item_context(conn, kind, item_id)  # Authorize before decoding or processing any photo.
        previous = await idempotency.lookup(conn, user.user_id, key, digest)
        if previous is not None:
            return previous
    data = None
    if body.photo:
        try:
            raw = base64.b64decode(body.photo, validate=True)
            if len(raw) > 5_000_000:
                raise ValueError()
            data = await asyncio.to_thread(thumbnail, raw)
        except (ValueError, binascii.Error, SearchError):
            raise Problem(422, "invalid_image", "Choose a JPEG, PNG or WebP photo under 5 MB.") from None
    async with request.app.state.db.scoped(user.user_id) as conn:
        await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", f"image:{user.user_id}:{key}")
        previous = await idempotency.lookup(conn, user.user_id, key, digest)
        if previous is not None:
            return previous
        context = await item_context(conn, kind, item_id)
        state = await conn.fetchrow("SELECT * FROM item_images WHERE kind=$1 AND item_id=$2 FOR UPDATE", kind, item_id)
        asset_id = None
        if body.mode == "candidate":
            # Include inherited choices, but never accept an arbitrary global/private asset ID.
            available = await descriptor(conn, kind, item_id)
            allowed = {UUID(c["id"]) for c in available["choices"]}
            if body.asset_id not in allowed:
                raise Problem(422, "unknown_image_candidate", "Choose one of this item’s suggested images.")
            asset_id = body.asset_id
        elif data:
            asset_id = await conn.fetchval(
                """INSERT INTO item_image_assets(household_id,data,match_kind,attribution)
                VALUES($1,$2,'photo','Your household photo') RETURNING id""",
                context["household_id"],
                data,
            )
        identity_changed = body.identity is not None and (
            body.identity.model_dump(exclude_none=True) != state["product_identity"]
            or context["name"] != state["identity_item_name"]
        )
        if (
            body.mode == "automatic"
            and state
            and not identity_changed
            and not state["user_selected"]
            and state["updated_at"].timestamp() > time.time() - 60
        ):
            raise Problem(429, "image_cooldown", "Wait a minute before searching again.")
        if body.identity is not None:
            await conn.execute(
                """UPDATE item_images SET product_identity=$3,identity_item_name=$4,
                               candidates='{}' WHERE kind=$1 AND item_id=$2""",
                kind,
                item_id,
                body.identity.model_dump(exclude_none=True),
                context["name"],
            )
        version = await conn.fetchval(
            """UPDATE item_images SET version=version+1,user_selected=$3,
            asset_id=$4,status=$5,last_error=NULL,updated_at=now() WHERE kind=$1 AND item_id=$2 RETURNING version""",
            kind,
            item_id,
            body.mode != "automatic",
            asset_id,
            "queued" if body.mode == "automatic" else ("ready" if asset_id else "fallback"),
        )
        if body.mode == "automatic":
            await enqueue(
                conn,
                "image.resolve",
                {"kind": kind, "item_id": str(item_id), "version": version, "refresh": True},
                max_attempts=2,
            )
        await audit(
            conn,
            "image.selected",
            actor_id=user.user_id,
            household_id=context["household_id"],
            target_type=kind,
            target_id=item_id,
            meta={"mode": body.mode},
        )
        await notify(conn, context["household_id"], "image.updated", item_id)
        result = await descriptor(conn, kind, item_id)
        await idempotency.claim(conn, user.user_id, key, digest, 200, result)
        return result
