"""Shared product imagery with household-private overrides and version-fenced background work."""

import asyncio
import hashlib
import json
import re
from datetime import UTC, datetime, timedelta
from uuid import UUID

import httpx

from app.db import notify
from app.errors import Problem, not_found
from app.image_identity import SEARCH_VERSION, VERIFICATION_VERSION, ImageIdentity
from app.image_research import ImageFetcher, discover, verify_download
from app.jobs import enqueue
from app.price_search import SearchError

TABLES = {
    "inventory": ("inventory_items", "display_name"),
    "wishlist": ("wishlist_items", "title"),
    "list": ("shopping_list_items", "title"),
}


def fallback(name, category=None):
    groups = (
        ("milk", ("milk", "dairy", "yogurt", "cream")),
        ("eggs", ("egg",)),
        ("produce", ("apple", "banana", "fruit", "vegetable", "spinach", "produce", "avocado", "potato")),
        ("bread", ("bread", "bakery", "toast")),
        ("drink", ("water", "juice", "coffee", "tea", "beverage")),
        ("cleaning", ("soap", "detergent", "clean", "sponge", "paper towel")),
        ("cookware", ("pan", "skillet", "pot", "kitchen", "cookware")),
        ("electronics", ("headphone", "speaker", "charger", "electronic", "computer")),
        ("food", ("rice", "pasta", "food", "pantry", "cereal", "bean", "snack", "meat", "fish", "steak")),
    )
    # A specific name wins over a broad category (eggs are often categorized as dairy).
    for text in (name.casefold(), (category or "").casefold()):
        for key, terms in groups:
            if any(re.search(r"\b" + re.escape(term) + r"(?:s|es)?\b", text) for term in terms):
                return key
    return "item"


async def item_context(conn, kind, item_id):
    if kind not in TABLES:
        raise not_found("item")
    table, title = TABLES[kind]
    row = await conn.fetchrow(f"SELECT * FROM {table} WHERE id = $1", item_id)
    if row is None:
        raise not_found("item")
    row = dict(row)
    product = await conn.fetchrow("SELECT * FROM products WHERE id = $1", row.get("product_id"))
    known = None
    if kind == "wishlist":
        criteria = await conn.fetchval("SELECT criteria FROM price_watches WHERE wishlist_item_id=$1", item_id)
        known = (criteria or {}).get("product_url")
    binding = await conn.fetchrow(
        "SELECT product_identity,identity_item_name FROM item_images WHERE kind=$1 AND item_id=$2", kind, item_id
    )
    explicit = bool(binding and binding["product_identity"] and binding["identity_item_name"] == row[title])
    details = binding["product_identity"] if explicit else {"name": row[title]}
    if not explicit and product and product["source"] != "seed":
        # Catalog identity can help, but a catalog image URL alone is never verification.
        details = {**details, "brand": product["brand"], "gtin": product["gtin"]}
        if product["size_value"] and product["size_unit"]:
            details["size"] = f"{product['size_value']} {product['size_unit']}"
    try:
        identity = ImageIdentity.model_validate(details)
    except ValueError:
        identity = ImageIdentity(name=row[title])
    return {
        "identity": identity,
        "explicit_identity": explicit,
        "kind": kind,
        "item_id": item_id,
        "household_id": row["household_id"],
        "name": row[title],
        "category": row.get("category") or (product["category"] if product else None),
        "inventory_item_id": row.get("inventory_item_id"),
        "known_url": known,
        "catalog_url": product["image_url"] if product else None,
    }


async def descriptor(conn, kind, item_id, *, inherit=True):
    context = await item_context(conn, kind, item_id)
    state = await conn.fetchrow("SELECT * FROM item_images WHERE kind=$1 AND item_id=$2", kind, item_id)
    if (
        inherit
        and context["inventory_item_id"]
        and not context["explicit_identity"]
        and not (state and state["user_selected"])
    ):
        result = await descriptor(conn, "inventory", context["inventory_item_id"], inherit=False)
        return {**result, "inherited": True}
    asset = await conn.fetchrow("SELECT * FROM item_image_assets WHERE id=$1", state["asset_id"]) if state else None
    # Old/rolled-back workers may still write legacy assets. Fail closed on every read.
    if asset and asset["match_kind"] == "product" and not state["user_selected"] and not exact_asset(asset):
        asset = None
    choices = []
    if state:
        choices = [
            asset_info(a)
            for a in await conn.fetch(
                "SELECT * FROM item_image_assets WHERE id=ANY($1) ORDER BY created_at,id", state["candidates"]
            )
            if a["match_kind"] != "product" or candidate_asset(a)
        ]
    fallback_name = fallback(context["name"], context["category"])
    effective_identity = context["identity"]
    if asset and exact_asset(asset) and not state["user_selected"]:
        effective_identity = ImageIdentity.model_validate(asset["verification"]["requested"])
    match_status = (
        "user_confirmed"
        if asset and state["user_selected"]
        else "exact"
        if asset and exact_asset(asset)
        else "demo"
        if asset and asset["match_kind"] == "representative"
        else "needs_confirmation"
        if choices
        else "unresolved"
    )
    return {
        "match_status": match_status,
        "identity": effective_identity.model_dump(exclude_none=True),
        "missing_identity": effective_identity.missing(),
        "unresolved_reason": (
            "choose_variant"
            if choices
            else "search_pending"
            if state and state["status"] == "queued"
            else (state["last_error"] if state and state["last_error"] else "no_verified_match")
        )
        if match_status in ("unresolved", "needs_confirmation")
        else None,
        "display_path": asset_info(asset)["path"] if asset else None,
        "status": (state["status"] if state and (asset or state["status"] != "ready") else "fallback"),
        "fallback": fallback_name,
        "asset": asset_info(asset) if asset else None,
        "choices": choices,
        "user_selected": bool(state and state["user_selected"]),
        "inherited": False,
        "version": state["version"] if state else 0,
    }


def candidate_asset(asset):
    evidence = asset["verification"] or {}
    return evidence.get("version") == VERIFICATION_VERSION and evidence.get("status") in ("exact", "candidate")


def exact_asset(asset):
    evidence = asset["verification"] or {}
    return evidence.get("version") == VERIFICATION_VERSION and evidence.get("status") == "exact"


def asset_info(asset):
    return {
        "id": str(asset["id"]),
        "path": f"v1/item-images/assets/{asset['id']}",
        "source_url": asset["source_url"],
        "attribution": asset["attribution"],
        "match_kind": asset["match_kind"],
        "verification": asset["verification"],
        "title": (asset["verification"] or {}).get("title")
        or (asset["verification"] or {}).get("observed", {}).get("name"),
    }


class ItemImageService:
    def __init__(self, db, provider, fetcher=None):
        self.db, self.provider = db, provider
        self.fetcher = fetcher or ImageFetcher()
        self.handlers = {"image.resolve": self.resolve}

    async def start(self):
        # A previous release's worker may consume a new job kind during deployment/rollback.
        # Repair queued bindings at boot without rerunning successful or user-selected images.
        async with self.db.system() as conn:
            await conn.execute("SELECT pg_advisory_xact_lock(hashtext('images.start'))")
            await conn.execute("""INSERT INTO jobs(kind,payload,max_attempts)
                SELECT 'image.resolve',jsonb_build_object('kind',i.kind,'item_id',i.item_id,'version',i.version),2
                FROM item_images i WHERE i.status='queued' AND NOT i.user_selected
                  AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.kind='image.resolve'
                    AND j.status IN ('queued','running') AND j.payload->>'item_id'=i.item_id::text
                    AND j.payload->>'kind'=i.kind AND j.payload->>'version'=i.version::text)""")

    async def resolve(self, payload, attempt):
        kind, item_id, version = payload["kind"], UUID(payload["item_id"]), payload["version"]
        async with self.db.system() as conn:
            state = await conn.fetchrow("SELECT * FROM item_images WHERE kind=$1 AND item_id=$2", kind, item_id)
            if not state or state["version"] != version or state["user_selected"] or state["status"] != "queued":
                return
            try:
                context = await item_context(conn, kind, item_id)
            except Problem:
                return
            is_demo = await conn.fetchval(
                """SELECT EXISTS(SELECT 1 FROM household_members m JOIN users u
                ON u.id=m.user_id WHERE m.household_id=$1 AND u.is_demo)""",
                context["household_id"],
            )
            identity = hashlib.sha256(
                json.dumps(
                    [VERIFICATION_VERSION, SEARCH_VERSION, context["identity"].model_dump(), context["known_url"]],
                    ensure_ascii=True,
                ).encode()
            ).hexdigest()
            cached = await conn.fetch(
                """SELECT id FROM item_image_assets WHERE identity_key=$1
                AND household_id IS NULL AND created_at > $2
                AND verification->>'version'='2' AND verification->>'status' IN ('exact','candidate')
                ORDER BY created_at DESC LIMIT 3""",
                identity,
                datetime.now(UTC) - timedelta(days=90),
            )
        if (context["inventory_item_id"] and not context["explicit_identity"]) or is_demo:
            await self.finish(kind, item_id, version, [], None)
            return
        if cached and not payload.get("refresh"):
            await self.finish(kind, item_id, version, [r["id"] for r in cached], None)
            return
        async with self.db.system() as conn:
            claimed = await conn.fetchval(
                """INSERT INTO item_image_lookups(identity_key,lease_until,retry_after)
                VALUES($1,now()+interval '2 minutes',now()+interval '7 days')
                ON CONFLICT(identity_key) DO UPDATE SET lease_until=EXCLUDED.lease_until,
                retry_after=EXCLUDED.retry_after,finished=false
                WHERE item_image_lookups.retry_after < now() OR ($2 AND item_image_lookups.finished)
                   OR (NOT item_image_lookups.finished AND item_image_lookups.lease_until < now())
                RETURNING identity_key""",
                identity,
                bool(payload.get("refresh")),
            )
            lookup = await conn.fetchrow("SELECT * FROM item_image_lookups WHERE identity_key=$1", identity)
            if not claimed and not lookup["finished"] and payload.get("deferrals", 0) < 3:
                await enqueue(
                    conn,
                    "image.resolve",
                    {**payload, "deferrals": payload.get("deferrals", 0) + 1},
                    run_at=datetime.now(UTC) + timedelta(seconds=120),
                    max_attempts=2,
                )
                return
        if not claimed:
            await self.finish(kind, item_id, version, [], None)
            return
        ids, error = [], None
        try:
            async with asyncio.timeout(90):
                candidates = await discover(
                    self.provider, context["identity"].query(), context["known_url"], identity=context["identity"]
                )
                downloads = 0
                # Failed downloads consume the same three-download budget as valid images.
                for candidate in candidates:
                    if not candidate_asset(candidate):
                        continue
                    data = candidate.get("data")
                    if data is None:
                        if downloads >= 3:
                            break
                        downloads += 1
                        try:
                            data = await self.fetcher.fetch(candidate["image_url"])
                        except (SearchError, Problem, httpx.HTTPError):
                            continue
                    if not await verify_download(self.provider, candidate, data):
                        continue
                    async with self.db.system() as conn:
                        # Revalidate before storing. A stale job cannot publish a changed item's result.
                        current = await conn.fetchrow(
                            "SELECT * FROM item_images WHERE kind=$1 AND item_id=$2", kind, item_id
                        )
                        if not current or current["version"] != version or current["user_selected"]:
                            await conn.execute(
                                "UPDATE item_image_lookups SET finished=true WHERE identity_key=$1", identity
                            )
                            return
                        asset_id = await conn.fetchval(
                            """INSERT INTO item_image_assets
                            (identity_key,data,source_url,original_url,attribution,match_kind,verification)
                            VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id""",
                            identity,
                            data,
                            candidate["source_url"],
                            candidate["image_url"],
                            "Product image from source website",
                            candidate["match_kind"],
                            candidate["verification"],
                        )
                        ids.append(asset_id)
        except (SearchError, Problem, httpx.HTTPError, TimeoutError, ValueError, TypeError, KeyError):
            error = "image_discovery_unavailable"
        async with self.db.system() as conn:
            await conn.execute("UPDATE item_image_lookups SET finished=true WHERE identity_key=$1", identity)
        await self.finish(kind, item_id, version, ids, error)

    async def finish(self, kind, item_id, version, ids, error):
        async with self.db.system() as conn:
            selected = await conn.fetchval(
                """SELECT id FROM item_image_assets
                WHERE id=ANY($1::uuid[]) AND verification->>'version'='2' AND verification->>'status'='exact'
                ORDER BY array_position($1::uuid[],id) LIMIT 1""",
                ids,
            )
            household = await conn.fetchval(
                """UPDATE item_images SET status=$4,asset_id=$5,candidates=$6,
                last_error=$7,updated_at=now() WHERE kind=$1 AND item_id=$2 AND version=$3 AND NOT user_selected
                RETURNING household_id""",
                kind,
                item_id,
                version,
                "ready" if selected else "fallback",
                selected,
                ids,
                error,
            )
            if household:
                await notify(conn, household, "image.updated", item_id)


async def seed_demo_images(db, user_id):
    """Idempotent sample imagery, never presented as merchant or user photography."""
    from app.image_art import representative_png

    async with db.system() as conn:
        household = await conn.fetchval("SELECT household_id FROM household_members WHERE user_id=$1", user_id)
        rows = await conn.fetch(
            """SELECT i.* FROM item_images i WHERE household_id=$1
            AND NOT user_selected AND asset_id IS NULL""",
            household,
        )
        for row in rows:
            context = await item_context(conn, row["kind"], row["item_id"])
            key = fallback(context["name"], context["category"])
            asset_id = await conn.fetchval(
                """INSERT INTO item_image_assets
                (household_id,data,attribution,match_kind) VALUES($1,$2,$3,'representative') RETURNING id""",
                household,
                representative_png(key),
                "Agora sample illustration",
            )
            await conn.execute(
                """UPDATE item_images SET asset_id=$3,status='ready',version=version+1,
                candidates=ARRAY[$3::uuid],updated_at=now() WHERE kind=$1 AND item_id=$2""",
                row["kind"],
                row["item_id"],
                asset_id,
            )
