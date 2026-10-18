"""Unit tests for the pure forecasting math: no database needed."""

import random
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.core.forecast import (
    CATEGORY_PRIORS,
    DEFAULT_PRIOR,
    FULL_HISTORY,
    DailyLevel,
    Prior,
    as_of,
    blend,
    category_prior,
    confidence,
    day_label,
    explain,
    forecast,
    is_restock,
    segments,
    status,
    suggested_quantity,
    theil_sen,
    usage_phrase,
)

LA = ZoneInfo("America/Los_Angeles")
DAY0 = datetime(2026, 9, 26, tzinfo=UTC)  # a Saturday
NOW = datetime(2026, 10, 17, 3, 0, tzinfo=UTC)  # Friday evening in Seattle, Saturday in UTC


def series(readings: dict[int, float], days: int | None = None) -> list[DailyLevel]:
    """A daily series like ``timeseries.daily_levels``: readings on some days, carried forward on the rest."""
    last = max(readings) + 1 if days is None else days
    out, level = [], None
    for d in range(last):
        if d in readings:
            level = readings[d]
        out.append(DailyLevel(DAY0 + timedelta(days=d), level, 1 if d in readings else 0))
    return out


def latest_of(readings: dict[int, float], hour: int = 20) -> tuple[datetime, float]:
    d = max(readings)
    return DAY0 + timedelta(days=d, hours=hour), readings[d]


def run(readings: dict[int, float], now: datetime = NOW, prior: Prior | None = None, **kw):
    return forecast(series(readings, **kw), latest=latest_of(readings), now=now, prior=prior)


def linear(start: float, rate: float, days: range) -> dict[int, float]:
    return {d: round(start - rate * (d - days.start), 6) for d in days}


# ---------------------------------------------------------------- building blocks

def test_theil_sen_on_a_line_and_with_an_outlier():
    points = [(float(x), 10 - 0.5 * x) for x in range(8)]
    assert theil_sen(points) == pytest.approx((-0.5, -0.5, -0.5))
    points[3] = (3.0, 40.0)  # one wild misread
    slope, q25, q75 = theil_sen(points)
    assert slope == pytest.approx(-0.5, abs=0.05)
    assert q25 <= slope <= q75


def test_theil_sen_needs_two_distinct_x():
    with pytest.raises(ValueError):
        theil_sen([(1.0, 2.0)])
    with pytest.raises(ValueError):
        theil_sen([(1.0, 2.0), (1.0, 3.0)])


def test_restock_threshold_ignores_reading_noise():
    assert not is_restock(1.0, 1.05)  # 5% wobble from the vision model
    assert not is_restock(10.0, 11.0)  # +10% of a big count is still noise
    assert not is_restock(0.1, 0.3)  # below the absolute floor
    assert is_restock(0.3, 2.0)
    assert is_restock(3.0, 12.0)


def test_segments_split_at_restocks_and_drop_time_at_zero():
    runs, jumps = segments(series({0: 2.0, 1: 1.5, 2: 1.0, 3: 2.1, 4: 1.6, 5: 0.0, 6: 0.0, 7: 0.0, 8: 2.0}))
    assert [[q for _, q in r] for r in runs] == [[2.0, 1.5, 1.0], [2.1, 1.6, 0.0], [2.0]]
    assert jumps == pytest.approx([1.1, 2.0])


def test_segments_ignore_carried_forward_days():
    runs, _ = segments(series({0: 3.0, 3: 2.0, 6: 1.0}))
    assert [len(r) for r in runs] == [3]


def test_category_prior_scales_with_household_and_falls_back():
    assert category_prior("dairy", 1).rate_per_day == pytest.approx(CATEGORY_PRIORS["dairy"])
    assert category_prior("Dairy", 3).rate_per_day == pytest.approx(3 * CATEGORY_PRIORS["dairy"])
    assert category_prior(None, 2).rate_per_day == pytest.approx(2 * DEFAULT_PRIOR)
    assert category_prior("moon rocks", 0).household_size == 1
    assert category_prior("dairy", 99).household_size == 20


def test_blend_moves_from_prior_to_observed():
    assert blend(1.0, 0.0, n=0, k=3) == 0.0
    assert blend(1.0, 0.0, n=3, k=3) == 0.5
    assert blend(1.0, 0.0, n=300, k=3) == pytest.approx(1.0, abs=0.01)


# ---------------------------------------------------------------- forecasting

def test_steady_depletion_gives_the_rate_and_run_out():
    f = run(linear(4.0, 0.25, range(0, 12)))  # 4.0 down to 1.25 over 11 days
    assert f.method == "theil_sen" and f.n_segments == 1 and f.n_obs == 12
    assert f.rate_per_day == pytest.approx(0.25)
    assert f.rate_lo == pytest.approx(0.25) and f.rate_hi == pytest.approx(0.25)
    anchor, qty = latest_of(linear(4.0, 0.25, range(0, 12)))
    assert f.last_observed_at == anchor and f.last_quantity == pytest.approx(1.25)
    assert f.runout_at == anchor + timedelta(days=5)  # 1.25 left at 0.25/day
    assert f.span_days == 11


def test_sparse_scans_are_not_biased_by_carried_forward_days():
    readings = {d: 6.0 - 0.5 * d for d in range(0, 10, 3)}  # scanned every third day
    f = run(readings)
    assert f.rate_per_day == pytest.approx(0.5)


def test_restocks_start_new_segments_and_are_averaged():
    readings = {**linear(2.0, 0.2, range(0, 8)), **linear(2.0, 0.2, range(8, 16)), **linear(2.0, 0.2, range(16, 20))}
    f = run(readings)
    assert f.n_segments == 3 and f.rate_per_day == pytest.approx(0.2)
    assert f.restock_qty == pytest.approx(2.0 - 0.6)  # 0.6 left each time, topped up to 2.0


def test_one_bad_reading_barely_moves_the_rate():
    readings = linear(5.0, 0.3, range(0, 14))
    readings[6] = 0.2  # the model misread a half-hidden carton
    f = run(readings)
    assert f.rate_per_day == pytest.approx(0.3, rel=0.1)


def test_recent_habits_outweigh_old_ones():
    old_fast = linear(3.0, 0.6, range(0, 5))  # ended ~3 weeks before NOW
    recent_slow = linear(3.0, 0.1, range(14, 20))
    f = run({**old_fast, **recent_slow})
    assert f.n_segments == 2
    assert 0.1 < f.rate_per_day < 0.35  # pulled towards the recent rate, not the plain average (0.35)
    assert f.rate_lo <= 0.1 and f.rate_hi >= 0.6 - 0.25  # disagreement between segments widens the interval


def test_cold_start_blends_with_the_category_prior():
    prior = Prior(rate_per_day=0.5, weight=3)
    f = run({18: 2.0, 19: 1.9}, prior=prior)  # one informative reading saying 0.1/day
    assert f.method == "blended"
    assert f.rate_per_day == pytest.approx(blend(0.1, 0.5, n=1, k=3))
    assert f.rate_lo <= f.rate_per_day <= f.rate_hi


def test_enough_history_drops_the_prior():
    prior = Prior(rate_per_day=5.0)
    f = run(linear(4.0, 0.2, range(0, FULL_HISTORY + 1)), prior=prior)
    assert f.method == "theil_sen" and f.rate_per_day == pytest.approx(0.2)


def test_one_reading_uses_the_prior_alone():
    prior = category_prior("dairy", 2)
    f = run({19: 1.5}, prior=prior)
    assert f.method == "prior" and f.rate_per_day == pytest.approx(prior.rate_per_day)
    assert f.runout_at == latest_of({19: 1.5})[0] + timedelta(days=1.5 / prior.rate_per_day)
    assert f.household_size == 2


def test_nothing_to_go_on_is_insufficient():
    assert forecast([], latest=None, now=NOW, prior=category_prior("dairy")).method == "insufficient"
    f = run({19: 1.5})  # one reading, no prior
    assert f.method == "insufficient" and f.rate_per_day is None and f.runout_at is None
    assert status(f, NOW) == "unknown" and confidence(f) == "low"


def test_unused_items_never_run_out():
    f = run({d: 3.0 for d in range(10, 20)})
    assert f.rate_per_day == 0 and f.runout_at is None
    assert status(f, NOW) == "steady"


def test_already_empty_is_out_now():
    f = run({**linear(1.0, 0.25, range(15, 19)), 19: 0.0})
    assert f.qty_now == 0 and f.runout_at == f.last_observed_at
    assert status(f, NOW) == "out"


def test_qty_now_is_projected_from_the_last_reading():
    readings = linear(4.0, 0.25, range(0, 12))
    anchor, _ = latest_of(readings)
    f = run(readings, now=anchor + timedelta(days=2))
    assert f.qty_now == pytest.approx(1.25 - 0.5)
    later = as_of(f, anchor + timedelta(days=4))
    assert later.qty_now == pytest.approx(0.25) and later.runout_at == f.runout_at


def test_far_off_run_outs_are_not_given_a_date():
    f = run({d: 500 - 0.01 * d for d in range(0, 20)})
    assert f.rate_per_day == pytest.approx(0.01) and f.runout_at is None
    assert status(f, NOW) == "steady"


def test_interval_brackets_the_estimate_on_noisy_data():
    rng = random.Random(3)  # noqa: S311 - test data
    level, readings = 2.0, {}
    for d in range(21):
        level = max(0.0, level - 0.18 * rng.uniform(0.6, 1.4))
        if level < 0.4:
            level = 2.0
        readings[d] = round(level * rng.uniform(0.95, 1.05), 2)
    f = run(readings, prior=category_prior("dairy"))
    assert f.rate_per_day == pytest.approx(0.18, rel=0.2)
    assert f.rate_lo <= f.rate_per_day <= f.rate_hi
    assert f.runout_lo <= f.runout_at <= f.runout_hi
    assert confidence(f) == "high"


def test_confidence_levels():
    assert confidence(run(linear(4.0, 0.25, range(0, 12)))) == "high"
    assert confidence(run(linear(4.0, 0.25, range(14, 20)))) == "medium"
    assert confidence(run({18: 2.0, 19: 1.9}, prior=Prior(0.5))) == "low"
    assert confidence(run({19: 1.0}, prior=Prior(0.5))) == "low"


def test_suggested_quantity():
    f = run(linear(2.0, 0.2, range(0, 8)) | linear(2.0, 0.2, range(8, 12)))
    assert suggested_quantity(f, par_level=None) == 1  # restocked ~0.6 → 2.0, rounds to 1
    assert suggested_quantity(replace(f, restock_qty=9.6), par_level=None) == 10
    assert suggested_quantity(replace(f, qty_now=1.0), par_level=4) == 3
    assert suggested_quantity(replace(f, qty_now=5.0), par_level=4) == 1
    assert suggested_quantity(None, par_level=None) == 1
    assert suggested_quantity(None, par_level=2) == 2


# ---------------------------------------------------------------- explanations

def test_day_labels_are_relative_and_local():
    now = datetime(2026, 10, 16, 19, 0, tzinfo=UTC)  # Friday noon in Seattle
    assert day_label(now + timedelta(hours=1), now, LA) == "today"
    assert day_label(datetime(2026, 10, 17, 6, 30, tzinfo=UTC), now, LA) == "today"  # still Friday in Seattle
    assert day_label(now + timedelta(days=1), now, LA) == "tomorrow"
    assert day_label(now - timedelta(days=1), now, LA) == "yesterday"
    assert day_label(now + timedelta(days=6), now, LA) == "Thu"
    assert day_label(now - timedelta(days=3), now, LA) == "Tue"
    assert day_label(now + timedelta(days=8), now, LA) == "Oct 24"


def test_usage_phrases():
    assert usage_phrase(1.4, "unit") == "about 1.4 a day"
    assert usage_phrase(0.18, "unit") == "about one every 5.6 days"
    assert usage_phrase(0.05, "unit") == "about one every 20 days"
    assert usage_phrase(0.3, "gal") == "about 0.3 gal/day"
    assert usage_phrase(1.0, "unit") == "about 1 a day"
    assert usage_phrase(0.012, "lb") == "about 0.012 lb/day"  # small rates never round to zero
    assert usage_phrase(12.4, "unit") == "about 12 a day"


def test_explanation_reads_like_the_spec():
    now = datetime(2026, 10, 12, 22, 0, tzinfo=UTC)  # Monday afternoon in Seattle
    readings = {d: round(2.0 - 0.15 * (d - 7), 3) for d in range(7, 17) if d != 12}  # 9 scans over 9 days
    f = run(readings, now=now)
    f = replace(f, runout_at=datetime(2026, 10, 15, 20, tzinfo=UTC), runout_lo=datetime(2026, 10, 14, 20, tzinfo=UTC),
                runout_hi=datetime(2026, 10, 16, 20, tzinfo=UTC))
    text = explain("milk", "unit", f, now, LA)
    assert text == ("Milk will run out on Thu (Wed–Fri). Based on 9 scans over 9 days, you use about one every "
                    "6.7 days.")


def test_explanations_for_every_state():
    readings = linear(4.0, 0.25, range(0, 12))
    anchor, _ = latest_of(readings)
    soon = run(readings, now=anchor)
    assert explain("eggs", "unit", soon, anchor, LA).startswith("Eggs will run out on ")
    assert "Based on 12 scans over 11 days" in explain("eggs", "unit", soon, anchor, LA)

    out = run({**linear(1.0, 0.25, range(15, 19)), 19: 0.0})
    assert explain("strawberries", "unit", out, NOW, LA).startswith("Strawberries probably ran out (last seen")

    steady = run({d: 3.0 for d in range(10, 20)})
    assert explain("olive oil", "unit", steady, NOW, LA) == (
        "No run-out expected for olive oil. Based on 10 scans over 9 days, the level has held steady.")

    blended = run({18: 2.0, 19: 1.9}, prior=Prior(0.5))
    assert "plus typical use while history is short" in explain("yogurt", "unit", blended, NOW, LA)

    guess = run({19: 1.5}, prior=category_prior("dairy", 2))
    text = explain("butter", "unit", guess, NOW, LA)
    assert text.startswith("Butter will run out around ") and "2-person household" in text
    assert text.endswith("Scan it a few more times to personalize this.")

    assert explain("jam", "unit", run({19: 1.0}), NOW, LA) == (
        "Not enough history to forecast jam yet. Scan it a couple more times.")

    far = run({d: 500 - 0.01 * d for d in range(0, 20)})
    assert explain("rice", "lb", far, NOW, LA) == (
        "Rice won't run out for a long while. Based on 20 scans over 19 days, you use about 0.01 lb/day.")


def test_explanation_says_today_and_omits_a_collapsed_interval():
    readings = linear(1.0, 0.25, range(16, 20))  # 0.25 left after the last reading
    anchor, _ = latest_of(readings, hour=20)
    f = run(readings, now=anchor)
    text = explain("milk", "unit", f, anchor, UTC)
    assert text.startswith("Milk will run out tomorrow.")  # a perfect line has no interval to show
