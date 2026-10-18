"""Consumption rates and run-out dates from an item's quantity history. Pure functions: no I/O, no clock.

The input is the daily series from ``app.timeseries.daily_levels``: the quantity on hand at the end of each day,
plus how many readings fell on that day. Only days with readings are used for slopes. Carried-forward days are
flat by construction, and counting them would drag every rate towards zero when scans are sparse.

1. **Segment at restocks.** A jump up that's bigger than reading noise starts a new depletion segment.
2. **Rate per segment** is the Theil-Sen slope (median of pairwise slopes). One bad reading can't move it.
3. **Combine segments** with recency weights (half-life ``HALF_LIFE_DAYS``), so a habit change shows up quickly.
4. **Cold start:** blend in a category prior scaled by household size, ``r = (k*r_prior + n*r_obs) / (k + n)``,
   where ``n`` counts the informative readings. The prior fades as history accumulates.
5. **Run-out** = last reading's time + last quantity / rate. The interval comes from the rate interval: the
   quartiles of pairwise slopes within segments, widened by the spread between segments.

Every forecast carries its evidence (readings, days, segments), and ``explain`` turns it into one sentence.
"""

import math
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, tzinfo
from statistics import median
from typing import Literal

Method = Literal["theil_sen", "blended", "prior", "insufficient"]
Status = Literal["out", "runs_out", "steady", "unknown"]
Confidence = Literal["low", "medium", "high"]

HALF_LIFE_DAYS = 14.0  # a segment this old counts half as much as one ending today
PRIOR_WEIGHT = 3.0  # the prior is worth this many readings
FULL_HISTORY = 8  # informative readings after which the prior is dropped entirely
RESTOCK_ABS = 0.25  # a restock jump must exceed this many units...
RESTOCK_REL = 0.15  # ...and this fraction of the larger of the two levels (vision counts are a little noisy)
MAX_HORIZON = timedelta(days=365)  # run-outs further out than this are reported as "not soon"

# Typical use per person per day, in "units" (packages, or pieces for counted items). Deliberately rough: it only
# matters until an item has a few readings of its own.
CATEGORY_PRIORS: dict[str, float] = {
    "dairy": 0.15, "produce": 0.25, "meat": 0.12, "seafood": 0.08, "bakery": 0.12, "beverages": 0.3,
    "pantry": 0.06, "condiments": 0.03, "frozen": 0.06, "snacks": 0.1, "household": 0.04, "personal_care": 0.03,
}
DEFAULT_PRIOR = 0.1


@dataclass(frozen=True)
class DailyLevel:
    day: datetime  # start of the UTC day
    quantity: float | None  # end-of-day level, carried forward from earlier days; None before the first reading
    observations: int  # readings on this day


@dataclass(frozen=True)
class Prior:
    rate_per_day: float
    weight: float = PRIOR_WEIGHT
    category: str | None = None
    household_size: int = 1


@dataclass(frozen=True)
class Segment:
    start: datetime
    end: datetime
    points: int
    rate: float  # units per day, >= 0
    rate_lo: float
    rate_hi: float


@dataclass(frozen=True)
class Forecast:
    method: Method
    rate_per_day: float | None
    rate_lo: float | None
    rate_hi: float | None
    qty_now: float | None
    last_observed_at: datetime | None
    last_quantity: float | None
    runout_at: datetime | None
    runout_lo: datetime | None
    runout_hi: datetime | None
    n_obs: int
    n_segments: int
    span_days: float
    restock_qty: float | None
    household_size: int | None = None
    segments: tuple[Segment, ...] = field(default=(), compare=False)


def category_prior(category: str | None, household_size: int = 1) -> Prior:
    """Cold-start guess for a category, scaled linearly by the number of people in the household."""
    size = min(max(int(household_size or 1), 1), 20)
    base = CATEGORY_PRIORS.get((category or "").strip().lower(), DEFAULT_PRIOR)
    return Prior(rate_per_day=base * size, category=category, household_size=size)


def theil_sen(points: list[tuple[float, float]]) -> tuple[float, float, float]:
    """Median slope over all pairs with distinct x, plus the 25th and 75th percentiles of those slopes.
    Returns (slope, q25, q75). Needs at least two distinct x values."""
    slopes = sorted((y2 - y1) / (x2 - x1)
                    for i, (x1, y1) in enumerate(points) for x2, y2 in points[i + 1:] if x2 != x1)
    if not slopes:
        raise ValueError("need at least two points with different x")
    return median(slopes), _quantile(slopes, 0.25), _quantile(slopes, 0.75)


def _quantile(ordered: list[float], q: float) -> float:
    position = (len(ordered) - 1) * q
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def is_restock(previous: float, current: float) -> bool:
    jump = current - previous
    return jump > RESTOCK_ABS and jump > RESTOCK_REL * max(previous, current)


def segments(levels: list[DailyLevel]) -> tuple[list[list[tuple[datetime, float]]], list[float]]:
    """Split observed days into depletion runs at restocks. Returns (runs, restock jump sizes).

    Within a run, readings after the item first hits zero are dropped: sitting at zero says nothing about how
    fast it was used."""
    observed = sorted((lv.day, lv.quantity) for lv in levels if lv.observations > 0 and lv.quantity is not None)
    runs: list[list[tuple[datetime, float]]] = []
    jumps: list[float] = []
    for day, qty in observed:
        if runs and not is_restock(runs[-1][-1][1], qty):
            if runs[-1][-1][1] > 0:
                runs[-1].append((day, qty))
            continue
        if runs:
            jumps.append(qty - runs[-1][-1][1])
        runs.append([(day, qty)])
    return runs, jumps


def _segment(run: list[tuple[datetime, float]]) -> Segment | None:
    if len(run) < 2:
        return None
    origin = run[0][0]
    points = [((d - origin).total_seconds() / 86400, q) for d, q in run]
    slope, q25, q75 = theil_sen(points)
    # Consumption is the negative slope. The 75th-percentile slope is the shallowest decline (lowest rate).
    rate, lo, hi = max(-slope, 0.0), max(-q75, 0.0), max(-q25, 0.0)
    return Segment(start=run[0][0], end=run[-1][0], points=len(run), rate=rate, rate_lo=min(lo, rate),
                   rate_hi=max(hi, rate))


def blend(observed: float, prior: float, n: float, k: float = PRIOR_WEIGHT) -> float:
    """Shrink an observed rate towards the prior: ``(k*prior + n*observed) / (k + n)``."""
    return (k * prior + n * observed) / (k + n)


def _weighted(values: list[float], weights: list[float]) -> float:
    return sum(v * w for v, w in zip(values, weights, strict=True)) / sum(weights)


def forecast(levels: list[DailyLevel], *, latest: tuple[datetime, float] | None, now: datetime,
             prior: Prior | None = None) -> Forecast:
    """Forecast one item. ``latest`` is the most recent raw reading (time, quantity): the anchor for run-out,
    with its exact time rather than the day bucket."""
    runs, jumps = segments(levels)
    segs = [s for s in (_segment(r) for r in runs) if s is not None]
    observed = [lv for lv in levels if lv.observations > 0 and lv.quantity is not None]
    n_obs = sum(lv.observations for lv in observed)
    span = (observed[-1].day - observed[0].day).total_seconds() / 86400 if observed else 0.0
    restock_qty = median(jumps) if jumps else None
    informative = sum(s.points - 1 for s in segs)

    if segs:
        weights = [(s.points - 1) * 0.5 ** (max((now - s.end).total_seconds(), 0) / 86400 / HALF_LIFE_DAYS)
                   for s in segs]
        rate = _weighted([s.rate for s in segs], weights)
        lo = _weighted([s.rate_lo for s in segs], weights)
        hi = _weighted([s.rate_hi for s in segs], weights)
        if len(segs) > 1:  # habits drift between restocks; let that spread widen the interval
            spread = math.sqrt(_weighted([(s.rate - rate) ** 2 for s in segs], weights))
            lo, hi = min(lo, rate - spread), max(hi, rate + spread)
        method: Method = "theil_sen"
        if prior is not None and informative < FULL_HISTORY:
            p = prior.rate_per_day
            rate, lo, hi = (blend(rate, p, informative, prior.weight), blend(lo, p * 0.5, informative, prior.weight),
                            blend(hi, p * 1.5, informative, prior.weight))
            method = "blended"
    elif prior is not None and latest is not None:
        rate, lo, hi, method = prior.rate_per_day, prior.rate_per_day * 0.5, prior.rate_per_day * 1.5, "prior"
    else:
        return Forecast(method="insufficient", rate_per_day=None, rate_lo=None, rate_hi=None,
                        qty_now=latest[1] if latest else None, last_observed_at=latest[0] if latest else None,
                        last_quantity=latest[1] if latest else None, runout_at=None, runout_lo=None,
                        runout_hi=None, n_obs=n_obs, n_segments=len(segs), span_days=span, restock_qty=restock_qty,
                        household_size=prior.household_size if prior else None, segments=tuple(segs))

    lo, hi = max(min(lo, rate), 0.0), max(hi, rate)
    anchor, last_qty = latest if latest is not None else (observed[-1].day, float(observed[-1].quantity or 0))
    elapsed = max((now - anchor).total_seconds() / 86400, 0.0)
    qty_now = max(last_qty - rate * elapsed, 0.0)
    return Forecast(method=method, rate_per_day=rate, rate_lo=lo, rate_hi=hi, qty_now=qty_now,
                    last_observed_at=anchor, last_quantity=last_qty, runout_at=_runout(anchor, last_qty, rate),
                    runout_lo=_runout(anchor, last_qty, hi), runout_hi=_runout(anchor, last_qty, lo), n_obs=n_obs,
                    n_segments=len(segs), span_days=span, restock_qty=restock_qty,
                    household_size=prior.household_size if prior else None, segments=tuple(segs))


def as_of(f: Forecast, now: datetime) -> Forecast:
    """The same forecast with ``qty_now`` re-projected to ``now``: the level keeps falling between recomputes."""
    if f.rate_per_day is None or f.last_observed_at is None or f.last_quantity is None:
        return f
    elapsed = max((now - f.last_observed_at).total_seconds() / 86400, 0.0)
    return replace(f, qty_now=max(f.last_quantity - f.rate_per_day * elapsed, 0.0))


def _runout(anchor: datetime, quantity: float, rate: float) -> datetime | None:
    if quantity <= 0:
        return anchor
    if rate <= 0:
        return None
    days = quantity / rate
    return anchor + timedelta(days=days) if days <= MAX_HORIZON.days else None


def status(f: Forecast, now: datetime) -> Status:
    if f.method == "insufficient":
        return "unknown"
    if (f.qty_now is not None and f.qty_now <= 0) or (f.runout_at is not None and f.runout_at <= now):
        return "out"
    return "runs_out" if f.runout_at is not None else "steady"


def confidence(f: Forecast) -> Confidence:
    """How much to trust the date: driven by how much history there is and how tight the rate interval is."""
    if f.method in ("insufficient", "prior") or not f.rate_per_day:
        return "low"
    width = ((f.rate_hi or 0) - (f.rate_lo or 0)) / f.rate_per_day
    informative = f.n_obs - f.n_segments  # readings beyond the first of each segment; works on stored rows too
    if informative >= 10 and width <= 0.6:
        return "high"
    return "medium" if informative >= 4 and width <= 1.2 else "low"


def suggested_quantity(f: Forecast | None, par_level: float | None) -> float:
    """How much to put on a list: top up to par if one is set, else what this household usually buys."""
    if par_level:
        on_hand = (f.qty_now or 0.0) if f else 0.0
        return float(max(math.ceil(par_level - on_hand), 1))
    if f and f.restock_qty:
        return float(max(round(f.restock_qty), 1))
    return 1.0


# ---------------------------------------------------------------- explanations

def day_label(when: datetime, now: datetime, tz: tzinfo) -> str:
    """'today', 'tomorrow', a weekday within the next six days, else a date like 'Oct 24'."""
    local = when.astimezone(tz)
    days = (local.date() - now.astimezone(tz).date()).days
    if days in (-1, 0, 1):
        return {-1: "yesterday", 0: "today", 1: "tomorrow"}[days]
    if -6 <= days <= 6:
        return local.strftime("%a")
    return f"{local.strftime('%b')} {local.day}"


def _span(lo: datetime | None, hi: datetime | None, now: datetime, tz: tzinfo) -> str:
    if lo is None and hi is None:
        return ""
    low = day_label(lo, now, tz) if lo else "now"
    if hi is None:
        return f" ({low} or later)"
    high = day_label(hi, now, tz)
    return "" if low == high else f" ({low}–{high})"


def _number(value: float) -> str:
    if value < 0.1:
        return f"{value:.2g}"  # 0.012 -> "0.012", never "0"
    text = f"{value:.1f}" if value < 10 else f"{value:.0f}"
    return text[:-2] if text.endswith(".0") else text


def usage_phrase(rate: float, unit: str) -> str:
    """'about 1.4 a day', 'about one every 5.6 days', or 'about 0.3 gal/day' for measured units."""
    if unit and unit != "unit":
        return f"about {_number(rate)} {unit}/day"
    if rate >= 1:
        return f"about {_number(rate)} a day"
    return f"about one every {_number(1 / rate)} days"


def _evidence(f: Forecast) -> str:
    readings = "1 scan" if f.n_obs == 1 else f"{f.n_obs} scans"
    days = round(f.span_days)
    return f"{readings} over {days} day{'s' if days != 1 else ''}"


def explain(name: str, unit: str, f: Forecast, now: datetime, tz: tzinfo) -> str:
    """One or two sentences a person can check: when, roughly how sure, and what it's based on. Phrased so it
    reads right for "Milk" and "Strawberries" alike."""
    title = name[:1].upper() + name[1:]
    if f.method == "insufficient" or f.rate_per_day is None:
        return f"Not enough history to forecast {name} yet. Scan it a couple more times."
    usage = usage_phrase(f.rate_per_day, unit) if f.rate_per_day > 0 else ""
    if f.method == "prior":
        when = (f"will run out around {day_label(f.runout_at, now, tz)}{_span(f.runout_lo, f.runout_hi, now, tz)}"
                if f.runout_at else "won't run out for a long while")
        return (f"{title} {when}, assuming typical use for a {f.household_size or 1}-person household ({usage}). "
                "Scan it a few more times to personalize this.")
    basis = f"Based on {_evidence(f)}"
    if f.method == "blended":
        basis += " plus typical use while history is short"
    basis += f", you use {usage}." if usage else ", the level has held steady."
    state = status(f, now)
    if state == "out":
        seen = f" (last seen {day_label(f.last_observed_at, now, tz)})" if f.last_observed_at else ""
        return f"{title} probably ran out{seen}. {basis}"
    if state == "steady":
        return (f"No run-out expected for {name}. {basis}" if f.rate_per_day <= 0
                else f"{title} won't run out for a long while. {basis}")
    assert f.runout_at is not None
    when = day_label(f.runout_at, now, tz)
    when = when if when in ("today", "tomorrow") else f"on {when}"
    return f"{title} will run out {when}{_span(f.runout_lo, f.runout_hi, now, tz)}. {basis}"
