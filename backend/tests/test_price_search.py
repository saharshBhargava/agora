"""Untrusted search results must never bypass source verification or network boundaries."""
import json
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from app.config import Settings
from app.price_search import (
    PriceSearchProvider,
    ProductFetcher,
    SearchError,
    extract_offers,
    public_url,
)
from app.watch_ops import evaluate

CRITERIA = {"query": "Lodge cast iron skillet 10 inch", "required_terms": ["Lodge", "10 inch"],
            "target_price_cents": 3000, "quantity": 1, "fulfillment": "delivery", "location": "US"}
URL = "https://retailer.example/products/skillet"


def research_response(request):
    """External Gemini boundary for a real controller search -> read -> finish exchange."""
    body = json.loads(request.content)
    if "google_search" in body["tools"][0]:
        candidate = {"content": {"role": "model", "parts": [{"text": "An invented URL is not a source."}]},
                     "groundingMetadata": {"groundingChunks": [{"web": {"uri": URL, "title": "Lodge skillet"}}]}}
    else:
        last = body["contents"][-1]["parts"][0]
        response = last.get("functionResponse")
        if response is None:
            call = {"name": "web_search", "args": {"query": "Lodge cast iron skillet 10 inch", "limit": 8}}
        elif response["name"] == "web_search":
            call = {"name": "web_fetch", "args": {"url": URL}}
        else:
            return httpx.Response(200, json={"candidates": [{"finishReason": "STOP", "content": {
                "role": "model", "parts": [{"text": "Research complete."}]}}]})
        candidate = {"finishReason": "STOP", "content": {"role": "model", "parts": [{"functionCall": call}]}}
    return httpx.Response(200, json={"candidates": [candidate]})


def product_page(**overrides):
    offer = {"@type": "Offer", "price": "24.99", "priceCurrency": "USD", "url": URL,
             "availability": "https://schema.org/InStock", "itemCondition": "https://schema.org/NewCondition",
             "shippingDetails": {"@type": "OfferShippingDetails",
                                 "shippingDestination": {"@type": "DefinedRegion", "addressCountry": "US"},
                                 "shippingRate": {"@type": "MonetaryAmount", "value": "5.00", "currency": "USD"}}}
    offer.update(overrides)
    product = {"@type": "Product", "name": "Lodge cast iron skillet 10 inch", "sku": "L8SK3", "offers": offer}
    return '<script type="application/ld+json">' + json.dumps(product) + '</script>'


def test_verified_offer_qualifies_but_unknown_costs_never_meet_total_cap():
    offers = extract_offers(product_page(), URL, CRITERIA)
    assert len(offers) == 1 and offers[0].price_cents == 2499 and offers[0].shipping_cents == 500
    assert evaluate(CRITERIA, offers[0])["eligible"]
    result = evaluate({**CRITERIA, "max_total_cents": 3500}, offers[0])
    assert result["reason"] == "total_unknown" and not result["eligible"]


@pytest.mark.parametrize("change,reason", [
    ({"itemCondition": None}, "condition_mismatch"),
    ({"availability": "https://schema.org/OutOfStock"}, "out_of_stock"),
    ({"priceCurrency": "CAD"}, "currency_mismatch"),
    ({"price": "30.01"}, "above_target"),
    ({"shippingDetails": {}}, "fulfillment_unverified"),
    ({"priceValidUntil": "2000-01-01"}, "expired_offer"),
    ({"validForMemberTier": {"@type": "MemberProgramTier", "name": "Plus"}}, "unconfirmed_eligibility"),
    ({"description": "Subscribe to get this price"}, "unconfirmed_eligibility"),
    ({"description": "Apply coupon to get this price"}, "unconfirmed_eligibility"),
    ({"eligibleQuantity": {"minValue": 10}}, "unconfirmed_eligibility"),
    ({"eligibleTransactionVolume": {"price": 100}}, "unconfirmed_eligibility"),
    ({"businessFunction": "http://purl.org/goodrelations/v1#LeaseOut"}, "unconfirmed_eligibility"),
    ({"validFrom": "2099-01-01T00:00:00Z"}, "unconfirmed_eligibility"),
])
def test_unqualified_retailer_evidence_does_not_match(change, reason):
    offer = extract_offers(product_page(**change), URL, CRITERIA)[0]
    assert evaluate(CRITERIA, offer)["reason"] == reason


def test_country_wide_shipping_does_not_establish_zip_code_or_pickup():
    for criteria in ({**CRITERIA, "location": "98103"}, {**CRITERIA, "fulfillment": "pickup"}):
        offer = extract_offers(product_page(), URL, criteria)[0]
        assert evaluate(criteria, offer)["reason"] == "fulfillment_unverified"


def test_aggregate_price_wrong_domain_bad_money_and_model_prose_never_become_offers():
    for changes in ({"@type": "AggregateOffer", "lowPrice": "10.00"},
                    {"url": "https://other.example/same-product"}, {"price": "NaN"}, {"price": "1.001"}):
        assert extract_offers(product_page(**changes), URL, CRITERIA) == []
    assert extract_offers('Model says "verified price $1.00"', URL, CRITERIA) == []


@pytest.mark.parametrize("url", ["http://retailer.example", "https://127.0.0.1/a", "https://169.254.169.254/a",
                                 "https://[::1]/a", "https://user:secret@retailer.example", "https://x.local/a",
                                 "https://retailer.example:444/a", "https://retailer.example/\nprivate"])
def test_unsafe_urls_rejected(url):
    with pytest.raises(SearchError):
        public_url(url)


async def test_network_pins_checked_ip_preserves_tls_hostname_and_revalidates_redirect(monkeypatch):
    requests = []
    async def resolve(host):
        assert host == "retailer.example"
        return "93.184.216.34"
    monkeypatch.setattr("app.price_search.resolve_public", resolve)
    def handle(request):
        requests.append(request)
        assert request.url.host == "93.184.216.34"
        assert request.headers["host"] == "retailer.example"
        assert request.extensions["sni_hostname"] == "retailer.example"
        assert "authorization" not in request.headers and "x-goog-api-key" not in request.headers
        return httpx.Response(302, headers={"location": "https://127.0.0.1/private"})
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        with pytest.raises(SearchError, match="unsafe_product_url"):
            await ProductFetcher(client).fetch(URL, [])
    assert len(requests) == 1


async def test_real_provider_pipeline_discovers_then_verifies_and_bounds_pages(monkeypatch):
    async def resolve(host):
        return "93.184.216.34"
    monkeypatch.setattr("app.price_search.resolve_public", resolve)
    calls = []
    def handle(request):
        calls.append(request)
        if request.url.host == "generativelanguage.googleapis.com":
            assert request.headers["x-goog-api-key"] == "test-only"
            return research_response(request)
        return httpx.Response(200, text=product_page(), headers={"content-type": "text/html"})
    settings = Settings(_env_file=None, watch_search_providers=["google"],
                        env="test", watch_search_api_key="test-only", watch_max_pages=1)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        provider = PriceSearchProvider(settings, client, ProductFetcher(client))
        result = await provider.search(CRITERIA, [])
        assert len(result.offers) == 1 and result.errors == [] and result.checked_count == 1
        assert evaluate(CRITERIA, result.offers[0])["eligible"]
    assert len(calls) == 4  # controller, search adapter, controller, merchant page


async def test_no_key_reports_search_unavailable_but_direct_url_monitoring_works():
    class Fetcher:
        async def fetch(self, url, domains):
            return url, product_page()
    async with httpx.AsyncClient() as client:
        provider = PriceSearchProvider(Settings(_env_file=None, watch_search_providers=["google"],
                        env="test", gemini_api_key=None,
                                                watch_search_api_key=None), client, Fetcher())
        missing = await provider.search(CRITERIA, [])
        assert missing.errors == ["search_not_configured"]
        direct = await provider.search({**CRITERIA, "product_url": URL}, [])
        assert len(direct.offers) == 1 and not direct.errors


def test_known_stock_does_not_establish_multi_quantity_or_deadline():
    offer = extract_offers(product_page(), URL, CRITERIA)[0]
    assert evaluate({**CRITERIA, "quantity": 2}, offer)["reason"] == "quantity_unverified"
    tomorrow = (datetime.now(UTC) + timedelta(days=1)).date().isoformat()
    assert evaluate({**CRITERIA, "needed_by": tomorrow}, offer)["reason"] == "arrival_unverified"


@pytest.mark.parametrize('restriction', [
    {'eligibleQuantity': {'minValue': 10}},
    {'eligibleTransactionVolume': {'price': 100}},
    {'eligibleDuration': {'value': 12, 'unitCode': 'MON'}},
    {'validFrom': '2099-01-01T00:00:00Z'},
    {'availabilityStarts': '2099-01-01T00:00:00Z'},
    {'businessFunction': 'http://purl.org/goodrelations/v1#LeaseOut'},
    {'billingDuration': {'value': 12}},
    {'billingIncrement': 1},
    {'description': 'Requires subscription'},
    {'description': 'Use promo code at checkout'},
])
@pytest.mark.parametrize('nested', [False, True])
def test_attached_price_specification_restrictions_cannot_qualify(restriction, nested):
    specification = {'@type': 'UnitPriceSpecification', 'price': '24.99', **restriction}
    if nested:
        specification = {'@type': 'CompoundPriceSpecification', 'priceComponent': [specification]}
    offer = extract_offers(product_page(priceSpecification=specification), URL, CRITERIA)[0]
    assert not evaluate(CRITERIA, offer)['eligible']


@pytest.mark.parametrize('field', ['validFrom', 'availabilityStarts', 'priceValidUntil', 'validThrough',
                                    'availabilityEnds'])
@pytest.mark.parametrize('invalid', ['not-a-date', '', None, 123, {}])
@pytest.mark.parametrize('nested', [False, True])
def test_malformed_supplied_price_validity_fails_closed(field, invalid, nested):
    restriction = {field: invalid}
    if nested:
        restriction = {'priceSpecification': {'@type': 'UnitPriceSpecification', **restriction}}
    offer = extract_offers(product_page(**restriction), URL, CRITERIA)[0]
    assert not offer.eligibility_verified
    assert not evaluate(CRITERIA, offer)['eligible']


@pytest.mark.parametrize('field', ['availabilityEnds', 'validThrough', 'priceValidUntil'])
@pytest.mark.parametrize('nested', [False, True])
def test_expired_attached_price_or_availability_never_matches(field, nested):
    restriction = {field: '2000-01-01T00:00:00Z'}
    if nested:
        restriction = {'priceSpecification': {'@type': 'UnitPriceSpecification', **restriction}}
    offer = extract_offers(product_page(**restriction), URL, CRITERIA)[0]
    assert offer.valid_until == datetime(2000, 1, 1, tzinfo=UTC)
    assert evaluate(CRITERIA, offer)['reason'] == 'expired_offer'


@pytest.mark.parametrize('nested', [False, True])
def test_customer_segments_are_not_unlocked_by_membership_permission(nested):
    restriction = {'eligibleCustomerType': 'https://schema.org/BusinessAudience'}
    if nested:
        restriction = {'priceSpecification': {'@type': 'UnitPriceSpecification', **restriction}}
    offer = extract_offers(product_page(**restriction), URL, CRITERIA)[0]
    assert not offer.membership_required and not offer.eligibility_verified
    assert not evaluate({**CRITERIA, 'allow_membership': True}, offer)['eligible']


def test_public_price_windows_intersect_and_member_tiers_remain_explicit():
    now = datetime(2026, 10, 17, 12, tzinfo=UTC)
    offer = extract_offers(product_page(
        validFrom='2026-10-16T00:00:00Z', priceValidUntil='2026-10-30',
        priceSpecification={'@type': 'UnitPriceSpecification', 'validFrom': '2026-10-17T00:00:00Z',
                            'validThrough': '2026-10-18T18:00:00Z',
                            'validForMemberTier': {'@type': 'MemberProgramTier', 'name': 'Plus'}}),
        URL, CRITERIA, now)[0]
    assert offer.eligibility_verified and offer.membership_required
    assert offer.valid_until == datetime(2026, 10, 18, 18, tzinfo=UTC)
    assert not evaluate(CRITERIA, offer, now)['eligible']
    assert evaluate({**CRITERIA, 'allow_membership': True}, offer, now)['eligible']


def test_unrepresentable_inclusive_expiry_fails_closed():
    offer = extract_offers(product_page(priceValidUntil='9999-12-31'), URL, CRITERIA)[0]
    assert not offer.eligibility_verified and not evaluate(CRITERIA, offer)['eligible']
