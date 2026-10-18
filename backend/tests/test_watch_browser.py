"""Last-resort browser handoff boundaries and device-evidence provenance."""
import json
from datetime import UTC, datetime
from uuid import UUID, uuid4

import httpx
import pytest

from app.config import Settings
from app.price_search import PriceSearchProvider, SearchResult
from app.watch_browser import BrowserPage, browser_prices
from tests.conftest import login
from tests.test_price_search import CRITERIA, URL, product_page


async def pending(client, app, monkeypatch, title='Lodge cast iron skillet 10 inch'):
    headers = await login(client, 'browser'+uuid4().hex[:12])
    user = (await client.get('/v1/me', headers=headers)).json()
    saved = await client.post('/v1/wishlist', headers=headers, json={'title': title, 'target_price_cents': 3000})
    assert saved.status_code == 201
    rows = (await client.get('/v1/watches', headers=headers)).json()['watches']
    watch = next(w for w in rows if w['wishlist_item_id'] == saved.json()['id'])
    run = watch['runs'][0]

    async def search(*_):
        return SearchResult(checked_count=2, errors=['retailer_access_limited'], browser_urls=[URL])

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await app.state.watches.check_job({'watch_id': watch['id'], 'run_id': run['id'], 'user_id': user['id']}, 1)
    watch = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert watch['browser_fallback']['status'] == 'pending'
    return headers, user, watch


def product():
    return json.loads(product_page().split('>', 1)[1].rsplit('<', 1)[0])


def body(watch):
    return {'run_id': watch['runs'][0]['id'], 'criteria_version': watch['criteria_version']}


async def claim(client, headers, watch, key=None):
    return await client.post(f"/v1/watches/{watch['id']}/browser-claim",
                             headers=headers | {'Idempotency-Key': key or uuid4().hex}, json=body(watch))


async def test_browser_fallback_completes_with_comparison_but_never_creates_verified_alerts(client, app, monkeypatch):
    headers, user, watch = await pending(client, app, monkeypatch)
    key = uuid4().hex
    claimed = await claim(client, headers, watch, key)
    assert claimed.status_code == 200, claimed.text
    assert (await claim(client, headers, watch, key)).json() == claimed.json()
    assert (await claim(client, headers, watch)).status_code == 409
    assert 'token' not in str((await client.get('/v1/watches/'+watch['id'], headers=headers)).json())
    payload = {**body(watch), 'token': claimed.json()['token'], 'outcome': 'completed',
               'pages': [{'source_url': URL, 'final_url': URL, 'products': [product()]}]}
    key = uuid4().hex
    for _ in range(2):
        response = await client.post(f"/v1/watches/{watch['id']}/browser-result",
                                     headers=headers | {'Idempotency-Key': key}, json=payload)
        assert response.status_code == 200, response.text
        assert response.json() == {'status': 'completed', 'price_count': 1}
    result = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert result['browser_fallback']['status'] == 'completed'
    assert result['prices'][0]['unit_price_cents'] == 2499
    assert result['prices'][0]['provenance'] == 'device_browser'
    assert result['prices'][0]['is_current']
    assert not result['matches']
    assert (await client.get('/v1/notifications', headers=headers)).json() == []
    async with app.state.db.scoped(UUID(user['id'])) as conn:
        assert not await conn.fetchval('SELECT 1 FROM watch_observations WHERE watch_id=$1', UUID(watch['id']))


@pytest.mark.parametrize('change', ['rename', 'pause', 'new_run', 'agent_pause', 'expired_lease', 'wrong_token'])
async def test_stale_browser_results_cannot_change_prices(client, app, monkeypatch, change):
    headers, user, watch = await pending(client, app, monkeypatch)
    claimed = (await claim(client, headers, watch)).json()
    if change == 'rename':
        await client.patch('/v1/wishlist/'+watch['wishlist_item_id'], headers=headers, json={'title': 'PS5'})
    elif change == 'pause':
        await client.patch('/v1/watches/'+watch['id'], headers=headers, json={'status': 'paused'})
    elif change == 'new_run':
        await client.post('/v1/watches/'+watch['id']+'/check', headers=headers | {'Idempotency-Key': uuid4().hex})
    elif change == 'agent_pause':
        async with app.state.db.scoped(UUID(user['id'])) as conn:
            await conn.execute('UPDATE user_settings SET agent_paused_at=now() WHERE user_id=$1', UUID(user['id']))
    elif change == 'expired_lease':
        async with app.state.db.scoped(UUID(user['id'])) as conn:
            await conn.execute("UPDATE watch_runs SET browser_expires_at=now()-interval '1 second' WHERE id=$1",
                               UUID(watch['runs'][0]['id']))
    else:
        claimed['token'] = str(uuid4())
    result = await client.post('/v1/watches/'+watch['id']+'/browser-result',
                              headers=headers | {'Idempotency-Key': uuid4().hex},
                              json={**body(watch), 'token': claimed['token'], 'outcome': 'completed',
                                    'pages': [{'source_url': URL, 'final_url': URL, 'products': [product()]}]})
    assert result.status_code == 409, result.text
    result = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert result['prices'] == []


async def test_browser_claim_is_household_scoped_and_recoverable(client, app, monkeypatch):
    headers, user, watch = await pending(client, app, monkeypatch)
    stranger = await login(client, 'stranger'+uuid4().hex[:12])
    assert (await claim(client, stranger, watch)).status_code == 404
    first = (await claim(client, headers, watch)).json()
    async with app.state.db.scoped(UUID(user['id'])) as conn:
        await conn.execute("UPDATE watch_runs SET browser_expires_at=now()-interval '1 second' WHERE id=$1",
                           UUID(watch['runs'][0]['id']))
    loaded = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert loaded['browser_fallback']['status'] == 'pending'
    second = await claim(client, headers, watch)
    assert second.status_code == 200 and second.json()['token'] != first['token']


async def test_browser_interaction_required_finishes_and_offers_explicit_review(client, app, monkeypatch):
    headers, _, watch = await pending(client, app, monkeypatch)
    claimed = (await claim(client, headers, watch)).json()
    response = await client.post('/v1/watches/'+watch['id']+'/browser-result',
                                headers=headers | {'Idempotency-Key': uuid4().hex},
                                json={**body(watch), 'token': claimed['token'], 'outcome': 'interaction_required'})
    assert response.json() == {'status': 'unavailable', 'price_count': 0}
    loaded = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert loaded['runs'][0]['interaction_urls'] == [URL]
    assert loaded['browser_fallback']['status'] == 'unavailable'
    assert loaded['prices'] == []


async def test_demo_never_exposes_or_claims_browser_work(client, app):
    headers = await login(client, 'demo')
    watch = (await client.get('/v1/watches', headers=headers)).json()['watches'][0]
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE watch_runs SET browser_state='pending',browser_urls=$2 WHERE id=$1",
                           UUID(watch['runs'][0]['id']), [URL])
    result = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert result['browser_fallback'] is None
    assert (await claim(client, headers, result)).status_code == 409


async def test_queued_server_work_cannot_be_claimed_for_browser(client, app):
    headers = await login(client, 'queued'+uuid4().hex[:12])
    await client.post('/v1/wishlist', headers=headers, json={'title': 'PS5'})
    watch = (await client.get('/v1/watches', headers=headers)).json()['watches'][0]
    assert watch['browser_fallback'] is None
    assert (await claim(client, headers, watch)).status_code == 409


@pytest.mark.parametrize('source,final', [('https://other.example/p', URL), (URL, 'https://other.example/p'),
                                          (URL, 'https://127.0.0.1/p'), (URL, 'http://retailer.example/p')])
def test_browser_evidence_cannot_introduce_unapproved_sources(source, final):
    with pytest.raises(Exception) as error:
        browser_prices(CRITERIA, [BrowserPage(source_url=source, final_url=final, products=[product()])], [URL])
    assert error.value.code == 'invalid_browser_source'


@pytest.mark.parametrize('field,value', [('price', 'NaN'), ('price', '1.001'), ('priceCurrency', 'CAD'),
                                        ('availability', 'https://schema.org/OutOfStock'),
                                        ('itemCondition', 'https://schema.org/UsedCondition'),
                                        ('validForMemberTier', {'name': 'Members'}),
                                        ('description', 'Coupon required')])
def test_browser_prices_reject_invalid_or_conditional_evidence(field, value):
    p = product()
    p['offers'][field] = value
    assert browser_prices(CRITERIA, [BrowserPage(source_url=URL, final_url=URL, products=[p])], [URL]) == []


@pytest.mark.parametrize('title', ['Sony PlayStation 5 console', 'PlayStation®5 Digital Edition'])
def test_rendered_price_supports_optional_target_and_ps5_alias_without_fabricated_availability(title):
    p = {'@type': 'Product', 'name': title,
         'offers': {'@type': 'Offer', 'price': '499.99', 'priceCurrency': 'USD'}}
    prices = browser_prices({'query': 'PS5', 'target_price_cents': None},
                            [BrowserPage(source_url=URL, final_url=URL, products=[p])], [URL])
    assert prices[0]['unit_price_cents'] == 49999 and prices[0]['reason'] == 'browser_observed'
    assert datetime.fromisoformat(prices[0]['observed_at']) <= datetime.now(UTC)
    assert browser_prices({'query': 'Xbox Series X'},
                          [BrowserPage(source_url=URL, final_url=URL, products=[p])], [URL]) == []


def test_distinct_retailers_and_product_pages_precede_repeated_categories():
    urls = ['https://one.example/browse/consoles', 'https://one.example/p/xbox', 'https://two.example/p/xbox']
    assert PriceSearchProvider.retailer_urls(urls) == [urls[1], urls[2], urls[0]]


async def test_pending_browser_work_waits_for_next_foreground_but_prices_expire(client, app, monkeypatch):
    headers, user, watch = await pending(client, app, monkeypatch)
    async with app.state.db.scoped(UUID(user['id'])) as conn:
        await conn.execute("UPDATE watch_runs SET finished_at=now()-interval '2 hours' WHERE id=$1",
                           UUID(watch['runs'][0]['id']))
    loaded = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert loaded['browser_fallback']['status'] == 'pending'
    assert (await claim(client, headers, watch)).status_code == 200
    async with app.state.db.scoped(UUID(user['id'])) as conn:
        old = {'id': str(uuid4()), 'observed_at': '2020-01-01T00:00:00+00:00', 'unit_price_cents': 1}
        await conn.execute("UPDATE watch_runs SET browser_state='completed',browser_prices=$2 WHERE id=$1",
                           UUID(watch['runs'][0]['id']), [old])
    loaded = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert loaded['prices'] == []


async def test_normal_server_price_prevents_browser_fallback(client, app, monkeypatch):
    from app.price_search import extract_offers
    headers = await login(client, 'normal'+uuid4().hex[:12])
    user = (await client.get('/v1/me', headers=headers)).json()
    await client.post('/v1/wishlist', headers=headers, json={'title': CRITERIA['query'], 'target_price_cents': 3000})
    watch = (await client.get('/v1/watches', headers=headers)).json()['watches'][0]

    async def search(*_):
        return SearchResult(checked_count=1, offers=extract_offers(product_page(), URL, watch['criteria']),
                            browser_urls=[URL])

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await app.state.watches.check_job({'watch_id': watch['id'], 'run_id': watch['runs'][0]['id'],
                                      'user_id': user['id']}, 1)
    loaded = (await client.get('/v1/watches/'+watch['id'], headers=headers)).json()
    assert loaded['prices'] and loaded['browser_fallback'] is None
    assert (await claim(client, headers, loaded)).status_code == 409


@pytest.mark.parametrize('succeeds', [True, False])
async def test_normal_discovery_tries_multiple_retailers_with_one_shared_budget(monkeypatch, succeeds):
    settings = Settings(_env_file=None, watch_search_providers=['keenable'], gemini_api_key=None,
                        watch_search_api_key=None, openai_model='', watch_max_pages=5)
    async with httpx.AsyncClient() as external:
        provider = PriceSearchProvider(settings, external)
        searches, reads = [], []

        async def sources(query, criteria, limit, *, budget):
            searches.append(budget)
            return [{'url': f'https://shop{i}.example/products/skillet'} for i in range(7)]

        async def fetch(url, domains):
            reads.append(url)
            if succeeds and len(reads) == 2:
                return url, product_page(url=url)
            from app.price_search import SearchError
            raise SearchError('retailer_access_limited')

        monkeypatch.setattr(provider, 'search_sources', sources)
        monkeypatch.setattr(provider.fetcher, 'fetch', fetch)
        result = await provider.search(CRITERIA, [])
    assert len(reads) == (3 if succeeds else 5)
    assert len(searches) == (1 if succeeds else 2)
    assert all(budget is searches[0] for budget in searches)
    assert len(set(reads)) == len(reads)
    assert result.checked_urls == reads
    assert result.browser_urls == [f'https://shop{i}.example/products/skillet' for i in range(5)]
    assert provider.has_usable_price(CRITERIA, result) == succeeds
