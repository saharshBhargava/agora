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


class ItemDetail(ItemOut):
    daily: list[DailyPoint]
    observations: list[Observation]
    purchase_history: list[PurchaseOrigin]
    series_engine: Literal["timescale", "postgres"]


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
