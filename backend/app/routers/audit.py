from fastapi import APIRouter, Query, Request

from app.auth import CurrentUser, Principal
from app.schemas import AuditEntry, AuditVerify

router = APIRouter(prefix="/v1/audit", tags=["trust"])

# Recompute every row's hash from its content and its predecessor's stored hash. Any edited or deleted row shows
# up as the first id where the recomputed hash, or the link to the previous row, stops matching.
VERIFY_SQL = """
WITH chain AS (
  SELECT id, hash, prev_hash, audit_row_hash(prev_hash, a) AS recomputed,
         lag(hash) OVER (ORDER BY id) AS previous
  FROM audit_log a
)
SELECT count(*) AS rows_checked,
       min(id) FILTER (WHERE hash <> recomputed
                          OR prev_hash <> coalesce(previous, repeat('0', 64))) AS first_broken_id
FROM chain
"""


@router.get("", response_model=list[AuditEntry])
async def list_audit(request: Request, limit: int = Query(default=50, ge=1, le=200),
                     user: Principal = CurrentUser) -> list[AuditEntry]:
    """What happened in your households, newest first. Row-level security limits this to your own trail."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        rows = await conn.fetch("SELECT id, time, actor_type, action, target_type, target_id, meta FROM audit_log "
                                "ORDER BY id DESC LIMIT $1", limit)
    return [AuditEntry(**dict(r)) for r in rows]


@router.get("/verify", response_model=AuditVerify)
async def verify(request: Request, user: Principal = CurrentUser) -> AuditVerify:
    """Check the whole chain's integrity. Runs across all rows but returns only counts, never their content."""
    async with request.app.state.db.system() as conn:
        row = await conn.fetchrow(VERIFY_SQL)
    return AuditVerify(ok=row["first_broken_id"] is None, rows_checked=row["rows_checked"],
                       first_broken_id=row["first_broken_id"])
