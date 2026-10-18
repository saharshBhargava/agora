"""Pure wishlist logic: priority scoring, learning from feedback, and the re-suggestion guard. No I/O.

Scoring is deliberately simple and explainable. Each item gets

    score = 1000 if pinned
          + 100 * priority tier (the user's 1-5, default 3)
          + signal points in [0, 99] (source, confidence, feedback on similar items, age, needed-by, stock)

so the user's own choices always outrank anything the system infers: a pinned item beats every unpinned
one, and a priority-4 item beats every priority-3 item whatever its signals. Every non-zero contribution
comes with a short human-readable reason.
"""

import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from app.core.detections import normalize

REJECTION_WINDOW = timedelta(days=30)
DEFAULT_PRIORITY = 3
PRIORITY_NAMES = {1: "lowest", 2: "low", 3: "normal", 4: "high", 5: "highest"}
MAX_REASONS = 4

# Rejections that say something about the user's taste. "already_have" only says the timing was off.
NEGATIVE_REJECTIONS = {"not_interested", "too_expensive", "wrong_item", "other"}

_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def title_key(title: str) -> str:
    """Key for "the same thing": lowercase, punctuation dropped, single spaces, crude singular."""
    key = normalize(_NON_ALNUM.sub(" ", title.lower()))
    return key or title.strip().lower()[:120]


def category_key(category: str | None) -> str | None:
    if category is None:
        return None
    key = " ".join(category.lower().split())
    return key or None


# ---------------------------------------------------------------- learning from feedback

@dataclass
class Tally:
    liked: int = 0
    disliked: int = 0

    @property
    def net(self) -> int:
        return self.liked - self.disliked

    def __add__(self, other: "Tally") -> "Tally":
        return Tally(self.liked + other.liked, self.disliked + other.disliked)

    def __sub__(self, other: "Tally") -> "Tally":
        return Tally(self.liked - other.liked, self.disliked - other.disliked)


@dataclass(frozen=True)
class Outcome:
    """What happened to one agent suggestion: the learning signal it contributes."""

    item_id: str
    title: str
    title_key: str
    category: str | None
    status: str
    accepted: bool
    reject_reason: str | None = None
    reject_comment: str | None = None
    decided_at: datetime | None = None
    target_price_cents: int | None = None
    thumbs_up: int = 0
    thumbs_down: int = 0

    @property
    def signal(self) -> Tally:
        """Accepts and thumbs-up count as liked; thumbs-down and taste rejections count as disliked."""
        rejected = self.status == "rejected" and self.reject_reason in NEGATIVE_REJECTIONS
        return Tally(self.thumbs_up + int(self.accepted), self.thumbs_down + int(rejected))


class FeedbackIndex:
    """Liked/disliked totals per category and per normalized title, with an item's own signal removable so it
    never boosts or sinks itself."""

    def __init__(self, outcomes: Iterable[Outcome]):
        self.by_category: dict[str, Tally] = {}
        self.by_title: dict[str, Tally] = {}
        self.own: dict[str, Outcome] = {}
        for o in outcomes:
            self.own[o.item_id] = o
            if o.category:
                self.by_category[o.category] = self.by_category.get(o.category, Tally()) + o.signal
            self.by_title[o.title_key] = self.by_title.get(o.title_key, Tally()) + o.signal

    def similar(self, item_id: str | None, category: str | None, key: str) -> tuple[Tally, Tally]:
        """(category tally, title tally) from every other suggestion."""
        own = self.own.get(item_id) if item_id is not None else None
        category_tally = self.by_category.get(category, Tally()) if category else Tally()
        title_tally = self.by_title.get(key, Tally())
        if own is not None:
            if own.category and own.category == category:
                category_tally = category_tally - own.signal
            if own.title_key == key:
                title_tally = title_tally - own.signal
        return category_tally, title_tally


# ---------------------------------------------------------------- priority score

@dataclass(frozen=True)
class ScoreInput:
    source: str
    created_at: datetime
    pinned: bool = False
    priority: int | None = None
    confidence: float | None = None
    needed_by: date | None = None
    on_hand: float | None = None
    par_level: float | None = None
    category: str | None = None
    category_feedback: Tally = field(default_factory=Tally)
    title_feedback: Tally = field(default_factory=Tally)


@dataclass(frozen=True)
class Score:
    value: float
    reasons: list[str]


def _plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def score(item: ScoreInput, now: datetime) -> Score:
    """Deterministic priority score and the reasons behind it, most important first."""
    tier_reasons: list[str] = []
    signals: list[tuple[float, str]] = []

    base = 1000.0 if item.pinned else 0.0
    if item.pinned:
        tier_reasons.append("Pinned by you")
    tier = item.priority or DEFAULT_PRIORITY
    base += 100 * tier
    if item.priority is not None and item.priority != DEFAULT_PRIORITY:
        tier_reasons.append(f"You set priority {PRIORITY_NAMES[item.priority]}")

    if item.source == "user":
        signals.append((15.0, "Added by you"))
    else:
        confidence = item.confidence if item.confidence is not None else 0.5
        signals.append((round((confidence - 0.5) * 20, 1), f"Agent is {round(confidence * 100)}% confident"))
        # Learning only shapes the agent's ideas; it never re-ranks something the user asked for.
        cat = item.category_feedback
        if cat.net > 0:
            signals.append((min(cat.net * 4, 12), f"You liked {_plural(cat.liked, 'similar suggestion')}"
                                                  f" in {item.category}"))
        elif cat.net < 0:
            signals.append((max(cat.net * 4, -16), f"You turned down {_plural(cat.disliked, 'similar suggestion')}"
                                                   f" in {item.category}"))
        title = item.title_feedback
        if title.net > 0:
            signals.append((min(title.net * 8, 16), "You liked this suggestion before"))
        elif title.net < 0:
            signals.append((max(title.net * 8, -24), "You turned this down before"))

    if item.needed_by is not None:
        days = (item.needed_by - now.date()).days
        if days < 0:
            signals.append((25.0, "Past its needed-by date"))
        elif days <= 3:
            signals.append((20.0, "Needed today" if days == 0 else f"Needed in {_plural(days, 'day')}"))
        elif days <= 7:
            signals.append((12.0, f"Needed in {days} days"))
        elif days <= 14:
            signals.append((6.0, f"Needed in {days} days"))

    if item.on_hand is not None and item.par_level is not None and item.on_hand < item.par_level:
        signals.append((15.0, f"Running low: {item.on_hand:g} left, you keep {item.par_level:g}"))

    age_days = max((now - item.created_at).days, 0)
    if age_days >= 3:
        signals.append((round(min(age_days, 30) / 3, 1), f"Waiting {_plural(age_days, 'day')}"))

    points = 50 + sum(p for p, _ in signals)
    points = min(max(points, 0.0), 99.0)
    ranked = [r for p, r in sorted(signals, key=lambda s: -abs(s[0])) if p != 0]
    return Score(round(base + points, 1), (tier_reasons + ranked)[:MAX_REASONS])


def rank_key(value: float, created_at: datetime, item_id: str) -> tuple:
    """Sort key: highest score first, then oldest, then id, so equal scores never shuffle between requests."""
    return (-value, created_at, item_id)


# ---------------------------------------------------------------- re-suggestion guard

@dataclass(frozen=True)
class Rejection:
    title_key: str
    reason_code: str
    rejected_at: datetime
    target_price_cents: int | None = None


def blocking_rejection(key: str, target_price_cents: int | None, rejections: Iterable[Rejection],
                       now: datetime) -> Rejection | None:
    """The recent rejection that stops the agent re-suggesting this item, if any.

    A rejection of the same normalized title within the window blocks it. The one exception is "too
    expensive": the agent may come back with a strictly lower target price than the one that was rejected.
    """
    for r in sorted(rejections, key=lambda r: r.rejected_at, reverse=True):
        if r.title_key != key or now - r.rejected_at > REJECTION_WINDOW:
            continue
        if (r.reason_code == "too_expensive" and r.target_price_cents is not None
                and target_price_cents is not None and target_price_cents < r.target_price_cents):
            continue
        return r
    return None


# ---------------------------------------------------------------- agent context

def agent_context(outcomes: list[Outcome], open_titles: list[tuple[str, str]], now: datetime,
                  limit: int = 20) -> dict:
    """A compact summary of the household's reactions, sized for an on-device model's prompt.

    ``open_titles`` is (title, status) for items currently suggested, snoozed or on the list.
    """
    index = FeedbackIndex(outcomes)
    accepted = sum(1 for o in outcomes if o.accepted)
    rejected = sum(1 for o in outcomes if o.status == "rejected")
    pending = sum(1 for o in outcomes if o.status in ("suggested", "snoozed"))
    decided = accepted + rejected

    def categories(pick) -> list[dict]:
        rows = [(c, pick(t)) for c, t in index.by_category.items() if pick(t) > 0]
        return [{"category": c, "count": n} for c, n in sorted(rows, key=lambda r: (-r[1], r[0]))][:limit]

    recent = sorted((o for o in outcomes if o.status == "rejected" and o.decided_at is not None
                     and now - o.decided_at <= REJECTION_WINDOW), key=lambda o: o.decided_at, reverse=True)
    recently_rejected = [{"title": o.title, "category": o.category, "reason_code": o.reject_reason,
                          "comment": (o.reject_comment or "")[:140] or None,
                          "rejected_at": o.decided_at.isoformat()} for o in recent[:limit]]

    do_not_suggest: list[dict] = []
    seen: set[str] = set()
    for o in recent:
        if o.title_key in seen:
            continue
        seen.add(o.title_key)
        entry = {"title": o.title, "reason": f"rejected:{o.reject_reason}",
                 "until": (o.decided_at + REJECTION_WINDOW).date().isoformat()}
        if o.reject_reason == "too_expensive" and o.target_price_cents is not None:
            entry["unless_price_below_cents"] = o.target_price_cents
        do_not_suggest.append(entry)
    for title, status in open_titles:
        if (key := title_key(title)) not in seen:
            seen.add(key)
            do_not_suggest.append({"title": title, "reason": "already_on_wishlist" if status == "active"
                                   else f"already_{status}"})

    liked, disliked = categories(lambda t: t.liked), categories(lambda t: t.disliked)
    rate = round(accepted / decided, 2) if decided else None
    summary = [f"Accepted {accepted} of {decided} decided suggestions." if decided
               else "No suggestions decided yet."]
    if liked:
        summary.append("Likes: " + ", ".join(f"{c['category']} ({c['count']})" for c in liked[:5]) + ".")
    if disliked:
        summary.append("Avoid: " + ", ".join(f"{c['category']} ({c['count']})" for c in disliked[:5]) + ".")
    if do_not_suggest:
        summary.append("Do not suggest: " + ", ".join(d["title"] for d in do_not_suggest[:10]) + ".")
    return {
        "generated_at": now.isoformat(),
        "window_days": REJECTION_WINDOW.days,
        "suggestions": {"accepted": accepted, "rejected": rejected, "pending": pending, "acceptance_rate": rate},
        "liked_categories": liked,
        "disliked_categories": disliked,
        "recently_rejected": recently_rejected,
        "do_not_suggest": do_not_suggest[:limit * 2],
        "summary": " ".join(summary),
    }
