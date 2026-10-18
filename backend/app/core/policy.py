"""The agent-commerce policy engine. Pure and deterministic: no I/O, no clock, no model.

The on-device model *proposes* an intent ("buy 2 oat milk at Ballard Market for $8.98, because..."). This module
*disposes*: ``decide`` returns ``allow``, ``needs_approval`` or ``deny`` plus the reasons, in plain language,
that the app shows the user verbatim. The same inputs always give the same answer, so every decision can be
replayed and explained later.

Three kinds of outcome:

* **deny**: hard stops no approval can override at proposal time (agent paused, autonomy set to Inform, an
  identical request already in flight, too many purchases in the last hour).
* **needs_approval**: anything outside what the user pre-authorized (autonomy below "buy within mandate", no
  mandate covers it, over a cap or budget, possibly bought already). The user decides.
* **allow**: every check passed. For purchases that means autonomy "buy within mandate" and a live mandate whose
  scope, per-purchase cap, period cap and confirmation threshold all fit, with budget headroom to spare.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

AUTONOMY_LEVELS = ("inform", "prepare", "buy_with_approval", "buy_within_mandate")
LEVEL_NAMES = {"inform": "Inform", "prepare": "Prepare", "buy_with_approval": "Buy with approval",
               "buy_within_mandate": "Buy within mandate"}
KIND_VERBS = {"list_add": "add things to your lists", "add_to_cart": "add things to a cart",
              "calendar_event": "draft shopping trips on your calendar"}

MAX_PURCHASES_PER_HOUR = 3
VELOCITY_WINDOW = timedelta(hours=1)
DUPLICATE_WINDOW = timedelta(days=7)

PENDING = frozenset({"proposed", "approved", "executing"})  # could still turn into a purchase
COMMITTED = frozenset({"approved", "executing", "succeeded", "outcome_unknown"})  # spent, or may have been
UNSETTLED = frozenset({"approved", "executing", "outcome_unknown"})  # committed but not yet in spend_entries


# ---------------------------------------------------------------- inputs

@dataclass(frozen=True)
class ProposedIntent:
    kind: str
    title: str
    item_key: str
    amount_cents: int | None = None
    merchant_id: str | None = None
    merchant_name: str | None = None
    category: str | None = None


@dataclass(frozen=True)
class AgentSettings:
    autonomy_level: str
    paused: bool = False
    timezone: str = "UTC"


@dataclass(frozen=True)
class Mandate:
    id: str
    label: str
    max_per_txn_cents: int
    expires_at: datetime
    period: str = "month"
    max_per_period_cents: int | None = None
    require_confirm_above_cents: int | None = None
    merchant_ids: frozenset[str] | None = None  # None = any merchant
    categories: frozenset[str] | None = None  # None = any category
    status: str = "active"


@dataclass(frozen=True)
class Budget:
    id: str
    period: str
    limit_cents: int
    spent_cents: int  # recorded spend in the current period (spend_entries)
    category: str | None = None  # None = all spending


@dataclass(frozen=True)
class PastIntent:
    """A recent intent in the same household. ``mine`` marks the ones made by this user's agent."""

    id: str
    kind: str
    status: str
    decision: str
    created_at: datetime
    item_key: str = ""
    amount_cents: int | None = None  # the final amount when known
    mandate_id: str | None = None
    category: str | None = None
    mine: bool = True


# ---------------------------------------------------------------- output

@dataclass(frozen=True)
class Reason:
    code: str
    message: str


@dataclass(frozen=True)
class Verdict:
    decision: str  # allow | needs_approval | deny
    reasons: tuple[Reason, ...]
    mandate_id: str | None = None

    @property
    def messages(self) -> list[str]:
        return [r.message for r in self.reasons]

    @property
    def codes(self) -> list[str]:
        return [r.code for r in self.reasons]


# ---------------------------------------------------------------- helpers

def money(cents: int) -> str:
    return f"-${-cents / 100:,.2f}" if cents < 0 else f"${cents / 100:,.2f}"


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def period_start(now: datetime, period: str, tz: ZoneInfo) -> datetime:
    """Start of the calendar day, week (Monday) or month containing ``now``, in the user's time zone."""
    local = now.astimezone(tz)
    day = local.date()
    if period == "week":
        day -= timedelta(days=day.weekday())
    elif period == "month":
        day = day.replace(day=1)
    elif period != "day":
        raise ValueError(f"unknown period {period!r}")
    return datetime(day.year, day.month, day.day, tzinfo=tz)


def _ago(delta: timedelta) -> str:
    minutes = int(delta.total_seconds() // 60)
    if minutes < 60:
        return "just now" if minutes < 2 else f"{minutes} minutes ago"
    if minutes < 48 * 60:
        hours = minutes // 60
        return "1 hour ago" if hours == 1 else f"{hours} hours ago"
    return f"{minutes // (24 * 60)} days ago"


def _where(intent: ProposedIntent) -> str:
    text = f"'{intent.title}'"
    if intent.merchant_name:
        text += f" at {intent.merchant_name}"
    if intent.category:
        text += f" ({intent.category})"
    return text


def _covers(m: Mandate, intent: ProposedIntent) -> bool:
    if m.merchant_ids is not None and intent.merchant_id not in m.merchant_ids:
        return False
    return m.categories is None or intent.category in m.categories


_PERIOD_ADJECTIVE = {"day": "daily", "week": "weekly", "month": "monthly"}


# ---------------------------------------------------------------- checks

def _budget_checks(intent: ProposedIntent, amount: int, budgets: list[Budget], recent: list[PastIntent],
                   now: datetime, tz: ZoneInfo) -> tuple[list[Reason], list[Reason]]:
    over, fine = [], []
    for b in sorted(budgets, key=lambda b: (b.category is not None, b.category or "", b.period, b.id)):
        if b.category is not None and b.category != intent.category:
            continue
        start = period_start(now, b.period, tz)
        unsettled = sum(p.amount_cents or 0 for p in recent
                        if p.kind == "purchase" and p.status in UNSETTLED and p.created_at >= start
                        and (b.category is None or p.category == b.category))
        used = b.spent_cents + unsettled
        name = f"{_PERIOD_ADJECTIVE[b.period]} {b.category + ' ' if b.category else ''}budget"
        if used >= b.limit_cents:
            over.append(Reason("over_budget", f"Your {name} is already used up ({money(used)} of "
                                              f"{money(b.limit_cents)})."))
        elif used + amount > b.limit_cents:
            over.append(Reason("over_budget", f"This would take your {name} to {money(used + amount)} of "
                                              f"{money(b.limit_cents)}."))
        else:
            fine.append(Reason("within_budget", f"{money(b.limit_cents - used - amount)} left in your {name} "
                                                f"after this."))
    return over, fine


def _mandate_check(intent: ProposedIntent, amount: int, mandates: list[Mandate], recent: list[PastIntent],
                   now: datetime, tz: ZoneInfo) -> tuple[Mandate | None, list[Reason]]:
    """The first live, in-scope mandate that fits, with the reasons it fits; or None and why nothing did."""
    active = [m for m in mandates if m.status == "active"]
    if not active:
        return None, [Reason("no_mandate", "You haven't given your agent a spending mandate, so it needs your OK.")]
    in_scope = [m for m in active if _covers(m, intent)]
    if not in_scope:
        return None, [Reason("outside_mandate", f"None of your mandates cover {_where(intent)}.")]
    live = [m for m in in_scope if m.expires_at > now]
    if not live:
        latest = max(in_scope, key=lambda m: (m.expires_at, m.id))
        expired = latest.expires_at.astimezone(tz)
        return None, [Reason("mandate_expired", f"Your '{latest.label}' mandate expired on {expired:%b} "
                                                f"{expired.day}. Renew it to let the agent buy on its own.")]

    first_failures: list[Reason] | None = None
    for m in live:
        failures, fits = [], []
        if amount > m.max_per_txn_cents:
            failures.append(Reason("over_txn_cap", f"{money(amount)} is over the {money(m.max_per_txn_cents)} "
                                                   f"per-purchase limit in your '{m.label}' mandate."))
        else:
            fits.append(Reason("within_mandate", f"Within your '{m.label}' mandate: {money(amount)} of "
                                                 f"{money(m.max_per_txn_cents)} allowed per purchase."))
        if m.require_confirm_above_cents is not None and amount > m.require_confirm_above_cents:
            failures.append(Reason("confirm_above", f"Your '{m.label}' mandate asks you to confirm purchases over "
                                                    f"{money(m.require_confirm_above_cents)}."))
        if m.max_per_period_cents is not None:
            start = period_start(now, m.period, tz)
            used = sum(p.amount_cents or 0 for p in recent
                       if p.mandate_id == m.id and p.status in COMMITTED and p.created_at >= start)
            if used + amount > m.max_per_period_cents:
                failures.append(Reason("over_period_cap", f"This would bring '{m.label}' to {money(used + amount)} "
                                                          f"this {m.period}, over its "
                                                          f"{money(m.max_per_period_cents)} limit."))
            else:
                fits.append(Reason("mandate_period_left", f"{money(m.max_per_period_cents - used - amount)} left on "
                                                          f"'{m.label}' this {m.period} after this."))
        if not failures:
            return m, fits
        first_failures = first_failures or failures
    return None, first_failures or []


# ---------------------------------------------------------------- the decision

def decide(intent: ProposedIntent, settings: AgentSettings, mandates: list[Mandate], budgets: list[Budget],
           recent_intents: list[PastIntent], now: datetime) -> Verdict:
    """Decide what the agent may do with ``intent``. ``now`` is passed in, never read, so this stays pure.

    ``mandates`` are this user's (any status), ``budgets`` the household's active ones with their recorded spend
    for the current period, and ``recent_intents`` the household's intents from at least the last month.
    """
    tz = zone(settings.timezone)
    level = settings.autonomy_level
    if level not in AUTONOMY_LEVELS:
        raise ValueError(f"unknown autonomy level {level!r}")

    if settings.paused:
        return Verdict("deny", (Reason("agent_paused", "You paused your agent. Resume it to let it act again."),))
    if level == "inform":
        return Verdict("deny", (Reason("autonomy_inform", "Your agent is set to Inform, so it can suggest things "
                                                          "but not act on them."),))
    if intent.kind != "purchase":
        return Verdict("allow", (Reason("autonomy_allows", f"{LEVEL_NAMES[level]} lets your agent "
                                                           f"{KIND_VERBS[intent.kind]} without asking."),))
    if intent.amount_cents is None or intent.amount_cents <= 0:
        return Verdict("deny", (Reason("missing_amount", "A purchase needs a price before the agent can ask."),))
    amount = intent.amount_cents
    purchases = [p for p in recent_intents if p.kind == "purchase"]

    # Hard stops.
    if any(p.item_key == intent.item_key and p.status in PENDING for p in purchases):
        return Verdict("deny", (Reason("duplicate_pending", f"'{intent.title}' is already waiting for approval or "
                                                            "being bought."),))
    # Every request the agent got through counts, approved or not, except ones the user's kill switch cancelled.
    recent_mine = [p for p in purchases if p.mine and p.decision != "deny" and p.status != "cancelled"
                   and p.created_at > now - VELOCITY_WINDOW]
    if len(recent_mine) >= MAX_PURCHASES_PER_HOUR:
        return Verdict("deny", (Reason("velocity_limit", f"Your agent already asked to buy {len(recent_mine)} things "
                                                         "in the last hour, which is the limit. Try again later or "
                                                         "buy it yourself."),))

    escalations: list[Reason] = []
    notes: list[Reason] = []

    earlier = sorted((p for p in purchases if p.item_key == intent.item_key and p.status in ("succeeded",
                      "outcome_unknown") and p.created_at > now - DUPLICATE_WINDOW),
                     key=lambda p: (p.created_at, p.id), reverse=True)
    if earlier:
        last, ago = earlier[0], _ago(now - earlier[0].created_at)
        if last.status == "outcome_unknown":
            escalations.append(Reason("duplicate_unknown", f"An order for '{intent.title}' placed {ago} may have "
                                                           "gone through. Check before buying again."))
        else:
            escalations.append(Reason("duplicate_recent", f"'{intent.title}' was already bought {ago}."))

    over, fine = _budget_checks(intent, amount, budgets, recent_intents, now, tz)
    escalations += over
    notes += fine

    mandate: Mandate | None = None
    if level in ("prepare", "buy_with_approval"):
        escalations.insert(0, Reason("autonomy_requires_approval", f"Your agent is set to {LEVEL_NAMES[level]}, so "
                                                                   "every purchase needs your OK."))
    else:
        mandate, mandate_reasons = _mandate_check(intent, amount, mandates, recent_intents, now, tz)
        if mandate is None:
            escalations = mandate_reasons + escalations
        else:
            notes = mandate_reasons + notes

    if escalations:
        return Verdict("needs_approval", tuple(escalations + notes))
    assert mandate is not None  # buy_within_mandate with nothing to escalate means a mandate fit
    return Verdict("allow", tuple(notes), mandate.id)
