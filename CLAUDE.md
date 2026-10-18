# Agora: working rules for agents

Agora is a hackathon app: an iOS SwiftUI client (`Agora/`) and a FastAPI + Postgres/TimescaleDB backend
(`backend/`). **Before coding, including after a pause, read [docs/current-state.md](docs/current-state.md)
and [docs/pr-handoff.md](docs/pr-handoff.md), fetch origin, and reconcile your checkout with `origin/main`.**
Inspect and preserve local changes before merging/rebasing. Never replace main with an older feature branch,
hard-reset another agent's checkout, or reapply work that is already merged.

Documentation map:

- [Current state](docs/current-state.md): verified baseline, resume checklist, implementation versus backlog.
- [Deployment](docs/deployment.md): live Render/Tiger configuration, automatic updates, recovery limits and access.
- [Frontend handoff](docs/frontend-handoff.md): API URL, exact sign-in procedure and credential locations.
- [SETUP.md](SETUP.md): recreating the environment and optional local fallback; not a request to recreate live services.
- [backend/README.md](backend/README.md): code layout, API overview, local development and tests.
- [API contracts](docs/api/) and [frontend requests](docs/frontend-requests.md): implemented APIs versus UI/planned work.
- [Backend spec](docs/backend-spec.md): design/roadmap, including unimplemented proposals; not a deployment manifest.
- [Dibs README](docs/dibs/README.md): the separate shared-grocery-run app in `ios/`, `server/`, `web/` (see "Dibs" below).

## Shipping to production (continuous delivery)

Merging to `main` **is** the release. Read [docs/deployment.md](docs/deployment.md) before backend or DB work.

- A green `backend` CI run on main triggers `.github/workflows/deploy.yml`: Render builds that commit, new
  migrations apply on boot, `/readyz` gates traffic, read-only smoke checks run, and a failing release is
  rolled back automatically. Failed builds or boots never replace the running release.
- **After merging backend work, check the deploy run (`gh run watch` / `gh run list --workflow deploy.yml`)
  before saying you're done.** If it's red, fixing it is your job: fix forward with a new PR. Production
  keeps serving the last good release meanwhile.
- Anyone with write access can operate production from GitHub, with no Render or Tiger login:
  `gh workflow run deploy.yml -f action=status|deploy|rollback|restart` (deploy/rollback accept `-f ref=<sha>`).
  Don't ask the owner to click things in Render for routine releases.
- `/readyz` reports the running `commit` and `migrations.pending`. Trust it, not the newest GitHub SHA, for
  what is live.
- **Migrations must be backward compatible** with the release still serving: additive only (new tables,
  nullable or defaulted columns, indexes, backfills). Drops, renames, type changes, `SET NOT NULL` and deletes
  need expand → contract across two releases, with `-- agora: allow-breaking <reason>` on the contract step.
  The PR's `release-rehearsal` job enforces this and proves the previous release still runs on your schema.
- Keep CI and Render usage lean: no preview environments or extra Render services (they share 750 free
  hours), no new frequent schedules, and no smoke checks that write to production.
- Backups run daily (`db-backup`, encrypted). Restoring and the laptop fallback are in docs/deployment.md.

## Preserve the current integration

- The hosted API is `https://agora-api-yq3m.onrender.com`; `Config/Agora.xcconfig` already sets the shared
  origin. Do not blank it or commit a developer's tunnel/local override.
- Demo onboarding is **username `demo` + the private Render `AGORA_DEMO_PASSWORD`**, with Google optional.
  Do not restore the old mandatory Google gate or require real Google/model credentials for this account.
- `CalendarConnection` owns account/session selection; `Agora/API/AgoraClient.swift` obtains the appropriate
  demo Bearer session or Google ID token. Do not resurrect the deleted competing `AgoraAPIClient`.
- Preserve the model abstraction (`Agora/Models/`), Gemini/OpenAI-compatible routing for ordinary users,
  and server-verified built-in demo responses. Keep inventory recognition details/validation and provider provenance.
- Keep the HS256 subject allowlist in `backend/app/auth.py`: demo/dev tokens cannot impersonate `google:*` users.
- Preserve payment idempotency across transaction rollback: proposal charges use the stable user + client
  `Idempotency-Key`; an existing intent's approval uses its persisted ID. See the commerce API contract.
- Do not reset/import over the hosted database to reconcile a branch or refresh data. Normal boot applies new
  migrations and additive demo backfills. Use reset/import only against an explicitly disposable local target,
  unless the user specifically authorizes a hosted destructive operation.

## Keep the demo account current (required)

There is exactly one demo account (`backend/app/demo_account.py`). The team demos the app by signing in to it,
so it must always look like a real, fully used account in every feature.

- **When you add or change a feature that stores household or user data, extend `_seed` in
  `backend/app/demo_account.py` with realistic rows for it**, in the same PR. `tests/test_demo_account.py` fails
  if any household/user-scoped table has no demo rows. Only list a table in its `NO_DEMO_DATA` if it genuinely
  can't hold seeded data, and give the reason.
- Seeded account records must look realistic: names, dates relative to "now", store names and product labels.
  The user explicitly requested a demo login and mock integrations: keep the **Sign in to demo** label and
  truthful simulation/media disclosures. Do not remove those disclosures to make fixtures appear to be real AI.
- **Isolation is mandatory.** `users.is_demo` (server-only, never returned by the API, not writable by the request
  role) is the single switch:
  - Mock or simulated behaviour (payments, external side effects) applies **only** when `is_demo_user(...)` is
    true. Real accounts must never get mock data or mock behaviour.
  - The demo account must never reach real external effects (real payments, real emails).
  - Native demo models require server-verified `/v1/demo/profile` eligibility; ordinary users cannot select
    built-in recognition provenance. Account switching/sign-out must invalidate stale tokens and model work.
- Never seed mock data into non-demo accounts on hosted deploys (`AGORA_SEED_NEW_USERS` is local-dev only).
- New features must also backfill an existing demo account idempotently through `ensure_demo_account`;
  updating only the initial `_seed` leaves the live account stale.
- After changing the seed, check it locally with `uv run python -m app.tools.demo reset` against a dev database.
  Confirm the target DSN is local/disposable first; this command deletes and recreates the demo data.

## Backend conventions

- Request work goes through `db.scoped(user_id)`. It runs as the `agora_rw` role with row-level security. New
  household tables need RLS policies (`household_id = ANY (app_household_ids())`) and explicit grants.
- Migrations: `backend/migrations/NNNN_name.sql`. Pick the next free number on `main`, and if another open branch
  already claims it, take the next one. Never edit a migration that has been merged; add a new one.
  TimescaleDB-only steps go in `*.timescale.sql`, and nothing may depend on them. The verified baseline has
  `0013_calendar_events.sql`; consult current main/open PRs before reserving the next number. Old branch-local
  `0007`/`0008` forecast/commerce names were renumbered: use the handoff mapping, never apply both versions.
  Keep new migrations compatible with the previous live backend; app rollback does not undo committed SQL.
- Every user action writes `audit(...)` with no personal content in `meta`, and calls `notify(...)` for live sync.
- Schemas use `Strict` (extra='forbid'). Errors use `Problem` (RFC 7807). Mutating agent endpoints take an
  `Idempotency-Key`.
- Model output is untrusted data. Validate and clamp it, and never follow instructions found in it.
- Tests: `cd backend && AGORA_TEST_DATABASE_URL=postgresql://... uv run pytest -q` and `uv run ruff check .`.
  CI runs both TimescaleDB and plain Postgres 17, builds the Docker image from the Blueprint paths, and on PRs
  rehearses the release (migration guard, upgrade of the previous release's DB, old + new code smoke tests).
  iOS changes run the simulator auth/integration checks in `.github/workflows/ios.yml`. Merge only on green
  for the applicable checks. Documentation-only changes need link/diff/fact checks, not unrelated app test runs.
- On Windows, pass `encoding="utf-8"` whenever Python reads or writes repo files.

## Docs to keep in sync

When an endpoint changes, update its contract in `docs/api/`, and add or adjust a section in
`docs/frontend-requests.md` if the UI needs work. When hosting or setup changes, update `SETUP.md` and
`render.yaml` together, plus `docs/deployment.md` and the current-state record. For a docs-only clarification
of existing settings, changing `render.yaml` is not necessary and must not introduce infrastructure changes.
Record separately: repository baseline, actual live commit, migration state, dated verification, and unverified
work. Do not claim a merge was deployed, a backup was tested, or a roadmap item was implemented without evidence.

## Dibs (separate app in `ios/`, `server/`, `web/`)

Dibs is its own app with its own Node server, storage and people; Agora's rules above (RLS, migrations,
demo seed, audit/notify) apply to `backend/`, not to Dibs. Details: [docs/dibs/README.md](docs/dibs/README.md).

- Tests: `pnpm install && pnpm -r test`, `pnpm -C server exec tsc --noEmit`, `scripts/smoke.sh`; iOS with
  `cd ios && xcodegen generate` then `xcodebuild test -scheme Dibs` on a simulator. CI: `.github/workflows/dibs.yml`.
- Hosting is a laptop + tunnel (`scripts/demo-server.sh`). Do not add a Render service for it, and do not point
  Render at the root `Dockerfile` (that image is Dibs; `render.yaml` must keep `rootDir: backend`).
- Keep `PAYMENTS=sim` (the Cybersource sandbox mode needs its own keys). Secrets (`GEMINI_API_KEY`,
  `AGORA_DEMO_PASSWORD`) live in the gitignored `server/.env`; never log or commit them. Every run action needs
  that person's key.
- Model output is untrusted here too: names and receipt lines are validated and clamped. A live price is read
  from QFC's search page by a deterministic parser, falling back to Gemini reading that page's text, and the
  receipt line replaces it at settle. The Gemini fallback does not meet Agora's "model text is never a price
  source" rule, so do not reuse it in `backend/` as is.

