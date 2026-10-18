# Pending PR integration handoff

Updated October 17, 2026 (America/Los_Angeles). Read this before resuming older feature branches.

## Password-first demo access

[PR #17](https://github.com/saharshBhargava/agora/pull/17) merged as
`f65cf0eccd2da9661f2d1220e861cbd9ff765997` and was deployed to Render on October 17 at 8:36 PM PDT.
[PR verification](https://github.com/saharshBhargava/agora/actions/runs/39093773083): 24 iOS tests passed
and the onboarding screenshot was captured; backend Postgres 17, TimescaleDB and image checks passed.
Locally, 238 backend tests and the required dev demo reset passed. The live password-only smoke check
verified login, profile, 12 inventory items, three private Calendar events and availability, with anonymous
profile access rejected (401). No Google or model-provider credentials were used in that check.


The sample account now signs into iOS using username `demo` and the existing Render
`AGORA_DEMO_PASSWORD`. Google is an optional alternate entry. Do not restore a mandatory Google-only gate.
`CalendarConnection` owns the verified account session; `AgoraClient` asks it for the appropriate Bearer
credential. Password sessions are origin-bound in Keychain. Never commit the password or add provider keys
for the sample account. `users.is_demo` remains server-only and is not exposed in profile responses.

Migration `0013_calendar_events.sql` stores the private account calendar. Seed/reset/backfill include realistic
events; old `/v1/calendar` routes also dispatch demo requests internally so they cannot reach Google.
Native sample chat/captions/recognition use the built-in ModelClient; server scans select built-in vision
per user. Ordinary accounts retain their real providers. Built-in recognition provenance is denied for
ordinary users. The iOS CI job builds and runs auth/transport tests on a simulator.

## Forecasts and shopping lists — PR #9

Current main includes the dedicated demo account from PR #11. The forecast branch now incorporates it and
backfills forecasts and a realistic shopping list for an existing demo account without resetting its history.
The demo coverage test remains mandatory for every new household/user table.

The unmerged forecast migrations were renamed from `0007_forecasts*` to `0010_forecasts*`, after main's
`0009_demo_account.sql`. Do not restore the old migration names or edit any migration once merged. An old
branch-local development database that already ran `0007_forecasts*` must be recreated before using the
renamed files; never apply both sets against the same database.

API contract: [forecasts and lists](api/forecasts-and-lists.md). UI requirements remain in
[frontend requests](frontend-requests.md). Sync from origin/main before continuing feature work; do not
overwrite the consolidated Google ID-token AgoraClient with the deleted AgoraAPIClient implementation.

PR #9 merged as `1dba30f400825000a07ec78ee4fb24b09e254d07`. Validation: 136 tests passed against local
Postgres 16; GitHub's Postgres 17, TimescaleDB 17 and Docker image jobs all passed on integration head `1db59a5`.

## Agent commerce — PR #10

The commerce integration includes current main, forecasts/lists, the dedicated demo account, and hosting
handoff PR #12 (`66e63cd98f4ec91de7e264552357b9ac75492dae`).
[PR #10](https://github.com/saharshBhargava/agora/pull/10) merged as
`b218ca8684a3c7c7a1d8400a6a4398825b0e438b`. Its final head `a2d59bd` and the merge commit both passed
Postgres 17, TimescaleDB 17 and Docker CI. No original pending PR remains open.

Migration mapping for old commerce branches:

| Old unmerged migration | Final migration |
|---|---|
| `0007_agent_commerce.sql` | `0011_agent_commerce.sql` |
| `0008_spend_hypertable.timescale.sql` | `0012_spend_hypertable.timescale.sql` |

Recreate branch-local development databases that used the old names; do not run both migration sets.
Merged migration files must remain immutable. Hosted databases that already have `0010` need only the new
commerce migrations and `app.tools.demo ensure` (normal hosted boot runs migrations and seed automatically).
Do not reset the hosted demo to add these features.

Behavior changes that resumed agents must preserve:

- `ensure_demo_account` backfills new commerce data without resetting earlier inventory/history. It adds a
  realistic mandate, monthly budget, purchase/spending history and an approval waiting for the user.
- Server checkouts simulate payments only when `users.is_demo` is true. Ordinary accounts get
  `503 payments_unavailable` until a real provider exists; no simulated order or spend is recorded.
  The demo always uses simulation, even if a real provider is configured later. No payment credentials are
  needed for the current release.
- Hosted `app.seed` creates only the catalog and the single designated demo account. The old `kedar` and
  `saharsh` synthetic histories are local dev/test only. Ordinary Google accounts remain empty.
- Pause/resume publish `agent.updated` for the user ID even without changed intents. Refresh agent state
  when handling these events. API examples captured with legacy `kedar` credentials are illustrative;
  use the designated demo identity for simulated checkout.
- Current client integration stays on `Agora/API/AgoraClient.swift` using Google ID tokens. Read the
  [frontend hosting handoff](frontend-handoff.md) for current deployment status and client configuration.

Local validation: all **193 tests passed** against Postgres 16, Ruff passed, and
`uv run --no-sync python -m app.tools.demo reset` succeeded against a fresh, isolated local database.
GitHub checks must pass on the final PR head before merge; the required matrix covers Postgres 17,
TimescaleDB 17, and the deploy Docker image. No hosted database was reset during PR validation.

After merge, the owner-authorized hosting setup applied `0011`/`0012` to Tiger and backfilled the designated
demo account without a reset. The demo has a mandate, four intents, a budget, three orders and three spend
entries in addition to its existing inventory/list history. Read-only API checks against Tiger passed for
all new commerce read endpoints. Render is now deployed and verified publicly; native Google sign-in still
needs device testing. See the [deployment record](frontend-handoff.md#current-deployment-record).

The original sleeping forecast and commerce checkouts were left intact at their earlier local commits.
Before resuming one, inspect its local changes, fetch origin, and integrate current main using the team's
normal workflow. Do not push an old branch as a replacement for main or reapply the renamed migrations.

## Render build-path correction

The first Render build of `99fadec` failed before Docker ran: its effective context was `backend/backend`.
Keep `rootDir: backend`, with `dockerfilePath: ./Dockerfile` and `dockerContext: .`. Those Docker paths are
relative to the service root, despite the generic Blueprint reference's repo-root wording. Do not restore
the old `./backend/...` paths. The image CI job now reads and builds from `render.yaml` using
`.github/scripts/build_render_image.py`, so an invalid effective path fails before deployment.
This change does not alter secrets, migrations or demo data.

## Live hosting and frontend configuration

The Blueprint was manually synced and approved, and Render successfully deployed `d6bac9d` at
`https://agora-api-yq3m.onrender.com`. Public readiness/docs/schema and actual demo-password login plus
authenticated inventory/list/forecast/commerce reads were verified October 17, 2026. Unauthenticated
requests correctly return 401. The keep-warm workflow variable is configured and its manual run passed.

`Config/Agora.xcconfig` now supplies the public team API URL by default. Resumed frontend agents should
pull main, remove stale local URL overrides, and rebuild. Do not blank the shared API URL or restore old
deployment paths. See [frontend-handoff.md](frontend-handoff.md) for a ready-to-send teammate message and
the remaining Google test-user/demo-email/device-key setup. Secrets remain in Render; none were committed.


## Wishlist and suggestion integration

Wishlist UI, model-backed ideas and six-hour replenishment jobs include the password-only demo changes.
The new refresh-state migration is `0014_wishlist_refresh.sql`; `0013_calendar_events.sql` is already
merged and must not be renamed. Demo backfill preserves both Calendar events and shopping refresh state.
The built-in, server-verified demo model also supports Shopping suggestions without external model calls.
