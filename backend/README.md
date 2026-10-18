# Agora backend

> **Deploying for the demo?** Follow [SETUP.md](../SETUP.md): every account and key, in order, all free.

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

All routes are under `/v1` and need `Authorization: Bearer <token>`. Scan uploads and agent wishlist
suggestions need an `Idempotency-Key` header. Errors are RFC 7807 `application/problem+json`.

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
| `GET /inventory/{id}?days=30` | Daily gap-filled series, raw observations with provenance, run-out forecast |
| `PATCH /inventory/{id}`, `POST /inventory/{id}/observations` | Edit item; record a manual count |
| `GET /wishlist`, `POST /wishlist` | Household wishlist as a priority queue (score + reasons); manual add |
| `POST /wishlist/suggestions` | Agent suggestion (rationale + confidence, `Idempotency-Key`); refuses recent rejections |
| `POST /wishlist/{id}/accept\|reject\|snooze\|purchased`, `PATCH`, `DELETE` | Suggestion decisions and item lifecycle |
| `POST /wishlist/{id}/feedback`, `GET /wishlist/agent-context` | Thumbs up/down; feedback summary for the on-device agent |
| `GET /forecasts/runouts?within=7d` | What runs out soon, with interval, explanation and suggested store |
| `GET /lists`, `POST /lists`, `GET\|PATCH /lists/{id}` | Shopping lists (archived, never deleted) |
| `POST /lists/{id}/items`, `PATCH\|DELETE /lists/{id}/items/{id}` | List lines; agent lines must carry an explanation |
| `POST /lists/generate` | Per-store lists from upcoming run-outs (`Idempotency-Key`) |
| `GET /events` | Server-Sent Events: `scan.updated`, `inventory.updated`, `wishlist.updated`, `forecast.updated`, `list.updated` (IDs only; refetch) |
| `GET /audit`, `GET /audit/verify` | Your audit trail; hash-chain integrity check |
| `GET /merchants?q=`, `POST /merchants`, `GET /merchants/{id}` | Store search and find-or-create (see [docs/api/purchased-from.md](../docs/api/purchased-from.md)) |
| `PATCH /scans/{id}`, `PATCH /scans/{id}/detections/{id}` | Change or clear an upload's or one product's store |

Wishlist contract, lifecycle and scoring: [docs/api/wishlist.md](../docs/api/wishlist.md). Forecasting method and
lists: [docs/api/forecasts-and-lists.md](../docs/api/forecasts-and-lists.md). UI work waiting on the
frontend team: [docs/frontend-requests.md](../docs/frontend-requests.md).

## Where things live

```
app/main.py           app factory, middleware (request IDs, security headers, body limit)
app/auth.py           dev HMAC tokens / OIDC JWKS verification, first-login bootstrap
app/db.py             pool; scoped() = per-request role + row-level security; audit + notify helpers
app/pipeline.py       scan job: frames → vision → merge → match → review/auto-commit → media purge
app/core/             pure logic (merging, quantities, auto-accept rules, wishlist scoring, forecasting), unit-tested
app/forecasting.py    forecast jobs: refresh after each confirmed scan, nightly fan-out, stored history
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
| Auth | Google ID tokens from the iOS app (`AGORA_AUTH_MODE=google`), plus dev tokens for the seeded accounts in `AGORA_ENV=demo` | No | Uses the existing iOS OAuth client; no server-side Google secrets |

Steps (the full walkthrough, including Google sign-in, is in [SETUP.md](../SETUP.md)):

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

## Native Google Calendar onboarding and Gemini tools

Calendar now runs directly in the iOS app using Google's **GoogleSignIn / GoogleSignInSwift 9.2.0 SDK**
and Google Calendar REST API. Each user signs into Google and grants Calendar access during onboarding.
A deployed Agora backend is **not required for Calendar or chat**. Google access/refresh tokens stay under
SDK management on the device; they are never sent to Gemini or the inventory backend.

### One-time Google Cloud setup

The shared Agora iOS client is configured in `Config/Agora.xcconfig`. Existing project users can build
with those defaults; while Google OAuth is in Testing, their sign-in account must be added as a test user.
For a separate Google Cloud project, follow these steps and override the client locally:

1. Create or select a Google Cloud project and enable **Google Calendar API**.
2. Under **Google Auth Platform**, configure Branding, Audience and Data Access. If the app is External and
   in Testing, add your own Google account and other testers under **Test users**.
3. Add these requested Calendar scopes:
   - `https://www.googleapis.com/auth/calendar.events`
   - `https://www.googleapis.com/auth/calendar.freebusy`
4. Under **Clients**, create an OAuth client of type **iOS** with bundle ID **`dev.agora.browserchat`**.
   Use the app's signing Team ID if Google asks for it. No Web client, client secret, backend callback URL,
   or token encryption key is needed for this native Calendar flow.
5. Copy `Config/Local.xcconfig.example` to **`Config/Local.xcconfig`** (gitignored) and replace both values:

   ```xcconfig
   AGORA_GOOGLE_IOS_CLIENT_ID = YOUR_CLIENT_ID.apps.googleusercontent.com
   AGORA_GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.YOUR_CLIENT_ID
   ```

   For example, `123456789-abc.apps.googleusercontent.com` becomes
   `com.googleusercontent.apps.123456789-abc`. These are public identifiers, not secrets. The checked-in
   `Config/Agora.xcconfig` loads this optional local file for both Debug and Release, and `Agora/Info.plist`
   expands the values into `GIDClientID` and `CFBundleURLSchemes`. CI uses the shared defaults unless overridden.
6. Open the project, allow Swift Package Manager to resolve dependencies, rebuild and run. Sign in with
   Google and approve both Calendar permissions. The SDK handles callback validation, credential storage,
   restoration and token refresh. The app remains in onboarding if access is cancelled or only partially granted.
7. Add the existing Gemini API key under **Settings → Connected accounts** and try:
   **“Find a free half hour tomorrow afternoon and add a grocery run.”**

An unconfigured build shows that Google sign-in needs setup and disables the sign-in button; waiting or
retrying won't fix missing configuration. Live Calendar authorization and event creation still need to be
verified with an approved test account. Google's external Testing mode can expire Calendar grants after seven days;
complete the applicable OAuth verification/publishing steps for public distribution.

### Behavior and limits

Gemini receives `calendar_freebusy` and `calendar_create_event`. Availability and event requests go from
the phone to `https://www.googleapis.com/calendar/v3/`. Agora displays the exact event details before saving.
The phone validates timestamp offsets against IANA timezone/DST rules, bounds availability to 31 days,
and uses deterministic event IDs plus request fingerprints to recover retries without duplicate events.
An uncertain write stops the agent and asks the user to inspect Google Calendar before retrying. Account
changes invalidate pending approvals. No Calendar credentials enter model messages, logs or event data.

The initial tools support the **primary calendar**, timed events, optional location/description, and no
attendees/invitations. Recurring events, secondary calendar selection, editing/deleting events and autonomous
server scheduling are not implemented. Settings provides reconnect, local sign-out and Google disconnect
(revocation). Existing events remain after disconnecting.

### Optional inventory backend

The Home screen's inventory feature uses `AgoraAPIClient`, separately from `CalendarConnection`.
Leaving the backend unconfigured displays an inventory availability message and does not block Calendar.
To enable inventory, deploy the existing FastAPI/Postgres service and configure:

```dotenv
AGORA_AUTH_MODE=google
AGORA_GOOGLE_IOS_CLIENT_ID=YOUR_CLIENT_ID.apps.googleusercontent.com
```

In `Config/Local.xcconfig`, add:

```xcconfig
AGORA_API_BASE_URL = https:/$()/YOUR_API_HOST
```

The `$()` is intentional: it prevents xcconfig from treating `//` as a comment, and expands to an empty string.
The app sends a freshly obtained **Google ID token** to this backend only. The backend checks Google's JWT
signature, issuer, audience, authorized party and expiration against the configured iOS client ID. It maps
Google's stable subject to the same Agora user as the earlier server OAuth flow. Inventory failures do not
sign the user out of Calendar. Run migrations before starting the service, as described above.

### Earlier server-side Calendar implementation

The backend's `/v1/integrations/google/*`, `/v1/calendar/*` routes and migration remain available for existing
clients, but the iOS app no longer calls them. They require the legacy `AGORA_GOOGLE_CLIENT_ID`,
`AGORA_GOOGLE_CLIENT_SECRET`, `AGORA_GOOGLE_REDIRECT_URI`, and `AGORA_GOOGLE_TOKEN_KEY` settings. Native
Calendar does not read or migrate the old `app.agora.account` Keychain session; existing users sign into the
native Google SDK once. If you previously deployed server-side Calendar and want to retire it, revoke/remove
those legacy connections using the existing backend flow before removing its secrets. Native disconnect
revokes the grants associated with the native Google client.

### Validation

`AgoraTests/CalendarTests.swift` tests native auth restoration/partial consent/cancellation, missing client
configuration, direct Calendar calls, account changes, approval, timezone validation, retry recovery and
separation of inventory identity tokens from Calendar access tokens using mocked Google responses.
`backend/tests/test_native_google_auth.py` validates signed native ID tokens, rejects mismatched claims and
signatures, preserves existing Google account IDs, and tests inventory isolation on real Postgres.
A real Google sign-in and event creation still need the Google Cloud setup above.

References: [Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating),
[Google APIs from iOS](https://developers.google.com/identity/sign-in/ios/api-access),
[Backend identity verification](https://developers.google.com/identity/sign-in/ios/backend-auth).
