"""Price watches: deterministic eligibility, scoped persistence, races and durable alert deduplication."""
import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.price_search import Offer, SearchResult
from app.watch_ops import evaluate
from app.watch_schemas import WatchCriteria
from tests.conftest import login


def criteria(**changes):
    return WatchCriteria(query='Lodge 12 inch cast iron skillet', required_terms=['Lodge', '12 inch', 'skillet'],
                         excluded_terms=['lid only'], fulfillment='delivery', location='US', target_price_cents=4000,
                         **changes).model_dump(mode='json')


def offer(**changes):
    values = dict(url='https://www.lodgecastiron.com/skillet', title='Lodge 12 inch cast iron skillet',
                  merchant='Lodge', price_cents=2999, available=True, available_quantity=10, condition='new',
                  fulfillment='delivery', location='US', observed_at=datetime.now(UTC),
                  shipping_cents=0, tax_cents=300, fees_cents=0, evidence='Source page: in stock, $29.99.')
    return Offer(**(values | changes))


@pytest.mark.parametrize(('changes', 'reason'), [
    ({'price_cents': 4999}, 'above_target'),
    ({'available': False}, 'out_of_stock'),
    ({'title': 'Lodge 12 inch cast iron skillet lid only'}, 'excluded_term'),
    ({'title': 'Generic frying pan'}, 'required_terms_missing'),
    ({'condition': 'used'}, 'condition_mismatch'),
    ({'location': ''}, 'fulfillment_unverified'),
    ({'currency': 'CAD'}, 'currency_mismatch'),
    ({'membership_required': True}, 'unconfirmed_eligibility'),
    ({'subscription_required': True}, 'unconfirmed_eligibility'),
    ({'coupon_required': True}, 'unconfirmed_eligibility'),
    ({'evidence': ''}, 'missing_evidence'),
    ({'observed_at': datetime.now(UTC)-timedelta(hours=1)}, 'stale_observation'),
])
def test_deterministic_eligibility(changes, reason):
    result = evaluate(criteria(), offer(**changes))
    assert not result['eligible'] and result['reason'] == reason


def test_pack_quantity_all_in_caps_and_deadline():
    c = criteria(quantity=4, max_total_cents=6500)
    result = evaluate(c, offer(price_cents=3000, pack_quantity=2))
    assert result['eligible'] and result['unit_price_cents'] == 1500 and result['total_price_cents'] == 6300
    assert not evaluate(criteria(quantity=3), offer(pack_quantity=2))['eligible']
    assert not evaluate(c, offer(price_cents=3000, pack_quantity=2, tax_cents=None))['eligible']
    assert not evaluate(c, offer(price_cents=3000, pack_quantity=2, available_quantity=1))['eligible']
    assert not evaluate(c, offer(price_cents=3000, pack_quantity=2, available_quantity=None))['eligible']
    assert not evaluate(criteria(needed_by=datetime.now(UTC).date()), offer())['eligible']
    assert evaluate(criteria(needed_by=datetime.now(UTC).date()), offer(arrives_by=datetime.now(UTC)))['eligible']


async def new_watch(client, handle='watcher', *, subscription=None, title='Cast iron skillet'):
    headers = await login(client, handle)
    me = (await client.get('/v1/me', headers=headers)).json()
    item = await client.post('/v1/wishlist', headers=headers,
                             json={'household_id': me['households'][0]['id'], 'title': title})
    assert item.status_code == 201, item.text
    body = {'confirmed': True, 'criteria': criteria()}
    if subscription:
        body['subscription'] = subscription
    response = await client.put(f"/v1/wishlist/{item.json()['id']}/watch", json=body,
                                headers=headers | {'Idempotency-Key': uuid4().hex})
    assert response.status_code == 200, response.text
    return headers, me, item.json(), response.json()


async def run_watch(app, watch):
    run = watch['runs'][0]
    async with app.state.db.system() as conn:
        user_id = await conn.fetchval('SELECT user_id FROM watch_runs WHERE id=$1', UUID(run['id']))
    await app.state.watches.check_job({'watch_id': watch['id'], 'run_id': run['id'], 'user_id': str(user_id)}, 3)


async def test_confirmation_idempotency_and_household_rls(client, app):
    headers, me, item, watch = await new_watch(client, 'watchlifecycle')
    key = uuid4().hex
    body = {'confirmed': True, 'criteria': criteria()}
    url = f"/v1/wishlist/{item['id']}/watch"
    a, b = await asyncio.gather(*(client.put(url, json=body, headers=headers | {'Idempotency-Key': key})
                                  for _ in range(2)))
    assert a.status_code == b.status_code == 200 and a.json() == b.json()
    bad = await client.put(url, json=body | {'confirmed': False}, headers=headers | {'Idempotency-Key': uuid4().hex})
    assert bad.status_code == 409 and bad.json()['title'] == 'confirmation_required'
    reused = await client.put(url, json=body | {'confirmed': False}, headers=headers | {'Idempotency-Key': key})
    assert reused.status_code == 422
    stranger = await login(client, 'watchstranger')
    assert (await client.get(f"/v1/watches/{watch['id']}", headers=stranger)).status_code == 404
    stranger_me = (await client.get('/v1/me', headers=stranger)).json()
    async with app.state.db.scoped(UUID(stranger_me['id'])) as conn:
        assert not await conn.fetchval('SELECT 1 FROM price_watches WHERE id=$1', UUID(watch['id']))
        assert not await conn.fetchval('SELECT 1 FROM watch_runs WHERE watch_id=$1', UUID(watch['id']))
        assert not await conn.fetchval('SELECT 1 FROM watch_subscriptions WHERE watch_id=$1', UUID(watch['id']))


async def test_source_checks_match_inbox_outbox_and_dedupe(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchmatch', subscription={'push_enabled': True})
    calls = []

    async def search(c, urls):
        calls.append(c)
        return SearchResult(offers=[offer(), offer(price_cents=5000)], checked_count=2)

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await run_watch(app, watch)
    current = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert current['last_result'] == 'matched' and current['last_successful_at']
    assert current['runs'][0]['offer_count'] == 2 and current['runs'][0]['match_count'] == 1
    assert len(current['matches']) == 1 and current['matches'][0]['unit_price_cents'] == 2999
    async with app.state.db.scoped(UUID(me['id'])) as conn:
        assert await conn.fetchval('SELECT count(*) FROM notifications WHERE watch_id=$1', UUID(watch['id'])) == 1
        assert await conn.fetchval('SELECT count(*) FROM notification_outbox WHERE user_id=$1', UUID(me['id'])) == 1
    key = uuid4().hex
    checked = await client.post(f"/v1/watches/{watch['id']}/check", headers=headers | {'Idempotency-Key': key})
    assert checked.status_code == 202
    retry = await client.post(f"/v1/watches/{watch['id']}/check", headers=headers | {'Idempotency-Key': key})
    assert retry.json() == checked.json()
    assert (await client.post(f"/v1/watches/{watch['id']}/check",
                              headers=headers | {'Idempotency-Key': uuid4().hex})).status_code == 429
    current = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    await run_watch(app, current)
    async with app.state.db.scoped(UUID(me['id'])) as conn:
        assert await conn.fetchval('SELECT count(*) FROM watch_matches WHERE watch_id=$1', UUID(watch['id'])) == 1
        assert await conn.fetchval('SELECT count(*) FROM notifications WHERE watch_id=$1', UUID(watch['id'])) == 1
    assert len(calls) == 2


async def test_parent_edits_and_pause_invalidate_inflight_result(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchrace')
    entered, release = asyncio.Event(), asyncio.Event()

    async def search(c, urls):
        entered.set()
        await release.wait()
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    task = asyncio.create_task(run_watch(app, watch))
    await entered.wait()
    edited = await client.patch(f"/v1/wishlist/{item['id']}", headers=headers, json={'quantity': 2})
    assert edited.status_code == 200, edited.text
    release.set()
    await task
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['status'] == 'paused' and result['confirmed_at'] is None
    assert result['criteria_version'] > watch['criteria_version'] and not result['matches']
    assert result['runs'][0]['status'] == 'skipped'
    resumed = await client.patch(f"/v1/watches/{watch['id']}", headers=headers, json={'status': 'active'})
    assert resumed.status_code == 409 and resumed.json()['title'] == 'confirmation_required'
    async with app.state.db.scoped(UUID(me['id'])) as conn:
        assert not await conn.fetchval('SELECT 1 FROM notifications WHERE watch_id=$1', UUID(watch['id']))


async def test_provider_failure_is_distinct_from_no_match(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchfailure')

    async def failed(c, urls):
        return SearchResult(errors=['source_unavailable'])

    monkeypatch.setattr(app.state.watches.provider, 'search', failed)
    await run_watch(app, watch)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['last_result'] == 'failed' and result['last_successful_at'] is None
    assert result['last_checked_at'] and result['last_error'] == 'search_unavailable'

    async def no_match(c, urls):
        return SearchResult(offers=[offer(price_cents=5000)], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', no_match)
    checked = await client.post(f"/v1/watches/{watch['id']}/check",
                                headers=headers | {'Idempotency-Key': uuid4().hex})
    assert checked.status_code == 202
    watch = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    await run_watch(app, watch)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['last_result'] == 'no_match' and result['last_error'] is None and result['last_successful_at']


async def test_six_hour_sweep_coalesces_and_skips_agent_pause(client, app):
    headers, me, item, watch = await new_watch(client, 'watchsweep')
    await app.state.watches.sweep({}, 1)
    await app.state.watches.sweep({}, 1)
    async with app.state.db.system() as conn:
        assert await conn.fetchval("SELECT count(*) FROM watch_runs WHERE watch_id=$1 AND status='queued'",
                                   UUID(watch['id'])) == 1
        assert await conn.fetchval("SELECT count(*) FROM jobs WHERE kind='watch.sweep' AND status='queued'") == 1
    paused = await client.post('/v1/agent/pause', headers=headers, json={})
    assert paused.status_code == 200, paused.text
    await run_watch(app, watch)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['runs'][0]['status'] == 'skipped' and not result['matches']


async def test_subscription_only_reconfirmation_does_not_spend_another_check(client, app):
    headers, me, item, watch = await new_watch(client, 'watchsame')
    for _ in range(3):
        response = await client.put(f"/v1/wishlist/{item['id']}/watch",
                                    headers=headers | {'Idempotency-Key': uuid4().hex},
                                    json={'confirmed': True, 'criteria': criteria(),
                                          'subscription': {'push_enabled': True}})
        assert response.status_code == 200
        assert response.json()['criteria_version'] == watch['criteria_version']
    async with app.state.db.system() as conn:
        assert await conn.fetchval('SELECT count(*) FROM watch_runs WHERE watch_id=$1', UUID(watch['id'])) == 1
    await client.patch(f"/v1/watches/{watch['id']}", headers=headers, json={'status': 'paused'})
    resumed = await client.patch(f"/v1/watches/{watch['id']}", headers=headers, json={'status': 'active'})
    assert resumed.status_code == 200 and resumed.json()['runs'][0]['status'] == 'queued'


async def test_retry_run_and_execution_generation_prevent_duplicate_network(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchretry')
    run_id = watch['runs'][0]['id']
    payload = {'watch_id': watch['id'], 'run_id': run_id, 'user_id': me['id']}
    calls = 0

    async def failed(c, urls):
        nonlocal calls
        calls += 1
        return SearchResult(errors=['temporary_failure'])

    monkeypatch.setattr(app.state.watches.provider, 'search', failed)
    with pytest.raises(RuntimeError, match='search_unavailable'):
        await app.state.watches.check_job(payload, 1)
    entered, release = asyncio.Event(), asyncio.Event()

    async def recovered(c, urls):
        nonlocal calls
        calls += 1
        entered.set()
        await release.wait()
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', recovered)
    task = asyncio.create_task(app.state.watches.check_job(payload, 2))
    await entered.wait()
    await app.state.watches.check_job(payload, 2)
    release.set()
    await task
    response = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert calls == 2 and response['runs'][0]['status'] == 'succeeded'
    assert response['runs'][0]['error_code'] is None and response['last_error'] is None


async def test_household_check_budget_is_enforced_for_changed_criteria(client, app):
    headers, me, item, watch = await new_watch(client, 'watchbudget')
    async with app.state.db.system() as conn:
        await conn.execute(
            '''INSERT INTO watch_runs(household_id,watch_id,user_id,criteria_version,status,trigger)
               SELECT $1,$2,$3,1,'skipped','manual' FROM generate_series(1,29)''',
            UUID(watch['household_id']), UUID(watch['id']), UUID(me['id']))
    response = await client.put(f"/v1/wishlist/{item['id']}/watch", headers=headers | {'Idempotency-Key': uuid4().hex},
                                json={'confirmed': True, 'criteria': criteria(quantity=2)})
    assert response.status_code == 429 and response.json()['title'] == 'check_budget_exceeded'


async def test_out_of_stock_then_restock_alerts_after_cooldown(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchrestock')
    stock = True

    async def search(c, urls):
        return SearchResult(offers=[offer(available=stock)], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await run_watch(app, watch)
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE notifications SET created_at=now()-interval '2 days' WHERE watch_id=$1",
                           UUID(watch['id']))
    stock = False
    checked = await client.post(f"/v1/watches/{watch['id']}/check",
                                headers=headers | {'Idempotency-Key': uuid4().hex})
    assert checked.status_code == 202
    await run_watch(app, (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json())
    stock = True
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE price_watches SET last_manual_at=now()-interval '1 hour' WHERE id=$1",
                           UUID(watch['id']))
    checked = await client.post(f"/v1/watches/{watch['id']}/check",
                                headers=headers | {'Idempotency-Key': uuid4().hex})
    assert checked.status_code == 202
    await run_watch(app, (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json())
    async with app.state.db.system() as conn:
        assert await conn.fetchval('SELECT count(*) FROM notifications WHERE watch_id=$1', UUID(watch['id'])) == 2


async def test_removing_membership_during_network_suppresses_result(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchmembergone')
    entered, release = asyncio.Event(), asyncio.Event()

    async def search(c, urls):
        entered.set()
        await release.wait()
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    task = asyncio.create_task(run_watch(app, watch))
    await entered.wait()
    async with app.state.db.system() as conn:
        await conn.execute('DELETE FROM household_members WHERE household_id=$1 AND user_id=$2',
                           UUID(watch['household_id']), UUID(me['id']))
    release.set()
    await task
    async with app.state.db.system() as conn:
        assert not await conn.fetchval('SELECT 1 FROM watch_matches WHERE watch_id=$1', UUID(watch['id']))
        assert await conn.fetchval('SELECT status FROM watch_runs WHERE watch_id=$1', UUID(watch['id'])) == 'skipped'


async def test_wishlist_purchased_completes_watch_and_deadline_expires(client, app):
    headers, me, item, watch = await new_watch(client, 'watchcomplete')
    response = await client.post(f"/v1/wishlist/{item['id']}/purchased", headers=headers, json={})
    assert response.status_code == 200, response.text
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['status'] == 'completed' and result['confirmed_at'] is None
    headers, me, item, watch = await new_watch(client, 'watchexpired')
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE price_watches SET criteria=jsonb_set(criteria,'{needed_by}',to_jsonb((current_date-1)::text)) "
            "WHERE id=$1", UUID(watch['id']))
    await app.state.watches.sweep({}, 1)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['status'] == 'expired'


def test_identity_and_numeric_terms_use_whole_words():
    assert not evaluate(criteria(), offer(title='Lodge 120 inch cast iron skillet'))['eligible']
    c = criteria()
    c['required_terms'] = ['black']
    assert not evaluate(c, offer(title='Black patio chair'))['eligible']
    c['query'] = 'milk'
    c['required_terms'] = []
    assert not evaluate(c, offer(title='Vanilla milkshake'))['eligible']


async def test_global_alert_cap_serializes_concurrent_watches(client, app, monkeypatch):
    headers, me, item, first = await new_watch(client, 'watchglobalcap')
    _, _, _, second = await new_watch(client, 'watchglobalcap', title='Camping skillet')
    monkeypatch.setattr(app.state.settings, 'watch_daily_alert_cap', 1)

    async def search(c, urls):
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await asyncio.gather(run_watch(app, first), run_watch(app, second))
    async with app.state.db.system() as conn:
        assert await conn.fetchval('SELECT count(*) FROM notifications WHERE user_id=$1', UUID(me['id'])) == 1
        assert await conn.fetchval('SELECT count(*) FROM watch_matches WHERE household_id=$1',
                                   UUID(first['household_id'])) == 2


async def test_old_matching_offer_is_history_after_newer_out_of_stock_source(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchhistory')

    async def stocked(c, urls):
        return SearchResult(offers=[offer()], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', stocked)
    await run_watch(app, watch)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['matches'][0]['is_current']

    async def empty(c, urls):
        return SearchResult(offers=[offer(available=False)], checked_count=1)

    monkeypatch.setattr(app.state.watches.provider, 'search', empty)
    await client.post(f"/v1/watches/{watch['id']}/check", headers=headers | {'Idempotency-Key': uuid4().hex})
    await run_watch(app, (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json())
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['last_result'] == 'no_match' and not result['matches'][0]['is_current']
    assert result['rejection_reasons'] == ['out_of_stock']


async def test_background_and_manual_checks_share_reserved_daily_budget(client, app, monkeypatch):
    headers, me, item, watch = await new_watch(client, 'watchdailybudget')
    monkeypatch.setattr(app.state.settings, 'watch_daily_check_cap', 6)
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE watch_runs SET status='succeeded',finished_at=now() WHERE watch_id=$1",
                           UUID(watch['id']))
        await conn.execute(
            '''INSERT INTO watch_runs(household_id,watch_id,user_id,criteria_version,status,trigger)
               VALUES($1,$2,$3,1,'failed','scheduled')''',
            UUID(watch['household_id']), UUID(watch['id']), UUID(me['id']))
        await conn.execute("UPDATE price_watches SET next_check_at=now()-interval '1 hour' WHERE id=$1",
                           UUID(watch['id']))
    await app.state.watches.sweep({}, 1)
    result = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert result['last_error'] == 'check_budget_exhausted' and result['last_result'] == 'skipped'
    assert len(result['runs']) == 2
    checked = await client.post(f"/v1/watches/{watch['id']}/check",
                                headers=headers | {'Idempotency-Key': uuid4().hex})
    assert checked.status_code == 429 and checked.json()['title'] == 'check_budget_exhausted'


@pytest.mark.parametrize(('query', 'wrong', 'correct'), [
    ('Lodge 8 inch skillet', 'Lodge 9 inch skillet', 'Lodge 8 inch skillet'),
    ('Vitamin D supplement', 'Vitamin C supplement', 'Vitamin D supplement'),
    ('Grade A eggs', 'Grade B eggs', 'Grade A eggs'),
])
def test_single_character_product_and_size_tokens_remain_required(query, wrong, correct):
    c = criteria()
    c['query'], c['required_terms'] = query, []
    assert evaluate(c, offer(title=wrong))['reason'] == 'required_terms_missing'
    assert evaluate(c, offer(title=correct))['eligible']


@pytest.mark.parametrize('changes', [
    {'query': '!!!'}, {'location': '...'}, {'required_terms': ['!!!']},
    {'excluded_terms': ['   ']}, {'allowed_domains': ['shop..example.com']},
    {'product_url': 'https://127.0.0.1/private'}, {'product_url': 'https://name:secret@example.com'},
])
def test_confirmation_rejects_unmatchable_criteria_and_unsafe_links(changes):
    with pytest.raises(ValueError):
        WatchCriteria.model_validate(criteria() | changes)


async def test_later_eligible_source_is_not_crowded_out_by_unrelated_variants(client, app, monkeypatch):
    headers, _, _, watch = await new_watch(client, 'latersource')
    async def search(c, urls):
        unrelated = [offer(url=f'https://retailer.example/variant/{i}', title='Wrong product') for i in range(25)]
        return SearchResult(offers=[*unrelated, offer()], checked_count=2)
    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await run_watch(app, watch)
    current = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert current['last_result'] == 'matched' and current['runs'][0]['offer_count'] == 20
    assert current['matches'][0]['is_current'] and current['matches'][0]['unit_price_cents'] == 2999


async def test_interactive_source_is_a_handoff_not_a_verified_match_or_retry(client, app, monkeypatch):
    headers, me, _, watch = await new_watch(client, 'interactionneeded')
    url = 'https://retailer.example/select-size'
    async def search(c, urls):
        return SearchResult(checked_count=1, errors=['interaction_required'], interaction_urls=[url])
    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await app.state.watches.check_job({'watch_id': watch['id'], 'run_id': watch['runs'][0]['id'],
                                     'user_id': me['id']}, 1)
    current = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert current['last_error'] == 'interaction_required' and not current['matches']
    assert current['runs'][0]['interaction_urls'] == [url]
    assert not (await client.get('/v1/notifications', headers=headers)).json()


async def test_published_expiry_within_freshness_window_moves_match_to_history(client, app, monkeypatch):
    headers, _, _, watch = await new_watch(client, 'shortexpiry')
    async def search(c, urls):
        return SearchResult(offers=[offer(valid_until=datetime.now(UTC)+timedelta(minutes=1))], checked_count=1)
    monkeypatch.setattr(app.state.watches.provider, 'search', search)
    await run_watch(app, watch)
    before = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert before['matches'][0]['is_current']
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE watch_observations SET offer=jsonb_set(offer,'{valid_until}',"
                           "to_jsonb((now()-interval '1 second')::text)) WHERE watch_id=$1", UUID(watch['id']))
    after = (await client.get(f"/v1/watches/{watch['id']}", headers=headers)).json()
    assert not after['matches'][0]['is_current']
