"""Time-series queries with two interchangeable implementations.

On TimescaleDB we use hyperfunctions (``time_bucket_gapfill`` + ``locf``). On plain Postgres the same results
come from ``generate_series`` and lateral lookups. Callers never need to know which one ran, and the test suite
checks that both return identical rows.
"""

from datetime import datetime
from uuid import UUID

import asyncpg

_DAILY_TIMESCALE = """
SELECT time_bucket_gapfill('1 day', time, $2::timestamptz, $3::timestamptz) AS day,
       locf(last(quantity, time),
            (SELECT quantity FROM inventory_observations
              WHERE inventory_item_id = $1 AND time < $2 ORDER BY time DESC LIMIT 1)) AS quantity
FROM inventory_observations
WHERE inventory_item_id = $1 AND time >= $2 AND time < $3
GROUP BY day
ORDER BY day
"""

_DAILY_POSTGRES = """
SELECT d.day,
       (SELECT o.quantity FROM inventory_observations o
         WHERE o.inventory_item_id = $1 AND o.time < d.day + interval '1 day'
         ORDER BY o.time DESC LIMIT 1) AS quantity
FROM generate_series(date_bin('1 day', $2::timestamptz, timestamptz '2000-01-01 00:00:00+00'),
                     $3::timestamptz - interval '1 microsecond', interval '1 day') AS d(day)
ORDER BY d.day
"""


async def daily_quantity(conn: asyncpg.Connection, item_id: UUID, start: datetime, end: datetime,
                         *, timescale: bool) -> list[tuple[datetime, float | None]]:
    """Quantity on hand at the end of each UTC day in [start, end), carrying the last value forward."""
    rows = await conn.fetch(_DAILY_TIMESCALE if timescale else _DAILY_POSTGRES, item_id, start, end)
    return [(r["day"], float(r["quantity"]) if r["quantity"] is not None else None) for r in rows]


# Same series plus the number of readings per day, which the forecaster needs to tell real readings from
# carried-forward ones. On Timescale, gapfilled days come back with a NULL count.
_LEVELS_TIMESCALE = """
SELECT time_bucket_gapfill('1 day', time, $2::timestamptz, $3::timestamptz) AS day,
       locf(last(quantity, time),
            (SELECT quantity FROM inventory_observations
              WHERE inventory_item_id = $1 AND time < $2 ORDER BY time DESC LIMIT 1)) AS quantity,
       count(*) AS observations
FROM inventory_observations
WHERE inventory_item_id = $1 AND time >= $2 AND time < $3
GROUP BY day
ORDER BY day
"""

_LEVELS_POSTGRES = """
SELECT d.day,
       (SELECT o.quantity FROM inventory_observations o
         WHERE o.inventory_item_id = $1 AND o.time < d.day + interval '1 day'
         ORDER BY o.time DESC LIMIT 1) AS quantity,
       (SELECT count(*) FROM inventory_observations o
         WHERE o.inventory_item_id = $1 AND o.time >= greatest(d.day, $2::timestamptz)
           AND o.time < least(d.day + interval '1 day', $3::timestamptz)) AS observations
FROM generate_series(date_bin('1 day', $2::timestamptz, timestamptz '2000-01-01 00:00:00+00'),
                     $3::timestamptz - interval '1 microsecond', interval '1 day') AS d(day)
ORDER BY d.day
"""


async def daily_levels(conn: asyncpg.Connection, item_id: UUID, start: datetime, end: datetime,
                       *, timescale: bool) -> list[tuple[datetime, float | None, int]]:
    """Like ``daily_quantity``, with a third column: how many readings were taken that day."""
    rows = await conn.fetch(_LEVELS_TIMESCALE if timescale else _LEVELS_POSTGRES, item_id, start, end)
    return [(r["day"], float(r["quantity"]) if r["quantity"] is not None else None, int(r["observations"] or 0))
            for r in rows]
