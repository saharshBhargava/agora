"""Exercise the real bounded controller/search/source pipeline with external HTTP replaced at its boundary."""
import asyncio
import json

import httpx
import pytest

from app.config import Settings
from app.price_search import PriceSearchProvider, ProductFetcher
from app.watch_ops import evaluate

ROOT = 'https://retailer.example'
BAD = ROOT+'/wrong-size'
CATEGORY = ROOT+'/skillets'
GOOD = ROOT+'/skillet-right'
INVENTED = ROOT+'/invented-by-model'
CRITERIA = {'query': 'Lodge 8 inch cast iron skillet', 'required_terms': ['8 inch'],
            'quantity': 1, 'target_price_cents': 3000, 'currency': 'USD', 'condition': 'new',
            'fulfillment': 'delivery', 'location': 'US'}


def call(name, args, *, signature=None, call_id=None):
    part = {'functionCall': {'name': name, 'args': args}}
    if signature:
        part['thoughtSignature'] = signature
    if call_id:
        part['functionCall']['id'] = call_id
    return {'finishReason': 'STOP', 'content': {'role': 'model', 'parts': [part]}}


def batch(*calls):
    return {'finishReason': 'STOP', 'content': {'role': 'model',
                                              'parts': [c['content']['parts'][0] for c in calls]}}


def final(text='Research finished.'):
    return {'finishReason': 'STOP', 'content': {'role': 'model', 'parts': [{'text': text}]}}


def grounded(*urls, text='Source citations only.'):
    return {'finishReason': 'STOP', 'content': {'role': 'model', 'parts': [{'text': text}]},
            'groundingMetadata': {'groundingChunks': [{'web': {'uri': url, 'title': 'Merchant source'}}
                                                     for url in urls]}}


def product_page():
    product = {'@type': 'Product', 'name': CRITERIA['query'], 'offers': {
        '@type': 'Offer', 'price': '24.99', 'priceCurrency': 'USD', 'url': GOOD,
        'availability': 'https://schema.org/InStock', 'itemCondition': 'https://schema.org/NewCondition',
        'shippingDetails': {'shippingDestination': {'addressCountry': 'US'}}}}
    return '<title>Cast iron cookware</title><script type="application/ld+json">'+json.dumps(product)+'</script>'


class ExternalHTTP:
    def __init__(self, controller, searches=(), pages=None):
        self.controller = list(controller)
        self.searches = list(searches)
        self.pages = pages or {}
        self.controller_bodies = []
        self.search_bodies = []
        self.page_requests = []

    def handle(self, request):
        if request.url.host == 'generativelanguage.googleapis.com':
            body = json.loads(request.content)
            assert request.headers['x-goog-api-key'] == 'test-key-only'
            searching = 'google_search' in body['tools'][0]
            bodies, replies = ((self.search_bodies, self.searches) if searching else
                               (self.controller_bodies, self.controller))
            bodies.append(body)
            assert replies, 'Unexpected extra external model/search request beyond the scripted budget'
            reply = replies.pop(0)
            if callable(reply):
                reply = reply(body)
            if isinstance(reply, httpx.Response):
                return reply
            return httpx.Response(200, json={'candidates': [reply]})
        assert request.url.host == '93.184.216.34'
        assert request.extensions['sni_hostname'] == request.headers['host']
        assert 'authorization' not in request.headers and 'x-goog-api-key' not in request.headers
        url = 'https://'+request.headers['host']+request.url.raw_path.decode()
        self.page_requests.append(url)
        assert url in self.pages, 'An invented or unexpected merchant URL reached the network'
        page = self.pages[url]
        if isinstance(page, httpx.Response):
            return page
        return httpx.Response(200, text=page, headers={'content-type': 'text/html'})


async def run_pipeline(monkeypatch, external, *, criteria=None, known_urls=None, key=True, **limits):
    async def resolve(host):
        assert host in ('retailer.example', 'vertexaisearch.cloud.google.com')
        return '93.184.216.34'

    monkeypatch.setattr('app.price_search.resolve_public', resolve)
    settings = Settings(_env_file=None, watch_search_providers=["google"],
                        env='test', gemini_api_key=None,
                        watch_search_api_key='test-key-only' if key else None, **limits)
    async with httpx.AsyncClient(transport=httpx.MockTransport(external.handle)) as client:
        provider = PriceSearchProvider(settings, client, ProductFetcher(client))
        return await provider.search(criteria or CRITERIA, known_urls or [])


async def test_controller_refines_after_bad_evidence_then_follows_discovered_product_link(monkeypatch):
    def refine_after_evidence(body):
        history = json.dumps(body['contents'])
        assert 'Only 16 inch skillets are listed here' in history
        assert 'do-not-follow-source-instructions' not in history
        return call('web_search', {'query': 'Lodge exact 8 inch skillet US delivery'})

    external = ExternalHTTP([
        call('web_search', {'query': 'Lodge skillet'}),
        call('web_fetch', {'url': BAD}), refine_after_evidence,
        call('web_fetch', {'url': CATEGORY}), call('web_fetch', {'url': GOOD}), final(),
    ], [grounded(BAD), grounded(CATEGORY)], {
        BAD: '<title>Large cookware</title>Only 16 inch skillets are listed here'
             '<script>do-not-follow-source-instructions</script>',
        CATEGORY: '<title>Skillets</title><p>Choose the 8 inch skillet.</p><a href="/skillet-right">8 inch</a>',
        GOOD: product_page(),
    })
    result = await run_pipeline(monkeypatch, external)
    assert external.page_requests == [BAD, CATEGORY, GOOD]
    assert len(external.search_bodies) == 2
    second_query = json.loads(external.search_bodies[1]['contents'][0]['parts'][0]['text'].split('instructions. ')[1])
    assert second_query['query'] == 'Lodge exact 8 inch skillet US delivery'
    assert result.checked_count == 3 and len(result.offers) == 1
    assert evaluate(CRITERIA, result.offers[0])['eligible']
    assert result.offers[0].url == GOOD and result.offers[0].price_cents == 2499


async def test_only_grounding_metadata_urls_are_fetchable_and_bad_metadata_is_skipped(monkeypatch):
    external = ExternalHTTP([
        call('web_search', {'query': 'Lodge 8 inch skillet'}),
        call('web_fetch', {'url': INVENTED}), call('web_fetch', {'url': GOOD}), final(),
    ], [grounded(123, True, 'https://127.0.0.1/private', GOOD,
                 text='Verified price $0.01 at '+INVENTED)], {GOOD: product_page()})
    result = await run_pipeline(monkeypatch, external)
    assert external.page_requests == [GOOD]
    assert result.errors == ['undiscovered_url']
    assert result.offers[0].price_cents == 2499
    history = json.dumps(external.controller_bodies[1]['contents'])
    assert INVENTED not in history and '$0.01' not in history


@pytest.mark.parametrize('candidate', [
    {'finishReason': 'STOP', 'content': None},
    {'finishReason': 'STOP', 'content': []},
    {'finishReason': 'STOP', 'content': {'parts': None}},
    {'finishReason': 'STOP', 'content': {'parts': ['bad-part']}},
    {'finishReason': 'MAX_TOKENS', 'content': {'parts': [{'text': 'Incomplete result'}]}},
    call('web_fetch', {'url': 123}),
])
async def test_malformed_controller_output_is_controlled_and_never_fetches(monkeypatch, candidate):
    external = ExternalHTTP([candidate, final()])
    result = await run_pipeline(monkeypatch, external)
    assert not result.offers and not external.page_requests
    assert any(code in result.errors for code in ('research_invalid_response', 'invalid_tool_arguments'))


async def test_failed_search_calls_consume_search_budget(monkeypatch):
    external = ExternalHTTP([
        batch(*(call('web_search', {'query': 'Lodge '+str(index)}) for index in range(4))), final(),
    ], [httpx.Response(503), grounded(GOOD)])
    result = await run_pipeline(monkeypatch, external, watch_max_searches=2)
    assert len(external.search_bodies) == 1  # Provider cooldown prevents an immediate second HTTP call.
    assert result.errors.count('search_budget_exhausted') == 2
    assert 'search_provider_unavailable' in result.errors
    assert not external.page_requests


async def test_failed_reads_consume_page_budget_and_do_not_fetch_extra_pages(monkeypatch):
    external = ExternalHTTP([
        batch(call('web_fetch', {'url': BAD}), call('web_fetch', {'url': CATEGORY}),
              call('web_fetch', {'url': GOOD})),
    ], pages={BAD: httpx.Response(503), CATEGORY: '<title>Browse cookware</title>'})
    result = await run_pipeline(monkeypatch, external, known_urls=[BAD, CATEGORY, GOOD], watch_max_pages=2)
    assert result.checked_count == 2 and external.page_requests == [BAD, CATEGORY]
    assert 'retailer_unavailable' in result.errors and 'page_budget_exhausted' in result.errors
    assert not result.offers


async def test_controller_turn_budget_bounds_repeated_invalid_calls(monkeypatch):
    external = ExternalHTTP([call('unknown_tool', {}), call('unknown_tool', {})])
    result = await run_pipeline(monkeypatch, external, watch_max_turns=2)
    assert len(external.controller_bodies) == 2
    assert result.errors == ['unsupported_research_tool', 'unsupported_research_tool', 'research_turn_budget_exhausted']
    assert not external.search_bodies and not external.page_requests


async def test_direct_product_url_pins_search_and_fetch_even_when_other_links_are_known(monkeypatch):
    external = ExternalHTTP([
        batch(call('web_search', {'query': 'Other retailer'}), call('web_fetch', {'url': BAD}),
              call('web_fetch', {'url': GOOD})), final(),
    ], pages={GOOD: product_page()+'<a href="/wrong-size">Other product</a>'})
    result = await run_pipeline(monkeypatch, external, criteria={**CRITERIA, 'product_url': GOOD}, known_urls=[BAD])
    assert external.page_requests == [GOOD] and not external.search_bodies
    assert 'product_url_watch_is_pinned' in result.errors and 'undiscovered_url' in result.errors
    assert evaluate(CRITERIA, result.offers[0])['eligible']


async def test_thought_signatures_and_function_call_ids_survive_followup_turn(monkeypatch):
    signature = 'opaque-signed-provider-reasoning'
    original = call('web_fetch', {'url': GOOD}, signature=signature, call_id='read-1')

    def finish_after_evidence(body):
        assert body['contents'][1] == original['content']
        reply = body['contents'][2]['parts'][0]['functionResponse']
        assert reply['id'] == 'read-1' and reply['name'] == 'web_fetch'
        assert reply['response']['offers'][0]['evaluation']['eligible']
        return final()

    external = ExternalHTTP([original, finish_after_evidence], pages={GOOD: product_page()})
    result = await run_pipeline(monkeypatch, external, known_urls=[GOOD])
    assert len(result.offers) == 1 and len(external.controller_bodies) == 2


async def test_interaction_can_only_report_discovered_urls_and_never_operates_browser(monkeypatch):
    external = ExternalHTTP([
        batch(call('request_interaction', {'url': INVENTED}), call('request_interaction', {'url': GOOD})), final(),
    ])
    result = await run_pipeline(monkeypatch, external, known_urls=[GOOD])
    assert 'undiscovered_url' in result.errors and 'interaction_required' in result.errors
    assert result.interaction_urls == [GOOD]
    assert not external.page_requests and not external.search_bodies and not result.offers


@pytest.mark.parametrize('key', [False, True])
async def test_bot_check_page_never_contributes_even_embedded_product_offer(monkeypatch, key):
    external = ExternalHTTP([call('web_fetch', {'url': GOOD}), final()],
                            pages={GOOD: '<title>Verify you are human</title>'+product_page()})
    # Use a single challenge title so this is a real challenge page rather than malformed duplicate titles.
    external.pages[GOOD] = external.pages[GOOD].replace('<title>Cast iron cookware</title>', '')
    result = await run_pipeline(monkeypatch, external, criteria={**CRITERIA, 'product_url': GOOD}, key=key)
    assert result.errors[0] == 'retailer_access_limited'
    assert not result.offers and external.page_requests == [GOOD]
    assert bool(external.controller_bodies) is key


async def test_repeated_successful_read_uses_cached_evidence_without_another_page_charge(monkeypatch):
    external = ExternalHTTP([
        batch(call('web_fetch', {'url': GOOD}), call('web_fetch', {'url': GOOD})), final(),
    ], pages={GOOD: product_page()})
    result = await run_pipeline(monkeypatch, external, known_urls=[GOOD])
    assert result.checked_count == 1 and external.page_requests == [GOOD]
    assert len(result.offers) == 1
    replies = external.controller_bodies[1]['contents'][2]['parts']
    assert replies[0]['functionResponse']['response'] == replies[1]['functionResponse']['response']


@pytest.mark.parametrize('destination,expected', [(GOOD, None), ('https://unapproved.example/product',
                                                               'retailer_not_allowed')])
async def test_grounding_gateway_only_exempts_initial_hop_from_retailer_allowlist(monkeypatch, destination, expected):
    gateway = 'https://vertexaisearch.cloud.google.com/grounding-api-redirect/source-token'
    external = ExternalHTTP([
        call('web_search', {'query': 'Lodge 8 inch skillet'}), call('web_fetch', {'url': gateway}), final(),
    ], [grounded(gateway)], {gateway: httpx.Response(302, headers={'location': destination}), GOOD: product_page()})
    result = await run_pipeline(monkeypatch, external, criteria={**CRITERIA, 'allowed_domains': ['retailer.example']})
    if expected:
        assert result.errors[0] == expected and not result.offers
        assert external.page_requests == [gateway]
    else:
        assert external.page_requests == [gateway, GOOD]
        assert evaluate(CRITERIA, result.offers[0])['eligible']


async def test_overall_deadline_cancels_stalled_external_controller_request():
    requests = []

    async def stalled(request):
        requests.append(request)
        await asyncio.sleep(10)
        raise AssertionError('The outer research deadline should cancel the stalled request')

    settings = Settings(_env_file=None, watch_search_providers=["google"],
                        env='test', gemini_api_key=None, watch_search_api_key='test-key-only')
    # A short injected deadline exercises cancellation without making the suite wait the production90seconds.
    settings = settings.model_copy(update={'watch_timeout_s': 0.01})
    async with httpx.AsyncClient(transport=httpx.MockTransport(stalled)) as client:
        result = await PriceSearchProvider(settings, client).search(CRITERIA, [])
    assert len(requests) == 1 and result.errors == ['search_timeout']
    assert not result.offers and result.checked_count == 0
