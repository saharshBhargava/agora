"""Private notification inbox and APNs device registration."""

from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Query, Request
from pydantic import Field, field_validator

from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.errors import not_found
from app.notifications import apns_available
from app.routers.account import require_household
from app.schemas import Strict

router = APIRouter(prefix="/v1", tags=["notifications"])


class NotificationOut(Strict):
    id: UUID
    household_id: UUID
    watch_id: UUID
    match_id: UUID
    title: str
    body: str
    created_at: datetime
    read_at: datetime | None


class PushDeviceIn(Strict):
    token: str = Field(min_length=32, max_length=512)
    environment: Literal["sandbox", "production"]

    @field_validator("token")
    @classmethod
    def valid_token(cls, value: str) -> str:
        value = value.strip()
        if len(value) % 2 or any(c not in "0123456789abcdefABCDEF" for c in value):
            raise ValueError("must be an even-length hexadecimal APNs device token")
        return value.lower()


class PushDeviceOut(Strict):
    id: UUID
    environment: Literal["sandbox", "production"]
    delivery_status: Literal["available", "unavailable"]


class NotificationReadOut(Strict):
    id: UUID
    read_at: datetime


def _delivery_status(settings) -> str:
    return "available" if apns_available(settings) else "unavailable"


@router.get("/notifications", response_model=list[NotificationOut])
async def list_notifications(request: Request, household_id: UUID | None = None,
                             unread_only: bool = False, limit: int = Query(default=100, ge=1, le=200),
                             user: Principal = CurrentUser) -> list[NotificationOut]:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch(
            """SELECT id, household_id, watch_id, match_id, title, body, created_at, read_at
               FROM notifications WHERE household_id = $1 AND user_id = $2
                 AND ($3::boolean IS FALSE OR read_at IS NULL)
               ORDER BY created_at DESC, id LIMIT $4""",
            household_id, user.user_id, unread_only, limit)
    return [NotificationOut(**dict(row)) for row in rows]


@router.post("/notifications/{notification_id}/read", response_model=NotificationReadOut)
async def mark_notification_read(notification_id: UUID, request: Request,
                                 user: Principal = CurrentUser) -> NotificationReadOut:
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(
            """UPDATE notifications SET read_at = coalesce(read_at, now())
               WHERE id = $1 AND user_id = $2 RETURNING id, household_id, read_at""",
            notification_id, user.user_id)
        if row is None:
            raise not_found("notification")
        await audit(conn, "notification.read", actor_id=user.user_id, household_id=row["household_id"],
                    target_type="notification", target_id=row["id"])
        await notify(conn, row["household_id"], "notification.updated", row["id"])
    return NotificationReadOut(id=row["id"], read_at=row["read_at"])


@router.post("/push-devices", response_model=PushDeviceOut)
async def register_push_device(body: PushDeviceIn, request: Request,
                               user: Principal = CurrentUser) -> PushDeviceOut:
    """Register an APNs token without returning it; same-user registration is idempotent."""
    db = request.app.state.db
    async with db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, None, user.user_id)
        # The narrowly scoped function derives ownership from app_user_id() and transfers an installation token
        # when the account changes. The token never leaves this request or appears in the response.
        row = await conn.fetchrow(
            "SELECT id, environment FROM register_push_device($1, $2)", body.token, body.environment)
        await audit(conn, "push_device.registered", actor_id=user.user_id, household_id=household_id,
                    target_type="push_device", target_id=row["id"], meta={"environment": body.environment})
        await notify(conn, household_id, "push_device.updated", row["id"])
    return PushDeviceOut(id=row["id"], environment=row["environment"],
                         delivery_status=_delivery_status(request.app.state.settings))


@router.delete("/push-devices/{device_id}", status_code=204)
async def delete_push_device(device_id: UUID, request: Request, user: Principal = CurrentUser) -> None:
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, None, user.user_id)
        deleted = await conn.fetchrow(
            "DELETE FROM push_devices WHERE id = $1 AND user_id = $2 RETURNING id",
            device_id, user.user_id)
        if deleted is None:
            raise not_found("push device")
        await audit(conn, "push_device.deleted", actor_id=user.user_id, household_id=household_id,
                    target_type="push_device", target_id=deleted["id"])
        await notify(conn, household_id, "push_device.updated", deleted["id"])
