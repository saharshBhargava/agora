"""Live sync over Server-Sent Events. One shared LISTEN connection fans out to per-client queues, filtered to
the households each client belongs to. Events carry only IDs and types; clients refetch through the API."""

import asyncio
import json
import logging
from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from app.auth import CurrentUser, Principal
from app.db import Database

router = APIRouter(prefix="/v1", tags=["events"])
log = logging.getLogger("agora.events")


class Broadcaster:
    def __init__(self, db: Database):
        self.db = db
        self.subscribers: set[tuple[frozenset[str], asyncio.Queue]] = set()
        self._conn = None

    async def start(self) -> None:
        assert self.db.pool is not None
        self._conn = await self.db.pool.acquire()
        await self._conn.add_listener("agora_events", self._on_event)

    async def stop(self) -> None:
        if self._conn is not None and self.db.pool is not None:
            await self._conn.remove_listener("agora_events", self._on_event)
            await self.db.pool.release(self._conn)
            self._conn = None

    def _on_event(self, _conn, _pid, _channel, payload: str) -> None:
        try:
            event = json.loads(payload)
        except ValueError:
            return
        for households, queue in list(self.subscribers):
            if event.get("household_id") in households and queue.qsize() < 100:
                queue.put_nowait(event)

    async def stream(self, households: frozenset[str], request: Request) -> AsyncIterator[str]:
        queue: asyncio.Queue = asyncio.Queue()
        entry = (households, queue)
        self.subscribers.add(entry)
        try:
            yield "retry: 3000\n\n"
            while not await request.is_disconnected():
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=15)
                    yield f"event: {event['type']}\ndata: {json.dumps(event)}\n\n"
                except TimeoutError:
                    yield ": keep-alive\n\n"
        finally:
            self.subscribers.discard(entry)


@router.get("/events", response_class=StreamingResponse)
async def events(request: Request, user: Principal = CurrentUser) -> StreamingResponse:
    async with request.app.state.db.scoped(user.user_id) as conn:
        rows = await conn.fetch("SELECT household_id FROM household_members WHERE user_id = $1", user.user_id)
    households = frozenset(str(UUID(str(r["household_id"]))) for r in rows)
    return StreamingResponse(request.app.state.broadcaster.stream(households, request),
                             media_type="text/event-stream",
                             headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})
