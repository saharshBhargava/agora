# Current state — mandatory read before resuming work

Verified October 17, 2026 (PDT; October 18 UTC). This is a dated snapshot, not a claim that GitHub and Render
always have the same commit. Fetch and inspect current state before acting. Current user instructions take
precedence; older chat history and planning documents do not override current main.

## Resume checklist

1. Read root [CLAUDE.md](../CLAUDE.md), this file and [PR handoff](pr-handoff.md) before editing.
2. In **your own checkout**, run `git status --short --branch`, `git fetch origin`, then inspect
   `git log --oneline HEAD..origin/main` and the diff from your branch's merge base to `origin/main`.
   Preserve local edits/commits; merge or rebase current main through the normal workflow. Do not blindly
   pull into a dirty checkout, hard-reset it, force-push main, or delete another agent's worktree.
3. Check whether your original PR is already merged. Original wishlist, forecast/list and commerce work
   is merged. Reconcile only still-needed changes; do not duplicate the old implementation or rename
   merged migrations back to branch-local names.
4. Distinguish implemented API, implemented iOS UI, simulated demo behavior and backlog using the table below.
   Continue your assigned scope; this snapshot is not an instruction to implement every backlog item.
5. Before database work, compare `backend/migrations/` and open PRs. Before deployment, read the
   [operations record](deployment.md), inspect Render's live commit, and use a disposable database for tests.
6. Keep this record, relevant contracts and the handoff current when your work changes these facts.

## Verified repository and deployment baseline

| Item | Verified state |
|---|---|
| Repository audited | `origin/main` at `860dc1cda617da0263015dd314d90f6fe8745d66` (PR #19, documentation) |
| Actual live backend | `f65cf0eccd2da9661f2d1220e861cbd9ff765997` (PR #17); Render reports **Live** |
| Why the SHAs differ | PR #19 changes documentation only; it does not require a new backend image. This documentation update will also advance main. Never assume every main commit is live. |
| API origin | `https://agora-api-yq3m.onrender.com` — no `/v1` suffix in iOS configuration |
| API root / docs / schema | `/v1`, [/docs](https://agora-api-yq3m.onrender.com/docs), [/openapi.json](https://agora-api-yq3m.onrender.com/openapi.json) |
| Render service | `agora-api`, ID `srv-dba2ram1egvs739549ug`; Free compute, Hobby workspace |
| Blueprint | `exs-dba2p92jnfac73e4kfu0`, `render.yaml`, branch `main` |
| Backend runtime | One Docker web service, including the in-process job worker; no separate Render database/worker |
| Database | Existing Tiger PostgreSQL **18.6**, TimescaleDB **2.30.2**; DB-backed media storage |
| Schema | All applicable repo SQL migrations through `0013_calendar_events.sql` are applied, including Timescale steps |
| Ordinary auth / demo auth | `AGORA_AUTH_MODE=google`; hosted password login also enabled by `AGORA_ENV=demo` and the private demo password |
| Hosted seeding | `AGORA_SEED_ON_BOOT=true`, `AGORA_SEED_NEW_USERS=false`; catalog + one designated demo, additive backfills |
| Automatic deploy mode | Was Render's own **After CI Checks Pass**. On Oct 18 ~05:10 UTC production still lacked main's `/v1/wishlist/refresh` (7bc3f8e, backend CI green at 24a6d49), so it had **not** auto-deployed. Replaced by the GitHub-driven pipeline in `.github/workflows/deploy.yml` (see [deployment](deployment.md)); it needs the one-time `RENDER_API_KEY` secret, and its first live run is not yet recorded here |
| Warm-up | GitHub repository variable `AGORA_API_URL` is the live origin; keep-warm is scheduled every 10 minutes, not an uptime guarantee |
| PR state at audit | No earlier PR remains open; #4, #8–#19 described in the handoff are already merged |

The Tiger schema was rechecked read-only during this documentation audit: exactly one designated demo
account, 12 inventory items, 3 Calendar events, 1 shopping list, 9 wishlist rows, 4 intents and 3 orders.
These are observed counts, not invariants to restore by resetting the live account; normal testing changes data.

Public `/readyz` and `/openapi.json` returned 200; readiness reported `timescale:true`. Anonymous
`/v1/demo/profile` returned 401. At 8:38 PM PDT, the exact private demo password was verified against live
login, profile, inventory, Calendar listing and availability. No Google/model credentials were used.

Both **post-merge** backend CI and iOS CI passed for live commit `f65cf0e`:
[backend](https://github.com/saharshBhargava/agora/actions/runs/39094132788),
[iOS](https://github.com/saharshBhargava/agora/actions/runs/39094132758).
iOS ran 24 selected auth/transport/integration tests and captured onboarding. This is not a claim that every
iOS test, real Google consent, real model inference or a physical device flow was exercised.

## Sign-in and provider behavior: preserve this split

| | Designated demo account | Ordinary Google account |
|---|---|---|
| Entry | **Sign in to demo**, username `demo`, private Render `AGORA_DEMO_PASSWORD` | Native Google Sign-In + Calendar consent |
| Google required? | **No.** Verified allowlisted Google email is an optional alternate entry to the same account. | Yes for current native ordinary-account onboarding |
| Visible identity | Alex Rivera, handle `alexrivera`; `demo` is the login alias | The user's own account/household |
| Agora API credential | Password login returns Bearer `access_token`; `expires_at` is Unix seconds; token stored origin-bound in Keychain | Fresh Google **ID token**, not Google Calendar access token |
| Chat/captions/recognition | Built-in `agora-sample-v1` fixtures, no external model calls or provider keys; source media ignored in native fixture flow | Assigned Gemini or OpenAI-compatible profile; its configured credentials/capabilities apply |
| Calendar | Private persisted Agora events; availability + explicitly approved creation; no Google event/invitation | Native Google Calendar API using SDK access token |
| Server-uploaded scans | Built-in vision selected per server-owned demo flag, even if real keys exist | Configured vision/fallback, separate from device model settings |
| Agora-native checkout | Simulated only; no real charge | `503 payments_unavailable` until a real provider is implemented |
| Seeded history | One populated designated account | Empty household initially; no automatic synthetic history |

Eligibility is checked by server-owned `users.is_demo`; it is never returned as a writable/public flag.
`GET /v1/demo/profile` verifies eligibility. Built-in recognition provenance is denied to ordinary accounts.
Sign-out/account switching must clear or invalidate old work. Preserve simulation disclosures; fixture
responses are not general AI inference. Demo still needs a reachable Agora backend and valid session.

The password, database DSN, JWT signing secret and provider keys are **not in Git**. Retrieve the demo
password from Render Environment and share privately. Do not rotate/regenerate existing secrets or create
a Gmail account just to let the frontend team sign in. See [frontend handoff](frontend-handoff.md).

## Implemented versus still requested

| Area | Current implementation | Still outstanding / boundary |
|---|---|---|
| Home/inventory | Shared authenticated store; active/archived items, quantities, edits, history, stores/purchase dates; low-stock card | Home low-stock uses `par_level`, not the new run-out API; do not describe it as a forecast integration |
| Capture | Photos/video, model captions and recognition, user review and metadata-only inventory save | Real Google/provider/device flows still need appropriate real-account testing; built-in demo ignores media |
| Model routing | `Agora/Models/` abstraction; Gemini/OpenAI-compatible connections, profiles, per-feature assignment; demo override | Do not revert to Gemini-only controllers or send demo captures to external models |
| Recognition details | Readable brand/variant/package-size fields composed into reviewed item names; shared validation and Gemini-compatible schema | Do not restore the earlier broad-name-only prompt or unsupported generation-schema constraints |
| Wishlist | Backend lifecycle, priority ranking, suggestions and feedback; native Wishlist and Suggested views (`Agora/Shopping/`, 7bc3f8e); realistic demo rows | Live retailer price monitoring is deferred |
| Forecasts/lists | Backend run-outs, histories, list CRUD and generation; demo backfill | Full native run-out/list screens/integration remain requested |
| Commerce | Backend policy, mandates, approval/outcome lifecycle, pause/resume, budgets/spend, stable provider idempotency | Native commerce approval/mandate/budget UI remains requested; no real Stripe/Visa provider wired |
| Calendar | Native tools and approval; demo-private routes + persistence; ordinary native Google route | Upcoming-trip summary UI and automatic list-to-trip scheduling are not implemented |
| Suggestions/price watches | Six-hour backend replenishment jobs (00/06/12/18 UTC, `0014_wishlist_refresh.sql`), `POST /v1/wishlist/refresh`, on-demand model ideas (7bc3f8e) | Price monitoring not implemented. Not live until a release containing 7bc3f8e is deployed |
| Other roadmap | Design notes describe receipts, scores/social, richer prices and additional integrations | Do not claim them live or create their proposed tables simply because they appear in the spec |
| Operations | CI + PR release rehearsal (migration guard, upgrade and rollback compatibility), GitHub-driven deploy with smoke checks and automatic rollback, deploy/rollback/status/restart for any writer, readiness with commit + migration state, keep-warm monitor, daily encrypted DB backup, local launcher/snapshots | First live managed release/rollback/backup run, a tested restore into a new database, verified branch protection and staging. The pipeline needs the owner's one-time secrets (deployment.md) |

## Source-of-truth map

- **Current facts:** this file + [deployment record/runbook](deployment.md), with verification dates.
- **Stale branch reconciliation:** [PR handoff](pr-handoff.md); root [agent rules](../CLAUDE.md).
- **Runtime contract:** current routers/schemas/migrations and deployed OpenAPI, plus [API contracts](api/).
- **Frontend integration:** [frontend handoff](frontend-handoff.md); [frontend requests](frontend-requests.md) is backlog where marked.
- **Recreating/local fallback:** [SETUP.md](../SETUP.md) and [backend README](../backend/README.md).
- **Historical design/reference:** [backend spec](backend-spec.md), [original planning notes](Dubhacks%20Planning%201.md),
  [judging rubric](RUBRIC.md). These are not evidence of implementation or instructions to change hosting.

If a later inspection disagrees with this snapshot, resolve against current main/live provider evidence and
update the dated record. Do not change the deployment just to make it match an older document.
