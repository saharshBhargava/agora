"""Idempotency keys for mutating requests. Phones retry on flaky networks, so a retried POST must return the
original result rather than doing the work twice."""

import hashlib
import json
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import Request

from app.errors import Problem


def key_from(request: Request) -> str:
    key = request.headers.get("idempotency-key", "")
    if not 8 <= len(key) <= 128 or not key.isascii() or not key.isprintable():
        raise Problem(400, "idempotency_key_required", "Send an Idempotency-Key header (8-128 characters).")
    return key


def request_hash(*parts: Any) -> str:
    return hashlib.sha256(json.dumps(parts, default=str, sort_keys=True).encode()).hexdigest()


async def lookup(conn: asyncpg.Connection, user_id: UUID, key: str, digest: str) -> dict | None:
    row = await conn.fetchrow("SELECT request_hash, response FROM idempotency_keys WHERE user_id = $1 AND key = $2",
                              user_id, key)
    if row is None:
        return None
    if row["request_hash"] != digest:
        raise Problem(422, "idempotency_key_reused", "That Idempotency-Key was already used for a different request.")
    return row["response"]


async def claim(conn: asyncpg.Connection, user_id: UUID, key: str, digest: str, status: int,
                response: dict, *, operation: str | None = None) -> bool:
    """Record the response. Returns False if a concurrent request with the same key won the race."""
    inserted = await conn.fetchval(
        """INSERT INTO idempotency_keys (user_id, key, request_hash, status_code, response, operation)
           VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING RETURNING true""",
        user_id, key, digest, status, response, operation)
    return bool(inserted)


async def begin_optional_add(conn: asyncpg.Connection, request: Request, user_id: UUID,
                             operation: str, body: dict) -> tuple[str | None, str, dict | None]:
    """Backward-compatible create routes: chat always supplies a key; older forms need not.

    Serialize keyed retries before doing any writes. The caller must authorize the destination first.
    """
    key = key_from(request) if "idempotency-key" in request.headers else None
    digest = request_hash(operation, body)
    if key is None:
        return None, digest, None
    await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", f"{user_id}:{key}")
    return key, digest, await lookup(conn, user_id, key, digest)


async def finish_optional_add(conn: asyncpg.Connection, user_id: UUID, key: str | None,
                              digest: str, response: dict) -> None:
    if key is not None and not await claim(conn, user_id, key, digest, 201, response):
        raise Problem(409, "duplicate_request", "This request is being processed; retry with the same key.")


def item_name_key(value: str) -> str:
    # Conservative identity: no fuzzy matching or merging of variants/units.
    return " ".join(value.casefold().split())
