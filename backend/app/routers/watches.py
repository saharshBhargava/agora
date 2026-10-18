"""Wishlist-backed price research, explicit watch settings, and optional foreground browser evidence."""
from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse

from app import idempotency
from app.auth import CurrentUser, Principal
from app.db import audit, notify
from app.demo_account import is_demo_user
from app.errors import Problem, not_found
from app.routers.account import require_household
from app.watch_browser import BrowserClaim, BrowserResult, claim_browser, finish_browser
from app.watch_ops import MANUAL_COOLDOWN, load_watch, queue_check
from app.watch_schemas import WatchPatch, WatchPut
from app.wishlist_ops import lock_household

router = APIRouter(prefix='/v1', tags=['price watches'])


async def _browser_request(watch_id, body, request, user, operation, handler):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash(operation, watch_id, body.model_dump(mode='json'))
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, watch_id)
        if cached := await idempotency.lookup(conn, user.user_id, key, digest):
            return JSONResponse(cached)
        response = jsonable_encoder(await handler(conn, row, user.user_id, body))
        if not await idempotency.claim(conn, user.user_id, key, digest, 200, response):
            raise Problem(409, 'duplicate_request', 'Retry this request shortly.')
        return JSONResponse(response)


@router.post('/watches/{watch_id}/browser-claim')
async def browser_claim(watch_id: UUID, body: BrowserClaim, request: Request, user: Principal = CurrentUser):
    return await _browser_request(watch_id, body, request, user, 'watch.browser_claim', claim_browser)


@router.post('/watches/{watch_id}/browser-result')
async def browser_result(watch_id: UUID, body: BrowserResult, request: Request, user: Principal = CurrentUser):
    return await _browser_request(watch_id, body, request, user, 'watch.browser_result', finish_browser)


async def _capabilities(request, user_id):
    service = request.app.state.watches
    async with service.db.scoped(user_id) as conn:
        demo = await is_demo_user(conn, user_id)
    return demo or bool(getattr(service.provider, 'available', False)), (
        demo or bool(getattr(service.provider, 'discovery_available', False)))


async def _locked(conn, watch_id):
    household_id = await conn.fetchval('SELECT household_id FROM price_watches WHERE id=$1', watch_id)
    if household_id is None:
        raise not_found('watch')
    await lock_household(conn, household_id)
    row = await conn.fetchrow(
        '''SELECT p.*,w.status AS item_status FROM price_watches p JOIN wishlist_items w ON w.id=p.wishlist_item_id
           WHERE p.id=$1 FOR UPDATE OF p''', watch_id)
    if row is None:
        raise not_found('watch')
    return row


async def _check_budget(conn, household_id):
    count = await conn.fetchval(
        "SELECT count(*) FROM watch_runs WHERE household_id=$1 AND trigger IN ('manual','confirmed') "
        "AND created_at > now()-interval '1 hour'", household_id)
    if count >= 30:
        raise Problem(429, 'check_budget_exceeded', 'This household has reached its hourly price-check limit.')


async def _not_paused(conn, user_id):
    if await conn.fetchval('SELECT agent_paused_at IS NOT NULL FROM user_settings WHERE user_id=$1', user_id):
        raise Problem(409, 'agent_paused', 'Resume your agent before checking prices.')


def _require_active(row):
    if row['item_status'] != 'active':
        raise Problem(409, 'wishlist_inactive', 'Only active wishlist items can be watched.')
    if row['confirmed_at'] is None:
        raise Problem(409, 'confirmation_required', 'Review and confirm the current purchase criteria.')


@router.get('/watches')
async def list_watches(request: Request, household_id: UUID | None = None, user: Principal = CurrentUser):
    available, discovery = await _capabilities(request, user.user_id)
    async with request.app.state.db.scoped(user.user_id) as conn:
        household_id = await require_household(conn, household_id, user.user_id)
        rows = await conn.fetch('SELECT id FROM price_watches WHERE household_id=$1 ORDER BY created_at DESC LIMIT 100',
                                household_id)
        watches = [await load_watch(conn, r['id'], user.user_id, available=available,
                                    discovery_available=discovery) for r in rows]
        provider = request.app.state.watches.provider
        return {'watches': watches, 'automatic_watches': True,
                'search_available': available, 'discovery_available': discovery,
                'discovery_status': ('available' if discovery else
                                     getattr(provider, 'discovery_status', 'search_not_configured'))}


@router.get('/watches/{watch_id}')
async def get_watch(watch_id: UUID, request: Request, user: Principal = CurrentUser):
    available, discovery = await _capabilities(request, user.user_id)
    async with request.app.state.db.scoped(user.user_id) as conn:
        return await load_watch(conn, watch_id, user.user_id, available=available, discovery_available=discovery)


@router.put('/wishlist/{item_id}/watch')
async def put_watch(item_id: UUID, body: WatchPut, request: Request, user: Principal = CurrentUser):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash('watch.put', item_id, body.model_dump(mode='json'))
    available, discovery = await _capabilities(request, user.user_id)
    async with request.app.state.db.scoped(user.user_id) as conn:
        item = await conn.fetchrow('SELECT * FROM wishlist_items WHERE id=$1', item_id)
        if item is None:
            raise not_found('wishlist item')
        await lock_household(conn, item['household_id'])
        if cached := await idempotency.lookup(conn, user.user_id, key, digest):
            return JSONResponse(cached)
        item = await conn.fetchrow('SELECT * FROM wishlist_items WHERE id=$1 FOR UPDATE', item_id)
        if not body.confirmed:
            raise Problem(409, 'confirmation_required', 'Review and explicitly confirm the purchase criteria.')
        if item['status'] != 'active':
            raise Problem(409, 'wishlist_inactive', 'Accept the wishlist item before confirming a price watch.')
        await _not_paused(conn, user.user_id)
        if body.criteria.needed_by and body.criteria.needed_by < datetime.now(UTC).date():
            raise Problem(422, 'deadline_passed', 'The needed-by date must be today or later.')
        watch = await conn.fetchrow('SELECT * FROM price_watches WHERE wishlist_item_id=$1 FOR UPDATE', item_id)
        if not watch or watch['status'] != 'active':
            count = await conn.fetchval(
                "SELECT count(*) FROM price_watches WHERE household_id=$1 AND status='active'", item['household_id'])
            maximum = getattr(request.app.state.settings, 'watch_max_active', 25)
            if count >= maximum:
                raise Problem(409, 'watch_limit_reached', 'Pause another watch before activating this one.')
        criteria = body.criteria.model_dump(mode='json')
        changed = not watch or watch['criteria'] != criteria or watch['confirmed_at'] is None
        needs_check = changed or watch['status'] != 'active'
        if needs_check:
            await _check_budget(conn, item['household_id'])
        if watch and changed:
            await conn.execute(
                '''UPDATE watch_runs SET status='skipped',finished_at=now(),error_code='criteria_changed'
                   WHERE watch_id=$1 AND status IN ('queued','running')''', watch['id'])
        if watch is None:
            watch = await conn.fetchrow(
                '''INSERT INTO price_watches(household_id,wishlist_item_id,created_by,criteria,confirmed_at)
                   VALUES($1,$2,$3,$4,now()) RETURNING *''', item['household_id'], item_id, user.user_id, criteria)
        else:
            watch = await conn.fetchrow(
                '''UPDATE price_watches SET criteria=$2,criteria_version=criteria_version+$3,status='active',
                   created_by=$4,confirmed_at=now(),updated_at=now(),next_check_at=now(),
                   last_error=NULL,last_result=CASE WHEN $3>0 THEN 'pending' ELSE last_result END
                   WHERE id=$1 RETURNING *''', watch['id'], criteria, int(changed), user.user_id)
        if body.subscription is not None:
            sub = body.subscription
            await conn.execute(
                '''INSERT INTO watch_subscriptions(watch_id,household_id,user_id,push_enabled,quiet_start_hour,
                   quiet_end_hour,timezone,daily_cap,cooldown_hours) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
                   ON CONFLICT(watch_id,user_id) DO UPDATE SET push_enabled=EXCLUDED.push_enabled,
                   quiet_start_hour=EXCLUDED.quiet_start_hour,quiet_end_hour=EXCLUDED.quiet_end_hour,
                   timezone=EXCLUDED.timezone,daily_cap=EXCLUDED.daily_cap,cooldown_hours=EXCLUDED.cooldown_hours,
                   updated_at=now()''', watch['id'], watch['household_id'], user.user_id, sub.push_enabled,
                sub.quiet_start_hour, sub.quiet_end_hour, sub.timezone, sub.daily_cap, sub.cooldown_hours)
        else:
            await conn.execute(
                '''INSERT INTO watch_subscriptions(watch_id,household_id,user_id) VALUES($1,$2,$3)
                   ON CONFLICT DO NOTHING''', watch['id'], watch['household_id'], user.user_id)
        if needs_check:
            await queue_check(conn, watch, user.user_id, 'confirmed',
                              daily_cap=getattr(request.app.state.settings, 'watch_daily_check_cap', 200))
        await audit(conn, 'watch.confirmed', actor_id=user.user_id, household_id=watch['household_id'],
                    target_type='watch', target_id=watch['id'], meta={'criteria_version': watch['criteria_version']})
        await notify(conn, watch['household_id'], 'watch.updated', watch['id'])
        response = jsonable_encoder(await load_watch(
            conn, watch['id'], user.user_id, available=available, discovery_available=discovery))
        if not await idempotency.claim(conn, user.user_id, key, digest, 200, response):
            raise Problem(409, 'duplicate_request', 'This request is already being processed; retry shortly.')
        return JSONResponse(response)


@router.patch('/watches/{watch_id}')
async def patch_watch(watch_id: UUID, body: WatchPatch, request: Request, user: Principal = CurrentUser):
    available, discovery = await _capabilities(request, user.user_id)
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, watch_id)
        if body.status == 'active':
            _require_active(row)
            await _not_paused(conn, user.user_id)
            await lock_household(conn, row['household_id'])
            maximum = getattr(request.app.state.settings, 'watch_max_active', 25)
            count = await conn.fetchval(
                "SELECT count(*) FROM price_watches WHERE household_id=$1 AND status='active' AND id<>$2",
                row['household_id'], watch_id)
            if count >= maximum:
                raise Problem(409, 'watch_limit_reached', 'Pause another watch before activating this one.')
        updated = await conn.fetchrow(
            'UPDATE price_watches SET status=$2,updated_at=now(),next_check_at=now() WHERE id=$1 RETURNING *',
            watch_id, body.status)
        if body.status == 'active' and row['status'] != 'active':
            await _check_budget(conn, row['household_id'])
            await queue_check(conn, updated, user.user_id, 'confirmed',
                              daily_cap=getattr(request.app.state.settings, 'watch_daily_check_cap', 200))
        if body.status == 'paused':
            await conn.execute(
                '''UPDATE watch_runs SET status='skipped',finished_at=now(),error_code='watch_paused'
                   WHERE watch_id=$1 AND status IN ('queued','running')''', watch_id)
        await audit(conn, 'watch.' + body.status, actor_id=user.user_id, household_id=row['household_id'],
                    target_type='watch', target_id=watch_id)
        await notify(conn, row['household_id'], 'watch.updated', watch_id)
        return await load_watch(conn, watch_id, user.user_id, available=available, discovery_available=discovery)


@router.post('/watches/{watch_id}/check', status_code=202)
async def check_watch(watch_id: UUID, request: Request, user: Principal = CurrentUser):
    key = idempotency.key_from(request)
    digest = idempotency.request_hash('watch.check', watch_id)
    async with request.app.state.db.scoped(user.user_id) as conn:
        row = await _locked(conn, watch_id)
        if cached := await idempotency.lookup(conn, user.user_id, key, digest):
            return JSONResponse(cached, status_code=202)
        _require_active(row)
        if row['status'] != 'active':
            raise Problem(409, 'watch_inactive', 'Resume this price watch before checking.')
        await _not_paused(conn, user.user_id)
        now = datetime.now(UTC)
        if row['last_manual_at'] and now-row['last_manual_at'] < MANUAL_COOLDOWN:
            raise Problem(429, 'check_cooldown', 'Wait five minutes before checking this watch again.')
        await _check_budget(conn, row['household_id'])
        response = jsonable_encoder(await queue_check(
            conn, row, user.user_id, 'manual',
            daily_cap=getattr(request.app.state.settings, 'watch_daily_check_cap', 200)))
        await conn.execute('UPDATE price_watches SET last_manual_at=$2 WHERE id=$1', watch_id, now)
        await audit(conn, 'watch.check_requested', actor_id=user.user_id, household_id=row['household_id'],
                    target_type='watch', target_id=watch_id)
        await notify(conn, row['household_id'], 'watch.updated', watch_id)
        if not await idempotency.claim(conn, user.user_id, key, digest, 202, response):
            raise Problem(409, 'duplicate_request', 'This request is already being processed; retry shortly.')
        return JSONResponse(response, status_code=202)
