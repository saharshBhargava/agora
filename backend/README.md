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
| `GET /merchants?q=`, `POST /merchants`, `GET /merchants/{id}` | Store search and find-or-create (see [docs/api/purchased-from.md](../docs/api/purchased-from.md)) |
| `PATCH /scans/{id}`, `PATCH /scans/{id}/detections/{id}` | Change or clear an upload's or one product's store |

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

## Deploy

Everything is configured by environment variables and runs from one Docker image, so any host that can run a
container and any Postgres 14+ will work. Moving hosts means moving env vars; nothing in the code changes.

### Default setup: no credit card anywhere

| Piece | Service | Card? | Notes |
|---|---|---|---|
| Database | Tiger Cloud **Free** plan | No | 2 free services, 750 MiB each, TimescaleDB included. (A separate 30-day trial also needs no card.) |
| API + worker | Render **free** web service via `render.yaml` | No | Sleeps after ~15 idle min, ~1 min to wake. 750 free hours/month covers one service 24/7 |
| Media | Postgres itself (`AGORA_STORAGE_BACKEND=db`) | n/a | Frames are small and deleted after review, so there's no bucket to set up |
| Vision | Gemini API key from AI Studio | No | Free tier. Perceptron is used instead if the sponsor gives us a key |
| Auth | Built-in dev tokens (`AGORA_ENV=demo`) | n/a | No identity-provider account needed for the demo |

Steps:

1. Tiger Cloud: create a **Free** service and copy the connection string (`postgres://tsdbadmin:...?sslmode=require`).
2. Render: **New > Blueprint**, pick this repo. Render reads `render.yaml`. Paste the Tiger URL into
   `AGORA_DATABASE_URL` and, optionally, a Gemini key into `AGORA_GEMINI_API_KEY`.
3. Deploy. On boot the container runs migrations, seeds the demo accounts (`AGORA_SEED_ON_BOOT=true`), and starts.
   Check `https://<service>.onrender.com/readyz`: it reports `"timescale": true` on Tiger.
4. Before judging, open `/healthz` once to wake the service. Optionally point a free uptime pinger at it every
   5 minutes to keep it warm.

### Switching when something runs out

| If this runs out | Switch to | What changes |
|---|---|---|
| Tiger free storage / trial | Neon or Supabase free Postgres, or local Docker | `AGORA_DATABASE_URL` only. Timescale migrations are skipped and plain-SQL queries take over automatically. Use the **direct** (non-pooled) URL; if you must use a pooler, also set `AGORA_DB_PGBOUNCER=true` (live sync then falls back to polling) |
| Render hours | Railway, Koyeb, Fly.io (`fly.toml`), Cloud Run, a laptop | Same image; it listens on `$PORT` when the host sets one, otherwise 8080 |
| Gemini / Perceptron quota | The other provider, or `replay` | `AGORA_VISION_PROVIDER` / `AGORA_VISION_FALLBACK`. A provider with no key degrades to replay with a warning, so a missing key can't crash a deploy |
| Need a bucket after all | Any S3-compatible store (R2, B2, Supabase Storage, MinIO) | `AGORA_STORAGE_BACKEND=s3` + `AGORA_S3_*` |
| No host at all | Laptop + `cloudflared tunnel --url http://localhost:8000` | Free, no account. Gives an HTTPS URL a physical iPhone can reach |

The database URL is read from `AGORA_DATABASE_URL`, or from `DATABASE_URL` when a host injects that name.

## Google Calendar onboarding and Gemini tools

Agora now uses first-party Google OAuth and the Calendar API. The iOS onboarding screen requires a Calendar
connection and uses the Google identity to create/sign into an Agora account. No MCP service or third-party
connector is involved. The integration is implemented but requires your own Google Cloud configuration;
no credentials or deployed API URL are included in the repository.

### Configure Google and the backend

1. In your Google Cloud project, enable **Google Calendar API**. Configure Google Auth Platform branding,
   audience and consent. For development, add each tester under **Test users**.
2. Create an OAuth client of type **Web application**. Register the exact HTTPS redirect URI:
   `https://YOUR_API_HOST/v1/integrations/google/callback`.
   Google returns to the backend, which forwards the authorization code to the iOS authentication session.
   This implementation uses `ASWebAuthenticationSession` and a confidential web client; it does not need
   the Google Sign-In SDK or a separate iOS OAuth client.
3. Request these scopes: `openid`, `email`, `https://www.googleapis.com/auth/calendar.events`, and
   `https://www.googleapis.com/auth/calendar.freebusy`. Users must grant both Calendar permissions.
4. Set backend secrets/configuration:

   ```dotenv
   AGORA_AUTH_MODE=google
   AGORA_GOOGLE_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
   AGORA_GOOGLE_CLIENT_SECRET=YOUR_WEB_CLIENT_SECRET
   AGORA_GOOGLE_REDIRECT_URI=https://YOUR_API_HOST/v1/integrations/google/callback
   AGORA_GOOGLE_TOKEN_KEY=BASE64_ENCODED_32_BYTE_RANDOM_KEY
   ```

   Generate the encryption key once with `openssl rand -base64 32`. Keep it stable across deployments and
   back it up securely. Changing it without re-encrypting stored tokens requires users to reconnect.
   All four Google settings are validated together. `AGORA_ENV=prod` supports `AGORA_AUTH_MODE=google`.
   If using the existing Fly configuration, override its `AGORA_AUTH_MODE=dev` with `google`.
5. Apply migrations with `uv run python -m app.migrate` (Docker already runs migrations at startup), then
   restart the API. Ensure your reverse proxy and observability tooling do not log query strings on the
   OAuth callback. Agora redacts query strings in Uvicorn access logs and returns `Cache-Control: no-store`.
6. For public rollout, complete Google's OAuth verification as required by the requested scopes. Google
   Calendar authorization on an external OAuth app in **Testing** typically expires after seven days;
   publishing/verification is needed for a lasting public onboarding experience.

### Configure and run iOS

In the Agora target's Xcode **Build Settings**, set the user-defined `AGORA_API_BASE_URL` to the HTTPS API
origin, e.g. `https://YOUR_API_HOST`, for each build configuration. It is intentionally empty by default.
`Agora/Info.plist` includes that setting and the `dev.agora.browserchat` callback scheme. Do not put the
Google client secret or encryption key in the app. Use an HTTPS development endpoint reachable by both
Google and the phone/simulator. The project generator preserves the required plist configuration; set the
API URL again after generating a fresh project.

Run the app, choose **Connect Google Calendar**, select a Google account and approve permissions. Cancelled
or partially granted authorization leaves onboarding incomplete. Under **Settings → Connected accounts**,
users can reconnect, sign out, or disconnect/revoke access. Disconnect also invalidates their Agora sessions;
existing Google Calendar events remain. Sign out removes only the current Agora session. Sessions expire
at 30 days, after which the user signs in again. Google access tokens are refreshed independently of Agora sessions.

After adding the existing Gemini API key in Settings, try:

> Find a free half hour tomorrow afternoon and add a grocery run.

Gemini receives `calendar_freebusy` and `calendar_create_event`. It resolves relative dates using the device
clock/timezone. Agora shows the exact title, start/end, timezone, location and description before creating
an event. The API validates timestamps and DST offsets. The initial implementation supports the user's
**primary calendar**, timed events, and no attendees/invitations. Editing, deleting, recurring events and
secondary calendar selection are not implemented.

### API and security

- `POST /v1/integrations/google/start`: creates expiring OAuth state bound to a device-generated PKCE challenge.
  A signed-in reconnect is also bound to the current Agora account.
- `GET /v1/integrations/google/callback`: validates state and returns to the system authentication session.
- `POST /v1/integrations/google/exchange`: consumes state once, exchanges the code using PKCE, verifies Google
  identity and required scopes, and issues a random Agora session token. The phone stores it in Keychain;
  the database stores only its SHA-256 hash. Google credentials never enter the Gemini conversation.
- `GET /v1/integrations/google`: connection status for the authenticated user.
- `DELETE /v1/integrations/google`: revokes Google access and removes the connection and Agora sessions.
- `POST /v1/auth/logout`: revokes the current Agora session.
- `POST /v1/calendar/freebusy`: accepts offset-aware `start`, `end`, and IANA `timezone`; max window 31 days.
- `POST /v1/calendar/events`: additionally accepts `title`, optional `description`/`location`, `confirmed: true`,
  and an `Idempotency-Key` header. The native app sets confirmation only after the user approves; it is not a
  model argument. As with any authenticated client API, the server trusts the client to capture confirmation.
  Google event IDs are derived from the user and request key. Retries recover the existing event and reject
  mismatched payloads. An uncertain result stops the agent and asks the user to check Calendar.

Refresh tokens use AES-256-GCM with user ID as authenticated associated data. Connection rows have row-level
security; session/state tables are restricted to the authentication service. The backend never stores the
user's calendar contents. Audit records contain action names and event IDs only.

Validation: `AGORA_TEST_DATABASE_URL=postgresql://... uv run pytest -q` exercises real Postgres isolation,
PKCE/state replay, permissions, event retries, revocation, session expiry and validation with mocked Google
HTTP responses. `AgoraTests/CalendarTests.swift` covers native callback validation, tool validation and the
Gemini approval/execution loop. A real Google sign-in and event creation still require configured credentials.

References: [Google web-server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server),
[Calendar event creation](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert),
[Calendar free/busy](https://developers.google.com/workspace/calendar/api/v3/reference/freebusy/query).
