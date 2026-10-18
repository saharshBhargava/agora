"""API → durable forecast job → automatic store lists → user decisions, without a chat request."""
import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app import replenishment
from tests.conftest import login


async def account(client):
    headers = await login(client, 'auto_' + uuid4().hex[:12])
    me = (await client.get('/v1/me', headers=headers)).json()
    return headers, UUID(me['id']), UUID(me['households'][0]['id'])


async def item(client, headers, name, **fields):
    household = (await client.get('/v1/me', headers=headers)).json()['households'][0]['id']
    response = await client.post('/v1/inventory', headers=headers,
                                 json={'household_id': household, 'display_name': name, 'quantity': 0, **fields})
    assert response.status_code == 201, response.text
    return response.json()


async def lists(client, headers):
    response = await client.get('/v1/lists', headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


async def store(client, headers, name):
    response = await client.post('/v1/merchants', headers=headers, json={'name': name, 'locality': 'Downtown'})
    assert response.status_code == 201, response.text
    return response.json()['merchant']['id']


async def test_stock_updates_create_lists_without_chat_or_generate_request(client, app):
    h, user, household = await account(client)
    market = await store(client, h, 'Corner Market')
    target = await store(client, h, 'Household Store')
    milk = await item(client, h, 'Oat milk', preferred_merchant_id=market, par_level=2, unit='cartons')
    soap = await item(client, h, 'Dish soap', preferred_merchant_id=target, quantity=1, par_level=3)
    await item(client, h, 'Coffee filters')
    await item(client, h, 'Plenty of rice', quantity=30, par_level=2)
    await item(client, h, 'Unknown stock', quantity=None, par_level=2)
    await app.state.worker.drain()
    result = await lists(client, h)
    assert len(result) == 3
    by_store = {row['merchant']['id'] if row['merchant'] else None: row for row in result}
    assert by_store[market]['items'][0]['inventory_item_id'] == milk['id']
    assert by_store[target]['items'][0]['inventory_item_id'] == soap['id']
    assert by_store[None]['items'][0]['title'] == 'Coffee filters'
    assert by_store[market]['items'][0]['quantity'] == 2
    assert by_store[target]['items'][0]['quantity'] == 2
    assert all(row['source'] == 'generated' and row['items'][0]['explanation'] for row in result)
    payload = {'household_id': str(household), 'user_id': str(user)}
    await asyncio.gather(*(app.state.shopping.replenish_job(payload, 1) for _ in range(3)))
    assert await lists(client, h) == result
    other, outsider, _ = await account(client)
    await app.state.shopping.replenish_job({'household_id': str(household), 'user_id': str(outsider)}, 1)
    assert await lists(client, other) == []
    assert await lists(client, h) == result


@pytest.mark.parametrize('decision', ['check', 'delete', 'archive', 'done'])
async def test_decisions_wait_for_new_observation(client, app, decision):
    h, user, household = await account(client)
    stock = await item(client, h, 'Paper towels')
    await app.state.worker.drain()
    lst = (await lists(client, h))[0]
    line = lst['items'][0]
    if decision == 'check':
        response = await client.patch(f"/v1/lists/{lst['id']}/items/{line['id']}", headers=h, json={'checked': True})
    elif decision == 'delete':
        response = await client.delete(f"/v1/lists/{lst['id']}/items/{line['id']}", headers=h)
    else:
        response = await client.patch(f"/v1/lists/{lst['id']}", headers=h,
                                      json={'status': 'archived' if decision == 'archive' else 'done'})
    assert response.status_code in (200, 204), response.text
    await app.state.shopping.replenish_job({'household_id': str(household), 'user_id': str(user)}, 1)
    assert not [i for row in await lists(client, h) for i in row['items'] if not i['checked']]
    # A new stock reading starts a new decision, even if the observed item is still empty.
    response = await client.post(f"/v1/inventory/{stock['id']}/observations", headers=h, json={'quantity': 0})
    assert response.status_code == 201, response.text
    await app.state.worker.drain()
    assert len([i for row in await lists(client, h) for i in row['items'] if not i['checked']]) == 1


async def test_restock_removes_only_untouched_automatic_lines(client, app):
    h, _, _ = await account(client)
    a = await item(client, h, 'Coffee filters', par_level=2)
    b = await item(client, h, 'Paper towels', par_level=2)
    await app.state.worker.drain()
    lst = (await lists(client, h))[0]
    edited = next(i for i in lst['items'] if i['inventory_item_id'] == b['id'])
    response = await client.patch(f"/v1/lists/{lst['id']}/items/{edited['id']}", headers=h,
                                  json={'quantity': 7, 'note': 'For the party'})
    assert response.status_code == 200
    await client.post(f"/v1/lists/{lst['id']}/items", headers=h, json={'title': 'Birthday candles'})
    for row in (a, b):
        response = await client.post(f"/v1/inventory/{row['id']}/observations", headers=h, json={'quantity': 20})
        assert response.status_code == 201
    await app.state.worker.drain()
    lines = (await lists(client, h))[0]['items']
    assert {i['title'] for i in lines} == {'Paper towels', 'Birthday candles'}
    assert next(i for i in lines if i['title'] == 'Paper towels')['quantity'] == 7


async def test_pause_resume_sweep_and_restart(client, app):
    h, user, household = await account(client)
    await client.post('/v1/agent/pause', headers=h)
    await item(client, h, 'Toothpaste')
    await app.state.worker.drain()
    assert await lists(client, h) == []
    await client.post('/v1/agent/resume', headers=h)
    # Existing six-hour sweep covers households even without further inventory mutations.
    await app.state.shopping.sweep({}, 1)
    await app.state.worker.drain()
    before = await lists(client, h)
    assert len(before) == 1 and before[0]['items'][0]['title'] == 'Toothpaste'
    await asyncio.gather(app.state.shopping.start(), app.state.shopping.start())
    await app.state.worker.drain()
    assert await lists(client, h) == before
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM jobs WHERE kind='wishlist.sweep' AND status='queued'") == 1
        assert not await conn.fetchval("SELECT 1 FROM jobs WHERE kind='lists.replenish' AND status='failed'")


async def test_consumption_forecast_and_last_purchase_store(client, app):
    h, user, household = await account(client)
    market = await store(client, h, 'Neighborhood Market')
    stock = await item(client, h, 'Coffee beans', quantity=3, unit='cups')
    now = datetime.now(UTC)
    async with app.state.db.scoped(user) as conn:
        # Real history: one cup daily, still above zero, no restock threshold.
        for days in range(1, 11):
            await conn.execute("""INSERT INTO inventory_observations
                (time,household_id,inventory_item_id,quantity,source,recorded_by)
                VALUES ($1,$2,$3,$4,'manual',$5)""",
                now-timedelta(days=days), household, UUID(stock['id']), 3+days, user)
        scan = await conn.fetchval("""INSERT INTO scans
            (household_id,user_id,captured_at,media_kind,status,provider,model,confirmed_at)
            VALUES ($1,$2,$3,'photos','confirmed','test','history',$3) RETURNING id""", household, user, now)
        detection = await conn.fetchval("""INSERT INTO scan_detections
            (scan_id,household_id,label,confidence,count,quantity,inventory_item_id,review)
            VALUES ($1,$2,'Coffee beans',0.9,13,13,$3,'accepted') RETURNING id""", scan, household, UUID(stock['id']))
        await conn.execute("""INSERT INTO inventory_purchase_origins
            (scan_detection_id,scan_id,household_id,inventory_item_id,merchant_id,observed_at,quantity)
            VALUES ($1,$2,$3,$4,$5,$6,13)""", detection, scan, household, UUID(stock['id']),
            UUID(market), now-timedelta(days=10))
    await app.state.worker.drain()
    result = await lists(client, h)
    assert len(result) == 1 and result[0]['merchant']['id'] == market
    line = result[0]['items'][0]
    assert line['merchant_basis'] == 'last_purchase' and line['needed_by'] is not None
    assert 'Confidence:' in line['explanation']
    due = datetime.fromisoformat(line['needed_by'])
    assert now+timedelta(days=2) < due < now+timedelta(days=4)


async def test_stale_forecast_unknown_stock_and_manual_title_dedup(client, app):
    h, user, household = await account(client)
    stock = await item(client, h, 'Milk', quantity=0)
    # Run only the forecast handler; leave automatic work queued.
    await app.state.pipeline.forecaster.refresh_job({'household_id': str(household), 'user_id': str(user)}, 1)
    response = await client.post(f"/v1/inventory/{stock['id']}/observations", headers=h, json={'quantity': 100})
    assert response.status_code == 201
    await app.state.shopping.replenish_job({'household_id': str(household), 'user_id': str(user)}, 1)
    assert await lists(client, h) == []
    manual = await client.post('/v1/lists', headers=h, json={'name': 'My groceries'})
    await client.post(f"/v1/lists/{manual.json()['id']}/items", headers=h, json={'title': '  COFFEE filters  '})
    await item(client, h, 'Coffee filters')
    await app.state.worker.drain()
    assert len([i for row in await lists(client, h) for i in row['items']]) == 1


async def test_queued_update_while_running_is_not_lost(client, app):
    _, user, household = await account(client)
    async with app.state.db.scoped(user) as conn:
        await replenishment.enqueue(conn, household, user)
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE jobs SET status='running', locked_until=now()+interval '5 minutes' "
                           "WHERE kind='lists.replenish' AND payload->>'household_id'=$1", str(household))
    async with app.state.db.scoped(user) as conn:
        await replenishment.enqueue(conn, household, user)
        await replenishment.enqueue(conn, household, user)
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM jobs WHERE kind='lists.replenish' AND status='queued' "
                                   "AND payload->>'household_id'=$1", str(household)) == 1


async def test_prior_predictions_and_stale_observations(client, app):
    h, user, household = await account(client)
    prior = await item(client, h, 'Milk', quantity=0.1, category='dairy')
    stale = await item(client, h, 'Old milk', quantity=0)
    async with app.state.db.system() as conn:
        await conn.execute("""WITH old AS (
            DELETE FROM inventory_observations WHERE inventory_item_id=$1 RETURNING *
        ) INSERT INTO inventory_observations (time,household_id,inventory_item_id,quantity,source,recorded_by)
          SELECT now()-interval '31 days',household_id,inventory_item_id,quantity,source,recorded_by FROM old""",
          UUID(stale['id']))
    await app.state.worker.drain()
    lines = [i for row in await lists(client, h) for i in row['items']]
    assert len(lines) == 1 and lines[0]['inventory_item_id'] == prior['id']
    assert 'Confidence: low' in lines[0]['explanation']


async def test_wishlist_rejection_and_snooze_are_respected(client, app):
    h, _, _ = await account(client)
    for action in ['reject', 'snooze']:
        stock = await item(client, h, f'{action} refill')
        suggested = await client.post('/v1/wishlist/suggestions', headers={**h, 'Idempotency-Key': uuid4().hex},
                                      json={'title': stock['display_name'], 'inventory_item_id': stock['id'],
                                            'rationale': 'Recorded stock is empty.', 'confidence': 0.9})
        assert suggested.status_code == 201, suggested.text
        response = await client.post(f"/v1/wishlist/{suggested.json()['id']}/{action}", headers=h,
                                      json={'days': 7} if action == 'snooze' else {'reason_code': 'not_interested'})
        assert response.status_code == 200, response.text
    await app.state.worker.drain()
    assert await lists(client, h) == []


async def test_full_lists_and_caps_do_not_break_background_jobs(client, app, monkeypatch):
    from app.routers import lists as list_routes
    h, user, household = await account(client)
    monkeypatch.setattr(list_routes, 'MAX_ITEMS_PER_LIST', 1)
    monkeypatch.setattr(list_routes, 'MAX_OPEN_LISTS', 2)
    for index in range(3):
        await item(client, h, f'Refill {index}')
    await app.state.worker.drain()
    result = await lists(client, h)
    assert len(result) == 2 and all(len(row['items']) == 1 for row in result)
    async with app.state.db.system() as conn:
        assert not await conn.fetchval("SELECT 1 FROM jobs WHERE kind='lists.replenish' AND status='failed' "
                                      "AND payload->>'household_id'=$1", str(household))
    # Capacity becomes available later: existing items remain unique and the remaining need is added.
    monkeypatch.setattr(list_routes, 'MAX_OPEN_LISTS', 3)
    await app.state.shopping.replenish_job({'household_id': str(household), 'user_id': str(user)}, 1)
    assert len([i for row in await lists(client, h) for i in row['items']]) == 3


async def test_new_store_and_stock_reconcile_but_manual_edits_are_preserved(client, app):
    h, _, _ = await account(client)
    stock = await item(client, h, 'Paper towels', par_level=3)
    await app.state.worker.drain()
    initial = (await lists(client, h))[0]
    market = await store(client, h, 'Saved market')
    response = await client.patch(f"/v1/inventory/{stock['id']}", headers=h, json={'preferred_merchant_id': market})
    assert response.status_code == 200
    await app.state.worker.drain()
    result = await lists(client, h)
    current = next(row for row in result if row['merchant'] and row['merchant']['id'] == market)
    assert current['items'][0]['quantity'] == 3
    assert next(row for row in result if row['id'] == initial['id'])['items'] == []
    await client.post(f"/v1/inventory/{stock['id']}/observations", headers=h, json={'quantity': 1})
    await app.state.worker.drain()
    current = next(row for row in await lists(client, h) if row['id'] == current['id'])
    assert current['items'][0]['quantity'] == 2
    await client.patch(f"/v1/lists/{current['id']}/items/{current['items'][0]['id']}", headers=h, json={'quantity': 9})
    await client.post(f"/v1/inventory/{stock['id']}/observations", headers=h, json={'quantity': 2})
    await app.state.worker.drain()
    current = next(row for row in await lists(client, h) if row['id'] == current['id'])
    assert current['items'][0]['quantity'] == 9
