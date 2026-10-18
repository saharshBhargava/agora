from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request

from app.auth import CurrentUser, Principal, ensure_user, mint_dev_token
from app.db import audit
from app.errors import Problem, not_found
from app.schemas import DevLoginIn, Household, Location, LocationIn, Me, Settings, SettingsPatch, TokenOut

router = APIRouter(prefix="/v1", tags=["account"])


async def load_households(conn: asyncpg.Connection, user_id: UUID) -> list[Household]:
    rows = await conn.fetch(
        """SELECT h.id, h.name, m.role,
                  coalesce(json_agg(json_build_object('id', l.id, 'name', l.name, 'kind', l.kind)
                           ORDER BY l.created_at) FILTER (WHERE l.id IS NOT NULL), '[]') AS locations
           FROM households h JOIN household_members m ON m.household_id = h.id AND m.user_id = $1
           LEFT JOIN storage_locations l ON l.household_id = h.id
           GROUP BY h.id, h.name, m.role, m.joined_at ORDER BY m.joined_at""", user_id)
    return [Household(id=r["id"], name=r["name"], role=r["role"],
                      locations=[Location(**loc) for loc in r["locations"]]) for r in rows]


async def require_household(conn: asyncpg.Connection, household_id: UUID | None, user_id: UUID) -> UUID:
    """Resolve the household for a request. RLS already hides foreign households; this turns that into a 404."""
    if household_id is None:
        household_id = await conn.fetchval(
            "SELECT household_id FROM household_members WHERE user_id = $1 ORDER BY joined_at LIMIT 1", user_id)
    elif not await conn.fetchval("SELECT 1 FROM households WHERE id = $1", household_id):
        household_id = None
    if household_id is None:
        raise not_found("household")
    return household_id


@router.post("/dev/login", response_model=TokenOut, tags=["dev"])
async def dev_login(body: DevLoginIn, request: Request) -> TokenOut:
    """Development and demo sign-in. Disabled entirely when a real identity provider is configured."""
    settings = request.app.state.settings
    if not settings.dev_login_enabled:
        raise not_found()
    if settings.env == "demo" and body.handle not in settings.demo_handles:
        raise Problem(403, "demo_user_only", "This demo only allows the seeded accounts.")
    subject = f"dev:{body.handle}"
    await ensure_user(request.app.state.db, subject, body.handle, body.display_name or body.handle.title())
    token, exp = mint_dev_token(settings, subject)
    return TokenOut(access_token=token, expires_at=exp)


@router.get("/me", response_model=Me)
async def me(request: Request, user: Principal = CurrentUser) -> Me:
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await conn.fetchrow(
            """SELECT u.id, u.handle, u.display_name, s.timezone, s.autonomy_level, s.household_size,
                      s.media_retention
               FROM users u JOIN user_settings s ON s.user_id = u.id WHERE u.id = $1""", user.user_id)
        households = await load_households(conn, user.user_id)
    return Me(id=row["id"], handle=row["handle"], display_name=row["display_name"],
              settings=Settings(**{k: row[k] for k in Settings.model_fields}), households=households)


@router.patch("/me/settings", response_model=Settings)
async def update_settings(body: SettingsPatch, request: Request, user: Principal = CurrentUser) -> Settings:
    changes = body.model_dump(exclude_none=True)
    async with request.app.state.db.scoped(user.user_id) as conn:
        if "timezone" in changes and not await conn.fetchval(
                "SELECT 1 FROM pg_timezone_names WHERE name = $1", changes["timezone"]):
            raise Problem(422, "invalid_timezone", "Unknown time zone.")
        if changes:
            columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(changes, start=2))  # names are fixed
            await conn.execute(f"UPDATE user_settings SET {columns}, updated_at = now() WHERE user_id = $1",
                               user.user_id, *changes.values())
            await audit(conn, "settings.updated", actor_id=user.user_id, target_type="user", target_id=user.user_id,
                        meta={"fields": sorted(changes)})
        row = await conn.fetchrow("SELECT * FROM user_settings WHERE user_id = $1", user.user_id)
    return Settings(**{k: row[k] for k in Settings.model_fields})


@router.get("/households", response_model=list[Household])
async def households(request: Request, user: Principal = CurrentUser) -> list[Household]:
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await load_households(conn, user.user_id)


@router.post("/households/{household_id}/locations", response_model=Location, status_code=201)
async def add_location(household_id: UUID, body: LocationIn, request: Request,
                       user: Principal = CurrentUser) -> Location:
    async with request.app.state.db.scoped(user.user_id) as conn:
        await require_household(conn, household_id, user.user_id)
        try:
            row = await conn.fetchrow(
                "INSERT INTO storage_locations (household_id, name, kind) VALUES ($1, $2, $3) RETURNING id, name, kind",
                household_id, body.name, body.kind)
        except asyncpg.UniqueViolationError as error:
            raise Problem(409, "location_exists", "A location with that name already exists.") from error
    return Location(**dict(row))
