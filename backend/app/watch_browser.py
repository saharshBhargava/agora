"""Last-resort device-browser evidence, separate from server-verified offers and alerts."""
import json
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit
from uuid import UUID, uuid4

from pydantic import Field, field_validator

from app.db import audit, notify
from app.demo_account import is_demo_user
from app.errors import Problem
from app.price_search import SearchError, domain_allowed, extract_offers, public_url
from app.schemas import Strict


class BrowserClaim(Strict):
    run_id: UUID
    criteria_version: int = Field(ge=1)


class BrowserPage(Strict):
    source_url: str = Field(max_length=2048)
    final_url: str = Field(max_length=2048)
    products: list[dict] = Field(default_factory=list, max_length=20)

    @field_validator('products')
    @classmethod
    def bounded_products(cls, value):
        if len(json.dumps(value).encode()) > 100_000:
            raise ValueError('Product evidence is too large.')
        return value


class BrowserResult(BrowserClaim):
    token: UUID
    outcome: str = Field(pattern=r'^(completed|unavailable|interaction_required|deferred)$')
    pages: list[BrowserPage] = Field(default_factory=list, max_length=5)


async def browser_status(conn, watch: dict, user_id: UUID):
    watch['browser_fallback'] = None
    if watch['status'] != 'active' or watch['simulation_disclosure']:
        return
    if await conn.fetchval('SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id=$1', user_id):
        return
    run = await conn.fetchrow('SELECT * FROM watch_runs WHERE watch_id=$1 ORDER BY created_at DESC,id DESC LIMIT 1',
                              watch['id'])
    if (not run or run['criteria_version'] != watch['criteria_version'] or run['status'] not in ('failed', 'succeeded')
            or not run['finished_at']):
        return
    state = run['browser_state']
    if state == 'claimed' and run['browser_expires_at'] and run['browser_expires_at'] < datetime.now(UTC):
        state = 'pending'
    if state != 'none':
        watch['browser_fallback'] = {'run_id': run['id'], 'status': state,
                                     'urls': run['browser_urls'] if state in ('pending', 'claimed') else []}
    if state == 'completed':
        for price in run['browser_prices']:
            try:
                age = datetime.now(UTC) - datetime.fromisoformat(price['observed_at'])
            except (KeyError, TypeError, ValueError):
                continue
            if timedelta(minutes=-1) <= age <= timedelta(minutes=30):
                watch['prices'].append({**price, 'is_current': True})
        watch['prices'].sort(key=lambda price: price['unit_price_cents'])


async def eligible_run(conn, watch, user_id, body):
    if await is_demo_user(conn, user_id):
        raise Problem(409, 'browser_demo_disabled', 'Demo checks never open external retailer pages.')
    if (watch['status'] != 'active' or watch['item_status'] != 'active' or not watch['confirmed_at']
            or watch['criteria_version'] != body.criteria_version):
        raise Problem(409, 'browser_check_stale', 'The watch changed. Refresh before continuing.')
    if await conn.fetchval('SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id=$1', user_id):
        raise Problem(409, 'agent_paused', 'Price checks are paused.')
    run = await conn.fetchrow('SELECT * FROM watch_runs WHERE watch_id=$1 '
                              'ORDER BY created_at DESC,id DESC LIMIT 1 FOR UPDATE',
                              watch['id'])
    if (not run or run['id'] != body.run_id or run['criteria_version'] != body.criteria_version
            or run['status'] not in ('failed', 'succeeded') or not run['finished_at']
            or run['browser_state'] not in ('pending', 'claimed')):
        raise Problem(409, 'browser_check_stale', 'Normal retailer checks must finish before browser fallback.')
    return run


async def claim_browser(conn, watch, user_id, body):
    run = await eligible_run(conn, watch, user_id, body)
    now = datetime.now(UTC)
    if run['browser_state'] == 'claimed' and run['browser_expires_at'] > now:
        raise Problem(409, 'browser_check_busy', 'Another device is checking these pages.')
    token, expires = uuid4(), now + timedelta(minutes=2)
    await conn.execute("UPDATE watch_runs SET browser_state='claimed',browser_token=$2,browser_user_id=$3,"
                       "browser_expires_at=$4 WHERE id=$1", run['id'], token, user_id, expires)
    await audit(conn, 'watch.browser_claimed', actor_id=user_id, household_id=watch['household_id'],
                target_type='watch', target_id=watch['id'], meta={'run_id': str(run['id'])})
    await notify(conn, watch['household_id'], 'watch.updated', watch['id'])
    return {'run_id': run['id'], 'token': token, 'expires_at': expires, 'urls': run['browser_urls']}


def browser_prices(criteria, pages, allowed_urls):
    from app.watch_ops import _words
    prices = {}
    for page in pages:
        try:
            source, final = public_url(page.source_url), public_url(page.final_url)
        except SearchError:
            raise Problem(422, 'invalid_browser_source', 'A public retailer source is required.') from None
        if (source not in allowed_urls or urlsplit(source).hostname != urlsplit(final).hostname
                or not domain_allowed(final, criteria.get('allowed_domains', []))):
            raise Problem(422, 'invalid_browser_source', 'Only retailer pages discovered by this check are accepted.')
        for offer in extract_offers(json.dumps(page.products), final, criteria):
            text = ' ' + _words(offer.title) + ' '
            required = criteria.get('required_terms', []) + _words(criteria['query']).split()
            if (not required or any(' '+_words(term)+' ' not in text for term in required)
                    or any(' '+_words(term)+' ' in text for term in criteria.get('excluded_terms', []))
                    or offer.currency != criteria.get('currency', 'USD') or not offer.eligibility_verified
                    or offer.membership_required or offer.subscription_required or offer.coupon_required
                    or any(marker in offer.evidence for marker in ('OutOfStock', 'Discontinued', 'SoldOut'))
                    or (offer.condition != 'unknown' and offer.condition != criteria.get('condition', 'new'))):
                continue
            # Device evidence is useful for comparison, but cannot create server-verified matches or push alerts.
            key = (offer.url, offer.title, offer.price_cents)
            prices[key] = {'id': str(uuid4()), 'title': offer.title, 'url': offer.url, 'merchant': offer.merchant,
                           'unit_price_cents': offer.price_cents, 'currency': offer.currency,
                           'observed_at': offer.observed_at.isoformat(), 'reason': 'browser_observed',
                           'provenance': 'device_browser',
                           'verification_note': 'Read in your browser. Confirm condition, availability '
                                                'and delivery with the retailer.'}
    return list(prices.values())[:20]


async def finish_browser(conn, watch, user_id, body):
    run = await eligible_run(conn, watch, user_id, body)
    if (run['browser_state'] != 'claimed' or run['browser_token'] != body.token
            or run['browser_user_id'] != user_id or run['browser_expires_at'] <= datetime.now(UTC)):
        raise Problem(409, 'browser_check_stale', 'This browser check is no longer current.')
    prices = browser_prices(watch['criteria'], body.pages, run['browser_urls'])
    state = 'completed' if prices else 'pending' if body.outcome == 'deferred' else 'unavailable'
    await conn.execute("UPDATE watch_runs SET browser_state=$2,browser_prices=$3,browser_token=NULL,"
                       "browser_expires_at=NULL,browser_user_id=NULL WHERE id=$1", run['id'], state, prices)
    if body.outcome == 'interaction_required' and not prices:
        urls = list(dict.fromkeys(run['interaction_urls'] + run['browser_urls']))[:5]
        await conn.execute('UPDATE watch_runs SET interaction_urls=$2 WHERE id=$1', run['id'], urls)
    await audit(conn, 'watch.browser_finished', actor_id=user_id, household_id=watch['household_id'],
                target_type='watch', target_id=watch['id'], meta={'run_id': str(run['id']), 'price_count': len(prices)})
    await notify(conn, watch['household_id'], 'watch.updated', watch['id'])
    return {'status': state, 'price_count': len(prices)}
