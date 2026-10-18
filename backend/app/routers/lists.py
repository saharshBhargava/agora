"""Shopping lists: made by hand, or generated per store from upcoming run-outs.

Anything the system or the agent puts on a list carries an explanation (enforced by the schema too), so the
user can always see why it's there. Lists are archived rather than deleted; single lines can be deleted.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request, Response
from fastapi.responses import JSONResponse

from app import idempotency
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import Problem, not_found
from app.merchants import MERCHANT_REF, ref, require_merchant
from app.routers.account import require_household
from app.routers.forecasts import upcoming
from app.schemas import (
    GenerateIn,
    GenerateOut,
    GenerateSkip,
    ListIn,
    ListItemIn,
    ListItemPatch,
    ListPatch,
    ListStatus,
    ShoppingList,
    ShoppingListItem,
)

router = APIRouter(prefix="/v1/lists", tags=["lists"])

DEFAULT_NAME = "Shopping list"
UNASSIGNED_NAME = "Groceries"
MAX_OPEN_LISTS = 50
MAX_ITEMS_PER_LIST = 200
BASIS_TEXT = {"preferred": "Your usual store is {store}.", "last_purchase": "Last bought at {store}."}

_LIST_SELECT = f"""
SELECT l.id, l.household_id, l.name, l.status, l.source, l.created_at, l.updated_at, l.completed_at,
       {MERCHANT_REF}
FROM shopping_lists l LEFT JOIN merchants m ON m.id = l.merchant_id
"""

_ITEM_SELECT = f"""
SELECT li.id, li.list_id, li.title, li.inventory_item_id, li.product_id, li.quantity::float8 AS quantity, li.unit,
       li.note, li.reason, li.added_by, li.explanation, li.merchant_basis, li.needed_by, li.checked, li.checked_at,
       li.created_at, li.updated_at, {MERCHANT_REF}
FROM shopping_list_items li LEFT JOIN merchants m ON m.id = li.merchant_id
"""

_ITEM_FIELDS = [f for f in ShoppingListItem.model_fields if f != "merchant"]


def _store_name(merchant: asyncpg.Record | None) -> str | None:
    if merchant is None or merchant["m_id"] is None:
        return None
    return f"{merchant['m_name']} ({merchant['m_locality']})" if merchant["m_locality"] else merchant["m_name"]


async def _load(conn: asyncpg.Connection, where: str, *args) -> list[ShoppingList]:
    lists = await conn.fetch(_LIST_SELECT + where, *args)
    items: dict[UUID, list[ShoppingListItem]] = {r["id"]: [] for r in lists}
    for r in await conn.fetch(_ITEM_SELECT + """WHERE li.list_id = ANY ($1)
                                               ORDER BY li.checked, li.needed_by NULLS LAST, li.created_at""",
                              list(items)):
        items[r["list_id"]].append(ShoppingListItem(**{k: r[k] for k in _ITEM_FIELDS}, merchant=ref(r, "m_")))
    out = []
    for r in lists:
        lines = items[r["id"]]
        due = [i.needed_by for i in lines if not i.checked and i.needed_by is not None]
        out.append(ShoppingList(id=r["id"], household_id=r["household_id"], name=r["name"], merchant=ref(r, "m_"),
                                status=r["status"], source=r["source"], needed_by=min(due) if due else None,
                                open_count=sum(not i.checked for i in lines), items=lines,
                                created_at=r["created_at"], updated_at=r["updated_at"],
                                completed_at=r["completed_at"]))
    far = datetime.max.replace(tzinfo=UTC)
    return sorted(out, key=lambda sl: (sl.status != "open", sl.needed_by or far, -sl.created_at.timestamp()))


async def _one(conn: asyncpg.Connection, list_id: UUID) -> ShoppingList:
    found = await _load(conn, "WHERE l.id = $1", list_id)
    if not found:
        raise not_found("shopping list")
    return found[0]


async def _locked_list(conn: asyncpg.Connection, list_id: UUID, *, must_be_open: bool = True) -> asyncpg.Record:
    row = await conn.fetchrow("SELECT * FROM shopping_lists WHERE id = $1 FOR UPDATE", list_id)
    if row is None:
        raise not_found("shopping list")
    if must_be_open and row["status"] != "open":
        raise Problem(409, "list_closed", f"This list is {row['status']}. Reopen it to change it.")
    return row


async def _touch(conn: asyncpg.Connection, household_id: UUID, list_id: UUID) -> None:
    await conn.execute("UPDATE shopping_lists SET updated_at = now() WHERE id = $1", list_id)
    await notify(conn, household_id, "list.updated", list_id)


async def _merchant_row(conn: asyncpg.Connection, merchant_id: UUID | None) -> asyncpg.Record | None:
    if merchant_id is None:
        return None
    return await conn.fetchrow(f"SELECT {MERCHANT_REF} FROM merchants m WHERE m.id = $1", merchant_id)


async def _create_list(conn: asyncpg.Connection, household_id: UUID, user_id: UUID, name: str,
                       merchant_id: UUID | None, source: str) -> UUID:
    if await conn.fetchval("SELECT count(*) FROM shopping_lists WHERE household_id = $1 AND status = 'open'",
                           household_id) >= MAX_OPEN_LISTS:
        raise Problem(409, "too_many_lists", "Too many open lists. Finish or archive some first.")
    return await conn.fetchval(
        """INSERT INTO shopping_lists (household_id, name, merchant_id, source, created_by)
           VALUES ($1, $2, $3, $4, $5) RETURNING id""", household_id, name[:80], merchant_id, source, user_id)


# ---------------------------------------------------------------- lists

@router.get("", response_model=list[ShoppingList])
async def list_lists(request: Request, household_id: UUID | None = None,
                     status: list[ListStatus] = Query(default=["open"]), user: Principal = CurrentUser
                     ) -> list[ShoppingList]:
    """The household's lists with their items, open and soonest-needed first. Repeat ``status`` for several.
    At most the 100 most recent lists."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        return await _load(conn, """WHERE l.household_id = $1 AND l.status = ANY ($2)
                                    ORDER BY l.created_at DESC LIMIT 100""", household_id, sorted(set(status)))


@router.post("", response_model=ShoppingList, status_code=201)
async def create_list(body: ListIn, request: Request, user: Principal = CurrentUser) -> ShoppingList:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        if body.merchant_id is not None:
            await require_merchant(conn, body.merchant_id, household_id)
        name = (body.name or "").strip() or _store_name(await _merchant_row(conn, body.merchant_id)) or DEFAULT_NAME
        list_id = await _create_list(conn, household_id, user.user_id, name, body.merchant_id, "user")
        await audit(conn, "list.created", actor_id=user.user_id, household_id=household_id,
                    target_type="shopping_list", target_id=list_id, meta={"source": "user"})
        await notify(conn, household_id, "list.updated", list_id)
        return await _one(conn, list_id)


@router.get("/{list_id}", response_model=ShoppingList)
async def get_list(list_id: UUID, request: Request, user: Principal = CurrentUser) -> ShoppingList:
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await _one(conn, list_id)


@router.patch("/{list_id}", response_model=ShoppingList)
async def update_list(list_id: UUID, body: ListPatch, request: Request, user: Principal = CurrentUser) -> ShoppingList:
    """Rename, change store, or move between open / done / archived."""
    changes = body.model_dump(exclude_unset=True)
    if changes.get("name", "") is None or changes.get("status", "") is None:
        raise Problem(422, "invalid_request", "name and status cannot be null.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked_list(conn, list_id, must_be_open=False)
        if changes.get("merchant_id") is not None:
            await require_merchant(conn, changes["merchant_id"], row["household_id"])
        if "name" in changes:
            changes["name"] = changes["name"].strip()
            if not changes["name"]:
                raise Problem(422, "invalid_request", "name can't be blank.")
        if "status" in changes and changes["status"] != row["status"]:
            if changes["status"] == "open" and await conn.fetchval(
                    "SELECT count(*) FROM shopping_lists WHERE household_id = $1 AND status = 'open'",
                    row["household_id"]) >= MAX_OPEN_LISTS:
                raise Problem(409, "too_many_lists", "Too many open lists. Finish or archive some first.")
            changes["completed_at"] = None if changes["status"] == "open" else (row["completed_at"] or
                                                                                 datetime.now(UTC))
        if changes:
            columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
            await conn.execute(f"UPDATE shopping_lists SET {columns}, updated_at = now() WHERE id = $1",
                               list_id, *changes.values())
            await audit(conn, "list.updated", actor_id=user.user_id, household_id=row["household_id"],
                        target_type="shopping_list", target_id=list_id,
                        meta={"fields": sorted(k for k in changes if k != "completed_at"),
                              **({"status": changes["status"]} if "status" in changes else {})})
            await notify(conn, row["household_id"], "list.updated", list_id)
        return await _one(conn, list_id)


# ---------------------------------------------------------------- items

@router.post("/{list_id}/items", response_model=ShoppingListItem, status_code=201)
async def add_item(list_id: UUID, body: ListItemIn, request: Request, user: Principal = CurrentUser
                   ) -> ShoppingListItem:
    """Add a line. Link an inventory item or product to fill in the title and unit. Agent lines
    (``added_by: "agent"``) must say why, and are audited as the agent."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        lst = await _locked_list(conn, list_id)
        household_id = lst["household_id"]
        title, unit, product_id = body.title.strip() if body.title else None, body.unit, body.product_id
        if body.inventory_item_id is not None:
            inv = await conn.fetchrow("""SELECT display_name, unit, product_id FROM inventory_items
                                         WHERE id = $1 AND household_id = $2""", body.inventory_item_id, household_id)
            if inv is None:
                raise not_found("inventory item")
            title = title or inv["display_name"]
            unit = unit or (inv["unit"] if inv["unit"] != "unit" else None)
            product_id = product_id or inv["product_id"]
        if body.product_id is not None:
            name = await conn.fetchval("SELECT name FROM products WHERE id = $1", body.product_id)
            if name is None:
                raise not_found("product")
            title = title or name
        if await conn.fetchval("SELECT count(*) FROM shopping_list_items WHERE list_id = $1",
                               list_id) >= MAX_ITEMS_PER_LIST:
            raise Problem(409, "list_full", f"A list can hold {MAX_ITEMS_PER_LIST} lines.")
        agent = body.added_by == "agent"
        try:
            async with conn.transaction():
                item_id = await conn.fetchval(
                    """INSERT INTO shopping_list_items (list_id, household_id, title, inventory_item_id, product_id,
                         quantity, unit, note, reason, added_by, explanation, merchant_id, merchant_basis, created_by)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) RETURNING id""",
                    list_id, household_id, title, body.inventory_item_id, product_id, body.quantity, unit, body.note,
                    "agent" if agent else "manual", body.added_by, body.explanation, lst["merchant_id"],
                    "list" if lst["merchant_id"] else None, user.user_id)
        except asyncpg.UniqueViolationError:
            raise Problem(409, "already_on_list", "That item is already on this list.") from None
        await audit(conn, "list.item_added", actor_type="agent" if agent else "user", actor_id=user.user_id,
                    household_id=household_id, target_type="shopping_list", target_id=list_id,
                    meta={"reason": "agent" if agent else "manual", "linked": body.inventory_item_id is not None})
        await _touch(conn, household_id, list_id)
        row = await conn.fetchrow(_ITEM_SELECT + "WHERE li.id = $1", item_id)
    return ShoppingListItem(**{k: row[k] for k in _ITEM_FIELDS}, merchant=ref(row, "m_"))


async def _locked_item(conn: asyncpg.Connection, list_id: UUID, item_id: UUID) -> asyncpg.Record:
    row = await conn.fetchrow("SELECT * FROM shopping_list_items WHERE id = $1 AND list_id = $2 FOR UPDATE",
                              item_id, list_id)
    if row is None:
        raise not_found("list item")
    return row


@router.patch("/{list_id}/items/{item_id}", response_model=ShoppingListItem)
async def update_item(list_id: UUID, item_id: UUID, body: ListItemPatch, request: Request,
                      user: Principal = CurrentUser) -> ShoppingListItem:
    """Edit a line or tick it off (``checked``)."""
    changes = body.model_dump(exclude_unset=True)
    if any(changes.get(name, "") is None for name in ("title", "quantity", "checked")):
        raise Problem(422, "invalid_request", "title, quantity and checked cannot be null.")
    async with request.app.state.db.scoped(user.user_id) as conn:
        lst = await _locked_list(conn, list_id)
        item = await _locked_item(conn, list_id, item_id)
        if "title" in changes:
            changes["title"] = changes["title"].strip()
            if not changes["title"]:
                raise Problem(422, "invalid_request", "title can't be blank.")
        if "checked" in changes and changes["checked"] != item["checked"]:
            changes["checked_at"] = datetime.now(UTC) if changes["checked"] else None
            changes["checked_by"] = user.user_id if changes["checked"] else None
        if changes:
            columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
            try:
                async with conn.transaction():
                    await conn.execute(f"UPDATE shopping_list_items SET {columns}, updated_at = now() WHERE id = $1",
                                       item_id, *changes.values())
            except asyncpg.UniqueViolationError:  # un-ticking a line that was added again meanwhile
                raise Problem(409, "already_on_list", "That item is already on this list, unticked.") from None
            await audit(conn, "list.item_updated", actor_id=user.user_id, household_id=lst["household_id"],
                        target_type="shopping_list", target_id=list_id,
                        meta={"fields": sorted(k for k in changes if k not in ("checked_at", "checked_by"))})
            await _touch(conn, lst["household_id"], list_id)
        row = await conn.fetchrow(_ITEM_SELECT + "WHERE li.id = $1", item_id)
    return ShoppingListItem(**{k: row[k] for k in _ITEM_FIELDS}, merchant=ref(row, "m_"))


@router.delete("/{list_id}/items/{item_id}", status_code=204)
async def delete_item(list_id: UUID, item_id: UUID, request: Request, user: Principal = CurrentUser) -> Response:
    async with request.app.state.db.scoped(user.user_id) as conn:
        lst = await _locked_list(conn, list_id)
        item = await _locked_item(conn, list_id, item_id)
        await conn.execute("DELETE FROM shopping_list_items WHERE id = $1", item_id)
        await audit(conn, "list.item_removed", actor_id=user.user_id, household_id=lst["household_id"],
                    target_type="shopping_list", target_id=list_id, meta={"reason": item["reason"]})
        await _touch(conn, lst["household_id"], list_id)
    return Response(status_code=204)


# ---------------------------------------------------------------- generation

@router.post("/generate", response_model=GenerateOut)
async def generate(body: GenerateIn, request: Request, user: Principal = CurrentUser) -> JSONResponse:
    """Build per-store lists from everything that runs out within ``within_days``.

    Each item goes to its preferred store, else wherever it was last bought, else (if ``include_unassigned``)
    a "Groceries" list. Items already on an open list are skipped, so running this again only adds what's new.
    Lines are added to the store's open generated list if there is one. Requires an ``Idempotency-Key`` header:
    a retry returns the original result instead of generating again.
    """
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("lists.generate", body.model_dump(mode="json"))
    now = datetime.now(UTC)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return JSONResponse(previous, headers={"Idempotent-Replay": "true"})
        # Concurrent generations for one household would otherwise both create the same store's list.
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('lists.generate'), hashtext($1))",
                           str(household_id))
        runouts = await upcoming(conn, household_id, user.user_id, timedelta(days=body.within_days), now)

        skipped: list[GenerateSkip] = []
        by_store: dict[UUID | None, list] = {}
        for r in runouts:
            if r.on_list_id is not None:
                skipped.append(GenerateSkip(inventory_item_id=r.item.id, title=r.item.display_name,
                                            reason="already_on_list", list_id=r.on_list_id))
            elif r.suggested_merchant is None and not body.include_unassigned:
                skipped.append(GenerateSkip(inventory_item_id=r.item.id, title=r.item.display_name,
                                            reason="no_store", list_id=None))
            else:
                by_store.setdefault(r.suggested_merchant.id if r.suggested_merchant else None, []).append(r)

        touched: list[UUID] = []
        added = 0
        for merchant_id, group in by_store.items():
            list_id = await conn.fetchval(
                """SELECT id FROM shopping_lists WHERE household_id = $1 AND status = 'open' AND source = 'generated'
                     AND merchant_id IS NOT DISTINCT FROM $2 ORDER BY created_at DESC LIMIT 1 FOR UPDATE""",
                household_id, merchant_id)
            if list_id is None:
                store = group[0].suggested_merchant
                name = (f"{store.name} ({store.locality})" if store and store.locality else
                        store.name if store else UNASSIGNED_NAME)
                list_id = await _create_list(conn, household_id, user.user_id, name, merchant_id, "generated")
            for r in group:
                store = r.suggested_merchant
                why = r.forecast.explanation
                if store and r.merchant_basis:
                    why += " " + BASIS_TEXT[r.merchant_basis].format(store=store.name)
                await conn.execute(
                    """INSERT INTO shopping_list_items (list_id, household_id, title, inventory_item_id, product_id,
                         quantity, unit, reason, added_by, explanation, merchant_id, merchant_basis, needed_by,
                         created_by)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, 'runout', 'system', $8, $9, $10, $11, $12)""",
                    list_id, household_id, r.item.display_name, r.item.id, r.item.product_id, r.suggested_quantity,
                    r.item.unit if r.item.unit != "unit" else None, why[:500], store.id if store else None,
                    r.merchant_basis, r.forecast.runout_at, user.user_id)
                added += 1
            touched.append(list_id)
            await _touch(conn, household_id, list_id)

        await audit(conn, "list.generated", actor_id=user.user_id, household_id=household_id,
                    target_type="household", target_id=household_id,
                    meta={"within_days": body.within_days, "lists": len(touched), "added": added,
                          "skipped": len(skipped)})
        lists = await _load(conn, "WHERE l.id = ANY ($1)", touched) if touched else []
        result = GenerateOut(lists=lists, added=added, skipped=skipped).model_dump(mode="json")
        if not await idempotency.claim(conn, user.user_id, key, digest, 200, result):
            raise Problem(409, "duplicate_request", "This request is already being processed; retry shortly.")
    return JSONResponse(result)
