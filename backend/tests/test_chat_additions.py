"""Chat uses the normal create routes with stable idempotency keys."""
import asyncio
from uuid import uuid4

import pytest

from tests.conftest import login


async def destination(client, headers, kind):
    household = (await client.get('/v1/me', headers=headers)).json()['households'][0]['id']
    if kind == 'inventory':
        return '/v1/inventory', {'household_id': household, 'display_name': 'Chat jasmine rice',
                                 'quantity': 2, 'unit': 'bags'}, 'display_name'
    if kind == 'wishlist':
        return '/v1/wishlist', {'household_id': household, 'title': 'Chat coffee grinder', 'quantity': 1}, 'title'
    result = await client.post('/v1/lists', headers=headers, json={'household_id': household, 'name': 'Weekend'})
    assert result.status_code == 201, result.text
    return f"/v1/lists/{result.json()['id']}/items", {'title': 'Chat eggs', 'quantity': 2, 'unit': 'cartons'}, 'title'


@pytest.mark.parametrize('kind', ['inventory', 'wishlist', 'list'])
async def test_chat_add_replay_duplicate_and_isolation(client, kind):
    headers = await login(client, 'chat_' + uuid4().hex[:12])
    other = await login(client, 'chat_other_' + uuid4().hex[:8])
    path, body, title = await destination(client, headers, kind)
    keyed = {**headers, 'Idempotency-Key': str(uuid4())}
    first = await client.post(path, headers=keyed, json=body)
    assert first.status_code == 201, first.text
    again = await client.post(path, headers=keyed, json=body)
    assert again.status_code == 201, again.text
    assert first.json() == again.json()
    changed = await client.post(path, headers=keyed, json={**body, 'quantity': 3})
    assert changed.status_code == 422
    assert changed.json()['title'] == 'idempotency_key_reused'
    duplicate = await client.post(path, headers={**headers, 'Idempotency-Key': str(uuid4())},
                                  json={**body, title: '  ' + body[title].upper() + '  ', 'quantity': 3})
    assert duplicate.status_code == 409, duplicate.text
    assert duplicate.json()['title'] == {'inventory': 'already_in_inventory', 'wishlist': 'already_on_wishlist',
                                         'list': 'already_on_list'}[kind]
    forbidden = await client.post(path, headers={**other, 'Idempotency-Key': keyed['Idempotency-Key']}, json=body)
    assert forbidden.status_code == 404, forbidden.text
    if kind == 'list':
        parent = path.removesuffix('/items')
        rows = (await client.get(parent, headers=headers)).json()['items']
        await client.patch(parent, headers=headers, json={'status': 'done'})
        replay = await client.post(path, headers=keyed, json=body)
        assert replay.status_code == 201
        assert replay.json()['id'] == first.json()['id']
    else:
        rows = (await client.get(path, headers=headers, params={'household_id': body['household_id']})).json()
    saved = [r for r in rows if r['id'] == first.json()['id']]
    assert len(saved) == 1
    assert saved[0]['quantity'] == body['quantity']


@pytest.mark.parametrize('kind', ['inventory', 'wishlist', 'list'])
async def test_chat_concurrent_retries_and_duplicate_names(client, kind):
    headers = await login(client, 'chat_race_' + uuid4().hex[:10])
    path, body, _ = await destination(client, headers, kind)
    keyed = {**headers, 'Idempotency-Key': str(uuid4())}
    results = await asyncio.gather(*(client.post(path, headers=keyed, json=body) for _ in range(3)))
    assert [r.status_code for r in results] == [201] * 3
    assert len({r.json()['id'] for r in results}) == 1
    path, body, field = await destination(client, headers, kind)
    body[field] += ' fresh'
    results = await asyncio.gather(*(client.post(path, headers={**headers, 'Idempotency-Key': str(uuid4())},
                                                 json=body) for _ in range(2)))
    assert sorted(r.status_code for r in results) == [201, 409]


@pytest.mark.parametrize('kind', ['inventory', 'wishlist', 'list'])
async def test_chat_validation_and_legacy_create(client, kind):
    headers = await login(client, 'chat_valid_' + uuid4().hex[:10])
    path, body, _ = await destination(client, headers, kind)
    bad_key = await client.post(path, headers={**headers, 'Idempotency-Key': 'x'}, json=body)
    assert bad_key.status_code == 400
    invalid = await client.post(path, headers={**headers, 'Idempotency-Key': str(uuid4())},
                                json={**body, 'quantity': -1})
    assert invalid.status_code == 422
    legacy = await client.post(path, headers=headers, json=body)
    assert legacy.status_code == 201, legacy.text


async def test_chat_demo_backfill_preserves_edits(app, client):
    from app.demo_account import ensure_demo_account
    headers = await login(client, 'demo')
    lists = (await client.get('/v1/lists', headers=headers)).json()
    weekend = next(r for r in lists if r['name'] == 'Weekend groceries')
    await client.patch('/v1/lists/' + weekend['id'], headers=headers, json={'name': 'My renamed weekend'})
    await ensure_demo_account(app.state.db, app.state.settings)
    after = (await client.get('/v1/lists', headers=headers)).json()
    assert any(r['id'] == weekend['id'] and r['name'] == 'My renamed weekend' for r in after)
    assert not any(r['name'] == 'Weekend groceries' for r in after)


async def test_chat_create_list_replay_duplicate_and_isolation(client):
    headers = await login(client, 'create_' + uuid4().hex[:12])
    other = await login(client, 'other_' + uuid4().hex[:12])
    household = (await client.get('/v1/me', headers=headers)).json()['households'][0]['id']
    body = {'household_id': household, 'name': 'Weekend supplies'}
    keyed = {**headers, 'Idempotency-Key': str(uuid4())}
    first = await client.post('/v1/lists', headers=keyed, json=body)
    assert first.status_code == 201, first.text
    replay = await client.post('/v1/lists', headers=keyed, json=body)
    assert replay.json() == first.json()
    changed = await client.post('/v1/lists', headers=keyed, json={**body, 'name': 'Other supplies'})
    assert changed.status_code == 422
    assert changed.json()['title'] == 'idempotency_key_reused'
    duplicate = await client.post('/v1/lists', headers={**headers, 'Idempotency-Key': str(uuid4())},
                                  json={**body, 'name': '  WEEKEND   supplies '})
    assert duplicate.status_code == 409, duplicate.text
    assert duplicate.json()['title'] == 'already_exists'
    forbidden = await client.post('/v1/lists', headers={**other, 'Idempotency-Key': keyed['Idempotency-Key']},
                                   json=body)
    assert forbidden.status_code == 404
    # The returned ID immediately accepts items and persists across a reload.
    path = '/v1/lists/' + first.json()['id']
    item = await client.post(path + '/items', headers={**headers, 'Idempotency-Key': str(uuid4())},
                             json={'title': 'Eggs', 'quantity': 2, 'unit': 'cartons'})
    assert item.status_code == 201, item.text
    assert (await client.get(path, headers=headers)).json()['items'][0]['title'] == 'Eggs'
    await client.patch(path, headers=headers, json={'status': 'done'})
    assert (await client.post('/v1/lists', headers=keyed, json=body)).json() == first.json()


async def test_chat_create_list_concurrency_and_legacy_forms(client):
    headers = await login(client, 'create_race_' + uuid4().hex[:8])
    body = {'name': 'Camping supplies'}
    keyed = {**headers, 'Idempotency-Key': str(uuid4())}
    results = await asyncio.gather(*(client.post('/v1/lists', headers=keyed, json=body) for _ in range(3)))
    assert [r.status_code for r in results] == [201] * 3
    assert len({r.json()['id'] for r in results}) == 1
    results = await asyncio.gather(*(client.post('/v1/lists', headers={**headers, 'Idempotency-Key': str(uuid4())},
                                                 json={'name': 'Picnic'}) for _ in range(2)))
    assert sorted(r.status_code for r in results) == [201, 409]
    assert (await client.post('/v1/lists', headers={**headers, 'Idempotency-Key': 'x'}, json=body)).status_code == 400
    # Older forms without keys keep their existing ability to create same-name lists.
    assert (await client.post('/v1/lists', headers=headers, json=body)).status_code == 201
    assert (await client.post('/v1/lists', headers=headers, json=body)).status_code == 201


async def test_chat_list_demo_backfill_preserves_renames_and_archives(app, client):
    from app.demo_account import ensure_demo_account
    headers = await login(client, 'demo')
    lists = (await client.get('/v1/lists', headers=headers)).json()
    market = next(row for row in lists if row['name'] == 'Sunday farmers market')
    assert {item['title'] for item in market['items']} == {'Seasonal apples', 'Sourdough loaf'}
    await client.patch('/v1/lists/' + market['id'], headers=headers,
                       json={'name': 'My market list', 'status': 'archived'})
    await ensure_demo_account(app.state.db, app.state.settings)
    after = (await client.get('/v1/lists', headers=headers)).json()
    assert not any(row['name'] == 'Sunday farmers market' for row in after)
    assert (await client.get('/v1/lists/' + market['id'], headers=headers)).json()['name'] == 'My market list'
