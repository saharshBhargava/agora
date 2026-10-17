from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


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
    merchant: MerchantRef
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
    detections: list[Detection] = []


class ScanPatch(Strict):
    purchased_from_merchant_id: UUID | None = Field(description="Store for the whole upload; null clears it")


class DetectionPatch(Strict):
    """Per-product store. Send ``purchased_from_merchant_id`` (null = explicitly no store) to override the
    scan's store for this product, or ``inherit_from_scan: true`` to go back to the scan's store."""
    purchased_from_merchant_id: UUID | None = None
    inherit_from_scan: bool = False


class ReviewDecision(Strict):
    detection_id: UUID
    action: Literal["accept", "reject", "correct"]
    label: str | None = Field(default=None, min_length=1, max_length=80)
    quantity: float | None = Field(default=None, ge=0, le=10000)
    inventory_item_id: UUID | None = None
    # Optional per-product store override; include the key with null to mark "no store" for this product.
    purchased_from_merchant_id: UUID | None = None


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
