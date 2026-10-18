"""Price research preferences; pending model suggestions do not activate a watch."""
import re
from datetime import date
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import Field, StrictBool, field_validator, model_validator

from app.price_search import SearchError, public_url
from app.schemas import Strict


class WatchCriteria(Strict):
    query: str = Field(min_length=1, max_length=200)
    product_url: str | None = Field(default=None, max_length=2048)
    required_terms: list[str] = Field(default_factory=list, max_length=20)
    excluded_terms: list[str] = Field(default_factory=list, max_length=20)
    quantity: int = Field(default=1, ge=1, le=99)
    target_price_cents: int | None = Field(default=None, ge=0, le=10000000)
    max_total_cents: int | None = Field(default=None, ge=1, le=10000000)
    currency: Literal['USD'] = 'USD'
    fulfillment: Literal['delivery', 'pickup']
    location: str = Field(min_length=2, max_length=200)
    allowed_domains: list[str] = Field(default_factory=list, max_length=20)
    condition: Literal['new', 'used', 'refurbished'] = 'new'
    allow_membership: bool = False
    needed_by: date | None = None

    @field_validator('query')
    @classmethod
    def clean_query(cls, value: str) -> str:
        if not value.strip():
            raise ValueError('Enter a product name.')
        return value.strip()

    @field_validator('location')
    @classmethod
    def clean_text(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 2:
            raise ValueError('Enter at least two characters.')
        if not any(c.isalnum() for c in value):
            raise ValueError('Enter a product or location containing letters or numbers.')
        return value

    @field_validator('required_terms', 'excluded_terms')
    @classmethod
    def clean_terms(cls, terms: list[str]) -> list[str]:
        if any(not t.strip() or len(t) > 80 or not any(c.isalnum() for c in t) for t in terms):
            raise ValueError('Terms must contain 1-80 characters.')
        return list(dict.fromkeys(t.strip().casefold() for t in terms))

    @field_validator('allowed_domains')
    @classmethod
    def clean_domains(cls, domains: list[str]) -> list[str]:
        result = []
        for domain in domains:
            domain = domain.lower().strip().removeprefix('www.')
            if (len(domain) > 253 or not re.fullmatch(
                    r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', domain)):
                raise ValueError('Enter domain names without paths.')
            result.append(domain)
        return list(dict.fromkeys(result))

    @field_validator('product_url')
    @classmethod
    def valid_url(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            return public_url(value)
        except SearchError as error:
            raise ValueError('A public HTTPS product URL is required.') from error


class WatchSubscription(Strict):
    push_enabled: bool = False
    quiet_start_hour: int | None = Field(default=None, ge=0, le=23)
    quiet_end_hour: int | None = Field(default=None, ge=0, le=23)
    timezone: str = Field(default='UTC', max_length=64)
    daily_cap: int = Field(default=3, ge=1, le=20)
    cooldown_hours: int = Field(default=24, ge=1, le=168)

    @model_validator(mode='after')
    def valid_quiet_hours(self):
        if (self.quiet_start_hour is None) != (self.quiet_end_hour is None):
            raise ValueError('Both quiet hour endpoints are required.')
        try:
            ZoneInfo(self.timezone)
        except (ValueError, ZoneInfoNotFoundError) as error:
            raise ValueError('Unknown timezone.') from error
        return self


class WatchPut(Strict):
    confirmed: StrictBool
    criteria: WatchCriteria
    subscription: WatchSubscription | None = None


class WatchPatch(Strict):
    status: Literal['active', 'paused']
