"""Bounded search routing; credentials and provider selection never come from model arguments.

Provider contracts and keyless routes are linked in docs/api/price-watches.md.
Search results only discover URLs: merchant reads independently establish prices.
"""
import asyncio
import json
import re
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime

import httpx

from app.price_search import SearchError, domain_allowed, public_url

KEYLESS = frozenset({'exa', 'parallel', 'keenable'})
MAX_RESPONSE = 1_000_000


@dataclass
class SearchBudget:
    remaining: int

    def spend(self):
        if self.remaining <= 0:
            raise SearchError('search_request_budget_exhausted')
        self.remaining -= 1


class ProviderFailure(Exception):
    def __init__(self, cooldown=10):
        self.cooldown = cooldown


def retry_delay(value):
    try:
        seconds = float(value)
    except (ValueError, TypeError):
        try:
            seconds = (parsedate_to_datetime(value) - datetime.now(UTC)).total_seconds()
        except (TypeError, ValueError, OverflowError):
            seconds = 60
    return max(1, min(3600, seconds))


def _mcp_result(raw: bytes):
    """Accept bounded JSON or SSE responses, extracting only the matching RPC result."""
    text = raw.decode('utf-8')
    try:
        messages = [json.loads(text)]
    except ValueError:
        messages = []
        for event in text.replace('\r\n', '\n').split('\n\n'):
            data = '\n'.join(line[5:].lstrip(' ') for line in event.splitlines() if line.startswith('data:'))
            if data:
                messages.append(json.loads(data))
    for message in messages:
        if not isinstance(message, dict) or message.get('id') != 1:
            continue
        result = message.get('result')
        if message.get('error') or not isinstance(result, dict) or result.get('isError'):
            raise ProviderFailure(60)
        return result
    raise ProviderFailure()


def _mcp_rows(result, provider):
    structured = result.get('structuredContent')
    if isinstance(structured, dict) and isinstance(structured.get('results'), list):
        return structured['results']
    content = result.get('content')
    if not isinstance(content, list):
        raise ProviderFailure()
    rows = []
    for block in content[:20]:
        if not isinstance(block, dict) or block.get('type') != 'text' or not isinstance(block.get('text'), str):
            continue
        text = block['text']
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict) and isinstance(parsed.get('results'), list):
            rows.extend(parsed['results'])
        elif provider == 'exa':
            # Exa's public MCP returns its own Title/URL records, not a model answer.
            matches = list(re.finditer(r'(?:\A|\n(?:---\n\n)?)Title: ([^\n]*)\nURL: (https://[^\s]+)\n', text))
            for index, match in enumerate(matches[:100]):
                end = matches[index+1].start() if index+1 < len(matches) else len(text)
                excerpt = text[match.end():end]
                snippet = re.split(r'(?:Highlights|Text):\n', excerpt, maxsplit=1)
                rows.append({'title': match[1], 'url': match[2],
                             'snippet': snippet[1][:1200] if len(snippet) > 1 else ''})
    if not rows:
        raise ProviderFailure()
    return rows


class WebSearchRouter:
    def __init__(self, settings, client: httpx.AsyncClient, google_search=None):
        self.settings, self.client, self.google_search = settings, client, google_search
        self.cursor = 0
        self.cooldowns: dict[str, float] = {}

    def key(self, name):
        value = getattr(self.settings, f'{name}_api_key', None)
        return value.get_secret_value().strip() if value else ''

    @property
    def enabled(self):
        return list(dict.fromkeys(name for name in self.settings.watch_search_providers if (
            (name == 'google' and self.google_search is not None)
            or self.key(name) or (self.settings.watch_search_keyless and name in KEYLESS))))

    @property
    def available(self):
        return bool(self.enabled)

    async def search(self, query: str, domains: list[str], limit: int, budget: SearchBudget):
        if not isinstance(query, str) or not 2 <= len(query.strip()) <= 200 or type(limit) is not int:
            raise SearchError('invalid_tool_arguments')
        limit = max(1, min(8, limit))
        names = self.enabled
        if not names:
            raise SearchError('search_not_configured')
        start = self.cursor % len(names)
        self.cursor += 1  # No await before rotation: concurrent runs get different starting providers.
        names = names[start:] + names[:start]
        attempted = False
        try:
            async with asyncio.timeout(self.settings.watch_search_timeout_s):
                for name in names:
                    if self.cooldowns.get(name, 0) > time.monotonic():
                        continue
                    budget.spend()
                    attempted = True
                    try:
                        rows = (await self.google_search(query, {'allowed_domains': domains}, limit)
                                if name == 'google' else await self._search(name, query.strip(), limit))
                        if not isinstance(rows, list):
                            raise ProviderFailure()
                        normalized = self._normalize(rows, domains, limit)
                        if rows and not normalized:
                            # Malformed or disallowed results must not block another provider.
                            raise ProviderFailure()
                        return normalized  # First success, including a legitimate zero-result response.
                    except ProviderFailure as error:
                        self.cooldowns[name] = time.monotonic() + error.cooldown
                    except (httpx.HTTPError, ValueError, KeyError, TypeError, SearchError):
                        self.cooldowns[name] = time.monotonic() + 10
        except TimeoutError as error:
            raise SearchError('search_timeout') from error
        raise SearchError('search_provider_unavailable' if attempted else 'search_providers_cooling_down')

    @staticmethod
    def _normalize(rows, domains, limit):
        sources = []
        seen = set()
        for row in rows[:100]:
            if not isinstance(row, dict):
                continue
            try:
                url = public_url(row.get('url'))
            except SearchError:
                continue
            # Google redirect URLs are accepted by its own adapter and validated at every fetch hop.
            from app.price_search import grounding_redirect
            if url in seen or (not domain_allowed(url, domains) and not grounding_redirect(url)):
                continue
            seen.add(url)
            snippet = row.get('snippet') or row.get('description') or row.get('excerpts') or row.get('highlights') or ''
            if isinstance(snippet, list):
                snippet = ' '.join(s for s in snippet[:5] if isinstance(s, str))
            sources.append({'url': url, 'title': str(row.get('title') or '')[:300],
                            'snippet': snippet[:1200] if isinstance(snippet, str) else ''})
            if len(sources) == limit:
                break
        return sources

    async def _request(self, url, *, headers=None, payload=None, params=None, mcp=False):
        # Fixed trusted endpoints only. Never follow a redirect carrying a provider credential.
        headers = {'User-Agent': 'Agora/1.0', **(headers or {})}
        if mcp:
            headers['Accept'] = 'application/json, text/event-stream'
            headers['MCP-Protocol-Version'] = '2025-03-26'
        async with self.client.stream('GET' if params is not None else 'POST', url, headers=headers,
                                      json=payload, params=params, timeout=8, follow_redirects=False) as response:
            if response.status_code == 429:
                raise ProviderFailure(retry_delay(response.headers.get('retry-after')))
            if response.status_code != 200:
                raise ProviderFailure(300 if response.status_code in (401, 402, 403) else 10)
            body = bytearray()
            async for chunk in response.aiter_bytes():
                body.extend(chunk)
                if len(body) > MAX_RESPONSE:
                    raise ProviderFailure()
        value = _mcp_result(bytes(body)) if mcp else json.loads(body)
        if not isinstance(value, dict) or value.get('success') is False or value.get('error'):
            raise ProviderFailure()
        return value

    async def _search(self, name, query, limit):
        key = self.key(name)
        if name == 'exa':
            if key:
                data = await self._request('https://api.exa.ai/search', headers={'x-api-key': key},
                                           payload={'query': query, 'numResults': limit, 'type': 'auto',
                                                    'contents': {'highlights': True}})
            else:
                return await self._mcp('https://mcp.exa.ai/mcp', 'web_search_exa',
                                       {'query': query, 'numResults': limit}, name)
        elif name == 'parallel':
            if key:
                data = await self._request('https://api.parallel.ai/v1/search', headers={'x-api-key': key},
                                           payload={'objective': query, 'search_queries': [query], 'mode': 'basic',
                                                    'advanced_settings': {'max_results': limit,
                                                        'excerpt_settings': {'max_chars_per_result': 1200}}})
            else:
                return await self._mcp('https://search.parallel.ai/mcp', 'web_search',
                                       {'objective': query, 'search_queries': [query]}, name)
        elif name == 'firecrawl':
            data = await self._request('https://api.firecrawl.dev/v2/search',
                                       headers={'Authorization': f'Bearer {key}'},
                                       payload={'query': query, 'limit': limit})
            return data['data']['web']
        elif name == 'keenable':
            path = '/v1/search' if key else '/v1/search/public'
            data = await self._request('https://api.keenable.ai'+path,
                                       headers={'X-Keenable-Title': 'Agora', **({'X-API-Key': key} if key else {})},
                                       payload={'query': query, 'mode': 'pro'})
        elif name == 'tavily':
            data = await self._request('https://api.tavily.com/search', headers={'Authorization': f'Bearer {key}'},
                                       payload={'query': query, 'max_results': limit, 'search_depth': 'basic',
                                                'include_answer': False, 'include_raw_content': False})
            for row in data.get('results', []):
                if isinstance(row, dict):
                    row['snippet'] = row.get('content', '')
        elif name == 'brave':
            data = await self._request('https://api.search.brave.com/res/v1/web/search',
                                       headers={'X-Subscription-Token': key}, params={'q': query, 'count': limit})
            return data['web']['results']
        else:
            raise ProviderFailure()
        return data['results']

    async def _mcp(self, url, tool, arguments, provider):
        # These two public services support stateless calls; no session IDs are rotated to evade limits.
        result = await self._request(url, mcp=True, payload={
            'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': tool, 'arguments': arguments}})
        return _mcp_rows(result, provider)
