import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager, suppress

import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware

from app.auth import TokenVerifier
from app.config import Settings, get_settings
from app.db import Database
from app.errors import Problem, handle_problem, handle_validation, problem_response
from app.google_calendar import GoogleCalendar
from app.jobs import Worker
from app.pipeline import Pipeline
from app.routers import account, audit, calendar, events, inventory, merchants, scans
from app.routers.events import Broadcaster
from app.storage import make_storage
from app.vision.providers import make_provider
from app.vision.service import VisionService

log = logging.getLogger("agora.http")


def _provider(kind: str, settings: Settings, client: httpx.AsyncClient):
    """A provider whose API key is missing degrades to offline replay instead of crashing the deploy."""
    try:
        return make_provider(kind, settings, client)
    except ValueError as error:
        log.warning("vision provider %s unavailable (%s); using replay fixtures", kind, error)
        return make_provider("replay", settings, client)


def build_pipeline(settings: Settings, db: Database, client: httpx.AsyncClient) -> Pipeline:
    primary = _provider(settings.vision_provider, settings, client)
    fallback = _provider(settings.vision_fallback, settings, client)
    vision = VisionService(primary, fallback if fallback and fallback.name != primary.name else None)
    return Pipeline(settings, db, make_storage(settings, db), vision)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        db = Database(settings.database_url.get_secret_value(), settings.db_pool_min, settings.db_pool_max,
                      pgbouncer=settings.db_pgbouncer)
        await db.connect()
        client = httpx.AsyncClient(follow_redirects=False)
        pipeline = build_pipeline(settings, db, client)
        broadcaster = Broadcaster(db)
        await broadcaster.start()
        app.state.settings, app.state.db, app.state.pipeline = settings, db, pipeline
        app.state.storage, app.state.broadcaster = pipeline.storage, broadcaster
        app.state.calendar = GoogleCalendar(settings, db, client)
        app.state.verifier = TokenVerifier(settings)
        app.state.worker = Worker(db, pipeline.handlers, settings.worker_concurrency)
        worker_task = asyncio.create_task(app.state.worker.run()) if settings.run_worker_in_process else None
        log.info("startup env=%s timescale=%s vision=%s/%s auth=%s", settings.env, db.timescale,
                 settings.vision_provider, settings.vision_fallback, settings.auth_mode)
        try:
            yield
        finally:
            if worker_task:
                app.state.worker.stop()
                worker_task.cancel()
                with suppress(asyncio.CancelledError):
                    await worker_task
            await broadcaster.stop()
            await client.aclose()
            await db.close()

    app = FastAPI(title="Agora API", version="0.1.0", lifespan=lifespan,
                  docs_url="/docs" if settings.env != "prod" else None, redoc_url=None)
    app.add_exception_handler(Problem, handle_problem)
    app.add_exception_handler(RequestValidationError, handle_validation)

    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=False,
                           allow_methods=["GET", "POST", "PATCH", "DELETE"],
                           allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])

    max_body = settings.max_video_bytes + 1024 * 1024

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        request.state.request_id = request.headers.get("x-request-id", "")[:64] or uuid.uuid4().hex
        length = request.headers.get("content-length")
        if length and length.isdigit() and int(length) > max_body:
            return problem_response(request, 413, "request_too_large", "Request body is too large.")
        started = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            log.exception("request.unhandled id=%s", request.state.request_id)
            response = problem_response(request, 500, "internal_error", "Something went wrong. Try again.")
        # Paths only: query strings can carry identifiers and are never logged.
        log.info("%s %s %s %.0fms id=%s", request.method, request.url.path, response.status_code,
                 (time.perf_counter() - started) * 1000, request.state.request_id)
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        response.headers.setdefault("Cache-Control", "no-store")
        return response

    @app.get("/healthz", tags=["ops"])
    async def healthz() -> dict:
        return {"ok": True}

    @app.get("/readyz", tags=["ops"])
    async def readyz(request: Request) -> dict:
        async with request.app.state.db.raw() as conn:
            await conn.fetchval("SELECT 1")
        return {"ok": True, "timescale": request.app.state.db.timescale, "version": app.version}

    for router in (account.router, inventory.router, merchants.router, scans.router, events.router,
                   audit.router, calendar.router):
        app.include_router(router)
    return app


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


class RedactAccessQuery(logging.Filter):
    """Uvicorn's default access logger otherwise records OAuth codes and state in query strings."""
    def filter(self, record):
        if isinstance(record.args, tuple) and len(record.args) == 5:
            client, method, path, version, status = record.args
            record.args = (client, method, str(path).split("?", 1)[0], version, status)
        return True


logging.getLogger("uvicorn.access").addFilter(RedactAccessQuery())
