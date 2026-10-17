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
                response: dict) -> bool:
    """Record the response. Returns False if a concurrent request with the same key won the race."""
    inserted = await conn.fetchval(
        """INSERT INTO idempotency_keys (user_id, key, request_hash, status_code, response)
           VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING RETURNING true""",
        user_id, key, digest, status, response)
    return bool(inserted)
