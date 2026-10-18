# Current state — mandatory read before resuming work

## Price discovery correction — October 18, 2026

Live keyless reproduction of the earlier price release exhausted PS5's five page reads on a buy-now
page and news articles; Xbox also selected a pricing PDF. The correction filters editorial/non-HTML
sources, follows matching product links on retailer category pages within the existing budget, and
keeps product pages ahead of categories even when diversifying retailers. Both model and model-free
research retain the best discovered URLs for the final browser fallback. There are no product-specific
URLs or prices in the implementation. Pinned URLs, merchant evidence validation, demo isolation and
alert eligibility remain unchanged. The local native runner now attempts up to five sources within
its lease; rebuilding the app is required for that client change.

After integrating current main (including chat additions), all 670 backend tests and Ruff passed.
The native browser suite passed 16 tests. Live search discovered direct PS5
product pages in 5.0 seconds and five Xbox product URLs in 17.4 seconds; these are search/discovery
timings, not successful verified-price checks. The actual shared WebKit browser read a live Xbox price at the fourth candidate (Newegg) in 1.6 seconds
and a PS5 Pro price from PlayStation Direct in 1.5 seconds per page. These are lower-confidence device
observations, not server-verified alerts. Release verification is pending.

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
| Wishlist | Backend lifecycle, priority ranking, suggestions and feedback; native Wishlist and Suggested views (`Agora/Shopping/`, 7bc3f8e); realistic demo rows | Reviewed price watches, source verification and offer inbox are implemented; real discovery needs a backend model connection |
| Forecasts/lists | Backend run-outs, histories, list CRUD and generation; demo backfill; native per-store list generation and checklists in Shopping trips | Dedicated forecast-history screens remain requested |
| Commerce | Backend policy, mandates, approval/outcome lifecycle, pause/resume, budgets/spend, stable provider idempotency | Native commerce approval/mandate/budget UI remains requested; no real Stripe/Visa provider wired |
| Calendar | Native tools and approval; demo-private routes + persistence; ordinary native Google route; Home trip summaries and reviewed list-to-trip planner | Calendar creation requires explicit review; store hours and travel routes are not inferred |
| Suggestions/price watches | Six-hour backend replenishment jobs (00/06/12/18 UTC, `0014_wishlist_refresh.sql`), `POST /v1/wishlist/refresh`, on-demand model ideas (7bc3f8e) | Price watches add migration 0016, six-provider discovery, bounded model research and optional APNs. Deployment verification is recorded separately below |
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

## Watchlist release preparation — October 18, 2026 UTC

Prepared on top of `a3c9a97`, preserving managed releases and trip-backend migration 0015. Migration
`0016_price_watches.sql` adds reviewed criteria, checks, merchant observations, matches, inbox and optional
push delivery, with idempotent designated-account backfill. Native watch setup/history/inbox and explicit
browser handoff are included; the separate uncommitted trip-planner UI is excluded.

Search supports Exa, Parallel, Firecrawl, Keenable, Tavily and Brave with provider fallback and budgets.
Exa/Parallel/Keenable keyless searches were verified live. The reasoning model is independently configured
as Gemini or an OpenAI-compatible service; phone model credentials are not uploaded. APNs and the native
push entitlement are optional. See [watch contract](api/price-watches.md).

This entry records repository changes and local verification, not a claim that production has this release.
Confirm the release commit and applied migrations with `/readyz` after the managed deploy succeeds.

## Verified watchlist deployment — October 18, 2026 UTC

[PR #25](https://github.com/saharshBhargava/agora/pull/25) reached main as
`ca727b6f2b73d182e3bfbb9239a1f40f941a2be8`. Its pre-release Postgres/TimescaleDB tests, image build,
upgrade/rollback rehearsal and iOS simulator checks all passed. Local validation on the reconciled release
included 536 backend tests, 23 selected iOS tests, Ruff, the migration guard and a disposable demo reset.

The [managed deployment](https://github.com/saharshBhargava/agora/actions/runs/39104163821) succeeded.
Read-only production verification reported that exact commit, TimescaleDB enabled, latest migration
`0016_price_watches.sql` and no pending migrations. Anonymous `/v1/watches` returned 401, confirming the
endpoint is deployed and requires authentication. This supersedes the older live-commit/schema snapshot
above. No production reset or real purchase was performed. Background inference configuration and actual
APNs delivery are not established by these deployment checks. A later documentation-only commit need not
change the running image.

## Native shopping-trip integration — October 18, 2026 UTC

The iOS planner connects existing run-out/list and trip APIs to Calendar availability, reviewed event
creation, durable outcomes and read-only recovery after uncertain writes. Home exposes upcoming trips and
per-store lists with checkable items. Demo traffic uses the private Calendar; ordinary accounts use their
primary Google Calendar. The backend and its demo backfill already shipped in PR #22; this client change
adds no database migration. This records source implementation, not distribution of a new iOS build.

Trip validation: 57 selected simulator tests passed on an isolated checkout of current main plus the trip
client, including the real local PostgreSQL/API flow (not skipped), Calendar recovery, account boundaries,
shopping and watch regressions. The live-flow test verified explicit approval, one persisted Calendar
event, session restoration, duplicate prevention and checklist updates. The trip client and tests match
those in PR #27. This did not write to production or exercise real Google credentials.

## Manual shopping-list creation — October 18, 2026 UTC

Local implementation on top of the native trip client adds **Home → Shopping lists & trips → New list**.
Users name a list, optionally choose a store, and add items with quantities, units and notes. Saved lists
remain checkable and participate in reviewed Calendar planning. Creating lists and items uses the existing
list APIs and makes no Calendar call. Forms preserve errors, clear on account/household changes, and block
repeat submissions after an unconfirmed save until the user closes the form and checks the saved lists.

The demo seed/backfill adds a realistic household-essentials list; an audit marker preserves renames and
archiving across subsequent sign-ins. No migration or API contract change is needed. Verification passed:
537 backend tests, Ruff, a disposable local CLI demo reset, and 37 selected simulator tests including both
real local API/Postgres flows (manual lists and replenishment trips, neither skipped). Simulator captures
were inspected for creation and checklist screens. This records local source validation, not a production
deployment or distribution of a new iOS build. List editing, deletion and history remain follow-up work.

## Lists navigation — October 18, 2026 UTC

The native Inventory tab is now **Lists**, with four vertically stacked navigation rows: Inventory list,
Shopping lists, Watch list, and Suggested for you. These open the existing inventory, shopping-list/trip,
price-watch, and suggestion screens. Household selection is available on Lists; Home still links directly
to the inventory list, and the watch list offers access to the wishlist and offer inbox. This is a local
client navigation change with no new stored data, API, or migration.

Validation: 73 selected iOS simulator tests passed, including inventory, shopping, watches, trips and
authentication checks. The Lists overview simulator capture was inspected. No production deployment or
new distributed iOS build is claimed.

## Native chat workspace — October 18, 2026

The native chat now has a model selector, independently streaming message rows, Markdown/tables/code,
copy/link controls, image/document previews, dictation, tool disclosures, inline approval states, immediate
Stop, and a searchable conversation sheet with rename/archive/delete. Drafts, attachments and provider
context are retained per chat **for the signed-in session**; sign-out/account changes clear this in-memory
history. The task journal remains metadata-only. No backend schema or stored server account data changed.

The same mounted `WKWebView` remains live across draggable thumbnail, hidden, expanded and wide-screen
side-pane presentations. User presentation changes do not cancel agent work; actual page interaction
revokes conflicting work. Tests verify identity, input text, scroll position, navigation history and session
cookies across these layouts. Gemini now streams visible text on tool turns while preserving signed
continuations and validating completed tool batches before execution. Private thought text is not rendered.

Validation: 71 selected simulator tests passed in an isolated checkout based on `524967d`, including the
chat, browser, auth/Calendar boundaries and both provider adapters. The real loopback streaming/tool flow
ran without skipping. The isolated checkout also included the already-existing local OpenAI-compatible
noncanonical-IP validation fix; without that unrelated fix, the existing `010.0.0.1` test fails on main.
The shared working checkout built successfully. Light/dark, large-text, empty/history, attachment/approval
and browser layouts were captured and inspected. Broader exploratory tests encountered an unsigned-build
Keychain limitation and a video-cancellation test process exit; no full-suite pass is claimed. Live provider
credentials, microphone hardware, real Google consent and a distributed iOS release are not verified here.
See [frontend handoff](frontend-handoff.md#native-chat-workspace--october-18-2026) for client behavior/limits.

Final layout follow-up: 11 focused chat/browser tests passed, followed by a successful render regression
check after resetting lazy row height estimates on Dynamic Type changes. This fixes an iOS 18 transcript
that could remain beyond its content after reducing text size. The final thumbnail/minimized capture was
inspected with the conversation visible and browser state retained. Local captures and logs are under
`build/chat-interface/` (ignored build artifacts). No production deployment was performed.

Publication validation: the exact chat-only changes on current main (`8292694`) passed all 42 selected
simulator tests, including chat rendering/browser state, authentication/Calendar boundaries and both
provider transports. This final run excludes the unrelated local IP-validation change mentioned above.
The Gemini schema correction and compact composer/tab spacing are included.

## Broad item image search — October 18, 2026

Backend PR [#31](https://github.com/saharshBhargava/agora/pull/31) adds migrations 0017/0018, household image bindings, private photos, demo-only
illustrations and bounded product-page discovery. Every item name is searchable without requiring brand,
model or barcode. Relevant ambiguous images are returned as titled choices and require confirmation;
only supported product matches auto-display. Search uses the existing web router independently of whether
a reasoning model is configured. Optional model tools and visual vetoes remain available.

The native implementation is local source work; this backend release does not distribute an iOS build.
Production was verified at `190de200a8028939aab01a51b03f770ee548b2d9` on October 18, 2026 UTC:
[deploy run](https://github.com/saharshBhargava/agora/actions/runs/39113668150) passed, `/readyz` reported
migration 0018 with no pending migrations, and the authenticated image route returned 401 without a token
instead of 404. PR and post-merge CI passed 602 tests on each of Postgres and TimescaleDB; Docker build and
PR migration/rollback rehearsal passed. Eight focused native tests passed. A local full run had 601 passes
and one disk-full failure; that isolated case passed after removing owned build artifacts.

Live public searches downloaded PS5 disc/digital photos, Xbox Series X versions and a Lodge skillet. A
disposable ordinary-account API flow for both consoles returned choices, saved explicit selections and served
image bytes. The local demo CLI reset produced 25 image bindings. No production-account writes were used
for these verification checks. Existing-item backfill is part of the additive production migration.
A follow-up preserves Unicode characters during identity comparison; its focused image suite has 65 passes. The shared workspace's
earlier exact-only search/fallback notes are superseded by [this contract](api/item-images.md).

## Automatic image defaults — October 18, 2026

This supersedes the required-choice flow above. New discoveries and cached results automatically select
the best relevant image. Existing unresolved items with saved candidates are adopted at worker startup;
version checks protect against stale workers, and explicit choices/removals/photos remain untouched.
`best_match` displays candidate evidence without relabeling it as exact SKU verification. Native source
removes the Choose prompt and keeps **Change image** as an optional override. No new migration is needed.
Validation: 604 backend tests passed on disposable PostgreSQL, including automatic selection, cached
results, idempotent retroactive adoption, stale-worker protection and manual override preservation. Real
public-page searches for PS5 and Xbox Series X selected and served images through an ordinary local account
without a selection request. All eight focused native tests passed, including automatic best-match display.
Deployment is pending at this entry.

## Chat additions MVP — October 18, 2026

Chat now exposes three validated tools for explicit user requests: add to an existing shopping list,
add an active wishlist item, or create a new inventory item. Each task first reads fresh household
context; ambiguous destinations are clarified. Saves use the shared stores, so confirmed additions
appear in the existing screens. Existing entries are reported without merging or changing quantities.
Account/household changes cancel pending work and clear chat context; uncertain writes require checking
Lists. Recommendations retain the separate suggestion/acceptance flow. The built-in demo uses a disclosed
single-item text grammar with real private-account persistence and an idempotent seed/backfill.

The three existing create APIs accept optional idempotency keys (always sent by chat), serialize retries
and save responses atomically. Keyed inventory/list additions reject case/whitespace-normalized duplicate
names; wishlist keeps its existing duplicate rules. No migration is needed. Existing automatic wishlist
watch synchronization is preserved in the shared checkout. See [chat additions](api/chat-additions.md).

Implementation was prepared on current main through `6a86e2f` and integrated with the shared checkout's
uncommitted work. Validation: **659 backend tests**, Ruff and diff checks passed; the combined app built,
and **71 selected iOS simulator tests passed with no skips**, including the real local API/Postgres chat
flow, duplicate handling, destination ambiguity, persistence reload, Stop and account/household boundaries.
A disposable local demo CLI reset also passed. Broader exploratory iOS runs encountered the existing
unsigned-build Keychain limitation and a browser-scroll timing assertion; no full iOS suite pass is claimed.
Live credentialed model inference, production deployment and a distributed iOS build were not performed.


## Automatic wishlist price checks — release preparation, October 18, 2026

The native “Preparing automatic price checks” text was shown for an absent watch even when the hosted
service did not support automatic watches. Read-only production readiness confirmed commit `6a86e2f`
and migration 0018; that version still required separate watch setup.

This backend change creates and queues watches when active wishlist items are saved/accepted, backfills
existing active items at worker startup and scheduled sweeps, and preserves explicit pauses. Targets are
optional; verified source prices appear independently of meeting a target. Multi-retailer research works
without a reasoning model. Migration 0019 supplies the final foreground browser claim/result protocol;
device-reported prices cannot generate server-verified offer alerts. Demo remains isolated.

`GET /v1/watches` now advertises `automatic_watches:true`. Updated native source distinguishes an older
service, an unloaded/failed request and a genuinely missing watch instead of promising endless preparation.
The native changes require a rebuilt app; this backend-only release does not distribute that build.

Local validation: the prior combined checkout passed 649 backend tests, 70 selected native regressions and
24 focused browser/watch tests, including a real disposable API/Postgres flow. The additive migration and
old/new API compatibility rehearsal passed. This isolated release is being checked separately before merge;
production availability must be established from its deploy run and `/readyz`, not this preparation entry.


## Chat additions released — October 18, 2026

[PR #33](https://github.com/saharshBhargava/agora/pull/33) merged as
`7c6603066d9071e8f3b92542b4f64dafed2a68c8`, including current main's automatic wishlist-price checks
and automatic item-image selection. All PR checks passed: Postgres, TimescaleDB, Docker image,
upgrade/rollback rehearsal and the iOS simulator. The isolated chat source passed 613 local backend tests
and 69 selected iOS tests, including real local chat/API/Postgres persistence without skips; after
integrating automatic watches, all 48 focused chat/wishlist/watch/demo tests passed again.

Post-merge backend CI and the [managed deployment](https://github.com/saharshBhargava/agora/actions/runs/39116019921)
succeeded. Read-only production `/readyz` verification reported that exact merge commit, TimescaleDB
enabled, migration `0019_watch_browser_fallback.sql` and no pending migrations. Chat adds no migration
of its own. No production reset or test writes were performed. The native tools require a rebuilt iOS app;
this verifies the backend release, not distribution of an iOS build or live credentialed model inference.


## Existing inventory image recovery — release candidate, October 18, 2026

Active inventory repairs missing image bindings at worker startup and household inventory loads. Empty
automatic results older than seven days retry, and startup revisits old search-version misses while
respecting the current negative cache. The existing image pipeline searches online and selects a result
without requiring edits or a manual image choice. Explicit selections, removals, photos and successful
images remain preserved. Demo seed/backfill restores labeled sample images without external searches.
No migration is needed.

The shared checkout passed 679 backend tests, Ruff, nine native image tests and a disposable demo CLI
reset. A live search probe against an ordinary disposable local account automatically recovered existing
Barilla spaghetti and PS5 items and served Walmart/PlayStation source images with HTTP 200. The native
continued-polling improvement remains local and requires a rebuilt app; this backend release does not
distribute the iOS client. Deployment verification will be recorded after the managed release succeeds.
