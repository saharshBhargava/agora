"""Provider failure containment, real wire formats, budget and model/search independence."""
import asyncio
import json
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime

import httpx
import pytest
from pydantic import ValidationError

from app.config import Settings
from app.price_search import PriceSearchProvider, SearchError
from app.web_search import SearchBudget, WebSearchRouter, retry_delay

URL = 'https://retailer.example/skillet'
ROW = {'title': 'Skillet', 'url': URL, 'snippet': 'A search snippet is not a verified price'}


def settings(**kwargs):
    return Settings(_env_file=None, env='test', gemini_api_key=None, watch_search_api_key=None, **kwargs)


@pytest.mark.parametrize('name,host,header,body', [
    ('exa', 'api.exa.ai', 'x-api-key', {'results': [ROW]}),
    ('parallel', 'api.parallel.ai', 'x-api-key', {'results': [ROW]}),
    ('firecrawl', 'api.firecrawl.dev', 'authorization', {'success': True, 'data': {'web': [ROW]}}),
    ('keenable', 'api.keenable.ai', 'x-api-key', {'results': [ROW]}),
    ('tavily', 'api.tavily.com', 'authorization', {'results': [{**ROW, 'content': ROW['snippet']}]}),
    ('brave', 'api.search.brave.com', 'x-subscription-token', {'web': {'results': [ROW]}}),
])
async def test_six_keyed_contracts_and_credential_isolation(name, host, header, body):
    def remote(request):
        assert request.url.host == host
        assert 'secret-for-this-provider' in request.headers[header]
        assert 'other-provider-secret' not in str(request.headers)
        assert 'secret' not in str(request.url) and b'secret' not in request.content
        if name == 'brave':
            assert request.method == 'GET' and request.url.params['count'] == '8'
        else:
            assert request.method == 'POST'
        return httpx.Response(200, json=body)
    config = settings(watch_search_providers=[name], **{name+'_api_key': 'secret-for-this-provider'})
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(config, client)
        assert await router.search('Lodge skillet', [], 8, SearchBudget(1)) == [ROW]


@pytest.mark.parametrize('name', ['exa', 'parallel', 'keenable'])
async def test_keyless_wire_formats(name):
    def remote(request):
        assert not any(k in request.headers for k in ('authorization', 'x-api-key', 'x-goog-api-key'))
        payload = json.loads(request.content)
        if name == 'keenable':
            assert request.url.path == '/v1/search/public'
            assert request.headers['x-keenable-title'] == 'Agora'
            return httpx.Response(200, json={'results': [ROW]})
        assert payload['method'] == 'tools/call'
        if name == 'parallel':
            assert payload['params']['name'] == 'web_search'
            text = json.dumps({'results': [ROW]})
        else:
            assert payload['params']['name'] == 'web_search_exa'
            text = 'Title: Skillet\nURL: '+URL+'\nPublished: N/A\nHighlights:\nUnverified price'
        body = {'jsonrpc': '2.0', 'id': 1, 'result': {'content': [{'type': 'text', 'text': text}]}}
        return (httpx.Response(200, json=body) if name == 'parallel' else
                httpx.Response(200, text='event: message\r\ndata: '+json.dumps(body)+'\r\n\r\n'))
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        sources = await WebSearchRouter(settings(watch_search_providers=[name]), client).search(
            'Lodge skillet', [], 8, SearchBudget(1))
        assert sources[0]['url'] == URL
        assert sources[0]['snippet']


async def test_rotation_first_success_no_merging():
    calls = []
    def remote(request):
        calls.append(request.url.host)
        return httpx.Response(200, json={'results': [ROW]})
    config = settings(watch_search_providers=['exa', 'keenable', 'exa'], exa_api_key='exa-only')
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(config, client)
        for _ in range(3):
            assert len(await router.search('Lodge skillet', [], 8, SearchBudget(2))) == 1
    assert calls == ['api.exa.ai', 'api.keenable.ai', 'api.exa.ai']


@pytest.mark.parametrize('name', ['exa', 'parallel'])
@pytest.mark.parametrize('structured', [False, True])
async def test_empty_mcp_results_are_success_without_fallback_or_cooldown(name, structured):
    calls = []

    def remote(request):
        calls.append(request)
        result = ({'structuredContent': {'results': []}} if structured else
                  {'content': [{'type': 'text', 'text': json.dumps({'results': []})}]})
        return httpx.Response(200, json={'jsonrpc': '2.0', 'id': 1, 'result': result})

    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(settings(watch_search_providers=[name, 'keenable']), client)
        budget = SearchBudget(2)
        assert await router.search('Lodge skillet', [], 8, budget) == []
        assert len(calls) == 1 and budget.remaining == 1 and not router.cooldowns


async def test_rate_limit_fallback_and_cooldown_shared_between_checks(monkeypatch):
    now = [100]
    monkeypatch.setattr('app.web_search.time.monotonic', lambda: now[0])
    calls = []
    def remote(request):
        calls.append(request.url.host)
        if request.url.host == 'api.exa.ai':
            return httpx.Response(429, headers={'retry-after': '120'}, text='sensitive provider error')
        return httpx.Response(200, json={'results': [ROW]})
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(settings(watch_search_providers=['exa', 'keenable'], exa_api_key='secret'), client)
        for _ in range(3):
            await router.search('Lodge skillet', [], 8, SearchBudget(2))
        assert calls.count('api.exa.ai') == 1
        now[0] = 221
        router.cursor = 0
        await router.search('Lodge skillet', [], 8, SearchBudget(2))
        assert calls.count('api.exa.ai') == 2


@pytest.mark.parametrize('failure', [
    httpx.Response(302, headers={'location': 'https://attacker.example/collect'}),
    httpx.Response(401, text='secret error'), httpx.Response(500),
    httpx.Response(200, text='not JSON'), httpx.Response(200, content=b'x' * 1_000_001),
    httpx.Response(200, json={'results': [{'url': 'http://localhost/private'}]}),
    httpx.Response(200, json={'unexpected': []}),
])
async def test_unusable_provider_falls_back_without_forwarding_secrets(failure):
    calls = []
    def remote(request):
        calls.append(request)
        if request.url.host == 'api.exa.ai':
            return failure
        assert request.url.host == 'api.keenable.ai'
        assert 'x-api-key' not in request.headers
        return httpx.Response(200, json={'results': [ROW]})
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(settings(watch_search_providers=['exa', 'keenable'], exa_api_key='secret'), client)
        assert await router.search('Lodge skillet', [], 8, SearchBudget(2)) == [ROW]
        assert len(calls) == 2


async def test_budget_spans_queries_and_counts_failed_attempts():
    calls = []
    def remote(request):
        calls.append(request)
        return httpx.Response(500)
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        router = WebSearchRouter(settings(watch_search_providers=['exa', 'keenable']), client)
        with pytest.raises(SearchError, match='search_request_budget_exhausted'):
            await router.search('Lodge skillet', [], 8, SearchBudget(1))
        assert len(calls) == 1
        budget = SearchBudget(0)
        with pytest.raises(SearchError, match='search_request_budget_exhausted'):
            await router.search('different skillet', [], 8, budget)
        assert len(calls) == 1


async def test_total_search_deadline_cancels_slow_provider():
    async def remote(request):
        await asyncio.sleep(10)
    config = settings(watch_search_providers=['keenable']).model_copy(update={'watch_search_timeout_s': 0.01})
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        with pytest.raises(SearchError, match='search_timeout'):
            await WebSearchRouter(config, client).search('Lodge skillet', [], 8, SearchBudget(2))


async def test_normalizes_caps_deduplicates_and_enforces_domains():
    rows = [ROW, ROW, {'url': 'https://unapproved.example/product'}, {'url': 'https://127.0.0.1/private'}]
    rows += [{**ROW, 'url': URL+str(i), 'title': 'a'*400, 'snippet': 'b'*2000} for i in range(12)]
    async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda r: httpx.Response(200, json={'results': rows}))) as client:
        result = await WebSearchRouter(settings(watch_search_providers=['keenable']), client).search(
            'Lodge skillet', ['retailer.example'], 100, SearchBudget(1))
        assert len(result) == 8 and len(set(r['url'] for r in result)) == 8
        assert len(result[1]['title']) == 300 and len(result[1]['snippet']) == 1200


def test_search_and_model_capabilities_are_independent():
    client = httpx.AsyncClient()
    provider = PriceSearchProvider(settings(), client)
    assert provider.router.enabled == ['exa', 'parallel', 'keenable']
    assert provider.router.available and provider.discovery_available and not provider.model_available
    assert provider.discovery_status == 'available'
    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model')
    provider = PriceSearchProvider(config, client)
    assert provider.discovery_available and not provider.key
    provider = PriceSearchProvider(config.model_copy(update={'watch_search_keyless': False}), client)
    assert provider.model_available and provider.discovery_status == 'search_not_configured'
    with pytest.raises(ValidationError):
        settings(watch_model_provider='openai-compatible', openai_model='')
    with pytest.raises(ValidationError):
        settings(watch_search_providers=['invented'])


def test_retry_after_http_date_and_clamping():
    assert retry_delay('999999') == 3600
    assert retry_delay('-20') == 1
    assert retry_delay(None) == 60
    assert 58 <= retry_delay(format_datetime(datetime.now(UTC)+timedelta(seconds=60))) <= 60
