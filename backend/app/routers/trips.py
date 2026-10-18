"""Durable approvals and device-reported Calendar results; no provider calls."""

import re
from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import AwareDatetime, Field, field_validator, model_validator

from app import idempotency
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import Problem, not_found
from app.routers.account import require_household
from app.schemas import Strict

router = APIRouter(prefix="/v1/trips", tags=["trips"])
ACTIVE = "(status IN ('reserved', 'outcome_unknown') OR (status = 'scheduled' AND ends_at > now()))"
RFC3339 = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)$")


class TripIn(Strict):
    list_id: UUID
    list_updated_at: AwareDatetime
    start: str = Field(max_length=40)
    end: str = Field(max_length=40)
    timezone: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=4000)
    location: str = Field(default="", max_length=500)

    @model_validator(mode="after")
    def validate_window(self):
        try:
            zone = ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError("Use an IANA timezone") from error
        for text in (self.start, self.end):
            if not RFC3339.fullmatch(text):
                raise ValueError("Use RFC3339 timestamps with explicit offsets")
            value = datetime.fromisoformat(text.replace("Z", "+00:00"))
            if value.utcoffset() != value.astimezone(zone).utcoffset():
                raise ValueError("Timestamp offset must agree with timezone")
        if not timedelta(0) < self.ends_at - self.starts_at <= timedelta(hours=4):
            raise ValueError("End must follow start by at most four hours")
        if not self.title.strip():
            raise ValueError("Title cannot be blank")
        return self

    @property
    def starts_at(self) -> datetime:
        return datetime.fromisoformat(self.start.replace("Z", "+00:00"))

    @property
    def ends_at(self) -> datetime:
        return datetime.fromisoformat(self.end.replace("Z", "+00:00"))


class TripOutcome(Strict):
    status: Literal["scheduled", "outcome_unknown", "failed"]
    event_id: str | None = Field(default=None, min_length=1, max_length=1024)
    event_url: str | None = Field(default=None, max_length=2048)

    @field_validator("event_url")
    @classmethod
    def safe_url(cls, value):
        if value is not None and not value.startswith("https://"):
            raise ValueError("Event URL must use HTTPS")
        return value

    @model_validator(mode="after")
    def event_required(self):
        if self.status == "scheduled" and not (self.event_id or "").strip():
            raise ValueError("A confirmed Calendar event ID is required")
        if self.status != "scheduled" and (self.event_id is not None or self.event_url is not None):
            raise ValueError("Only scheduled outcomes may include event details")
        return self


class Trip(Strict):
    id: UUID
    household_id: UUID
    list_id: UUID
    user_id: UUID
    mine: bool
    list_name: str
    start: str
    end: str
    timezone: str
    title: str
    description: str
    location: str
    status: Literal["reserved", "scheduled", "outcome_unknown", "failed"]
    event_id: str | None
    event_url: str | None
    created_at: datetime
    updated_at: datetime


def present(row, user_id: UUID) -> Trip:
    return Trip(**{k: row[k] for k in Trip.model_fields if k not in ("mine", "start", "end")},
                mine=row["user_id"] == user_id, start=row["start_text"], end=row["end_text"])


async def user_lock(conn, user_id: UUID):
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('trips.user'), hashtext($1))", str(user_id))


@router.get("", response_model=list[Trip])
async def get_trips(request: Request, household_id: UUID | None = None, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch("SELECT * FROM replenishment_trips WHERE household_id = $1 ORDER BY created_at DESC",
                                household_id)
        return [present(row, user.user_id) for row in rows]


@router.post("", response_model=Trip, status_code=201)
async def reserve(body: TripIn, request: Request, user: Principal = CurrentUser):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash("trips.reserve", body.model_dump(mode="json"))
    async with request.app.state.db.scoped(user.user_id) as conn:
        await user_lock(conn, user.user_id)
        if (previous := await idempotency.lookup(conn, user.user_id, key, digest)) is not None:
            return JSONResponse(previous, status_code=201, headers={"Idempotent-Replay": "true"})
        # List mutations take the same row lock; different members cannot reserve the same list concurrently.
        lst = await conn.fetchrow("SELECT * FROM shopping_lists WHERE id = $1 FOR UPDATE", body.list_id)
        if lst is None:
            raise not_found("shopping list")
        if await conn.fetchval(f"SELECT 1 FROM replenishment_trips WHERE list_id = $1 AND {ACTIVE}", body.list_id):
            raise Problem(409, "trip_exists", "This list already has a reserved or scheduled trip.")
        if lst["status"] != "open":
            raise Problem(409, "list_closed", "Reopen this shopping list before scheduling a trip.")
        if lst["updated_at"] != body.list_updated_at:
            raise Problem(409, "list_changed", "The list changed. Review its latest contents before scheduling.")
        if not await conn.fetchval("SELECT 1 FROM shopping_list_items WHERE list_id = $1 AND NOT checked",
                                   body.list_id):
            raise Problem(409, "list_empty", "Add an unchecked item before scheduling a trip.")
        now = datetime.now(UTC)
        if not now < body.starts_at <= now + timedelta(days=30) or body.ends_at > now + timedelta(days=30):
            raise Problem(422, "invalid_trip_time", "Choose a future trip ending within 30 days.")
        if await conn.fetchval(f"""SELECT 1 FROM replenishment_trips WHERE user_id = $1 AND {ACTIVE}
                                  AND starts_at < $3 AND ends_at > $2""",
                               user.user_id, body.starts_at, body.ends_at):
            raise Problem(409, "trip_overlap", "Another trip already occupies this time.")
        row = await conn.fetchrow(
            """INSERT INTO replenishment_trips (household_id, list_id, user_id, list_name, list_updated_at,
                 starts_at, ends_at, start_text, end_text, timezone, title, description, location)
               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *""",
            lst["household_id"], body.list_id, user.user_id, lst["name"], body.list_updated_at,
            body.starts_at, body.ends_at, body.start, body.end, body.timezone, body.title,
            body.description, body.location)
        result = present(row, user.user_id).model_dump(mode="json")
        if not await idempotency.claim(conn, user.user_id, key, digest, 201, result):
            raise Problem(409, "duplicate_request", "This request key is already being processed; retry shortly.")
        await audit(conn, "trip.reserved", actor_id=user.user_id, household_id=lst["household_id"],
                    target_type="trip", target_id=row["id"])
        await notify(conn, lst["household_id"], "trip.updated", row["id"])
        return JSONResponse(result, status_code=201)


@router.patch("/{trip_id}/outcome", response_model=Trip)
async def outcome(trip_id: UUID, body: TripOutcome, request: Request, user: Principal = CurrentUser):
    async with request.app.state.db.scoped(user.user_id) as conn:
        await user_lock(conn, user.user_id)
        row = await conn.fetchrow("SELECT * FROM replenishment_trips WHERE id = $1 AND user_id = $2 FOR UPDATE",
                                  trip_id, user.user_id)
        if row is None:
            raise not_found("trip")
        if (row["status"], row["event_id"], row["event_url"]) == (body.status, body.event_id, body.event_url):
            return present(row, user.user_id)
        # reserved → scheduled | outcome_unknown | failed
        # outcome_unknown → scheduled (verified event) | failed (user confirmed absence / release)
        # Terminal scheduled/failed only accept identical replays (handled above).
        allowed = {
            "reserved": {"scheduled", "outcome_unknown", "failed"},
            "outcome_unknown": {"scheduled", "failed"},
        }
        if body.status not in allowed.get(row["status"], set()):
            raise Problem(409, "invalid_trip_transition", "This Calendar outcome cannot be changed to that status.")
        row = await conn.fetchrow(
            """UPDATE replenishment_trips SET status = $2, event_id = $3, event_url = $4, updated_at = now()
               WHERE id = $1 RETURNING *""", trip_id, body.status, body.event_id, body.event_url)
        await audit(conn, "trip.outcome_reported", actor_id=user.user_id, household_id=row["household_id"],
                    target_type="trip", target_id=trip_id, meta={"status": body.status})
        await notify(conn, row["household_id"], "trip.updated", trip_id)
        return present(row, user.user_id)
