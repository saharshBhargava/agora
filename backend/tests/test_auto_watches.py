"""A wishlist save is the only activation step; source verification and alert limits still apply."""
import json
from uuid import UUID, uuid4

import httpx
import pytest

from app.price_search import PriceSearchProvider, ProductFetcher
from app.watch_ops import backfill_wishlist_watches, evaluate
from tests.conftest import login
from tests.test_price_search import URL, product_page
from tests.test_watches import criteria, offer
from tests.test_web_search import settings


async def account(client):
    headers = await login(client, 'auto'+uuid4().hex[:12])
    me = (await client.get('/v1/me', headers=headers)).json()
    return headers, me


async def watches(client, headers):
    response = await client.get('/v1/watches', headers=headers)
    assert response.status_code == 200, response.text
    assert response.json()['automatic_watches'] is True
    return response.json()['watches']


@pytest.mark.parametrize('target,expected_result', [(None, 'no_match'), (2000, 'no_match'), (3000, 'matched')])
async def test_save_alone_searches_real_sources_and_exposes_current_price(
        client, app, monkeypatch, target, expected_result):
    headers, me = await account(client)
    calls = []

    async def resolve(host):
        assert host == 'retailer.example'
        return '93.184.216.34'

    monkeypatch.setattr('app.price_search.resolve_public', resolve)

    def remote(request):
        calls.append(request.url.host)
        if request.url.host == 'api.keenable.ai':
            assert 'Lodge' in json.loads(request.content)['query']
            return httpx.Response(200, json={'results': [{'url': URL, 'title': 'Lodge skillet'}]})
        assert request.url.host == '93.184.216.34'
        return httpx.Response(200, text=product_page(), headers={'content-type': 'text/html'})

    config = settings(watch_search_providers=['keenable'])  # No reasoning-model credential.
    async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as external:
        monkeypatch.setattr(app.state.watches, 'provider',
                            PriceSearchProvider(config, external, ProductFetcher(external)))
        saved = await client.post('/v1/wishlist', headers=headers,
                                  json={'title': 'Lodge skillet', 'target_price_cents': target})
        assert saved.status_code == 201, saved.text
        watch, = await watches(client, headers)
        assert watch['wishlist_item_id'] == saved.json()['id']
        assert watch['status'] == 'active' and watch['confirmed_at'] and watch['search_available']
        assert watch['criteria']['target_price_cents'] == target
        assert watch['subscription']['push_enabled'] is False
        assert watch['runs'][0]['status'] == 'queued'
        await app.state.watches.check_job({'watch_id': watch['id'], 'run_id': watch['runs'][0]['id'],
                                          'user_id': me['id']}, 1)
        result, = await watches(client, headers)
    assert calls == ['api.keenable.ai', '93.184.216.34']
    assert result['last_result'] == expected_result
    assert result['prices'][0]['unit_price_cents'] == 2499 and result['prices'][0]['is_current']
    assert result['prices'][0]['url'] == URL
    inbox = (await client.get('/v1/notifications', headers=headers)).json()
    assert len(inbox) == int(expected_result == 'matched')
    async with app.state.db.scoped(UUID(me['id'])) as conn:
        assert not await conn.fetchval('SELECT 1 FROM orders WHERE household_id=$1', UUID(watch['household_id']))


async def test_only_accepted_suggestions_start_checks(client):
    headers, _ = await account(client)
    suggestion = await client.post('/v1/wishlist/suggestions', headers=headers | {'Idempotency-Key': uuid4().hex},
                                   json={'title': 'Coffee filters', 'rationale': 'For coffee', 'confidence': .8})
    assert suggestion.status_code == 201
    assert not await watches(client, headers)
    accepted = await client.post(f"/v1/wishlist/{suggestion.json()['id']}/accept", headers=headers)
    assert accepted.status_code == 200
    watch, = await watches(client, headers)
    assert watch['runs'][0]['status'] == 'queued' and watch['criteria']['target_price_cents'] is None


async def test_edits_research_new_criteria_and_preserve_explicit_pause(client):
    headers, _ = await account(client)
    item = (await client.post('/v1/wishlist', headers=headers, json={'title': 'Coffee filters'})).json()
    original, = await watches(client, headers)
    await client.patch(f"/v1/wishlist/{item['id']}", headers=headers,
                       json={'title': 'Unbleached coffee filters', 'quantity': 2, 'target_price_cents': 500})
    updated, = await watches(client, headers)
    assert updated['id'] == original['id'] and updated['status'] == 'active'
    assert updated['criteria']['query'] == 'Unbleached coffee filters'
    assert updated['criteria']['quantity'] == 2 and updated['criteria']['target_price_cents'] == 500
    assert sum(r['status'] == 'queued' for r in updated['runs']) == 1
    await client.patch(f"/v1/watches/{updated['id']}", headers=headers, json={'status': 'paused'})
    await client.patch(f"/v1/wishlist/{item['id']}", headers=headers, json={'target_price_cents': None})
    paused, = await watches(client, headers)
    assert paused['status'] == 'paused' and paused['criteria']['target_price_cents'] is None
    assert not any(r['status'] in ('queued', 'running') for r in paused['runs'])
    await client.delete(f"/v1/wishlist/{item['id']}", headers=headers)
    completed, = await watches(client, headers)
    assert completed['status'] == 'completed'


async def test_exhausted_check_budget_does_not_prevent_saving_or_remove_watch(client, app, monkeypatch):
    headers, _ = await account(client)
    monkeypatch.setattr(app.state.settings, 'watch_daily_check_cap', 3)
    for title in ['Coffee filters', 'Coffee beans']:
        response = await client.post('/v1/wishlist', headers=headers, json={'title': title})
        assert response.status_code == 201
    rows = await watches(client, headers)
    deferred = next(w for w in rows if w['title'] == 'Coffee beans')
    assert deferred['status'] == 'active' and deferred['last_error'] == 'check_budget_exhausted'
    assert not deferred['runs']


async def test_backfill_is_idempotent_and_preserves_existing_pauses(client, app):
    headers, me = await account(client)
    response = await client.post('/v1/wishlist', headers=headers, json={'title': 'Coffee filters'})
    assert response.status_code == 201
    existing, = await watches(client, headers)
    await client.patch(f"/v1/watches/{existing['id']}", headers=headers, json={'status': 'paused'})
    async with app.state.db.scoped(UUID(me['id'])) as conn:
        await conn.execute(
            '''INSERT INTO wishlist_items(household_id,title,normalized_title,source,status,created_by)
               VALUES($1,'Coffee grinder','coffee grinder','user','active',$2)''',
            UUID(me['households'][0]['id']), UUID(me['id']))
        await backfill_wishlist_watches(conn)
        await backfill_wishlist_watches(conn)
    rows = await watches(client, headers)
    assert len(rows) == 2
    assert next(w for w in rows if w['id'] == existing['id'])['status'] == 'paused'
    new = next(w for w in rows if w['id'] != existing['id'])
    assert new['status'] == 'active' and len(new['runs']) == 1


def test_missing_target_and_meaningless_identity_never_trigger_price_alerts():
    assert evaluate(criteria() | {'target_price_cents': None}, offer())['reason'] == 'target_not_set'
    assert evaluate(criteria() | {'query': '!!!'}, offer())['reason'] == 'required_terms_missing'
