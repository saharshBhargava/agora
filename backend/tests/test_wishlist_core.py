"""Unit tests for the pure wishlist logic: no database needed."""

from datetime import UTC, date, datetime, timedelta

from app.core.wishlist import (
    FeedbackIndex,
    Outcome,
    Rejection,
    ScoreInput,
    Tally,
    agent_context,
    blocking_rejection,
    category_key,
    rank_key,
    score,
    title_key,
)

NOW = datetime(2026, 10, 17, 12, 0, tzinfo=UTC)


def item(**kw) -> ScoreInput:
    return ScoreInput(**{"source": "agent", "created_at": NOW, "confidence": 0.5, **kw})


def outcome(item_id, title, category, status, accepted=False, reason=None, up=0, down=0, decided=NOW,
            price=None) -> Outcome:
    return Outcome(item_id=item_id, title=title, title_key=title_key(title), category=category, status=status,
                   accepted=accepted, reject_reason=reason, decided_at=decided, target_price_cents=price,
                   thumbs_up=up, thumbs_down=down)


def test_title_key_matches_the_same_thing_written_differently():
    assert title_key("Potato Chips!") == title_key("  potato   chip ") == "potato chip"
    assert title_key("2% Milk") == "2 milk"
    assert title_key("!!!") == "!!!"  # never empty, even with no letters or digits
    assert category_key("  Frozen   Foods ") == "frozen foods" and category_key(" ") is None


def test_pinned_beats_priority_beats_any_signal():
    pinned = score(item(source="user", pinned=True, priority=1), NOW)
    high = score(item(source="user", priority=5), NOW)
    # The strongest possible unprioritised item: overdue, running low, very old, confident, well liked.
    loaded = score(item(confidence=1.0, needed_by=date(2026, 1, 1), on_hand=0, par_level=5,
                        created_at=NOW - timedelta(days=90), category="dairy",
                        category_feedback=Tally(liked=10), title_feedback=Tally(liked=10)), NOW)
    low = score(item(source="user", priority=1), NOW)
    assert pinned.value > high.value > loaded.value > low.value
    assert loaded.value < 400  # signals are capped below one priority tier
    assert pinned.reasons[:2] == ["Pinned by you", "You set priority lowest"]


def test_user_items_outrank_equally_unremarkable_agent_items():
    assert score(item(source="user"), NOW).value > score(item(confidence=0.9), NOW).value
    assert score(item(source="user"), NOW).reasons == ["Added by you"]


def test_confidence_moves_agent_suggestions_both_ways():
    sure, unsure = score(item(confidence=0.95), NOW), score(item(confidence=0.1), NOW)
    neutral = score(item(confidence=0.5), NOW)
    assert sure.value > neutral.value > unsure.value
    assert neutral.reasons == []  # a zero contribution isn't worth explaining
    assert sure.reasons == ["Agent is 95% confident"]


def test_negative_category_feedback_down_weights_suggestions_only():
    disliked = Tally(liked=1, disliked=4)
    agent = score(item(category="snacks", category_feedback=disliked), NOW)
    assert agent.value == score(item(), NOW).value - 12
    assert agent.reasons == ["You turned down 4 similar suggestions in snacks"]
    # Feedback on suggestions never re-ranks something the user asked for.
    user = score(item(source="user", category="snacks", category_feedback=disliked), NOW)
    assert user.value == score(item(source="user"), NOW).value
    capped = score(item(category="snacks", category_feedback=Tally(disliked=50)), NOW)
    assert capped.value == score(item(), NOW).value - 16


def test_title_feedback_weighs_more_than_category_feedback():
    by_title = score(item(title_feedback=Tally(liked=1)), NOW)
    by_category = score(item(category="dairy", category_feedback=Tally(liked=1)), NOW)
    assert by_title.value > by_category.value > score(item(), NOW).value
    assert by_title.reasons == ["You liked this suggestion before"]
    assert score(item(title_feedback=Tally(disliked=1)), NOW).reasons == ["You turned this down before"]


def test_needed_by_urgency_steps():
    def pts(days):
        return score(item(needed_by=(NOW + timedelta(days=days)).date()), NOW).value
    assert pts(-2) > pts(0) == pts(3) > pts(5) > pts(10) > pts(30) == score(item(), NOW).value
    assert score(item(needed_by=NOW.date()), NOW).reasons == ["Needed today"]
    assert score(item(needed_by=date(2026, 10, 1)), NOW).reasons == ["Past its needed-by date"]


def test_below_par_and_age():
    low = score(item(on_hand=0.5, par_level=2), NOW)
    assert low.reasons == ["Running low: 0.5 left, you keep 2"]
    assert score(item(on_hand=2, par_level=2), NOW).reasons == []
    assert score(item(created_at=NOW - timedelta(days=2)), NOW).reasons == []  # too new to mention
    week = score(item(created_at=NOW - timedelta(days=9)), NOW)
    assert week.reasons == ["Waiting 9 days"] and week.value == score(item(), NOW).value + 3
    assert score(item(created_at=NOW - timedelta(days=400)), NOW).value == score(item(), NOW).value + 10


def test_score_is_deterministic_and_reasons_are_short_and_ordered():
    busy = item(source="user", pinned=True, priority=5, needed_by=date(2026, 10, 1), on_hand=0, par_level=1,
                created_at=NOW - timedelta(days=12))
    first, second = score(busy, NOW), score(busy, NOW)
    assert first == second
    assert first.reasons == ["Pinned by you", "You set priority highest", "Past its needed-by date",
                             "Added by you"]


def test_rank_key_breaks_ties_by_age_then_id():
    older, newer = NOW - timedelta(days=1), NOW
    keys = [rank_key(300, newer, "b"), rank_key(300, older, "z"), rank_key(301, newer, "c"),
            rank_key(300, newer, "a")]
    assert sorted(keys) == [(-301, newer, "c"), (-300, older, "z"), (-300, newer, "a"), (-300, newer, "b")]


def test_feedback_index_counts_accepts_thumbs_and_taste_rejections():
    index = FeedbackIndex([
        outcome("1", "Chips", "snacks", "rejected", reason="not_interested", down=1),
        outcome("2", "Pretzels", "snacks", "rejected", reason="already_have"),  # timing, not taste
        outcome("3", "Popcorn", "snacks", "active", accepted=True, up=2),
        outcome("4", "Chips", "snacks", "snoozed"),  # snoozing is not a signal
    ])
    assert index.by_category["snacks"] == Tally(liked=3, disliked=2)
    assert index.by_title["chip"] == Tally(liked=0, disliked=2)
    # An item never counts towards its own score.
    assert index.similar("1", "snacks", "chip") == (Tally(liked=3, disliked=0), Tally())
    assert index.similar(None, "snacks", "chip") == (Tally(liked=3, disliked=2), Tally(disliked=2))
    assert index.similar("3", None, "popcorn") == (Tally(), Tally())


def test_rejection_blocks_resuggestion_for_thirty_days():
    recent = Rejection("chip", "not_interested", NOW - timedelta(days=29))
    assert blocking_rejection("chip", None, [recent], NOW) == recent
    assert blocking_rejection("pretzel", None, [recent], NOW) is None
    old = Rejection("chip", "not_interested", NOW - timedelta(days=31))
    assert blocking_rejection("chip", None, [old], NOW) is None


def test_too_expensive_only_allows_a_lower_price():
    pricey = Rejection("air fryer", "too_expensive", NOW - timedelta(days=1), target_price_cents=12000)
    assert blocking_rejection("air fryer", 11999, [pricey], NOW) is None
    assert blocking_rejection("air fryer", 12000, [pricey], NOW) == pricey
    assert blocking_rejection("air fryer", None, [pricey], NOW) == pricey
    unpriced = Rejection("air fryer", "too_expensive", NOW - timedelta(days=1))
    assert blocking_rejection("air fryer", 100, [unpriced], NOW) == unpriced
    # A later "not interested" still blocks even if an earlier price objection would let it through.
    later = Rejection("air fryer", "not_interested", NOW)
    assert blocking_rejection("air fryer", 5000, [pricey, later], NOW) == later


def test_agent_context_is_compact_and_complete():
    ctx = agent_context([
        outcome("1", "Almond milk", "dairy", "active", accepted=True, up=1),
        outcome("2", "Chips", "snacks", "rejected", reason="not_interested", decided=NOW - timedelta(days=2)),
        outcome("3", "Blender", "kitchen", "rejected", reason="too_expensive", price=9900, down=1),
        outcome("4", "Old fad", "toys", "rejected", reason="wrong_item", decided=NOW - timedelta(days=60)),
        outcome("5", "Limes", "produce", "snoozed"),
    ], [("Almond milk", "active"), ("Limes", "snoozed"), ("Chips", "active")], NOW)
    assert ctx["suggestions"] == {"accepted": 1, "rejected": 3, "pending": 1, "acceptance_rate": 0.25}
    assert ctx["liked_categories"] == [{"category": "dairy", "count": 2}]
    assert ctx["disliked_categories"] == [{"category": "kitchen", "count": 2}, {"category": "snacks", "count": 1},
                                          {"category": "toys", "count": 1}]
    assert [r["title"] for r in ctx["recently_rejected"]] == ["Blender", "Chips"]  # newest first, 30-day window
    titles = [(d["title"], d["reason"]) for d in ctx["do_not_suggest"]]
    assert titles == [("Blender", "rejected:too_expensive"), ("Chips", "rejected:not_interested"),
                      ("Almond milk", "already_on_wishlist"), ("Limes", "already_snoozed")]
    assert ctx["do_not_suggest"][0]["unless_price_below_cents"] == 9900
    assert ctx["do_not_suggest"][1]["until"] == "2026-11-14"
    assert ctx["summary"].startswith("Accepted 1 of 4 decided suggestions. Likes: dairy (2).")
