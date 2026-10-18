"""Merchant lookups shared by the routers. Connections are user-scoped, so row-level security already limits
visibility to global merchants plus the user's own households' merchants."""

from uuid import UUID

import asyncpg

from app.errors import not_found
from app.schemas import MerchantRef

# Select list for a merchant joined as "m"; pair with ref(row, "m_").
MERCHANT_REF = "m.id AS m_id, m.name AS m_name, m.locality AS m_locality, m.household_id IS NULL AS m_is_global"


async def require_merchant(conn: asyncpg.Connection, merchant_id: UUID, household_id: UUID) -> None:
    """A merchant can be attached to a household's data only if it is global or belongs to that household.
    Merchants from the user's *other* households are refused too, so data never crosses households."""
    if not await conn.fetchval(
            "SELECT 1 FROM merchants WHERE id = $1 AND (household_id IS NULL OR household_id = $2)",
            merchant_id, household_id):
        raise not_found("merchant")


def ref(row: asyncpg.Record | None, prefix: str = "") -> MerchantRef | None:
    if row is None or row[f"{prefix}id"] is None:
        return None
    return MerchantRef(id=row[f"{prefix}id"], name=row[f"{prefix}name"], locality=row[f"{prefix}locality"],
                       scope="global" if row[f"{prefix}is_global"] else "household")
