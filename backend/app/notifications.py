"""Durable notification delivery through Apple's HTTP/2 APNs API."""

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import asyncpg
import httpx
import jwt

from app.db import Database
from app.errors import Problem
from app.watch_ops import queue_check
from app.wishlist_ops import lock_household

log = logging.getLogger("agora.notifications")
# HTTPX's INFO request URL contains the APNs device token. Keep transport request URLs out of application logs.
logging.getLogger("httpx").setLevel(logging.WARNING)
APNS_ENDPOINTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
MAX_PRICE_AGE = timedelta(minutes=30)
MAX_NOTIFICATION_AGE = timedelta(hours=24)
MAX_REVALIDATION_RUNS = 3


def _secret(settings, name: str) -> str | None:
    value = getattr(settings, name, None)
    if value is None:
        return None
    if hasattr(value, "get_secret_value"):
        value = value.get_secret_value()
    return value or None


def apns_available(settings) -> bool:
    return bool(getattr(settings, "apns_enabled", False) and all(
        _secret(settings, name) for name in ("apns_key_id", "apns_team_id", "apns_private_key", "apns_topic")))


class NotificationService:
    """Claims outbox rows durably and sends them with stable APNs identifiers for safe retries."""

    def __init__(self, db: Database, settings, http_client: httpx.AsyncClient | None = None):
        self.db = db
        self.settings = settings
        self.http_client = http_client
        self._owns_client = http_client is None
        self._cached_token: str | None = None
        self._cached_token_at = 0
        self._sweep_task: asyncio.Task | None = None
        self._stop_sweep = asyncio.Event()
        # Keep the total external-delivery window well inside the five-minute outbox lease.
        self.delivery_timeout_seconds = 90

    @property
    def available(self) -> bool:
        return apns_available(self.settings)

    async def start(self) -> None:
        """Create transport and poll the durable outbox so retries and quiet-hour deferrals run later."""
        await self._ensure_client()
        if self._sweep_task is None:
            self._stop_sweep.clear()
            self._sweep_task = asyncio.create_task(self._sweep_loop(), name="agora-notification-sweep")

    async def _ensure_client(self) -> None:
        if self.http_client is None:
            self.http_client = httpx.AsyncClient(http2=True, timeout=10, follow_redirects=False)

    async def close(self) -> None:
        if self._sweep_task is not None:
            self._stop_sweep.set()
            self._sweep_task.cancel()
            try:
                await self._sweep_task
            except asyncio.CancelledError:
                pass
            self._sweep_task = None
        if self._owns_client and self.http_client is not None:
            await self.http_client.aclose()
            self.http_client = None

    async def _sweep_loop(self) -> None:
        while not self._stop_sweep.is_set():
            try:
                await self.send_pending()
            except Exception as error:  # noqa: BLE001 - keep the worker alive through transient database failures
                log.warning("notification.sweep_error error=%s", type(error).__name__)
            try:
                await asyncio.wait_for(self._stop_sweep.wait(), timeout=15)
            except TimeoutError:
                pass

    @property
    def handlers(self):
        """Worker job handler for an explicit notification delivery wake-up."""
        return {"notification.deliver": self._handle_job}

    async def _handle_job(self, payload: dict, _attempt: int) -> None:
        await self.send_pending(notification_id=payload.get("notification_id"))

    def _provider_token(self) -> str:
        now = int(datetime.now(UTC).timestamp())
        if self._cached_token is None or now - self._cached_token_at >= 50 * 60:
            self._cached_token = jwt.encode(
                {"iss": _secret(self.settings, "apns_team_id"), "iat": now},
                _secret(self.settings, "apns_private_key"), algorithm="ES256",
                headers={"kid": _secret(self.settings, "apns_key_id")},
            )
            self._cached_token_at = now
        return self._cached_token

    async def send_pending(self, limit: int = 25, notification_id: str | None = None) -> int:
        """Deliver ready rows, returning the number claimed. Missing APNs config leaves real inbox rows pending."""
        demo_rows = await self._pending_demo_ids(limit, notification_id)
        for demo_row in demo_rows:
            # The demo account exercises the inbox while remaining isolated from real external effects.
            await self._finish(demo_row["id"], "sent", delivered=True)
        if not self.available:
            return len(demo_rows)
        await self._ensure_client()
        processed = len(demo_rows)
        for _ in range(max(0, limit - processed)):
            row = await self._claim(notification_id)
            if row is None:
                break
            processed += 1
            try:
                async with asyncio.timeout(self.delivery_timeout_seconds):
                    await self._deliver(row)
            except TimeoutError:
                log.warning("notification.delivery_timeout outbox_id=%s", row["outbox_id"])
                await self._retry(row["outbox_id"], "delivery_timeout")
            except Exception as error:  # noqa: BLE001 - outbox rows must survive unexpected provider failures
                log.warning("notification.delivery_error outbox_id=%s error=%s", row["outbox_id"], type(error).__name__)
                await self._retry(row["outbox_id"], "delivery_error")
        return processed

    async def _pending_demo_ids(self, limit: int, notification_id: str | None) -> list:
        async with self.db.system() as conn:
            return await conn.fetch(
                """WITH claim AS (
                     SELECT o.id FROM notification_outbox o JOIN users u ON u.id = o.user_id
                     WHERE u.is_demo AND o.run_at <= now()
                       AND (o.status = 'pending' OR (o.status = 'sending' AND o.locked_until < now()))
                       AND ($1::uuid IS NULL OR o.notification_id = $1::uuid)
                     ORDER BY o.run_at FOR UPDATE OF o SKIP LOCKED LIMIT $2
                   )
                   UPDATE notification_outbox o SET status = 'sending', attempts = attempts + 1,
                       locked_until = now() + interval '5 minutes'
                   FROM claim WHERE o.id = claim.id RETURNING o.id""",
                notification_id, limit)

    async def _claim(self, notification_id: str | None) -> asyncpg.Record | None:
        async with self.db.system() as conn:
            return await conn.fetchrow(
                """WITH claim AS (
                     SELECT o.id FROM notification_outbox o
                     JOIN users u ON u.id = o.user_id
                     JOIN user_settings us ON us.user_id = o.user_id
                     JOIN notifications n ON n.id = o.notification_id
                     JOIN watch_subscriptions sub ON sub.watch_id = n.watch_id AND sub.user_id = o.user_id
                     WHERE NOT u.is_demo AND o.run_at <= now()
                       AND (o.status = 'pending' OR (o.status = 'sending' AND o.locked_until < now()))
                       AND ($1::uuid IS NULL OR o.notification_id = $1::uuid)
                       AND NOT EXISTS (
                         SELECT 1 FROM notification_outbox sending
                         WHERE sending.user_id = o.user_id
                           AND sending.status = 'sending' AND sending.id <> o.id
                       )
                     ORDER BY o.run_at, o.id FOR UPDATE OF sub, us SKIP LOCKED LIMIT 1
                   ), selected AS (
                     UPDATE notification_outbox o SET status = 'sending', attempts = attempts + 1,
                         locked_until = now() + interval '5 minutes'
                     FROM claim WHERE o.id = claim.id
                     RETURNING o.id AS outbox_id, o.notification_id, o.household_id, o.user_id
                   )
                   SELECT s.*, n.watch_id, n.match_id, n.title, n.body, n.created_at, m.observed_at
                   FROM selected s JOIN notifications n ON n.id = s.notification_id
                   JOIN watch_matches m ON m.id = n.match_id""",
                notification_id)

    async def _deliver(self, row: asyncpg.Record) -> None:
        state = await self._validate(row)
        if state["suppress"]:
            await self._finish(row["outbox_id"], "suppressed", state["reason"])
            return
        if state["defer_until"] is not None:
            await self._defer(row["outbox_id"], state["defer_until"])
            return
        devices = state["devices"]
        if not devices:
            await self._finish(row["outbox_id"], "suppressed", "no_push_device")
            return
        retry_error = None
        delivered = False
        for index, device in enumerate(devices):
            # A long multi-device loop must recheck eligibility and the current offer before
            # each external request; APNs expiry is also enforced inside _send at call time.
            if index:
                state = await self._validate(row)
                if state["suppress"]:
                    if not delivered:
                        await self._finish(row["outbox_id"], "suppressed", state["reason"])
                        return
                    break
                if state["defer_until"] is not None:
                    if not delivered:
                        await self._defer(row["outbox_id"], state["defer_until"])
                        return
                    break
                if not any(current["id"] == device["id"] for current in state["devices"]):
                    continue
            response = await self._send(device, {**dict(row), "expires_at": state["expires_at"]})
            if response is None:
                delivered = True
            elif response == "invalidated":
                await self._delete_device(device["id"])
            elif response == "expired":
                if not delivered:
                    latest = await self._validate(row)
                    if latest["suppress"]:
                        await self._finish(row["outbox_id"], "suppressed", latest["reason"])
                    elif latest["defer_until"] is not None:
                        await self._defer(row["outbox_id"], latest["defer_until"])
                    else:
                        await self._defer(row["outbox_id"], datetime.now(UTC) + timedelta(seconds=30))
                    return
                break
            elif response.startswith("retry:"):
                retry_error = response.split(":", 1)[1]
        if delivered:
            # One successful device is enough for this outbox row. APNs collapse IDs stay stable across retries.
            await self._set_last_notified(row["watch_id"], row["user_id"])
            await self._finish(row["outbox_id"], "sent", delivered=True)
        elif retry_error:
            await self._retry(row["outbox_id"], retry_error)
        else:
            await self._finish(row["outbox_id"], "failed", "apns_rejected")

    async def _validate(self, row: asyncpg.Record) -> dict:
        now = datetime.now(UTC)
        async with self.db.system() as conn:
            data = await conn.fetchrow(
                """SELECT w.status, w.confirmed_at, w.criteria_version, m.criteria_version AS match_version,
                          m.observed_at, m.observation_id, m.criteria_version AS match_observation_version,
                          o.criteria_version AS observation_version, o.observed_at AS latest_observed_at, o.eligible,
                          NULLIF(o.offer->>'valid_until','')::timestamptz AS valid_until,
                          s.push_enabled, s.quiet_start_hour, s.quiet_end_hour, s.timezone, s.daily_cap,
                          s.cooldown_hours, s.last_notified_at, us.agent_paused_at,
                          (SELECT count(*) FROM notification_outbox x
                           JOIN notifications nx ON nx.id = x.notification_id
                           WHERE x.user_id = $2 AND nx.watch_id = $3 AND x.status = 'sent'
                             AND (x.delivered_at AT TIME ZONE s.timezone)::date =
                                 (now() AT TIME ZONE s.timezone)::date) AS sent_today,
                          (SELECT count(*) FROM notification_outbox x
                           WHERE x.user_id = $2 AND x.status = 'sent'
                             AND (x.delivered_at AT TIME ZONE us.timezone)::date =
                                 (now() AT TIME ZONE us.timezone)::date) AS sent_today_user
                   FROM price_watches w
                   JOIN watch_matches m ON m.watch_id = w.id AND m.id = $4
                   JOIN watch_observations o ON o.id = m.observation_id
                   JOIN watch_subscriptions s ON s.watch_id = w.id AND s.user_id = $2
                   JOIN household_members hm ON hm.household_id = w.household_id AND hm.user_id = s.user_id
                   JOIN user_settings us ON us.user_id = $2
                   WHERE w.id = $3 AND w.household_id = $1
                     AND o.listing_id = (SELECT listing_id FROM watch_observations WHERE id = m.observation_id)
                     AND o.id = (SELECT id FROM watch_observations WHERE listing_id = o.listing_id
                                ORDER BY observed_at DESC LIMIT 1)""",
                row["household_id"], row["user_id"], row["watch_id"], row["match_id"])
            devices = await conn.fetch(
                "SELECT id, token, environment FROM push_devices WHERE user_id = $1 ORDER BY created_at",
                row["user_id"])
        if data is None:
            return {"suppress": True, "reason": "watch_or_subscription_unavailable", "devices": []}
        if (data["status"] != "active" or data["confirmed_at"] is None or
                data["criteria_version"] != data["match_version"] or
                data["agent_paused_at"] is not None or not data["push_enabled"]):
            return {"suppress": True, "reason": "delivery_no_longer_allowed", "devices": []}
        if now - row["created_at"] > MAX_NOTIFICATION_AGE:
            return {"suppress": True, "reason": "notification_too_old", "devices": []}
        try:
            local_now = now.astimezone(ZoneInfo(data["timezone"]))
        except ZoneInfoNotFoundError:
            return {"suppress": True, "reason": "invalid_timezone", "devices": []}
        quiet_start, quiet_end = data["quiet_start_hour"], data["quiet_end_hour"]
        if quiet_start is not None and _is_quiet(local_now.hour, quiet_start, quiet_end):
            until = local_now.replace(hour=quiet_end, minute=0, second=0, microsecond=0)
            if quiet_start > quiet_end and local_now.hour >= quiet_start:
                until += timedelta(days=1)
            return {"suppress": False, "defer_until": until.astimezone(UTC), "devices": []}
        # Quiet hours can make a valid price observation old by morning. Recheck it before
        # delivery instead of either sending a stale price or permanently dropping the inbox item.
        if (data["eligible"] is not True or data["observed_at"] != data["latest_observed_at"] or
                data["match_observation_version"] != data["observation_version"] or
                now - data["observed_at"] > MAX_PRICE_AGE or
                (data["valid_until"] is not None and data["valid_until"] <= now)):
            return await self._revalidate(row)
        if data["last_notified_at"] is not None and now - data["last_notified_at"] < timedelta(
                hours=data["cooldown_hours"]):
            return {"suppress": True, "reason": "cooldown_active", "devices": []}
        if data["sent_today"] >= data["daily_cap"]:
            return {"suppress": True, "reason": "daily_cap_reached", "devices": []}
        if data["sent_today_user"] >= getattr(self.settings, "watch_daily_alert_cap", 20):
            return {"suppress": True, "reason": "user_daily_cap_reached", "devices": []}
        expires_at = data["observed_at"] + MAX_PRICE_AGE
        if data["valid_until"] is not None:
            expires_at = min(expires_at, data["valid_until"])
        return {"suppress": False, "defer_until": None, "devices": devices, "expires_at": expires_at}

    async def _revalidate(self, row: asyncpg.Record) -> dict:
        """Queue bounded fresh price checks for a stale deferred alert."""
        defer = datetime.now(UTC) + timedelta(seconds=30)
        async with self.db.system() as conn:
            await lock_household(conn, row["household_id"])
            watch = await conn.fetchrow(
                """SELECT w.*, m.criteria_version AS match_version, s.push_enabled,
                          us.agent_paused_at,
                          EXISTS (SELECT 1 FROM household_members hm
                                  WHERE hm.household_id=w.household_id AND hm.user_id=$3) AS is_member
                   FROM price_watches w
                   JOIN watch_matches m ON m.id=$4 AND m.watch_id=w.id
                   JOIN watch_subscriptions s ON s.watch_id=w.id AND s.user_id=$3
                   JOIN user_settings us ON us.user_id=$3
                   WHERE w.id=$1 AND w.household_id=$2 FOR UPDATE OF w, s""",
                row["watch_id"], row["household_id"], row["user_id"], row["match_id"])
            if (watch is None or watch["status"] != "active" or watch["confirmed_at"] is None or
                    watch["criteria_version"] != watch["match_version"] or not watch["push_enabled"] or
                    watch["agent_paused_at"] is not None or not watch["is_member"]):
                return {"suppress": True, "reason": "delivery_no_longer_allowed", "devices": []}
            active_run = await conn.fetchrow(
                """SELECT id FROM watch_runs WHERE watch_id=$1 AND criteria_version=$2
                   AND status IN ('queued','running') ORDER BY created_at DESC LIMIT 1""",
                watch["id"], watch["criteria_version"])
            if active_run is not None:
                return {"suppress": False, "defer_until": defer, "devices": []}
            checks = await conn.fetchval(
                """SELECT count(*) FROM watch_runs WHERE watch_id=$1 AND criteria_version=$2
                   AND trigger='scheduled' AND created_at >= $3""",
                watch["id"], watch["criteria_version"], row["created_at"])
            if checks >= MAX_REVALIDATION_RUNS:
                return {"suppress": True, "reason": "price_revalidation_unavailable", "devices": []}
            try:
                await queue_check(
                    conn, watch, row["user_id"], "scheduled",
                    daily_cap=getattr(self.settings, "watch_daily_check_cap", 200))
            except Problem as error:
                if error.code == "check_budget_exhausted":
                    return {"suppress": True, "reason": "price_revalidation_budget_exhausted", "devices": []}
                raise
        return {"suppress": False, "defer_until": defer, "devices": []}

    async def _send(self, device: asyncpg.Record, row: asyncpg.Record) -> str | None:
        assert self.http_client is not None
        expires_at = row.get("expires_at")
        if expires_at is None:
            expires_at = row["observed_at"] + MAX_PRICE_AGE
            valid_until = row.get("valid_until")
            if valid_until is not None:
                expires_at = min(expires_at, valid_until)
        if datetime.now(UTC) >= expires_at:
            return "expired"
        payload = {
            "aps": {"alert": {"title": row["title"], "body": row["body"]}, "sound": "default"},
            "notification_id": str(row["notification_id"]),
            "watch_id": str(row["watch_id"]),
        }
        try:
            response = await self.http_client.post(
                f"{APNS_ENDPOINTS[device['environment']]}/3/device/{device['token']}",
                json=payload,
                headers={"authorization": f"bearer {self._provider_token()}",
                         "apns-topic": _secret(self.settings, "apns_topic"),
                         "apns-push-type": "alert", "apns-priority": "10",
                         "apns-id": str(row["notification_id"]),
                         "apns-collapse-id": str(row["notification_id"])[:64],
                         "apns-expiration": str(int(expires_at.timestamp()))},
            )
        except (httpx.TimeoutException, httpx.NetworkError):
            return "retry:network_error"
        if response.status_code == 200:
            return None
        if response.status_code == 410:
            return "invalidated"
        if response.status_code == 429 or response.status_code >= 500:
            return f"retry:http_{response.status_code}"
        return f"permanent:http_{response.status_code}"

    async def _delete_device(self, device_id) -> None:
        async with self.db.system() as conn:
            await conn.execute("DELETE FROM push_devices WHERE id = $1", device_id)

    async def _set_last_notified(self, watch_id, user_id) -> None:
        async with self.db.system() as conn:
            await conn.execute(
                "UPDATE watch_subscriptions SET last_notified_at = now(), updated_at = now() "
                "WHERE watch_id = $1 AND user_id = $2", watch_id, user_id)

    async def _finish(self, outbox_id, status: str, reason: str | None = None, *, delivered: bool = False) -> None:
        async with self.db.system() as conn:
            await conn.execute(
                """UPDATE notification_outbox SET status = $2, last_error = $3,
                          delivered_at = CASE WHEN $4 THEN now() ELSE delivered_at END,
                          locked_until = NULL WHERE id = $1""",
                outbox_id, status, reason, delivered)

    async def _defer(self, outbox_id, until: datetime) -> None:
        async with self.db.system() as conn:
            await conn.execute(
                "UPDATE notification_outbox SET status = 'pending', run_at = $2, locked_until = NULL "
                "WHERE id = $1", outbox_id, until)

    async def _retry(self, outbox_id, reason: str) -> None:
        async with self.db.system() as conn:
            attempts = await conn.fetchval("SELECT attempts FROM notification_outbox WHERE id = $1", outbox_id)
            delay = min(60 * (2 ** max(0, (attempts or 1) - 1)), 6 * 60 * 60)
            await conn.execute(
                """UPDATE notification_outbox SET status = 'pending', last_error = $2,
                          run_at = now() + make_interval(secs => $3), locked_until = NULL WHERE id = $1""",
                outbox_id, reason[:80], delay)


def _is_quiet(hour: int, start: int, end: int) -> bool:
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end
