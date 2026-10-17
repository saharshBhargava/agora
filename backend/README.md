# Agora backend

FastAPI + Postgres (TimescaleDB when available). Design and rationale: [docs/backend-spec.md](../docs/backend-spec.md).

This is the **P0 spine**: dev auth, households, scan upload → vision → review → inventory time series, live sync,
audit trail, seed data, and offline replay for demos.

## Run locally

```bash
cd backend
docker compose up -d          # TimescaleDB on 127.0.0.1:5433 (same image family as Tiger Cloud)
uv sync
cp .env.example .env
uv run python -m app.seed     # migrates, then seeds catalog + 3 weeks of history for kedar / saharsh
uv run uvicorn app.main:create_app --factory --reload
```

Open http://localhost:8000/docs for the interactive API. To get a token:

```bash
curl -s -X POST localhost:8000/v1/dev/login -H 'content-type: application/json' -d '{"handle":"kedar"}'
```

Any Postgres 14+ works as well. Without TimescaleDB the `*.timescale.sql` migrations are skipped and time-series
queries use the plain-SQL implementation (`/readyz` reports which engine is active).

## Tests

```bash
AGORA_TEST_DATABASE_URL=postgresql://agora:agora-dev-only@127.0.0.1:5433/agora uv run pytest
```

Each run creates and drops its own database. CI runs the suite against both `timescaledb-ha:pg17` and
`postgres:17`.

## Vision providers

| `AGORA_VISION_PROVIDER` | Needs | Notes |
|---|---|---|
| `replay` (default) | nothing | Serves `seed/replay/<sha256>.json` fixtures. Unknown frames fail with `no_replay_fixture` |
| `perceptron` | `AGORA_PERCEPTRON_API_KEY` | `perceptron-mk1.5`, JSON-schema constrained output |
| `gemini` | `AGORA_GEMINI_API_KEY` | Good as `AGORA_VISION_FALLBACK` |

Every result is cached per household by frame hash, so re-running a scan never re-bills the provider. To make a
demo wifi-proof: run the demo scans once with a real provider, then
`uv run python -m app.tools.export_replay`, commit `seed/replay/`, and switch to `replay`.

## API (P0)

All routes are under `/v1` and need `Authorization: Bearer <token>`. Mutating scan uploads need an
`Idempotency-Key` header. Errors are RFC 7807 `application/problem+json`.

| Route | What it does |
|---|---|
| `POST /dev/login` | Dev/demo token (only seeded handles when `AGORA_ENV=demo`) |
| `GET /me`, `PATCH /me/settings` | Profile, households, retention and autonomy settings |
| `GET /households`, `POST /households/{id}/locations` | Households and storage locations |
| `POST /scans` | Multipart upload: up to 12 photos or one MP4/MOV. Returns 202; processing is async |
| `GET /scans`, `GET /scans/{id}` | Status plus detections with confidence, boxes (0-1000 grid) and matches |
| `GET /scans/{id}/frames/{n}` | Sanitized frame for the review UI (410 once retention deletes it) |
| `POST /scans/{id}/review` | Accept / correct / reject detections; only those reach inventory |
| `GET /inventory`, `POST /inventory` | Items with latest quantity; manual add |
| `GET /inventory/{id}?days=30` | Daily gap-filled series + raw observations with provenance |
| `PATCH /inventory/{id}`, `POST /inventory/{id}/observations` | Edit item; record a manual count |
| `GET /events` | Server-Sent Events: `scan.updated`, `inventory.updated` (IDs only; refetch) |
| `GET /audit`, `GET /audit/verify` | Your audit trail; hash-chain integrity check |

## Where things live

```
app/main.py           app factory, middleware (request IDs, security headers, body limit)
app/auth.py           dev HMAC tokens / OIDC JWKS verification, first-login bootstrap
app/db.py             pool; scoped() = per-request role + row-level security; audit + notify helpers
app/pipeline.py       scan job: frames → vision → merge → match → review/auto-commit → media purge
app/core/             pure logic (merging, quantities, auto-accept rules), unit-tested
app/vision/           provider contract, output validation, Perceptron / Gemini / replay, cache
app/timeseries.py     Timescale and plain-Postgres implementations of the same queries
app/jobs.py           Postgres job queue (SKIP LOCKED, LISTEN/NOTIFY wake-ups, backoff)
migrations/           numbered SQL; *.timescale.sql only runs where TimescaleDB exists
```

## Security model in one screen

- Each request runs as the `agora_rw` role with `app.user_id` set. Postgres row-level security restricts every
  household table, so a missed `WHERE` clause still can't leak another household's data. The worker uses the
  same scoping.
- `agora_rw` can only `INSERT`/`SELECT` the audit log. Each row hashes its predecessor; `/v1/audit/verify`
  catches edits and deletions (not truncation of the newest rows).
- Uploads are decoded and re-encoded, which strips EXIF/GPS and refuses non-images and decompression bombs. Videos
  are split into frames and the original is deleted. Frames are deleted after review by default.
- Model output is schema-validated and clamped; it is data, never instructions. Provider error bodies are never
  logged. Request logs contain paths only, with no query strings or bodies.
- `AGORA_ENV=prod` refuses dev auth. `AGORA_ENV=demo` requires a non-default token secret and only signs in seeded
  accounts.

## Deploy (Fly.io + Tiger Cloud + R2)

1. Create a Tiger Cloud service and copy its connection string.
2. Create a private R2 bucket and an access key scoped to it.
3. Run `fly launch --no-deploy --copy-config`, set the secrets listed at the top of `fly.toml`, then `fly deploy`.
4. Seed once with `fly ssh console -C "python -m app.seed"`.
