"""Payment providers for Agora-native checkout.

Only tokens ever pass through here: a provider charges a ``payment_method_ref`` (a token the provider issued
on the device) and hands back its own charge reference plus brand/last4 for display. Card numbers, CVVs and
bank details never reach this server, which keeps it out of PCI scope.

Every charge carries an idempotency key derived from the intent ID, so a retried request, a crashed worker or a
replayed approval can't charge twice: the provider returns the original result instead.

Seams for later, each a new ``PaymentProvider``:

* ``stripe_test``: ``PaymentIntent.create(amount, currency, payment_method=ref, confirm=True,
  idempotency_key=key)`` with a test-mode secret key.
* ``visa_sandbox``: Visa Intelligent Commerce. The mandate becomes the agent credential's spending controls,
  the intent ID travels as the transaction's agent context, and ``payment_method_ref`` is the network token.
"""

import hashlib
from dataclasses import dataclass
from typing import Literal, Protocol

from app.config import Settings

SIMULATED_DEFAULT_METHOD = "sim_visa_4242"
SIMULATED_METHODS = {  # token ref -> (brand, last4, decline code). Like Stripe's test cards, minus the numbers.
    "sim_visa_4242": ("visa", "4242", None),
    "sim_mastercard_4444": ("mastercard", "4444", None),
    "sim_visa_declined": ("visa", "0002", "card_declined"),
    "sim_visa_timeout": ("visa", "0119", "timeout"),
}


@dataclass(frozen=True)
class ChargeRequest:
    idempotency_key: str
    amount_cents: int
    currency: str
    payment_method_ref: str
    description: str


@dataclass(frozen=True)
class ChargeResult:
    status: Literal["succeeded", "declined"]
    provider_ref: str | None
    brand: str | None
    last4: str | None
    decline_code: str | None = None


class PaymentOutcomeUnknown(Exception):
    """The provider didn't say whether the charge happened (timeout, 5xx). Never retried automatically."""


class PaymentProvider(Protocol):
    name: str

    async def charge(self, request: ChargeRequest) -> ChargeResult: ...


class SimulatedPaymentProvider:
    """No real money. Deterministic: the same idempotency key always yields the same charge reference."""

    name = "simulated"

    def __init__(self) -> None:
        self._charges: dict[str, ChargeResult] = {}

    async def charge(self, request: ChargeRequest) -> ChargeResult:
        if request.idempotency_key in self._charges:
            return self._charges[request.idempotency_key]
        method = SIMULATED_METHODS.get(request.payment_method_ref)
        if method is None:
            result = ChargeResult("declined", None, None, None, "unknown_payment_method")
        else:
            brand, last4, decline = method
            if decline == "timeout":
                raise PaymentOutcomeUnknown("simulated timeout")
            ref = "sim_ch_" + hashlib.sha256(request.idempotency_key.encode()).hexdigest()[:24]
            result = (ChargeResult("declined", None, brand, last4, decline) if decline
                      else ChargeResult("succeeded", ref, brand, last4))
        self._charges[request.idempotency_key] = result
        return result


def make_payment_provider(settings: Settings) -> PaymentProvider:
    if settings.payment_provider == "simulated":
        return SimulatedPaymentProvider()
    raise ValueError(f"payment provider {settings.payment_provider!r} is not implemented yet")


def charge_key(intent_id: object) -> str:
    """The provider idempotency key for an intent: stable across every retry of that intent."""
    return f"agora-intent-{intent_id}"
