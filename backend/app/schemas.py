from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, field_validator, model_validator


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


def plausible_purchase_date(value: date) -> date:
    # One day of slack covers time zones ahead of UTC; two years back is plenty for groceries.
    today = datetime.now(UTC).date()
    if value > today + timedelta(days=1):
        raise ValueError("purchased_on can't be in the future")
    if value < today - timedelta(days=730):
        raise ValueError("purchased_on must be within the last two years")
    return value


PurchaseDate = Annotated[date, AfterValidator(plausible_purchase_date)]


# ---------------------------------------------------------------- auth / me

class DevLoginIn(Strict):
    handle: str = Field(pattern=r"^[a-z0-9_]{3,32}$")
    display_name: str | None = Field(default=None, min_length=1, max_length=80)
    password: str | None = Field(default=None, max_length=200, description="Required on hosted demo deploys")


class TokenOut(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"  # noqa: S105
    expires_at: int


class Location(BaseModel):
    id: UUID
    name: str
    kind: str


class Household(BaseModel):
    id: UUID
    name: str
    role: str
    locations: list[Location]


class Settings(BaseModel):
    timezone: str
    autonomy_level: str
    household_size: int
    media_retention: str


class SettingsPatch(Strict):
    timezone: str | None = Field(default=None, max_length=64)
    autonomy_level: Literal["inform", "prepare", "buy_with_approval", "buy_within_mandate"] | None = None
    household_size: int | None = Field(default=None, ge=1, le=20)
    media_retention: Literal["delete_after_review", "24h", "7d"] | None = None


class Me(BaseModel):
    id: UUID
    handle: str
    display_name: str
    settings: Settings
    households: list[Household]


class LocationIn(Strict):
    name: str = Field(min_length=1, max_length=40)
    kind: Literal["fridge", "freezer", "pantry", "bathroom", "other"]


# ---------------------------------------------------------------- merchants

class MerchantRef(BaseModel):
    id: UUID
    name: str
    locality: str | None
    scope: Literal["global", "household"]


class Merchant(BaseModel):
    id: UUID
    name: str
    locality: str | None
    kind: str
    is_small_business: bool
    website: str | None
    scope: Literal["global", "household"]
    household_id: UUID | None


class MerchantIn(Strict):
    name: str = Field(min_length=1, max_length=80)
    locality: str | None = Field(default=None, max_length=80, description="Neighborhood or branch, e.g. 'Ballard'")
    kind: Literal["grocery", "big_box", "online", "local", "other"] = "other"
    website: str | None = Field(default=None, max_length=200, pattern=r"^https://")
    household_id: UUID | None = None

    @field_validator("name")
    @classmethod
    def _has_letters(cls, value: str) -> str:
        if not any(c.isalnum() for c in value):
            raise ValueError("name needs at least one letter or digit")
        return value.strip()


class MerchantCreated(BaseModel):
    merchant: Merchant
    created: bool


# ---------------------------------------------------------------- inventory

class ItemOut(BaseModel):
    id: UUID
    household_id: UUID
    display_name: str
    category: str | None
    location_id: UUID | None
    unit: str
    par_level: float | None
    status: str
    product_id: UUID | None
    quantity: float | None = None
    observed_at: datetime | None = None
    source: str | None = None
    preferred_merchant_id: UUID | None = None
    last_purchased_from: MerchantRef | None = None
    last_purchased_on: date | None = None


class ItemIn(Strict):
    household_id: UUID
    display_name: str = Field(min_length=1, max_length=120)
    category: str | None = Field(default=None, max_length=40)
    location_id: UUID | None = None
    unit: str = Field(default="unit", max_length=20)
    par_level: float | None = Field(default=None, ge=0, le=10000)
    quantity: float | None = Field(default=None, ge=0, le=10000)
    preferred_merchant_id: UUID | None = None


class RecognitionItemIn(Strict):
    inventory_item_id: UUID | None = None
    display_name: str = Field(min_length=1, max_length=120)
    category: str | None = Field(default=None, max_length=40)
    unit: str = Field(min_length=1, max_length=20)
    quantity: float = Field(ge=0, le=10000, allow_inf_nan=False)
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)

    @field_validator("display_name", "unit")
    @classmethod
    def nonblank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("must not be blank")
        return value.strip()


class RecognitionIn(Strict):
    """Reviewed, client-recognized metadata only. No media or media references accepted."""
    household_id: UUID
    captured_at: datetime
    media_kind: Literal["photos", "video"]
    provider: Literal["gemini", "openai-compatible", "builtin"] = "gemini"
    model: str = Field(min_length=1, max_length=120, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:/ -]*$")
    location_id: UUID | None = None
    purchased_from_merchant_id: UUID | None = None
    purchased_on: PurchaseDate | None = None
    items: list[RecognitionItemIn] = Field(min_length=1, max_length=100)

    @field_validator("captured_at")
    @classmethod
    def valid_time(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value > datetime.now(UTC) + timedelta(minutes=5):
            raise ValueError("captured_at must include a time zone and cannot be in the future")
        return value


class RecognitionOut(BaseModel):
    recognition_id: UUID
    items: list[ItemOut]


class ItemPatch(Strict):
    display_name: str | None = Field(default=None, min_length=1, max_length=120)
    location_id: UUID | None = None
    par_level: float | None = Field(default=None, ge=0, le=10000)
    status: Literal["active", "archived"] | None = None
    preferred_merchant_id: UUID | None = None


class ObservationIn(Strict):
    quantity: float = Field(ge=0, le=10000)
    time: datetime | None = None


class Observation(BaseModel):
    time: datetime
    quantity: float
    source: str
    scan_id: UUID | None
    confidence: float | None


class DailyPoint(BaseModel):
    day: datetime
    quantity: float | None


class PurchaseOrigin(BaseModel):
    merchant: MerchantRef | None
    purchased_on: date | None
    observed_at: datetime
    quantity: float
    scan_id: UUID
    detection_id: UUID


class ForecastOut(BaseModel):
    """The latest run-out forecast for an item, with the evidence behind it and a sentence explaining it."""

    computed_at: datetime
    method: Literal["theil_sen", "blended", "prior", "insufficient"]
    status: Literal["out", "runs_out", "steady", "unknown"]
    confidence: Literal["low", "medium", "high"]
    rate_per_day: float | None
    rate_lo: float | None
    rate_hi: float | None
    qty_now: float | None = Field(description="Estimated quantity right now, projected from the last reading")
    last_observed_at: datetime | None
    last_quantity: float | None
    runout_at: datetime | None
    runout_lo: datetime | None
    runout_hi: datetime | None
    n_obs: int
    n_segments: int
    span_days: float
    restock_qty: float | None
    explanation: str


class ItemDetail(ItemOut):
    daily: list[DailyPoint]
    observations: list[Observation]
    purchase_history: list[PurchaseOrigin]
    series_engine: Literal["timescale", "postgres"]
    forecast: ForecastOut | None = None


class Runout(BaseModel):
    item: ItemOut
    forecast: ForecastOut
    suggested_quantity: float
    suggested_merchant: MerchantRef | None
    merchant_basis: Literal["preferred", "last_purchase"] | None
    on_list_id: UUID | None = Field(description="An open shopping list that already has this item, if any")


class RunoutsOut(BaseModel):
    household_id: UUID
    within_days: int
    as_of: datetime
    runouts: list[Runout]


# ---------------------------------------------------------------- scans

class Detection(BaseModel):
    id: UUID
    label: str
    brand: str | None
    category: str | None
    count: int
    fill_fraction: float | None
    quantity: float
    confidence: float
    match_score: float | None
    inventory_item_id: UUID | None
    inventory_item_name: str | None
    product_id: UUID | None
    bbox: dict | None
    frame_index: int | None
    review: str
    auto_accepted: bool
    # Effective store for this product: the detection's override if set, else the scan's store.
    purchased_from_merchant_id: UUID | None
    purchased_from: MerchantRef | None
    merchant_override: bool
    # Effective purchase date: the detection's override if set, else the scan's.
    purchased_on: date | None
    purchased_on_override: bool


class ScanOut(BaseModel):
    id: UUID
    household_id: UUID
    location_id: UUID | None
    captured_at: datetime
    media_kind: str
    frame_count: int
    media_deleted: bool
    status: str
    provider: str | None
    model: str | None
    latency_ms: int | None
    error_code: str | None
    created_at: datetime
    purchased_from_merchant_id: UUID | None
    purchased_from: MerchantRef | None
    purchased_on: date | None
    detections: list[Detection] = []


class ScanPatch(Strict):
    """Upload-level store and/or purchase date. Send only the fields to change; null clears one."""
    purchased_from_merchant_id: UUID | None = None
    purchased_on: PurchaseDate | None = None

    @model_validator(mode="after")
    def _something(self) -> "ScanPatch":
        if not self.model_fields_set:
            raise ValueError("send purchased_from_merchant_id and/or purchased_on")
        return self


class DetectionPatch(Strict):
    """Per-product overrides. Setting a field (null = explicitly none) overrides the upload's value for this
    product; listing it in ``inherit`` goes back to the upload's value."""
    purchased_from_merchant_id: UUID | None = None
    purchased_on: PurchaseDate | None = None
    inherit: list[Literal["purchased_from", "purchased_on"]] = Field(default_factory=list, max_length=2)

    @model_validator(mode="after")
    def _consistent(self) -> "DetectionPatch":
        field_names = {"purchased_from_merchant_id": "purchased_from", "purchased_on": "purchased_on"}
        setting = {name for field, name in field_names.items() if field in self.model_fields_set}
        if not setting and not self.inherit:
            raise ValueError("send a field to set, or list fields in inherit")
        if setting & set(self.inherit):
            raise ValueError("a field can't be both set and inherited")
        return self


class ReviewDecision(Strict):
    detection_id: UUID
    action: Literal["accept", "reject", "correct"]
    label: str | None = Field(default=None, min_length=1, max_length=80)
    quantity: float | None = Field(default=None, ge=0, le=10000)
    inventory_item_id: UUID | None = None
    # Optional per-product overrides; include a key with null to mark "none" for this product.
    purchased_from_merchant_id: UUID | None = None
    purchased_on: PurchaseDate | None = None


class ReviewIn(Strict):
    decisions: list[ReviewDecision] = Field(default_factory=list, max_length=100)
    # What happens to detections not mentioned in ``decisions``. Default: nothing is added without a yes.
    remaining: Literal["accept", "reject"] = "reject"


class ReviewOut(BaseModel):
    scan: ScanOut
    items_updated: int


# ---------------------------------------------------------------- audit

class AuditEntry(BaseModel):
    id: int
    time: datetime
    actor_type: str
    action: str
    target_type: str | None
    target_id: str | None
    meta: dict


class AuditVerify(BaseModel):
    ok: bool
    rows_checked: int
    first_broken_id: int | None


# ---------------------------------------------------------------- wishlist

RejectReason = Literal["not_interested", "already_have", "too_expensive", "wrong_item", "other"]
WishlistStatus = Literal["suggested", "active", "snoozed", "rejected", "purchased", "removed"]


class Evidence(Strict):
    kind: Literal["inventory_low", "purchase_history", "calendar", "price", "seasonal", "other"]
    detail: str = Field(min_length=1, max_length=200)


class WishlistItemIn(Strict):
    household_id: UUID | None = None
    title: str = Field(min_length=1, max_length=120)
    notes: str | None = Field(default=None, max_length=1000)
    category: str | None = Field(default=None, min_length=1, max_length=40)
    quantity: int = Field(default=1, ge=1, le=99)
    target_price_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    needed_by: date | None = None
    priority: int | None = Field(default=None, ge=1, le=5)
    pinned: bool = False
    product_id: UUID | None = None
    inventory_item_id: UUID | None = None


class WishlistSuggestionIn(Strict):
    household_id: UUID | None = None
    title: str = Field(min_length=1, max_length=120)
    rationale: str = Field(min_length=1, max_length=500)
    confidence: float = Field(ge=0, le=1)
    evidence: list[Evidence] = Field(default_factory=list, max_length=5)
    category: str | None = Field(default=None, min_length=1, max_length=40)
    quantity: int = Field(default=1, ge=1, le=99)
    target_price_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    needed_by: date | None = None
    product_id: UUID | None = None
    inventory_item_id: UUID | None = None


class WishlistPatch(Strict):
    title: str | None = Field(default=None, min_length=1, max_length=120)
    notes: str | None = Field(default=None, max_length=1000)
    category: str | None = Field(default=None, min_length=1, max_length=40)
    quantity: int | None = Field(default=None, ge=1, le=99)
    target_price_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    needed_by: date | None = None
    priority: int | None = Field(default=None, ge=1, le=5)
    pinned: bool | None = None


class RejectIn(Strict):
    reason_code: RejectReason
    comment: str | None = Field(default=None, max_length=500)


class SnoozeIn(Strict):
    """Either ``until`` (an offset-aware time) or ``days`` from now."""

    until: datetime | None = None
    days: int | None = Field(default=None, ge=1, le=180)

    @model_validator(mode="after")
    def _one_of(self) -> "SnoozeIn":
        if (self.until is None) == (self.days is None):
            raise ValueError("send exactly one of until or days")
        return self


class FeedbackIn(Strict):
    rating: Literal["up", "down"]
    reason_code: RejectReason | None = None
    comment: str | None = Field(default=None, max_length=500)


class FeedbackOut(BaseModel):
    wishlist_item_id: UUID
    rating: Literal["up", "down"]
    reason_code: str | None
    comment: str | None
    updated_at: datetime


class WishlistItem(BaseModel):
    id: UUID
    household_id: UUID
    title: str
    notes: str | None
    category: str | None
    quantity: int
    target_price_cents: int | None
    needed_by: date | None
    product_id: UUID | None
    inventory_item_id: UUID | None
    source: Literal["user", "agent"]
    status: WishlistStatus
    pinned: bool
    priority: int | None
    confidence: float | None
    rationale: str | None
    evidence: list[dict]
    snoozed_until: datetime | None
    reject_reason: str | None
    reject_comment: str | None
    my_feedback: Literal["up", "down"] | None
    score: float
    priority_reasons: list[str]
    created_at: datetime
    updated_at: datetime
    decided_at: datetime | None
    completed_at: datetime | None


class WishlistRefreshIn(Strict):
    household_id: UUID | None = None


class WishlistRefreshOut(BaseModel):
    household_id: UUID
    last_refreshed_at: datetime | None
    next_refresh_at: datetime
    last_error: str | None
    generated_count: int


# ---------------------------------------------------------------- agent commerce

IntentKind = Literal["purchase", "add_to_cart", "list_add", "calendar_event"]
IntentStatus = Literal["proposed", "approved", "rejected", "cancelled", "executing", "succeeded", "failed",
                       "outcome_unknown"]
IntentDecision = Literal["allow", "needs_approval", "deny"]
IntentRejectReason = Literal["too_expensive", "not_needed", "wrong_item", "wrong_merchant", "other"]
Cents = Annotated[int, Field(ge=1, le=10_000_000)]
DetailValue = Annotated[str, Field(max_length=300)] | int | float | bool | None


class IntentEvidence(Strict):
    kind: Literal["inventory_low", "runout_forecast", "purchase_history", "wishlist", "price", "product_page",
                  "calendar", "other"]
    detail: str = Field(min_length=1, max_length=200)


class IntentIn(Strict):
    """What the agent wants to do. The server decides whether it may; the model's own view is only evidence."""

    household_id: UUID | None = None
    kind: IntentKind
    title: str = Field(min_length=1, max_length=120)
    rationale: str = Field(min_length=1, max_length=500)
    evidence: list[IntentEvidence] = Field(default_factory=list, max_length=5)
    amount_cents: Cents | None = None
    currency: Literal["USD"] = "USD"
    quantity: int = Field(default=1, ge=1, le=99)
    merchant_id: UUID | None = None
    merchant_name: str | None = Field(default=None, min_length=1, max_length=80)
    category: str | None = Field(default=None, min_length=1, max_length=40)
    product_id: UUID | None = None
    url: str | None = Field(default=None, max_length=2000, pattern=r"^https://")
    # "device": the on-device browser agent acts in the visible browser and reports the outcome.
    # "agora": the server charges a tokenized payment method (purchases only).
    execution: Literal["device", "agora"] = "device"
    payment_method_ref: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{4,100}$")
    details: dict[Annotated[str, Field(pattern=r"^[a-z0-9_]{1,40}$")], DetailValue] = Field(default_factory=dict,
                                                                                            max_length=20)

    @model_validator(mode="after")
    def _consistent(self) -> "IntentIn":
        if self.kind == "purchase" and self.amount_cents is None:
            raise ValueError("a purchase needs amount_cents")
        if self.execution == "agora" and self.kind != "purchase":
            raise ValueError("only purchases can use Agora checkout")
        if self.payment_method_ref is not None and self.execution != "agora":
            raise ValueError("payment_method_ref is only for Agora checkout")
        return self


class IntentOut(BaseModel):
    id: UUID
    household_id: UUID
    kind: IntentKind
    execution: Literal["device", "agora"]
    title: str
    payload: dict
    amount_cents: int | None
    final_amount_cents: int | None
    currency: str
    merchant_id: UUID | None
    merchant_name: str | None
    category: str | None
    rationale: str
    evidence: list[dict]
    decision: IntentDecision
    decision_reasons: list[str]
    reason_codes: list[str]
    mandate_id: UUID | None
    status: IntentStatus
    decided_by: Literal["policy", "user", "kill_switch"] | None
    decided_at: datetime | None
    reject_reason: str | None
    error_code: str | None
    order_id: UUID | None
    mine: bool
    approval_expires_at: datetime | None
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None


class IntentRejectIn(Strict):
    reason_code: IntentRejectReason | None = None


class IntentOutcomeIn(Strict):
    """Reported by the on-device agent for ``execution: "device"`` intents."""

    status: Literal["executing", "succeeded", "failed", "outcome_unknown"]
    final_amount_cents: int | None = Field(default=None, ge=0, le=100_000_000)
    error_code: str | None = Field(default=None, pattern=r"^[a-z0-9_]{1,40}$")


class MandateIn(Strict):
    household_id: UUID | None = None
    label: str = Field(min_length=1, max_length=60)
    merchant_ids: list[UUID] | None = Field(default=None, min_length=1, max_length=20)
    categories: list[Annotated[str, Field(min_length=1, max_length=40)]] | None = Field(default=None, min_length=1,
                                                                                        max_length=20)
    max_per_txn_cents: Cents
    max_per_period_cents: int | None = Field(default=None, ge=1, le=100_000_000)
    period: Literal["day", "week", "month"] = "month"
    require_confirm_above_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    expires_at: datetime | None = None
    expires_in_days: int | None = Field(default=None, ge=1, le=365)

    @model_validator(mode="after")
    def _consistent(self) -> "MandateIn":
        if self.max_per_period_cents is not None and self.max_per_period_cents < self.max_per_txn_cents:
            raise ValueError("max_per_period_cents can't be below max_per_txn_cents")
        if self.expires_at is not None and self.expires_in_days is not None:
            raise ValueError("send expires_at or expires_in_days, not both")
        if self.expires_at is not None and self.expires_at.tzinfo is None:
            raise ValueError("expires_at must include a time zone offset")
        return self


class MandateOut(BaseModel):
    id: UUID
    household_id: UUID
    label: str
    merchant_ids: list[UUID] | None
    categories: list[str] | None
    currency: str
    max_per_txn_cents: int
    max_per_period_cents: int | None
    period: Literal["day", "week", "month"]
    require_confirm_above_cents: int | None
    expires_at: datetime
    status: Literal["active", "expired", "revoked"]
    revoked_at: datetime | None
    revoked_reason: str | None
    period_started_at: datetime
    spent_this_period_cents: int
    created_at: datetime


class AgentState(BaseModel):
    autonomy_level: str
    paused: bool
    paused_at: datetime | None
    active_mandates: int
    pending_approvals: int


class PauseOut(BaseModel):
    paused: bool
    paused_at: datetime | None
    mandates_revoked: int
    intents_cancelled: int
    in_flight: int


class BudgetIn(Strict):
    household_id: UUID | None = None
    period: Literal["week", "month"]
    category: str | None = Field(default=None, min_length=1, max_length=40)
    limit_cents: int = Field(ge=1, le=100_000_000)


class BudgetPatch(Strict):
    limit_cents: int | None = Field(default=None, ge=1, le=100_000_000)
    status: Literal["active", "archived"] | None = None


class BudgetOut(BaseModel):
    id: UUID
    household_id: UUID
    period: Literal["week", "month"]
    category: str | None
    limit_cents: int
    currency: str
    status: Literal["active", "archived"]
    starts_on: date
    period_started_at: datetime
    spent_cents: int
    pending_cents: int
    remaining_cents: int
    created_at: datetime
    updated_at: datetime


class SpendGroup(BaseModel):
    key: str | None
    label: str
    amount_cents: int
    entries: int


class SpendOut(BaseModel):
    household_id: UUID
    period: Literal["week", "month"]
    group: Literal["category", "merchant", "none"]
    start: datetime
    end: datetime
    currency: str
    total_cents: int
    groups: list[SpendGroup]
    budgets: list[BudgetOut]


# ---------------------------------------------------------------- shopping lists

ListReason = Literal["runout", "manual", "agent", "price_drop"]
ListStatus = Literal["open", "done", "archived"]


class ShoppingListItem(BaseModel):
    id: UUID
    list_id: UUID
    title: str
    inventory_item_id: UUID | None
    product_id: UUID | None
    quantity: float
    unit: str | None
    note: str | None
    reason: ListReason
    added_by: Literal["user", "agent", "system"]
    explanation: str | None
    merchant: MerchantRef | None
    merchant_basis: Literal["preferred", "last_purchase", "list"] | None
    needed_by: datetime | None
    checked: bool
    checked_at: datetime | None
    created_at: datetime
    updated_at: datetime


class ShoppingList(BaseModel):
    id: UUID
    household_id: UUID
    name: str
    merchant: MerchantRef | None
    status: ListStatus
    source: Literal["user", "generated"]
    needed_by: datetime | None = Field(description="Earliest run-out among unchecked items")
    open_count: int
    items: list[ShoppingListItem]
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None


class ListIn(Strict):
    household_id: UUID | None = None
    name: str | None = Field(default=None, min_length=1, max_length=80,
                             description="Defaults to the store's name, or 'Shopping list'")
    merchant_id: UUID | None = None


class ListPatch(Strict):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    status: ListStatus | None = None
    merchant_id: UUID | None = None


class ListItemIn(Strict):
    """Send a ``title``, or link an ``inventory_item_id`` / ``product_id`` and the title is filled in."""

    title: str | None = Field(default=None, min_length=1, max_length=120)
    inventory_item_id: UUID | None = None
    product_id: UUID | None = None
    quantity: float = Field(default=1, gt=0, le=1000)
    unit: str | None = Field(default=None, min_length=1, max_length=20)
    note: str | None = Field(default=None, max_length=500)
    added_by: Literal["user", "agent"] = "user"
    explanation: str | None = Field(default=None, min_length=1, max_length=500,
                                    description="Required when added_by is 'agent'")

    @model_validator(mode="after")
    def _identifiable(self) -> "ListItemIn":
        if self.title is None and self.inventory_item_id is None and self.product_id is None:
            raise ValueError("send a title, inventory_item_id or product_id")
        if self.title is not None and not self.title.strip():
            raise ValueError("title can't be blank")
        if self.added_by == "agent" and self.explanation is None:
            raise ValueError("agent-added items need an explanation")
        return self


class ListItemPatch(Strict):
    title: str | None = Field(default=None, min_length=1, max_length=120)
    quantity: float | None = Field(default=None, gt=0, le=1000)
    unit: str | None = Field(default=None, min_length=1, max_length=20)
    note: str | None = Field(default=None, max_length=500)
    checked: bool | None = None


class GenerateIn(Strict):
    household_id: UUID | None = None
    within_days: int = Field(default=7, ge=1, le=30)
    include_unassigned: bool = Field(default=True,
                                     description="Also list items with no known store, on a 'Groceries' list")


class GenerateSkip(BaseModel):
    inventory_item_id: UUID
    title: str
    reason: Literal["already_on_list", "no_store"]
    list_id: UUID | None


class GenerateOut(BaseModel):
    lists: list[ShoppingList]
    added: int
    skipped: list[GenerateSkip]
