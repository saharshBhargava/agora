"""Credential-free integrations, authorized solely by the server-owned is_demo flag."""

from fastapi import APIRouter, Query, Request

from app import idempotency
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.demo_account import is_demo_user
from app.errors import Problem, not_found
from app.routers.account import require_household
from app.routers.calendar import EventIn, TimeWindow

router = APIRouter(prefix="/v1/demo", tags=["demo"])


async def require_demo(conn, user_id):
    if not await is_demo_user(conn, user_id):
        raise Problem(403, "integration_unavailable", "This account uses its configured integrations.")


@router.get("/profile")
async def profile(request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_demo(conn, user.user_id)
        row = await conn.fetchrow("SELECT id, display_name FROM users WHERE id = $1", user.user_id)
        return dict(row)


@router.get("/calendar/events")
async def events(request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_demo(conn, user.user_id)
        rows = await conn.fetch(
            """SELECT id, title, description, location, starts_at AS start, ends_at AS end, timezone
               FROM calendar_events WHERE user_id = $1 ORDER BY starts_at DESC LIMIT 100""", user.user_id)
        return [dict(row) for row in rows]


@router.post("/calendar/freebusy")
async def freebusy(body: TimeWindow, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_demo(conn, user.user_id)
        rows = await conn.fetch(
            """SELECT greatest(starts_at, $2) AS start, least(ends_at, $3) AS end
               FROM calendar_events WHERE user_id = $1 AND starts_at < $3 AND ends_at > $2
               ORDER BY starts_at""", user.user_id, body.start, body.end)
        await audit(conn, "calendar.availability_checked", actor_id=user.user_id)
        return {"busy": [dict(row) for row in rows], "timezone": body.timezone}


@router.get("/calendar/events/by-request")
async def event_by_request(request: Request, key: str = Query(min_length=8, max_length=128),
                           user: Principal = CurrentUser):
    """Read-only recovery by the original Calendar request key, never by event title/time."""
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_demo(conn, user.user_id)
        row = await conn.fetchrow(
            "SELECT operation, status_code, response FROM idempotency_keys WHERE user_id = $1 AND key = $2",
            user.user_id, key)
        if row is None:
            raise not_found("Calendar request")
        if row["operation"] != "calendar.event":
            raise Problem(409, "idempotency_key_reused", "This key belongs to a different request.")
        response = row["response"]
        if row["status_code"] != 201 or response.get("created") is not True or not await conn.fetchval(
                "SELECT 1 FROM calendar_events WHERE user_id = $1 AND id::text = $2",
                user.user_id, response.get("id")):
            raise Problem(409, "outcome_unknown", "The original Calendar event could not be verified.")
        return {"created": True, "id": response["id"]}


@router.post("/calendar/events", status_code=201)
async def create_event(body: EventIn, request: Request, user: Principal = CurrentUser):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("calendar.event", body.model_dump(mode="json"))
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_demo(conn, user.user_id)
        if not body.confirmed:
            raise Problem(409, "confirmation_required", "Approve the event before adding it.")
        household_id = await require_household(conn, None, user.user_id)
        await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", f"{user.user_id}:{key}")
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return previous
        event_id = await conn.fetchval(
            """INSERT INTO calendar_events (user_id, household_id, title, description, location,
                 starts_at, ends_at, timezone) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id""",
            user.user_id, household_id, body.title, body.description, body.location,
            body.start, body.end, body.timezone)
        result = {"created": True, "id": str(event_id)}
        if not await idempotency.claim(conn, user.user_id, key, digest, 201, result, operation="calendar.event"):
            raise Problem(409, "duplicate_request", "This request key is already being processed; retry shortly.")
        await audit(conn, "calendar.event_created", actor_id=user.user_id, household_id=household_id,
                    target_type="calendar_event", target_id=event_id)
        await notify(conn, household_id, "calendar.updated", event_id)
        return result
