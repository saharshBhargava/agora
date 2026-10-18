import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app import shopping
from tests.conftest import login


async def setup(client):
    headers = await login(client, 'shop_' + uuid4().hex[:10])
    profile = (await client.get('/v1/me', headers=headers)).json()
    return headers, profile['households'][0]['id']


async def add(client, headers, household, name, quantity=0, par=2):
    response = await client.post('/v1/inventory', headers=headers, json={
        'household_id': household, 'display_name': name, 'quantity': quantity, 'par_level': par})
    assert response.status_code == 201, response.text
    return response.json()['id']


def test_six_hour_boundaries_and_downtime():
    for hour, expected in [(0, 6), (5, 6), (6, 12), (12, 18), (17, 18)]:
        now = datetime(2026, 10, 18, hour, 3, tzinfo=UTC)
        assert shopping.next_refresh(now) == now.replace(hour=expected, minute=0)
    assert shopping.next_refresh(datetime(2026, 10, 18, 23, tzinfo=UTC)) == datetime(2026, 10, 19, tzinfo=UTC)


async def test_refresh_creates_evidenced_suggestions_and_replays(client):
    h, household = await setup(client)
    item = await add(client, h, household, 'Dish soap')
    await add(client, h, household, 'Plenty of rice', quantity=12)
    state = (await client.get('/v1/wishlist/refresh-status', headers=h)).json()
    assert state['last_refreshed_at'] is None
    key = {**h, 'Idempotency-Key': uuid4().hex}
    first = await client.post('/v1/wishlist/refresh', headers=key, json={'household_id': household})
    assert first.status_code == 200, first.text
    assert first.json()['generated_count'] == 1
    second = await client.post('/v1/wishlist/refresh', headers=key, json={'household_id': household})
    assert second.json() == first.json()
    assert second.headers['Idempotent-Replay'] == 'true'
    suggestions = (await client.get('/v1/wishlist/suggestions', headers=h)).json()
    assert len(suggestions) == 1
    row = suggestions[0]
    assert row['inventory_item_id'] == item and row['source'] == 'agent'
    assert row['target_price_cents'] is None
    assert row['evidence'][0]['kind'] == 'inventory_low'
    assert 'Last recorded stock' in row['rationale']
    third = await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    assert third.json()['generated_count'] == 0
    assert (await client.post('/v1/wishlist/refresh', headers=h, json={})).status_code == 400


@pytest.mark.parametrize('decision,body', [('accept', {}), ('snooze', {'days': 7}),
                                          ('reject', {'reason_code': 'not_interested'}), ('purchased', {})])
async def test_refresh_preserves_user_decisions(client, decision, body):
    h, household = await setup(client)
    await add(client, h, household, 'Coffee filters')
    await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    row = (await client.get('/v1/wishlist/suggestions', headers=h)).json()[0]
    if decision == 'purchased':
        await client.post(f"/v1/wishlist/{row['id']}/accept", headers=h)
    response = await client.post(f"/v1/wishlist/{row['id']}/{decision}", headers=h, json=body)
    assert response.status_code == 200, response.text
    await client.patch(f"/v1/wishlist/{row['id']}", headers=h, json={'target_price_cents': 499})
    refreshed = await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    assert refreshed.json()['generated_count'] == 0
    current = (await client.get(f"/v1/wishlist/{row['id']}", headers=h)).json()
    assert current['status'] == response.json()['status']
    if decision in ('accept', 'snooze'):
        assert current['target_price_cents'] == 499


async def test_refresh_isolated_and_concurrent(client, app):
    h, household = await setup(client)
    other, _ = await setup(client)
    await add(client, h, household, 'Paper towels')
    assert (await client.get('/v1/wishlist/refresh-status', headers=other,
                            params={'household_id': household})).status_code == 404
    assert (await client.post('/v1/wishlist/refresh', headers={**other, 'Idempotency-Key': uuid4().hex},
                             json={'household_id': household})).status_code == 404
    results = await asyncio.gather(*[client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex},
                                                json={}) for _ in range(3)])
    assert all(r.status_code == 200 for r in results)
    assert sum(r.json()['generated_count'] for r in results) == 1
    assert (await client.get('/v1/wishlist/suggestions', headers=other)).json() == []


async def test_schedule_restart_and_due_job(client, app):
    h, household = await setup(client)
    await add(client, h, household, 'Laundry detergent')
    runner = app.state.shopping
    await asyncio.gather(runner.start(), runner.start())
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM jobs WHERE kind = 'wishlist.sweep' AND status = 'queued'") == 1
        # Claim the current sweep as the real Worker does before executing its handler.
        await conn.execute("UPDATE jobs SET status = 'running', locked_until = now() + interval '5 minutes' "
                           "WHERE kind = 'wishlist.sweep' AND status = 'queued'")
    await runner.sweep({}, 1)
    await runner.sweep({}, 2)  # retry cannot duplicate household work or the future sweep
    async with app.state.db.system() as conn:
        rows = await conn.fetch("SELECT payload FROM jobs WHERE kind = 'wishlist.refresh' "
                                "AND payload->>'household_id' = $1 AND status = 'queued'", household)
        assert len(rows) == 1
        future = await conn.fetchval("SELECT run_at FROM jobs WHERE kind = 'wishlist.sweep' AND status = 'queued'")
        assert datetime.now(UTC) < future <= datetime.now(UTC) + timedelta(hours=6)
    await runner.refresh_job(rows[0]['payload'], 1)
    assert len((await client.get('/v1/wishlist/suggestions', headers=h)).json()) == 1


async def test_failed_refresh_preserves_last_success(client, app, monkeypatch):
    h, household = await setup(client)
    await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    before = (await client.get('/v1/wishlist/refresh-status', headers=h)).json()
    async with app.state.db.system() as conn:
        user = await conn.fetchval('SELECT user_id FROM household_members WHERE household_id = $1', UUID(household))
    async def fail(*args, **kwargs):
        raise RuntimeError('provider secret must not be persisted')
    monkeypatch.setattr(shopping, 'refresh', fail)
    with pytest.raises(RuntimeError):
        await app.state.shopping.refresh_job({'household_id': household, 'user_id': str(user)}, 1)
    after = (await client.get('/v1/wishlist/refresh-status', headers=h)).json()
    assert after['last_refreshed_at'] == before['last_refreshed_at']
    assert after['last_error'] == 'refresh_failed'


async def test_paused_agent_does_not_generate(client, app):
    h, household = await setup(client)
    await add(client, h, household, 'Sponges')
    await client.post('/v1/agent/pause', headers=h)
    response = await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    assert response.status_code == 409 and response.json()['title'] == 'agent_paused'
    async with app.state.db.system() as conn:
        user = await conn.fetchval('SELECT user_id FROM household_members WHERE household_id = $1', UUID(household))
    await app.state.shopping.refresh_job({'household_id': household, 'user_id': str(user)}, 1)
    assert (await client.get('/v1/wishlist/suggestions', headers=h)).json() == []
    await client.post('/v1/agent/resume', headers=h)
    response = await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    assert response.json()['generated_count'] == 1


async def test_cap_stale_unknown_stock_and_shopping_list_suppression(client, app):
    h, household = await setup(client)
    stale = await add(client, h, household, 'Old observation')
    listed = await add(client, h, household, 'Already on list')
    await client.post('/v1/inventory', headers=h, json={'household_id': household, 'display_name': 'Unknown stock',
                                                     'par_level': 2})
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE inventory_observations SET time = now() - interval '31 days' "
                           'WHERE inventory_item_id = $1', UUID(stale))
    shopping_list = await client.post('/v1/lists', headers=h, json={'household_id': household, 'name': 'Weekly shop'})
    assert shopping_list.status_code == 201, shopping_list.text
    response = await client.post(f"/v1/lists/{shopping_list.json()['id']}/items", headers=h,
                                json={'title': 'Already on list', 'inventory_item_id': listed, 'quantity': 1})
    assert response.status_code == 201, response.text
    for i in range(7):
        await add(client, h, household, f'Refill {i}')
    response = await client.post('/v1/wishlist/refresh', headers={**h, 'Idempotency-Key': uuid4().hex}, json={})
    assert response.json()['generated_count'] == 5
    rows = (await client.get('/v1/wishlist/suggestions', headers=h)).json()
    assert len(rows) == 5 and all(row['title'].startswith('Refill') for row in rows)


async def test_edit_cannot_duplicate_open_title_and_blank_fields_fail_cleanly(client):
    h, _ = await setup(client)
    first = (await client.post('/v1/wishlist', headers=h, json={'title': 'Coffee'})).json()
    second = (await client.post('/v1/wishlist', headers=h, json={'title': 'Tea'})).json()
    response = await client.patch(f"/v1/wishlist/{second['id']}", headers=h, json={'title': 'coffee'})
    assert response.status_code == 409 and response.json()['title'] == 'already_on_wishlist'
    response = await client.patch(f"/v1/wishlist/{first['id']}", headers=h, json={'title': 'Coffee'})
    assert response.status_code == 200
    assert (await client.post('/v1/wishlist', headers=h, json={'title': '  '})).status_code == 422
    assert (await client.patch(f"/v1/wishlist/{first['id']}", headers=h, json={'title': '  '})).status_code == 422
    response = await client.post('/v1/wishlist/suggestions', headers={**h, 'Idempotency-Key': uuid4().hex},
                                 json={'title': 'Flour', 'rationale': ' ', 'confidence': 0.8})
    assert response.status_code == 422


async def test_paused_model_suggestions_are_refused(client):
    h, _ = await setup(client)
    await client.post('/v1/agent/pause', headers=h)
    response = await client.post('/v1/wishlist/suggestions', headers={**h, 'Idempotency-Key': uuid4().hex},
                                 json={'title': 'Flour', 'rationale': 'For baking.', 'confidence': 0.8})
    assert response.status_code == 409 and response.json()['title'] == 'agent_paused'
