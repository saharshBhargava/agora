from uuid import UUID

from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from app.auth import CurrentUser, Principal
from app.db import audit
from app.errors import not_found
from app.routers.account import require_household
from app.schemas import Merchant, MerchantCreated, MerchantIn

router = APIRouter(prefix="/v1/merchants", tags=["merchants"])

_COLUMNS = """id, name, locality, kind, is_small_business, website, household_id,
              CASE WHEN household_id IS NULL THEN 'global' ELSE 'household' END AS scope"""


def _merchant(row) -> Merchant:
    return Merchant(**{k: row[k] for k in Merchant.model_fields})


@router.get("", response_model=list[Merchant])
async def search_merchants(request: Request, q: str = Query(default="", max_length=80),
                           household_id: UUID | None = None, limit: int = Query(default=10, ge=1, le=50),
                           user: Principal = CurrentUser) -> list[Merchant]:
    """Search stores by name: exact matches, then prefix matches, then fuzzy ones. Covers the global catalog
    plus stores this household created. An empty ``q`` lists the household's stores, then global ones."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(
            f"""WITH input AS (SELECT agora_normalize_name($1) AS q)
                SELECT {_COLUMNS},
                       CASE WHEN normalized_name = input.q THEN 3
                            WHEN normalized_name LIKE input.q || '%' THEN 2
                            WHEN normalized_name LIKE '%' || input.q || '%' THEN 1 ELSE 0 END AS rank,
                       CASE WHEN input.q = '' THEN 0 ELSE similarity(normalized_name, input.q) END AS score
                FROM merchants, input
                WHERE (household_id IS NULL OR household_id = $2)
                  AND (input.q = '' OR normalized_name LIKE '%' || input.q || '%'
                       OR similarity(normalized_name, input.q) > 0.3)
                ORDER BY rank DESC, score DESC, (household_id IS NULL), name, locality NULLS FIRST
                LIMIT $3""",
            q, household_id, limit)
    return [_merchant(r) for r in rows]


@router.post("", response_model=MerchantCreated, status_code=201,
             responses={200: {"model": MerchantCreated, "description": "A matching merchant already existed"}})
async def create_merchant(body: MerchantIn, request: Request, user: Principal = CurrentUser) -> JSONResponse:
    """Find-or-create a store. If one with the same name and locality (ignoring case and punctuation) is already
    visible, global or in this household, that one is returned with ``created: false`` and status 200. Otherwise
    a household-private store is created (201). Users can never write to the global catalog."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, body.household_id, user.user_id)
        find = f"""SELECT {_COLUMNS} FROM merchants
                   WHERE normalized_name = agora_normalize_name($1)
                     AND normalized_locality = agora_normalize_name($2)
                     AND (household_id IS NULL OR household_id = $3)
                   ORDER BY (household_id IS NULL) DESC LIMIT 1"""
        existing = await conn.fetchrow(find, body.name, body.locality, household_id)
        created = False
        if existing is None:
            new_id = await conn.fetchval(
                """INSERT INTO merchants (name, locality, kind, website, household_id, created_by)
                   VALUES ($1, $2, $3, $4, $5, $6)
                   ON CONFLICT DO NOTHING RETURNING id""",
                body.name.strip(), body.locality.strip() if body.locality else None, body.kind, body.website,
                household_id, user.user_id)
            created = new_id is not None
            existing = await conn.fetchrow(find, body.name, body.locality, household_id)  # also covers a lost race
            if created:
                await audit(conn, "merchant.created", actor_id=user.user_id, household_id=household_id,
                            target_type="merchant", target_id=new_id)
    payload = MerchantCreated(merchant=_merchant(existing), created=created)
    return JSONResponse(payload.model_dump(mode="json"), status_code=201 if created else 200)


@router.get("/{merchant_id}", response_model=Merchant)
async def get_merchant(merchant_id: UUID, request: Request, user: Principal = CurrentUser) -> Merchant:
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(f"SELECT {_COLUMNS} FROM merchants WHERE id = $1", merchant_id)
    if row is None:
        raise not_found("merchant")
    return _merchant(row)
