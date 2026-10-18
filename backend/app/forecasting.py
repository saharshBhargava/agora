"""Computing and storing run-out forecasts. The math is in ``app.core.forecast``; this module feeds it from the
database and keeps ``consumption_forecasts`` current.

Forecasts are recomputed by the job queue: ``forecast.refresh`` after each confirmed scan or manual reading
(for the items it touched), and ``forecast.nightly`` for every household, since a run-out date moves closer
even when nobody scans. Refresh jobs run as a member of the household, so row-level security bounds them
exactly like an API request.
"""

import logging
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta, tzinfo
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

import asyncpg

from app.core.forecast import (
    DailyLevel,
    Forecast,
    as_of,
    category_prior,
    confidence,
    explain,
    forecast,
    status,
)
from app.db import Database, notify
from app.jobs import enqueue
from app.schemas import ForecastOut
from app.timeseries import daily_levels

log = logging.getLogger("agora.forecasting")

LOOKBACK = timedelta(days=60)  # older history is ignored: habits change
NIGHTLY_HOUR_UTC = 10  # 3am Pacific: after everyone's evening scans, before anyone's morning


async def compute_item(conn: asyncpg.Connection, item: asyncpg.Record, *, household_size: int, now: datetime,
                       timescale: bool) -> Forecast:
    end = now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    series = await daily_levels(conn, item["id"], end - LOOKBACK, end, timescale=timescale)
    latest = await conn.fetchrow(
        """SELECT time, quantity::float8 AS quantity FROM inventory_observations
           WHERE inventory_item_id = $1 AND time <= $2 ORDER BY time DESC LIMIT 1""", item["id"], now)
    return forecast([DailyLevel(day, qty, n) for day, qty, n in series],
                    latest=(latest["time"], latest["quantity"]) if latest else None, now=now,
                    prior=category_prior(item["category"], household_size))


async def store(conn: asyncpg.Connection, household_id: UUID, item_id: UUID, f: Forecast, now: datetime) -> None:
    await conn.execute(
        """INSERT INTO consumption_forecasts (computed_at, household_id, inventory_item_id, method, rate_per_day,
             rate_lo, rate_hi, qty_now, last_observed_at, last_quantity, runout_at, runout_lo, runout_hi, n_obs,
             n_segments, span_days, restock_qty, household_size)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
           ON CONFLICT (inventory_item_id, computed_at) DO NOTHING""",
        now, household_id, item_id, f.method, f.rate_per_day, f.rate_lo, f.rate_hi, f.qty_now, f.last_observed_at,
        f.last_quantity, f.runout_at, f.runout_lo, f.runout_hi, f.n_obs, f.n_segments, f.span_days, f.restock_qty,
        f.household_size)


async def refresh(conn: asyncpg.Connection, household_id: UUID, user_id: UUID, *, timescale: bool,
                  item_ids: list[UUID] | None = None, now: datetime | None = None) -> int:
    """Recompute and store forecasts for a household's active items (or just ``item_ids``). ``conn`` must be
    scoped to ``user_id``. Returns how many forecasts were written."""
    now = now or datetime.now(UTC)
    household_size = await conn.fetchval("SELECT household_size FROM user_settings WHERE user_id = $1", user_id) or 1
    items = await conn.fetch(
        """SELECT id, category FROM inventory_items
           WHERE household_id = $1 AND status = 'active' AND ($2::uuid[] IS NULL OR id = ANY ($2))""",
        household_id, item_ids)
    for item in items:
        f = await compute_item(conn, item, household_size=household_size, now=now, timescale=timescale)
        await store(conn, household_id, item["id"], f, now)
    if items:
        await notify(conn, household_id, "forecast.updated", household_id)
    return len(items)


async def request_refresh(conn: asyncpg.Connection, household_id: UUID, user_id: UUID,
                          item_ids: list[UUID] | None = None) -> None:
    """Queue a recompute in the caller's transaction, so it only happens if the change that prompted it commits."""
    payload: dict[str, Any] = {"household_id": str(household_id), "user_id": str(user_id)}
    if item_ids is not None:
        payload["item_ids"] = sorted({str(i) for i in item_ids})
    await enqueue(conn, "forecast.refresh", payload)


# ---------------------------------------------------------------- reading forecasts back

_COLUMNS = ("method", "rate_per_day", "rate_lo", "rate_hi", "qty_now", "last_observed_at", "last_quantity",
            "runout_at", "runout_lo", "runout_hi", "n_obs", "n_segments", "span_days", "restock_qty",
            "household_size")

_ROUNDING = {"rate_per_day": 4, "rate_lo": 4, "rate_hi": 4, "qty_now": 3, "last_quantity": 3, "restock_qty": 3,
             "span_days": 2}


async def latest(conn: asyncpg.Connection, item_ids: Iterable[UUID]) -> dict[UUID, asyncpg.Record]:
    """The most recent stored forecast per item (one index probe each, via the primary key)."""
    rows = await conn.fetch(
        """SELECT f.* FROM unnest($1::uuid[]) AS i(id)
           CROSS JOIN LATERAL (SELECT * FROM consumption_forecasts
                               WHERE inventory_item_id = i.id ORDER BY computed_at DESC LIMIT 1) f""",
        list(item_ids))
    return {r["inventory_item_id"]: r for r in rows}


def from_row(row: asyncpg.Record) -> Forecast:
    return Forecast(**{k: row[k] for k in _COLUMNS})


async def user_timezone(conn: asyncpg.Connection, user_id: UUID) -> tzinfo:
    name = await conn.fetchval("SELECT timezone FROM user_settings WHERE user_id = $1", user_id)
    try:
        return ZoneInfo(name or "UTC")
    except (KeyError, ValueError):
        return UTC


def to_out(row: asyncpg.Record, name: str, unit: str, now: datetime, tz: tzinfo) -> ForecastOut:
    """API shape for a stored forecast. Status and wording are worked out at read time, so "tomorrow" is
    relative to when you look, in your own time zone."""
    f = as_of(from_row(row), now)
    values = {k: getattr(f, k) for k in _COLUMNS if k != "household_size"}
    for k, digits in _ROUNDING.items():  # the explanation uses full precision; the numbers are for display
        if values[k] is not None:
            values[k] = round(values[k], digits)
    return ForecastOut(computed_at=row["computed_at"], status=status(f, now), confidence=confidence(f),
                       explanation=explain(name, unit, f, now, tz), **values)


def next_nightly(now: datetime) -> datetime:
    run = now.astimezone(UTC).replace(hour=NIGHTLY_HOUR_UTC, minute=0, second=0, microsecond=0)
    return run if run > now else run + timedelta(days=1)


async def schedule_nightly(conn: asyncpg.Connection, run_at: datetime | None) -> bool:
    """Queue the nightly refresh unless one is already queued or running (``run_at`` None = right away).
    Safe to call from every worker on every start. Returns True if it queued a run."""
    queued = await conn.fetchval(
        """INSERT INTO jobs (kind, payload, run_at, max_attempts)
           SELECT 'forecast.nightly', '{}', coalesce($1, now()), 100
           WHERE NOT EXISTS (SELECT 1 FROM jobs WHERE kind = 'forecast.nightly' AND status IN ('queued', 'running'))
           ON CONFLICT (kind) WHERE kind = 'forecast.nightly' AND status = 'queued' DO NOTHING
           RETURNING true""", run_at)
    return bool(queued)


class Forecaster:
    def __init__(self, db: Database):
        self.db = db

    @property
    def handlers(self) -> dict[str, Any]:
        return {"forecast.refresh": self.refresh_job, "forecast.nightly": self.nightly_job}

    async def refresh_job(self, payload: dict[str, Any], attempt: int) -> None:
        household_id, user_id = UUID(payload["household_id"]), UUID(payload["user_id"])
        item_ids = [UUID(i) for i in payload["item_ids"]] if "item_ids" in payload else None
        async with self.db.scoped(user_id) as conn:
            # The user may have left the household since the job was queued; then RLS hides it and we stop here.
            if not await conn.fetchval("SELECT 1 FROM households WHERE id = $1", household_id):
                return
            await refresh(conn, household_id, user_id, timescale=self.db.timescale, item_ids=item_ids)

    async def nightly_job(self, payload: dict[str, Any], attempt: int) -> None:
        """Fan out one refresh per household with active items, then book tomorrow's run. One transaction, so a
        failure retries the whole night rather than leaving the schedule broken."""
        async with self.db.system() as conn:
            households = await conn.fetch(
                """SELECT h.id, (SELECT m.user_id FROM household_members m WHERE m.household_id = h.id
                                 ORDER BY m.role = 'owner' DESC, m.joined_at LIMIT 1) AS user_id
                   FROM households h
                   WHERE EXISTS (SELECT 1 FROM inventory_items i WHERE i.household_id = h.id AND i.status = 'active')
                """)
            for h in households:
                if h["user_id"] is not None:
                    await request_refresh(conn, h["id"], h["user_id"])
            # Booked while this run is still 'running', so the queued-singleton index allows it.
            await conn.execute(
                """INSERT INTO jobs (kind, payload, run_at, max_attempts) VALUES ('forecast.nightly', '{}', $1, 100)
                   ON CONFLICT (kind) WHERE kind = 'forecast.nightly' AND status = 'queued' DO NOTHING""",
                next_nightly(datetime.now(UTC)))
        log.info("forecast.nightly households=%s", len(households))

    async def start(self) -> None:
        """Called when a worker starts: make sure the nightly refresh is on the schedule. A brand-new deployment
        runs it straight away, so existing data gets forecasts without waiting a day."""
        async with self.db.system() as conn:
            never = not await conn.fetchval("SELECT 1 FROM jobs WHERE kind = 'forecast.nightly' LIMIT 1")
            await schedule_nightly(conn, None if never else next_nightly(datetime.now(UTC)))
