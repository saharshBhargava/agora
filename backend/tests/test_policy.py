"""Table-driven tests for the agent-commerce policy engine. Pure functions, no database."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.core.policy import (
    AgentSettings,
    Budget,
    Mandate,
    PastIntent,
    ProposedIntent,
    decide,
    money,
    period_start,
)

NOW = datetime(2026, 10, 15, 18, 0, tzinfo=UTC)  # Thursday 11:00 in Seattle
TZ = "America/Los_Angeles"
MONTH_START = datetime(2026, 10, 1, 7, 0, tzinfo=UTC)  # Oct 1 00:00 PDT
MARKET = "11111111-1111-1111-1111-111111111111"
OTHER = "22222222-2222-2222-2222-222222222222"

MILK = ProposedIntent(kind="purchase", title="Oat milk", item_key="oat milk", amount_cents=899, merchant_id=MARKET,
                      merchant_name="Ballard Market", category="dairy")
GROCERIES = Mandate(id="m1", label="Groceries", max_per_txn_cents=5000, max_per_period_cents=20000, period="month",
                    expires_at=NOW + timedelta(days=30), merchant_ids=frozenset({MARKET}),
                    categories=frozenset({"dairy", "produce"}))
ANYWHERE = Mandate(id="m2", label="Small stuff", max_per_txn_cents=1500, expires_at=NOW + timedelta(days=5))
L3 = AgentSettings(autonomy_level="buy_within_mandate", timezone=TZ)


def past(i: int, **fields) -> PastIntent:
    base = {"id": f"p{i}", "kind": "purchase", "status": "succeeded", "decision": "allow",
            "created_at": NOW - timedelta(days=1), "item_key": f"thing {i}", "amount_cents": 1000,
            "mandate_id": None, "category": "dairy", "mine": True}
    return PastIntent(**{**base, **fields})


def budget(**fields) -> Budget:
    return Budget(**{"id": "b1", "period": "month", "limit_cents": 30000, "spent_cents": 10000, **fields})


CASES = [
    # name, overrides, decision, codes
    ("paused beats everything", {"settings": replace(L3, paused=True)}, "deny", ["agent_paused"]),
    ("inform never acts", {"settings": AgentSettings("inform")}, "deny", ["autonomy_inform"]),
    ("inform can't even add to a list", {"settings": AgentSettings("inform"),
                                          "intent": replace(MILK, kind="list_add", amount_cents=None)},
     "deny", ["autonomy_inform"]),
    ("prepare adds to lists", {"settings": AgentSettings("prepare"),
                               "intent": replace(MILK, kind="list_add", amount_cents=None)},
     "allow", ["autonomy_allows"]),
    ("prepare fills carts", {"settings": AgentSettings("prepare"), "intent": replace(MILK, kind="add_to_cart")},
     "allow", ["autonomy_allows"]),
    ("calendar drafts at buy_with_approval", {"settings": AgentSettings("buy_with_approval"),
                                              "intent": replace(MILK, kind="calendar_event", amount_cents=None)},
     "allow", ["autonomy_allows"]),
    ("prepare escalates purchases", {"settings": AgentSettings("prepare")}, "needs_approval",
     ["autonomy_requires_approval"]),
    ("buy_with_approval always asks, even with a mandate", {"settings": AgentSettings("buy_with_approval")},
     "needs_approval", ["autonomy_requires_approval"]),
    ("buy_with_approval still reports budget", {"settings": AgentSettings("buy_with_approval"),
                                                "budgets": [budget()]},
     "needs_approval", ["autonomy_requires_approval", "within_budget"]),
    ("no mandate", {"mandates": []}, "needs_approval", ["no_mandate"]),
    ("revoked mandate is no mandate", {"mandates": [replace(GROCERIES, status="revoked")]}, "needs_approval",
     ["no_mandate"]),
    ("within mandate", {}, "allow", ["within_mandate", "mandate_period_left"]),
    ("within mandate and budget", {"budgets": [budget()]}, "allow",
     ["within_mandate", "mandate_period_left", "within_budget"]),
    ("over per-purchase cap", {"intent": replace(MILK, amount_cents=5001)}, "needs_approval", ["over_txn_cap"]),
    ("exactly at the cap is fine", {"intent": replace(MILK, amount_cents=5000)}, "allow",
     ["within_mandate", "mandate_period_left"]),
    ("confirm threshold", {"mandates": [replace(GROCERIES, require_confirm_above_cents=500)]}, "needs_approval",
     ["confirm_above"]),
    ("period cap reached by earlier purchases under the mandate",
     {"recent": [past(1, mandate_id="m1", amount_cents=10000), past(2, mandate_id="m1", amount_cents=9500,
                                                                    status="executing")]},
     "needs_approval", ["over_period_cap"]),
    ("period cap ignores last month, rejected, failed and other mandates",
     {"recent": [past(1, mandate_id="m1", amount_cents=19000, created_at=MONTH_START - timedelta(minutes=1)),
                 past(2, mandate_id="m1", amount_cents=19000, status="rejected", decision="needs_approval"),
                 past(3, mandate_id="m1", amount_cents=19000, status="failed"),
                 past(4, mandate_id="m9", amount_cents=19000)]},
     "allow", ["within_mandate", "mandate_period_left"]),
    ("weekly period cap", {"mandates": [replace(GROCERIES, period="week", max_per_period_cents=5000)],
                           "recent": [past(1, mandate_id="m1", amount_cents=4500,
                                           created_at=datetime(2026, 10, 12, 8, tzinfo=UTC))]},
     "needs_approval", ["over_period_cap"]),
    ("other merchant", {"intent": replace(MILK, merchant_id=OTHER, merchant_name="Safeway")}, "needs_approval",
     ["outside_mandate"]),
    ("unknown merchant against a merchant-scoped mandate", {"intent": replace(MILK, merchant_id=None)},
     "needs_approval", ["outside_mandate"]),
    ("other category", {"intent": replace(MILK, category="household")}, "needs_approval", ["outside_mandate"]),
    ("expired mandate", {"mandates": [replace(GROCERIES, expires_at=NOW - timedelta(seconds=1))]},
     "needs_approval", ["mandate_expired"]),
    ("unscoped mandate covers anything", {"mandates": [ANYWHERE]}, "allow", ["within_mandate"]),
    ("falls through to a second mandate that fits",
     {"mandates": [replace(GROCERIES, max_per_txn_cents=500), ANYWHERE]}, "allow", ["within_mandate"]),
    ("over budget escalates even within mandate", {"budgets": [budget(spent_cents=29500)]}, "needs_approval",
     ["over_budget", "within_mandate", "mandate_period_left"]),
    ("used-up budget", {"budgets": [budget(spent_cents=30000)]}, "needs_approval",
     ["over_budget", "within_mandate", "mandate_period_left"]),
    ("budget counts approved-but-unsettled purchases",
     {"budgets": [budget(spent_cents=20000)],
      "recent": [past(1, status="approved", amount_cents=9500, mine=False)]},
     "needs_approval", ["over_budget", "within_mandate", "mandate_period_left"]),
    ("budget for another category doesn't apply", {"budgets": [budget(category="household", spent_cents=30000)]},
     "allow", ["within_mandate", "mandate_period_left"]),
    ("category and overall budgets both apply",
     {"budgets": [budget(), budget(id="b2", category="dairy", limit_cents=1000, spent_cents=0)]},
     "allow", ["within_mandate", "mandate_period_left", "within_budget", "within_budget"]),
    ("identical request pending", {"recent": [past(1, item_key="oat milk", status="proposed",
                                                   decision="needs_approval")]},
     "deny", ["duplicate_pending"]),
    ("identical request from another household member in flight",
     {"recent": [past(1, item_key="oat milk", status="executing", mine=False)]}, "deny", ["duplicate_pending"]),
    ("bought two days ago", {"recent": [past(1, item_key="oat milk", created_at=NOW - timedelta(days=2))]},
     "needs_approval", ["duplicate_recent", "within_mandate", "mandate_period_left"]),
    ("earlier order outcome unknown", {"recent": [past(1, item_key="oat milk", status="outcome_unknown")]},
     "needs_approval", ["duplicate_unknown", "within_mandate", "mandate_period_left"]),
    ("bought long ago is not a duplicate",
     {"recent": [past(1, item_key="oat milk", created_at=NOW - timedelta(days=8))]},
     "allow", ["within_mandate", "mandate_period_left"]),
    ("a failed earlier order is not a duplicate", {"recent": [past(1, item_key="oat milk", status="failed")]},
     "allow", ["within_mandate", "mandate_period_left"]),
    ("velocity limit", {"recent": [past(i, created_at=NOW - timedelta(minutes=10 * i)) for i in range(1, 4)]},
     "deny", ["velocity_limit"]),
    ("velocity ignores denials, other members and older purchases",
     {"recent": [past(1, created_at=NOW - timedelta(minutes=5), decision="deny", status="rejected"),
                 past(2, created_at=NOW - timedelta(minutes=5), mine=False),
                 past(3, created_at=NOW - timedelta(minutes=61)),
                 past(4, created_at=NOW - timedelta(minutes=5)),
                 past(5, created_at=NOW - timedelta(minutes=5), kind="list_add"),
                 past(6, created_at=NOW - timedelta(minutes=5), status="cancelled")]},
     "allow", ["within_mandate", "mandate_period_left"]),
    ("velocity counts escalated requests too",
     {"recent": [past(i, created_at=NOW - timedelta(minutes=i), decision="needs_approval", status="rejected")
                 for i in range(1, 4)]},
     "deny", ["velocity_limit"]),
    ("purchase without a price", {"intent": replace(MILK, amount_cents=None)}, "deny", ["missing_amount"]),
]


@pytest.mark.parametrize(("name", "overrides", "decision", "codes"), CASES, ids=[c[0] for c in CASES])
def test_decide(name, overrides, decision, codes):
    verdict = decide(overrides.get("intent", MILK), overrides.get("settings", L3),
                     overrides.get("mandates", [GROCERIES]), overrides.get("budgets", []),
                     overrides.get("recent", []), NOW)
    assert (verdict.decision, verdict.codes) == (decision, codes), verdict.messages
    assert all(r.message.endswith(".") for r in verdict.reasons)
    if decision == "allow" and overrides.get("intent", MILK).kind == "purchase":
        assert verdict.mandate_id is not None
    else:
        assert verdict.mandate_id is None


def test_messages_are_user_facing():
    allowed = decide(MILK, L3, [GROCERIES], [budget()], [past(1, mandate_id="m1", amount_cents=4000)], NOW)
    assert allowed.messages == [
        "Within your 'Groceries' mandate: $8.99 of $50.00 allowed per purchase.",
        "$151.01 left on 'Groceries' this month after this.",
        "$191.01 left in your monthly budget after this.",
    ]
    assert allowed.mandate_id == "m1"

    over = decide(replace(MILK, amount_cents=12500), L3, [GROCERIES],
                  [budget(category="dairy", limit_cents=10000, spent_cents=2000)], [], NOW)
    assert over.messages == [
        "$125.00 is over the $50.00 per-purchase limit in your 'Groceries' mandate.",
        "This would take your monthly dairy budget to $145.00 of $100.00.",
    ]
    outside = decide(replace(MILK, merchant_id=OTHER, merchant_name="Safeway"), L3, [GROCERIES], [], [], NOW)
    assert outside.messages == ["None of your mandates cover 'Oat milk' at Safeway (dairy)."]
    expired = decide(MILK, L3, [replace(GROCERIES, expires_at=datetime(2026, 10, 2, 6, tzinfo=UTC))], [], [], NOW)
    assert expired.messages == ["Your 'Groceries' mandate expired on Oct 1. Renew it to let the agent buy on its own."]
    dup = decide(MILK, L3, [GROCERIES], [], [past(1, item_key="oat milk", created_at=NOW - timedelta(hours=3))], NOW)
    assert dup.messages[0] == "'Oat milk' was already bought 3 hours ago."


def test_decide_is_deterministic():
    args = (MILK, L3, [GROCERIES, ANYWHERE], [budget()], [past(i) for i in range(5)], NOW)
    assert len({decide(*args) for _ in range(20)}) == 1


def test_unknown_autonomy_level_is_a_bug():
    with pytest.raises(ValueError):
        decide(MILK, AgentSettings("yolo"), [], [], [], NOW)


def test_period_start_in_local_time():
    tz = ZoneInfo(TZ)
    assert period_start(NOW, "month", tz) == MONTH_START
    assert period_start(NOW, "week", tz) == datetime(2026, 10, 12, 7, tzinfo=UTC)
    assert period_start(NOW, "day", tz) == datetime(2026, 10, 15, 7, tzinfo=UTC)
    # 03:00 UTC on Nov 1 is still Oct 31 in Seattle.
    assert period_start(datetime(2026, 11, 1, 3, tzinfo=UTC), "month", tz) == MONTH_START
    with pytest.raises(ValueError):
        period_start(NOW, "year", tz)


def test_money():
    assert (money(0), money(899), money(123456), money(-250)) == ("$0.00", "$8.99", "$1,234.56", "-$2.50")
