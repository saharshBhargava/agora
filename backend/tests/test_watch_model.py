"""A locally hosted tool-calling model can drive the same verified watch loop."""
import json

import httpx
import pytest

from app.price_search import PriceSearchProvider
from tests.test_price_search import CRITERIA, URL, product_page
from tests.test_web_search import ROW, settings


def completion(name=None, args=None):
    message = {'role': 'assistant', 'content': None if name else 'Finished.'}
    if name:
        message['tool_calls'] = [{'id': 'call_'+name, 'type': 'function',
                                  'function': {'name': name, 'arguments': json.dumps(args)}}]
    return {'choices': [{'finish_reason': 'tool_calls' if name else 'stop', 'message': message}]}


async def test_local_model_chooses_keyless_search_then_verified_read_without_gemini_or_apns():
    turns = [completion('web_search', {'query': 'Lodge skillet'}),
             completion('web_fetch', {'url': URL}), completion()]
    bodies = []
    def remote(request):
        assert 'authorization' not in request.headers and 'x-goog-api-key' not in request.headers
        if request.url.host == 'localhost':
            body = json.loads(request.content)
            assert body['model'] == 'local-tools-model'
            assert body['tools'][0]['function']['parameters']['type'] == 'object'
            bodies.append(body)
            return httpx.Response(200, json=turns.pop(0))
        assert request.url.host == 'api.keenable.ai'
        return httpx.Response(200, json={'results': [{**ROW, 'url': URL}]})
    class Fetcher:
        async def fetch(self, url, domains):
            assert url == URL
            return url, product_page()
    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model',
                      watch_search_providers=['keenable'], apns_enabled=False)
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        result = await PriceSearchProvider(config, client, Fetcher()).search(CRITERIA, [])
        assert len(result.offers) == 1 and result.offers[0].price_cents == 2499
        assert not result.errors and result.checked_count == 1
    assert len(bodies) == 3
    assert bodies[1]['messages'][1]['role'] == 'user'
    assert bodies[1]['messages'][2]['tool_calls'][0]['id'] == 'call_web_search'
    assert bodies[1]['messages'][3]['role'] == 'tool'
    assert bodies[1]['messages'][3]['tool_call_id'] == 'call_web_search'
    assert json.loads(bodies[2]['messages'][-1]['content'])['offers'][0]['evaluation']['eligible']


@pytest.mark.parametrize('reply', [
    {'choices': []}, {'choices': [{'finish_reason': 'length', 'message': {'role': 'assistant', 'content': 'x'}}]},
    {'choices': [{'finish_reason': 'tool_calls', 'message': {'role': 'assistant', 'tool_calls': [
        {'id': 'a', 'type': 'function', 'function': {'name': 'web_search', 'arguments': 'not JSON'}}]}}]},
    {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': None}}]},
])
async def test_malformed_model_output_never_becomes_an_offer(reply):
    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model')
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=reply))) as client:
        result = await PriceSearchProvider(config, client).search(CRITERIA, [])
        assert result.errors == ['research_invalid_response'] and not result.offers


async def test_model_credential_never_follows_redirect():
    calls = []
    def remote(request):
        calls.append(request)
        assert request.headers['authorization'] == 'Bearer model-only-secret'
        return httpx.Response(307, headers={'location': 'https://attacker.example/steal'})
    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model',
                      openai_api_key='model-only-secret')
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote), follow_redirects=True) as client:
        result = await PriceSearchProvider(config, client).search(CRITERIA, [])
        assert result.errors == ['research_model_unavailable'] and len(calls) == 1


@pytest.mark.parametrize('search_results,known_urls,expected_errors', [
    ([], [], []),
    ([ROW], [], ['research_no_evidence']),
    ([], [URL], ['research_no_evidence']),
])
async def test_empty_search_is_no_match_but_unread_sources_are_not_verified(
        search_results, known_urls, expected_errors):
    turns = [completion('web_search', {'query': 'Lodge skillet'}), completion()]

    def remote(request):
        if request.url.host == 'localhost':
            return httpx.Response(200, json=turns.pop(0))
        assert request.url.host == 'api.keenable.ai'
        return httpx.Response(200, json={'results': search_results})

    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model',
                      watch_search_providers=['keenable'])
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as client:
        result = await PriceSearchProvider(config, client).search(CRITERIA, known_urls)
    assert result.errors == expected_errors
    assert not result.offers and result.checked_count == 0


async def test_model_finishing_without_searching_is_still_a_failure():
    config = settings(watch_model_provider='openai-compatible', openai_model='local-tools-model')
    async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda r: httpx.Response(200, json=completion()))) as client:
        result = await PriceSearchProvider(config, client).search(CRITERIA, [])
    assert result.errors == ['research_no_evidence'] and not result.offers
