from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------- auth / me

class DevLoginIn(Strict):
    handle: str = Field(pattern=r"^[a-z0-9_]{3,32}$")
    display_name: str | None = Field(default=None, min_length=1, max_length=80)


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


class ItemIn(Strict):
    household_id: UUID
    display_name: str = Field(min_length=1, max_length=120)
    category: str | None = Field(default=None, max_length=40)
    location_id: UUID | None = None
    unit: str = Field(default="unit", max_length=20)
    par_level: float | None = Field(default=None, ge=0, le=10000)
    quantity: float | None = Field(default=None, ge=0, le=10000)


class ItemPatch(Strict):
    display_name: str | None = Field(default=None, min_length=1, max_length=120)
    location_id: UUID | None = None
    par_level: float | None = Field(default=None, ge=0, le=10000)
    status: Literal["active", "archived"] | None = None


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


class ItemDetail(ItemOut):
    daily: list[DailyPoint]
    observations: list[Observation]
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
    detections: list[Detection] = []


class ReviewDecision(Strict):
    detection_id: UUID
    action: Literal["accept", "reject", "correct"]
    label: str | None = Field(default=None, min_length=1, max_length=80)
    quantity: float | None = Field(default=None, ge=0, le=10000)
    inventory_item_id: UUID | None = None


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
