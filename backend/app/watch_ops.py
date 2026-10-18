"""Durable, six-hour price checks with deterministic eligibility and atomic alert creation."""
import asyncio
import hashlib
import json
import math
import re
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import asyncpg

from app.db import Database, audit, notify
from app.demo_account import is_demo_user
from app.errors import Problem, not_found
from app.jobs import enqueue
from app.price_search import Offer, SearchResult
from app.shopping import next_refresh
from app.watch_schemas import WatchCriteria, WatchSubscription
from app.wishlist_ops import lock_household

FRESHNESS = timedelta(minutes=30)
CHECK_TIMEOUT = 180
MANUAL_COOLDOWN = timedelta(minutes=5)


def _words(text: str) -> str:
    return ' '.join(re.findall(r'\w+', text.casefold()))


def evaluate(criteria: dict, offer: Offer, now: datetime | None = None) -> dict:
    """Never use a provider/model 'match' flag: every requirement is checked here."""
    now = now or datetime.now(UTC)
    c = WatchCriteria.model_validate(criteria)
    reason = None
    text = _words(offer.title)
    required = c.required_terms + _words(c.query).split()
    def contains(term: str) -> bool:
        return ' '+_words(term)+' ' in ' '+text+' '

    if any(not contains(t) for t in required):
        reason = 'required_terms_missing'
    elif any(contains(t) for t in c.excluded_terms):
        reason = 'excluded_term'
    url = urlsplit(offer.url)
    domain = (url.hostname or '').lower().removeprefix('www.')
    if url.scheme != 'https' or not domain or url.username or url.password:
        reason = reason or 'invalid_product_url'
    if c.allowed_domains and not any(domain == d or domain.endswith('.' + d) for d in c.allowed_domains):
        reason = reason or 'merchant_not_allowed'
    if not offer.evidence.strip():
        reason = reason or 'missing_evidence'
    if offer.observed_at.tzinfo is None or offer.observed_at > now + timedelta(minutes=1):
        reason = reason or 'invalid_observation_time'
    elif now - offer.observed_at > FRESHNESS:
        reason = reason or 'stale_observation'
    if offer.valid_until and (offer.valid_until.tzinfo is None or offer.valid_until <= now):
        reason = reason or 'expired_offer'
    if not offer.available:
        reason = reason or 'out_of_stock'
    if offer.currency != c.currency:
        reason = reason or 'currency_mismatch'
    if offer.condition != c.condition:
        reason = reason or 'condition_mismatch'
    if offer.fulfillment != c.fulfillment or _words(offer.location) != _words(c.location):
        reason = reason or 'fulfillment_unverified'
    if (not offer.eligibility_verified or (offer.membership_required and not c.allow_membership)
            or offer.subscription_required or offer.coupon_required):
        reason = reason or 'unconfirmed_eligibility'
    if c.needed_by:
        if not offer.arrives_by or offer.arrives_by.tzinfo is None or offer.arrives_by.date() > c.needed_by:
            reason = reason or 'arrival_unverified'
    packs = math.ceil(c.quantity / offer.pack_quantity)
    if c.quantity % offer.pack_quantity:
        reason = reason or 'pack_quantity_mismatch'
    if offer.available_quantity is not None and offer.available_quantity < packs:
        reason = reason or 'insufficient_stock'
    # Unknown quantity is safe for one available listing, but cannot establish multiple-pack stock.
    if packs > 1 and offer.available_quantity is None:
        reason = reason or 'quantity_unverified'
    unit = math.ceil(offer.price_cents / offer.pack_quantity)
    total = None
    if all(cost is not None for cost in (offer.shipping_cents, offer.tax_cents, offer.fees_cents)):
        total = offer.price_cents * packs + offer.shipping_cents + offer.tax_cents + offer.fees_cents
    if unit > c.target_price_cents:
        reason = reason or 'above_target'
    if c.max_total_cents is not None and (total is None or total > c.max_total_cents):
        reason = reason or ('total_unknown' if total is None else 'above_total_cap')
    return {'eligible': reason is None, 'reason': reason or 'confirmed_criteria_met',
            'unit_price_cents': unit, 'total_price_cents': total, 'quantity': c.quantity}


async def load_watch(conn: asyncpg.Connection, watch_id: UUID, user_id: UUID, *, available: bool,
                     discovery_available: bool = True) -> dict:
    row = await conn.fetchrow(
        'SELECT p.*,w.title FROM price_watches p JOIN wishlist_items w ON w.id=p.wishlist_item_id WHERE p.id=$1',
        watch_id)
    if row is None:
        raise not_found('watch')
    result = dict(row)
    result['subscription'] = await conn.fetchrow(
        'SELECT * FROM watch_subscriptions WHERE watch_id=$1 AND user_id=$2', watch_id, user_id)
    result['subscription'] = (
        {k: result['subscription'][k] for k in WatchSubscription.model_fields}
        if result['subscription'] else None)
    known_url = await conn.fetchval('SELECT 1 FROM watch_listings WHERE watch_id=$1 LIMIT 1', watch_id)
    result['search_available'] = available and bool(row['criteria'].get('product_url')
                                                   or known_url or discovery_available)
    matches = await conn.fetch(
        '''SELECT m.id,m.watch_id,m.criteria_version,m.title,m.url,m.merchant,m.unit_price_cents,m.total_price_cents,
                  m.currency,m.quantity,m.shipping_cents,m.tax_cents,m.fulfillment,m.location,m.condition,
                  m.observed_at,m.matched_at,m.evidence,m.reason,
                  (p.status='active' AND latest.id=m.observation_id AND latest.eligible
                   AND latest.observed_at>=now()-interval '30 minutes'
                   AND (latest.offer->>'valid_until' IS NULL
                        OR (latest.offer->>'valid_until')::timestamptz>now())) AS is_current
           FROM watch_matches m JOIN price_watches p ON p.id=m.watch_id
           JOIN watch_observations original ON original.id=m.observation_id
           JOIN LATERAL (SELECT id,eligible,observed_at,offer FROM watch_observations
                         WHERE listing_id=original.listing_id ORDER BY observed_at DESC,id DESC LIMIT 1) latest ON true
           WHERE m.watch_id=$1 AND m.criteria_version=$2 ORDER BY m.matched_at DESC LIMIT 10''',
        watch_id, row['criteria_version'])
    runs = await conn.fetch(
        '''SELECT id,watch_id,criteria_version,status,trigger,created_at,started_at,finished_at,offer_count,
                  match_count,error_code,interaction_urls FROM watch_runs
           WHERE watch_id=$1 ORDER BY created_at DESC LIMIT 5''',
        watch_id)
    result['matches'], result['runs'] = [dict(r) for r in matches], [dict(r) for r in runs]
    rejected = await conn.fetch(
        '''SELECT DISTINCT reason FROM watch_observations WHERE watch_id=$1 AND criteria_version=$2
           AND NOT eligible AND run_id=(SELECT id FROM watch_runs WHERE watch_id=$1 AND criteria_version=$2
             AND status='succeeded' ORDER BY created_at DESC LIMIT 1) ORDER BY reason LIMIT 10''',
        watch_id, row['criteria_version'])
    result['rejection_reasons'] = [r['reason'] for r in rejected] if row['last_result'] != 'failed' else []
    # Internal scheduling / account identities do not belong in the public representation.
    for key in ('created_by', 'last_manual_at'):
        result.pop(key, None)
    return result


async def _daily_checks(conn: asyncpg.Connection, household_id: UUID) -> int:
    # Reserve all three possible attempts before enqueueing. Request roles cannot inspect the global job
    # table, and reserving retries here guarantees the configured external-call ceiling even under failures.
    return await conn.fetchval(
        "SELECT count(*)::integer*3 FROM watch_runs WHERE household_id=$1 "
        "AND created_at > now()-interval '24 hours'", household_id)


async def queue_check(conn: asyncpg.Connection, watch: asyncpg.Record, user_id: UUID, trigger: str,
                      *, daily_cap: int = 200) -> dict:
    run = await conn.fetchrow(
        "SELECT * FROM watch_runs WHERE watch_id=$1 AND status IN ('queued','running')", watch['id'])
    if run is None:
        if await _daily_checks(conn, watch['household_id'])+3 > daily_cap:
            raise Problem(429, 'check_budget_exhausted', 'This household has reached its daily price-check limit.')
        run = await conn.fetchrow(
            '''INSERT INTO watch_runs(household_id,watch_id,user_id,criteria_version,trigger)
               VALUES($1,$2,$3,$4,$5) RETURNING *''',
            watch['household_id'], watch['id'], user_id, watch['criteria_version'], trigger)
        await enqueue(conn, 'watch.check', {'run_id': str(run['id']), 'watch_id': str(watch['id']),
                                          'user_id': str(user_id)}, max_attempts=3)
    return {'watch_id': watch['id'], 'run_id': run['id'], 'status': run['status']}


class WatchService:
    def __init__(self, db: Database, settings, provider):
        self.db, self.settings, self.provider = db, settings, provider

    @property
    def handlers(self):
        return {'watch.sweep': self.sweep, 'watch.check': self.check_job}

    async def available(self, user_id: UUID) -> bool:
        async with self.db.scoped(user_id) as conn:
            return await is_demo_user(conn, user_id) or bool(getattr(self.provider, 'available', False))

    async def start(self) -> None:
        async with self.db.system() as conn:
            await conn.execute(
                '''INSERT INTO jobs(kind,payload,max_attempts)
                   SELECT 'watch.sweep','{}',100 WHERE NOT EXISTS
                     (SELECT 1 FROM jobs WHERE kind='watch.sweep' AND status IN ('queued','running'))
                   ON CONFLICT(kind) WHERE kind='watch.sweep' AND status='queued' DO NOTHING''')

    async def sweep(self, payload: dict, attempt: int) -> None:
        now = datetime.now(UTC)
        async with self.db.system() as conn:
            expired = await conn.fetch(
                '''UPDATE price_watches SET status='expired',updated_at=now()
                   WHERE status='active' AND criteria->>'needed_by' IS NOT NULL
                     AND (criteria->>'needed_by')::date < current_date RETURNING *''')
            for row in expired:
                await audit(conn, 'watch.expired', actor_type='system', household_id=row['household_id'],
                            target_type='watch', target_id=row['id'])
                await notify(conn, row['household_id'], 'watch.updated', row['id'])
            # Recover interrupted runs without accepting a second completion of the stale snapshot.
            await conn.execute(
                '''UPDATE watch_runs SET status='failed',error_code='check_interrupted',finished_at=now()
                   WHERE status='running' AND started_at < now()-interval '5 minutes' ''')
            watches = await conn.fetch(
                '''SELECT p.* FROM price_watches p JOIN wishlist_items w ON w.id=p.wishlist_item_id
                   JOIN household_members m ON m.household_id=p.household_id AND m.user_id=p.created_by
                   JOIN user_settings s ON s.user_id=p.created_by
                   WHERE p.status='active' AND p.confirmed_at IS NOT NULL AND w.status='active'
                     AND s.agent_paused_at IS NULL AND p.next_check_at<=now()
                   ORDER BY p.next_check_at LIMIT 100''')
            for candidate in sorted(watches, key=lambda w: (str(w['household_id']), str(w['id']))):
                await lock_household(conn, candidate['household_id'])
                row = await conn.fetchrow(
                    "SELECT * FROM price_watches WHERE id=$1 AND status='active' AND next_check_at<=now() "
                    "FOR UPDATE SKIP LOCKED", candidate['id'])
                if row is None:
                    continue
                try:
                    await queue_check(conn, row, row['created_by'], 'scheduled',
                                      daily_cap=getattr(self.settings, 'watch_daily_check_cap', 200))
                except Problem as problem:
                    if problem.code != 'check_budget_exhausted':
                        raise
                    await conn.execute(
                        "UPDATE price_watches SET last_error='check_budget_exhausted',"
                        "last_result='skipped' WHERE id=$1",
                        row['id'])
                    await audit(conn, 'watch.check_skipped', actor_type='system', household_id=row['household_id'],
                                target_type='watch', target_id=row['id'], meta={'reason': 'check_budget_exhausted'})
                    await notify(conn, row['household_id'], 'watch.updated', row['id'])
                await conn.execute('UPDATE price_watches SET next_check_at=$2 WHERE id=$1',
                                   row['id'], next_refresh(now))
            await conn.execute(
                '''INSERT INTO jobs(kind,payload,run_at,max_attempts) VALUES('watch.sweep','{}',$1,100)
                   ON CONFLICT(kind) WHERE kind='watch.sweep' AND status='queued' DO NOTHING''', next_refresh(now))

    async def _snapshot(self, watch_id: UUID, run_id: UUID, user_id: UUID) -> tuple[dict, list[str]] | None:
        async with self.db.scoped(user_id) as conn:
            watch = await conn.fetchrow(
                '''SELECT p.*,w.status AS item_status,s.agent_paused_at FROM price_watches p
                   JOIN wishlist_items w ON w.id=p.wishlist_item_id
                   JOIN user_settings s ON s.user_id=$2 WHERE p.id=$1 FOR UPDATE OF p''', watch_id, user_id)
            run = await conn.fetchrow('SELECT * FROM watch_runs WHERE id=$1 FOR UPDATE', run_id)
            if not watch or not run or run['status'] not in ('queued', 'running', 'failed'):
                return None
            if run['status'] == 'running' and run['started_at'] > datetime.now(UTC)-timedelta(minutes=5):
                return None
            if run['status'] == 'failed' and await conn.fetchval(
                    "SELECT 1 FROM watch_runs WHERE watch_id=$1 AND id<>$2 AND status IN ('queued','running')",
                    watch_id, run_id):
                return None
            if (watch['status'] != 'active' or watch['confirmed_at'] is None or watch['item_status'] != 'active'
                    or watch['criteria_version'] != run['criteria_version'] or watch['agent_paused_at'] is not None):
                await conn.execute(
                    "UPDATE watch_runs SET status='skipped',finished_at=now(),error_code='watch_inactive' WHERE id=$1",
                    run_id)
                return None
            if await _daily_checks(conn, watch['household_id']) > getattr(
                    self.settings, 'watch_daily_check_cap', 200):
                await conn.execute(
                    "UPDATE watch_runs SET status='failed',finished_at=now(),"
                    "error_code='check_budget_exhausted' WHERE id=$1", run_id)
                return None
            execution_id = uuid4()
            await conn.execute(
                "UPDATE watch_runs SET status='running',started_at=now(),execution_id=$2 WHERE id=$1",
                run_id, execution_id)
            urls = await conn.fetch(
                'SELECT url FROM watch_listings WHERE watch_id=$1 ORDER BY updated_at DESC LIMIT 10', watch_id)
            snapshot = dict(watch)
            snapshot['execution_id'] = execution_id
            return snapshot, [row['url'] for row in urls]

    async def check_job(self, payload: dict, attempt: int) -> None:
        watch_id, run_id, user_id = (UUID(payload[k]) for k in ('watch_id', 'run_id', 'user_id'))
        snapshot = await self._snapshot(watch_id, run_id, user_id)
        if snapshot is None:
            return
        watch, urls = snapshot
        async with self.db.scoped(user_id) as conn:
            demo = await is_demo_user(conn, user_id)
        error = None
        try:
            if demo:
                result = self.demo_result(watch['criteria'])
            else:
                result = await asyncio.wait_for(self.provider.search(watch['criteria'], urls), timeout=CHECK_TIMEOUT)
            if result.errors and not result.offers:
                error = ('interaction_required' if result.interaction_urls else
                         'search_unavailable' if not result.checked_count else 'source_verification_failed')
        except TimeoutError:
            result, error = SearchResult(), 'search_timeout'
        except Exception:  # noqa: BLE001 - provider contents never enter logs or persisted error messages
            result, error = SearchResult(), 'search_failed'
        await self._commit(watch, run_id, user_id, result, error, demo=demo)
        if error and error != 'interaction_required' and attempt < 3:
            raise RuntimeError(error)

    @staticmethod
    def demo_result(criteria: dict) -> SearchResult:
        # This path is selected solely by the server-owned users.is_demo flag.
        now = datetime.now(UTC)
        c = WatchCriteria.model_validate(criteria)
        return SearchResult(offers=[Offer(
            url=c.product_url or 'https://www.lodgecastiron.com/product/round-cast-iron-classic-skillet',
            title=c.query, merchant='Lodge Cast Iron', price_cents=max(1, c.target_price_cents-500),
            available=True, available_quantity=99, condition=c.condition, fulfillment=c.fulfillment,
            location=c.location, observed_at=now, arrives_by=now+timedelta(days=1),
            shipping_cents=0, tax_cents=280, fees_cents=0,
            evidence='Merchant product page: in stock; current item price.',
            provider='merchant-jsonld')], checked_count=1)

    async def _commit(self, snapshot: dict, run_id: UUID, user_id: UUID, result: SearchResult,
                      error: str | None, *, demo: bool) -> None:
        now = datetime.now(UTC)
        # Cross-account subscriptions are private under RLS; this narrowly scoped maintenance transaction
        # explicitly checks household membership and pause state for the actor and every alert recipient.
        async with self.db.system() as conn:
            await lock_household(conn, snapshot['household_id'])
            await conn.fetch(
                '''SELECT user_id FROM user_settings WHERE user_id IN
                     (SELECT user_id FROM watch_subscriptions WHERE watch_id=$1 UNION SELECT $2::uuid)
                   ORDER BY user_id FOR UPDATE''', snapshot['id'], user_id)
            watch = await conn.fetchrow(
                '''SELECT p.*,w.status AS item_status,s.agent_paused_at FROM price_watches p
                   JOIN wishlist_items w ON w.id=p.wishlist_item_id JOIN user_settings s ON s.user_id=$2
                   WHERE p.id=$1 FOR UPDATE OF p,s''', snapshot['id'], user_id)
            run = await conn.fetchrow('SELECT * FROM watch_runs WHERE id=$1 FOR UPDATE', run_id)
            if (not watch or not run or run['status'] != 'running'
                    or run['execution_id'] != snapshot['execution_id']):
                return
            membership = await conn.fetchval(
                'SELECT 1 FROM household_members WHERE household_id=$1 AND user_id=$2 FOR KEY SHARE',
                watch['household_id'], user_id)
            valid = (membership and watch['status'] == 'active' and watch['confirmed_at'] is not None
                     and watch['item_status'] == 'active' and watch['agent_paused_at'] is None
                     and watch['criteria_version'] == snapshot['criteria_version'])
            if not valid:
                await conn.execute(
                    "UPDATE watch_runs SET status='skipped',finished_at=now(),"
                    "error_code='criteria_changed' WHERE id=$1",
                    run_id)
                return
            await conn.execute('UPDATE watch_runs SET interaction_urls=$2 WHERE id=$1',
                               run_id, result.interaction_urls[:5])
            if error:
                await conn.execute(
                    "UPDATE watch_runs SET status='failed',error_code=$2,finished_at=$3 WHERE id=$1",
                    run_id, error, now)
                await conn.execute(
                    '''UPDATE price_watches SET last_checked_at=$2,last_result='failed',last_error=$3,
                       next_check_at=$4,updated_at=$2 WHERE id=$1''', watch['id'], now, error, next_refresh(now))
            else:
                count = 0
                # Relevant later sources must not be crowded out by an earlier page's variant list.
                evaluated_offers = [(offer, evaluate(watch['criteria'], offer, now)) for offer in result.offers]
                evaluated_offers.sort(key=lambda item: (not item[1]['eligible'], item[1]['unit_price_cents']))
                for offer, evaluated in evaluated_offers[:20]:
                    listing = await conn.fetchval(
                        '''INSERT INTO watch_listings(household_id,watch_id,url,merchant) VALUES($1,$2,$3,$4)
                           ON CONFLICT(watch_id,url) DO UPDATE SET updated_at=now(),merchant=EXCLUDED.merchant
                           RETURNING id''', watch['household_id'], watch['id'], offer.url, offer.merchant)
                    previous_offer = await conn.fetchval(
                        'SELECT offer FROM watch_observations WHERE listing_id=$1 ORDER BY observed_at DESC LIMIT 1',
                        listing)
                    restocked = bool(previous_offer and not previous_offer.get('available'))
                    observation = await conn.fetchval(
                        '''INSERT INTO watch_observations(household_id,watch_id,listing_id,run_id,criteria_version,
                           offer,observed_at,eligible,reason) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id''',
                        watch['household_id'], watch['id'], listing, run_id, watch['criteria_version'],
                        offer.model_dump(mode='json'), offer.observed_at, evaluated['eligible'], evaluated['reason'])
                    if not evaluated['eligible']:
                        continue
                    count += 1
                    fingerprint = hashlib.sha256(json.dumps(
                        [offer.url, offer.price_cents, offer.pack_quantity, evaluated['total_price_cents'],
                         offer.condition, offer.fulfillment, offer.location,
                         str(run_id) if restocked else None], sort_keys=True).encode()).hexdigest()
                    match_id = await conn.fetchval(
                        '''INSERT INTO watch_matches(household_id,watch_id,observation_id,criteria_version,fingerprint,
                           title,url,merchant,unit_price_cents,total_price_cents,currency,quantity,shipping_cents,
                           tax_cents,fulfillment,location,condition,observed_at,evidence,reason)
                           VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)
                           ON CONFLICT(watch_id,criteria_version,fingerprint) DO UPDATE
                           SET observation_id=EXCLUDED.observation_id,observed_at=EXCLUDED.observed_at
                           RETURNING id''', watch['household_id'], watch['id'], observation, watch['criteria_version'],
                        fingerprint, offer.title, offer.url, offer.merchant, evaluated['unit_price_cents'],
                        evaluated['total_price_cents'], offer.currency, evaluated['quantity'], offer.shipping_cents,
                        offer.tax_cents, offer.fulfillment, offer.location, offer.condition, offer.observed_at,
                        [offer.evidence[:1000]],
                        'Confirmed item, price, availability and fulfillment requirements met.')
                    await self._alerts(conn, watch, match_id, offer, evaluated, now, demo=demo, restocked=restocked)
                await conn.execute(
                    '''UPDATE watch_runs SET status='succeeded',offer_count=$2,match_count=$3,finished_at=$4,
                       error_code=NULL WHERE id=$1''', run_id, len(result.offers[:20]), count, now)
                await conn.execute(
                    '''UPDATE price_watches SET last_checked_at=$2,last_successful_at=$2,last_result=$3,
                       last_error=$4,next_check_at=$5,updated_at=$2 WHERE id=$1''', watch['id'], now,
                    'matched' if count else 'no_match',
                    'interaction_required' if result.interaction_urls and not count else
                    'partial_search' if result.errors else None, next_refresh(now))
            await audit(conn, 'watch.checked', actor_type='agent', actor_id=user_id, household_id=watch['household_id'],
                        target_type='watch', target_id=watch['id'], meta={'failed': error is not None})
            await notify(conn, watch['household_id'], 'watch.updated', watch['id'])

    async def _alerts(self, conn, watch, match_id, offer, evaluated, now, *, demo: bool, restocked: bool) -> None:
        subscriptions = await conn.fetch(
            '''SELECT s.*,u.is_demo FROM watch_subscriptions s
               JOIN household_members m ON m.household_id=s.household_id AND m.user_id=s.user_id
               JOIN user_settings p ON p.user_id=s.user_id JOIN users u ON u.id=s.user_id
               WHERE s.watch_id=$1 AND s.household_id=$2 AND p.agent_paused_at IS NULL
               ORDER BY s.user_id FOR UPDATE OF s,p,m''', watch['id'], watch['household_id'])
        for sub in subscriptions:
            # Synthetic observations can never cross into an ordinary account, even after membership changes.
            if demo != sub['is_demo']:
                continue
            # Serialize caps across different watches for the same recipient.
            await conn.execute('SELECT pg_advisory_xact_lock(hashtext($1))', 'watch.alert.'+str(sub['user_id']))
            # A pending row from a quiet-hour delay can point at an observation that is no longer
            # current. Find it before applying price-improvement dedupe so a fresh qualifying offer
            # can replace the stale alert even if its price is slightly higher.
            pending = None
            if sub['push_enabled']:
                pending = await conn.fetchrow(
                    '''SELECT n.id AS notification_id,o.id AS outbox_id,
                              pm.observation_id AS match_observation_id,pm.criteria_version AS match_version,
                              latest.id AS latest_observation_id,latest.criteria_version AS latest_version,
                              latest.observed_at AS latest_observed_at,latest.eligible AS latest_eligible,
                              latest.valid_until
                       FROM notifications n JOIN notification_outbox o ON o.notification_id=n.id
                       JOIN watch_matches pm ON pm.id=n.match_id AND pm.criteria_version=$3
                       JOIN watch_observations original ON original.id=pm.observation_id
                       JOIN LATERAL (SELECT id,criteria_version,observed_at,eligible,
                                            NULLIF(offer->>'valid_until','')::timestamptz AS valid_until
                                     FROM watch_observations
                                     WHERE listing_id=original.listing_id
                                     ORDER BY observed_at DESC,id DESC LIMIT 1) latest ON true
                       WHERE n.user_id=$1 AND n.watch_id=$2 AND o.status='pending'
                         AND n.created_at >= $4
                       ORDER BY n.created_at DESC,n.id LIMIT 1 FOR UPDATE OF n,o''',
                    sub['user_id'], watch['id'], watch['criteria_version'], now-timedelta(hours=24))
            pending_is_stale = bool(pending and (
                pending['match_observation_id'] != pending['latest_observation_id'] or
                pending['latest_eligible'] is not True or
                pending['match_version'] != pending['latest_version'] or
                now-pending['latest_observed_at'] > FRESHNESS or
                (pending['valid_until'] is not None and pending['valid_until'] <= now)))
            prior_match = await conn.fetchrow(
                '''SELECT m.unit_price_cents,m.total_price_cents FROM notifications n
                   JOIN watch_matches m ON m.id=n.match_id WHERE n.user_id=$1 AND n.watch_id=$2
                   ORDER BY n.created_at DESC LIMIT 1''', sub['user_id'], watch['id'])
            if prior_match and not restocked and not pending_is_stale:
                lower_unit = evaluated['unit_price_cents'] < prior_match['unit_price_cents']
                lower_total = (evaluated['total_price_cents'] is not None
                               and prior_match['total_price_cents'] is not None
                               and evaluated['total_price_cents'] < prior_match['total_price_cents'])
                if not lower_unit and not lower_total:
                    continue
            # A quiet-hours delivery may trigger a fresh check after its original observation
            # expires. Coalesce a newly verified match into that still-pending inbox/outbox row
            # so the user gets the current price through one stable notification identifier.
            if pending:
                duplicate = await conn.fetchval(
                    'SELECT id FROM notifications WHERE user_id=$1 AND match_id=$2 AND id<>$3',
                    sub['user_id'], match_id, pending['notification_id'])
                if duplicate:
                    await conn.execute(
                        "UPDATE notification_outbox SET status='suppressed',last_error='coalesced_duplicate',"
                        "locked_until=NULL WHERE id=$1", pending['outbox_id'])
                    await audit(conn, 'notification.coalesced', actor_type='agent', actor_id=sub['user_id'],
                                household_id=watch['household_id'], target_type='notification',
                                target_id=pending['notification_id'],
                                meta={'duplicate_notification_id': str(duplicate),
                                      'outbox_id': str(pending['outbox_id'])})
                    continue
                notification = pending['notification_id']
                cents = evaluated['unit_price_cents']
                body = (f'{offer.title[:120]} is ${cents/100:.2f} per item at '
                        f'{offer.merchant[:80]}. Review the current offer.')
                await conn.execute(
                    '''UPDATE notifications SET match_id=$2,title=$3,body=$4 WHERE id=$1''',
                    notification, match_id, 'A price watch found a match', body)
                await conn.execute(
                    '''UPDATE notification_outbox SET status='pending',run_at=$2,attempts=0,last_error=NULL,
                              locked_until=NULL WHERE id=$1''', pending['outbox_id'], now)
                await audit(conn, 'notification.updated', actor_type='agent', actor_id=sub['user_id'],
                            household_id=watch['household_id'], target_type='notification', target_id=notification,
                            meta={'match_id': str(match_id), 'outbox_id': str(pending['outbox_id'])})
                await notify(conn, watch['household_id'], 'notification.updated', notification)
                continue
            last_inbox = await conn.fetchval(
                'SELECT max(created_at) FROM notifications WHERE user_id=$1 AND watch_id=$2',
                sub['user_id'], watch['id'])
            # Restocks must bypass cooldown: a deferred overnight alert may have been suppressed
            # after an intermediate out-of-stock observation, and that inbox row would otherwise
            # mute the later in-stock match the user was waiting for.
            if (last_inbox and not restocked
                    and now-last_inbox < timedelta(hours=sub['cooldown_hours'])):
                continue
            local = now.astimezone(ZoneInfo(sub['timezone']))
            day_start = local.replace(hour=0, minute=0, second=0, microsecond=0)
            daily = await conn.fetchval(
                'SELECT count(*) FROM notifications WHERE user_id=$1 AND created_at >=$2 AND watch_id=$3',
                sub['user_id'], day_start, watch['id'])
            global_daily = await conn.fetchval(
                'SELECT count(*) FROM notifications WHERE user_id=$1 AND created_at >=$2', sub['user_id'], day_start)
            if global_daily >= getattr(self.settings, 'watch_daily_alert_cap', 20):
                continue
            if daily >= sub['daily_cap']:
                continue
            cents = evaluated['unit_price_cents']
            notification = await conn.fetchval(
                '''INSERT INTO notifications(household_id,user_id,watch_id,match_id,title,body)
                   VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id,match_id) DO NOTHING RETURNING id''',
                watch['household_id'], sub['user_id'], watch['id'], match_id, 'A price watch found a match',
                f'{offer.title[:120]} is ${cents/100:.2f} per item at {offer.merchant[:80]}. Review the current offer.')
            if not notification:
                continue
            if sub['push_enabled']:
                await conn.execute(
                    '''INSERT INTO notification_outbox(household_id,user_id,notification_id)
                       VALUES($1,$2,$3) ON CONFLICT DO NOTHING''', watch['household_id'], sub['user_id'], notification)
                await enqueue(conn, 'notification.deliver', {'notification_id': str(notification)}, max_attempts=5)
            await audit(conn, 'notification.created', actor_type='agent', actor_id=sub['user_id'],
                        household_id=watch['household_id'], target_type='notification', target_id=notification)
            await notify(conn, watch['household_id'], 'notification.updated', notification)
