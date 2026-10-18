# Current state — mandatory read before resuming work

## Local checkout reconciliation — October 18, 2026

The shared checkout's local changes were saved in checkpoint `a45161a`, retained by
`backup/local-work-20261018`. Review branch `review/local-work-reconciled-20261018` merges
`origin/main` at `401603d` through `bf26470`, preserving native image displays, automatic-watch UI,
shared-browser fallback and the latest remote chat, authorization, notification and trip fixes.
Local `main` was fast-forwarded to `401603d`. Earlier entries describing these native files as
uncommitted are superseded by this checkpoint; the changes remain local, unpublished source.

Backend application code and migrations match `401603d` exactly. The remaining backend difference
is the native browser-test support server. Validation on the combined checkout passed **673 backend
tests** against disposable local PostgreSQL, Ruff, diff checks, and **117 selected iOS simulator tests**
covering images, browser fallback, watches, shopping, trips, chat, local models and account boundaries.
Logs: `/tmp/agora-reconciliation-backend.log` and `/tmp/agora-reconciliation-ios.log`; simulator results:
`/tmp/agora-reconciliation-tests.xcresult`. This work did not push branches, deploy, or write production data.
Open the existing Xcode project on the review branch to verify the combined app.

## Product discovery correction — deployed October 18, 2026, 09:44 UTC

PR [#36](https://github.com/saharshBhargava/agora/pull/36) fixes automatic checks spending their page
budget on articles/PDFs and losing product links behind category/navigation pages. Product pages now
precede categories even across repeated hosts, and relevant category links are eligible for browser
fallback even when the server read budget expires. The generic native runner checks up to five candidates
within its existing lease instead of stopping at three. No item-specific prices or URLs were added.

All **670 backend tests**, Ruff and diff checks passed on current main plus the correction; all **16
native browser tests** passed, and the final five-retailer regression passed again after fixture refinement.
Live discovery returned direct PS5 product pages in 5.0 seconds and Xbox product pages in 17.4 seconds.
The shared WebKit browser read Xbox at Newegg (fourth candidate) and PS5 standard, digital, Pro and bundle
prices at PlayStation Direct. The backend browser-evidence validator accepted the captured results.
These are live lower-confidence browser observations, never server-verified alerts or guaranteed future
prices. Logs are in `build/watch-browser/`. PR/main CI passed, and the
[deploy run](https://github.com/saharshBhargava/agora/actions/runs/39116414537) succeeded. Public readiness
verified commit `be1e9de4c9ea8088b266e6f668dc49d5809c05da`, migration 0019 and no pending migrations.
The backend correction is live; the native five-source change needs a rebuilt app. Existing terminal
checks can be rerun with **Check now**, or will use the new discovery on their next scheduled check.

## Latest price-watch release — October 18, 2026, 09:26 UTC

PR [#34](https://github.com/saharshBhargava/agora/pull/34) is deployed as
`047c8f5006b69ba002690d6ef57f0ccfdc86933c`. The
[deploy run](https://github.com/saharshBhargava/agora/actions/runs/39115233684) passed; public readiness
reports migration 0019 with no pending migrations. The live OpenAPI exposes browser claim/result routes
and optional target prices; anonymous watch access returns 401.

The endless “Preparing automatic price checks” message came from an absent watch against the earlier
backend, which still required separate setup. The release creates watches on wishlist save/acceptance
and backfills existing active items during worker startup/sweeps, preserving pauses. `automatic_watches`
is advertised in the watch-list response. The native missing-watch message now distinguishes unsupported,
unloaded/failed and not-started states; that text correction remains local and needs a rebuilt app.

The isolated backend release passed 649 local tests, Ruff, and the additive migration guard. PR and main
CI passed both PostgreSQL/TimescaleDB suites and the Docker build; PR upgrade/rollback rehearsal passed.
The local native status correction passed all 24 selected watch/shopping tests. No production-account
records were manually edited for diagnosis or verification. Earlier entries saying these backend changes
are local-only are superseded by this release; native browser/UI changes still require the matching app build.

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
| Wishlist | Backend lifecycle, priority ranking, suggestions and feedback; native Wishlist and Suggested views (`Agora/Shopping/`, 7bc3f8e); realistic demo rows | Automatic price research and optional targets are locally implemented below; verify deployment separately |
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

## Empty watch-search results — October 18, 2026 UTC

Local debugging reproduced two false failures: empty result arrays in MCP text blocks triggered provider
fallback/cooldown, and research ending after a successful empty search reported `research_no_evidence`.
The adapters now preserve explicit empty responses, and the controller allows `no_match` when a search
completed successfully and no known URLs await reading. Unread sources, model-only conclusions and actual
provider failures still cannot establish a successful empty check. No schema or seed change is needed.

Validation: 219 focused backend tests passed on disposable local PostgreSQL, including API/worker
persistence of `no_match` with no retry or notification; Ruff and diff checks passed. Live anonymous
Exa, Parallel and Keenable searches each returned product results for a Lodge skillet query. These checks
do not establish production model configuration. This fix is local and has not been deployed.

## Automatic wishlist price research — October 18, 2026 UTC

The user clarified that every active wishlist item should be watched automatically, with optional targets.
Saving or accepting an item now atomically creates its watch and queues a first check; wishlist edits update
the criteria and fence stale completions. Explicit pauses remain paused, purchases/removals complete watches,
and pending suggestions do not search. Existing active items are backfilled at worker startup/sweeps;
demo creation and idempotent backfill cover every active demo item. Daily/hourly budgets defer work without
rejecting wishlist saves. Defaults are new condition and US delivery, editable in watch settings.

Search works without a reasoning model through the enabled provider router and the existing public-page
verifier. With a model, the bounded research controller remains available. The API exposes source-backed
prices above the target as well as below it. Missing targets still show prices but cannot emit target-price
alerts. The demo remains simulated and explicitly labeled; ordinary accounts get no demo offers.

**Lists → Watch list** opens the wishlist with its Add item action, price summaries and optional settings.
The separate activation button is removed. Saves reload watches; queued checks refresh in the foreground
every two seconds for up to 90 seconds, cancelled on account/household changes. No new SQL migration is
needed. This is local source work, not a deployed backend or distributed iOS build.

Validation: 555 backend tests and Ruff passed in an isolated checkout on disposable PostgreSQL, and the
local demo CLI reset passed. All 18 selected iOS simulator tests passed, including the real local API/worker
flow with no skip: saving alone produced an offer, inbox entry, persisted session recovery and automatic
criteria resynchronization. The source-price comparison and demo disclosure capture was inspected. Isolation
excluded concurrent image/chat work in the shared checkout; no production data was changed or release made.

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

## Item images — October 18, 2026 UTC

Local source now gives inventory, wishlist/suggestions and shopping-list items a persistent image binding.
The native app shows bundled representative artwork immediately across inventory, Home, recognition review,
shopping lists and watch/offer views. Users can choose a discovered image, upload a private photo, restore a
representative image or return to automatic discovery. Linked items inherit inventory images unless overridden;
account/household changes clear private image caches. Demo illustrations are labeled and use no external search.

Migration `0017_item_images.sql` adds household-scoped bindings/private assets and a shared public-product
cache. Existing items are backfilled; identity changes queue bounded background research using the existing
web-search router, public-page reader and optional watch reasoning model. Extracted image candidates retain
source attribution, and validated downloads are resized and stripped of EXIF. Search failure leaves a usable
representative image. Worker startup repairs image jobs consumed by older releases; snapshot restore preserves
assets and requeues pending work. See the [item-image contract](api/item-images.md) for routes and limits.

Verification on disposable local PostgreSQL: **574 backend tests passed**, Ruff and diff checks passed,
and the additive migration guard passed. A fresh demo CLI reset produced images for every seeded item.
An upgrade rehearsal applied the migration/backfill twice and passed API read/write smoke checks with both
previous main (`524967d`) and current source against the upgraded schema. **86 selected iOS simulator tests
passed**, including the real local API/Postgres image flow; after final image-store refinements all seven image
tests passed again, with no skips. The rendered thumbnails were visually inspected. A live public-web Lodge
skillet lookup extracted candidates and downloaded a matching Target product image. Reasoning-model tool
behavior was tested with fixtures; live model inference and TimescaleDB were not exercised in these local checks.

Latest main (`8292694`, CI-only PR #29) was integrated without replacing concurrent local work. Validation
includes the shared checkout's automatic-watch changes. These are local implementation results: no backend
deployment, production data changes or distribution of a new iOS build is claimed.

Final layout follow-up: 11 focused chat/browser tests passed, followed by a successful render regression
check after resetting lazy row height estimates on Dynamic Type changes. This fixes an iOS 18 transcript
that could remain beyond its content after reducing text size. The final thumbnail/minimized capture was
inspected with the conversation visible and browser state retained. Local captures and logs are under
`build/chat-interface/` (ignored build artifacts). No production deployment was performed.

## Exact product-image verification — October 18, 2026 UTC

This supersedes the earlier image matching/fallback behavior above. Automatic images now require a
variant-bound JSON-LD Product image and either matching valid GTIN, consistent brand/model evidence, or
complete brand/variant/size/pack-count evidence. Extra/mismatched variants, packaging, accessories and
unknown required identity fields cannot be promoted by the research model. Catalog URLs, Open Graph images
and title word counts no longer establish a match. Source evidence is persisted; cache keys include the full
identity and verification version. Migration 0018 adds these fields and requeues earlier automatic matches.
Old or rollback-worker images without verification are hidden on read; explicit choices remain user-confirmed.

Native thumbnails use a neutral unavailable indicator for unresolved items. The editor accepts product name,
brand, model, variant, size, color, pack count and barcode; details persist independently and are invalidated
when the item is renamed. Linked items can override inherited identity. Demo illustrations remain explicitly
labeled sample assets and never count as exact matches. Configured reasoning models additionally inspect
sanitized public image bytes; uncertain/conflicting results veto the candidate. Without a model, evidence
explicitly says visual inspection was not performed. See the [updated contract](api/item-images.md).

Validation: 602 full backend tests passed on disposable PostgreSQL, then 74 focused image/snapshot/demo/model
checks passed after refinements. All 40 selected iOS tests passed, including the real local API identity and
photo persistence flow (no skip), legacy-image hiding, recognition, shopping and watches. Ruff and additive
migration guards passed; upgrading/backfilling twice and running old (`8292694`) and new APIs against the
upgraded database passed. The recognition unavailable indicator was visually inspected. The live Target
skillet page supplied no usable structured identity in the fetched HTML and correctly stayed unresolved;
this is not a successful live exact-image lookup. Exact-match positives and visual-model outcomes were
validated with controlled fixtures, not live inference credentials. These changes remain local; no deployment,
production data mutation, TimescaleDB validation or distributed iOS build is claimed.

Publication validation: the exact chat-only changes on current main (`8292694`) passed all 42 selected
simulator tests, including chat rendering/browser state, authentication/Calendar boundaries and both
provider transports. This final run excludes the unrelated local IP-validation change mentioned above.
The Gemini schema correction and compact composer/tab spacing are included.

## Broad item-image release — October 18, 2026

PR [#31](https://github.com/saharshBhargava/agora/pull/31) merged as `190de200`. It supersedes the
earlier exact-only eligibility restrictions: all names are searched; incomplete or variant-specific matches
become titled choices that require user confirmation. Source-backed product matches can display automatically.
The existing web router works independently of a configured reasoning model. Private photos, demo isolation,
inheritance, cache/version guards and evidence remain in place. See [the contract](api/item-images.md).

PR CI passed **602 tests on both Postgres and TimescaleDB**, Ruff, Docker build and migration/rollback
rehearsal. The local complete run had 601 passes and one disk-full failure; that isolated case passed after
removing owned build artifacts. Eight focused native tests passed. Live public searches retrieved PS5
disc/digital, Xbox Series X versions and a Lodge skillet. A disposable ordinary-account flow for PS5 and
Xbox persisted explicit selections and served authenticated image bytes. No production-account writes
were used for these checks. The native editor and Choose/retry messages require a rebuilt iOS app.

Production verified at `190de200` with migrations through 0018 and none pending.
[Deploy](https://github.com/saharshBhargava/agora/actions/runs/39113668150) passed; anonymous image access
returned 401 rather than 404, and OpenAPI exposes all image routes. The non-Latin identity correction shipped in
[#32](https://github.com/saharshBhargava/agora/pull/32). Final production readiness reports
`6a86e2fd489f636a90ec5f49d7b1a152dadc78cf`, migration 0018 and no pending migrations; its
[deploy run](https://github.com/saharshBhargava/agora/actions/runs/39114045696) passed. Both final CI
database suites passed 603 tests, and the anonymous hosted image route again returned 401.

## Hidden shared-browser price fallback — local verification, October 18, 2026

Ordinary wishlist items automatically start price research with optional targets. Normal research tries
multiple retailers within the existing budgets. If it finishes without a usable price, migration 0019
persists a final browser handoff. The iOS runner uses the same Chat `BrowserSession`/`WKWebView`, hidden,
only while the app is active and the browser is free. Existing Chat pages remain intact; human takeover,
new Chat work, backgrounding and account changes cancel it. Demo accounts never run external browser work.

Claim/result routes enforce household access, actor-bound expiring leases, criteria versions and current
run ownership. Rendered product evidence is validated and retained for 30 minutes with device-browser
provenance. It displays current prices and target comparisons but cannot create verified offer alerts.
Private/blocked pages finish unresolved and can offer manual review; automatic checks never sign in or buy.
See the [contract](api/price-watches.md#final-fallback-in-the-shared-chat-browser).

Verification: **649 full backend tests passed** on disposable PostgreSQL, including a run from an isolated
checkout reconciled with current main. Ruff and diff checks passed. Migration 0019 passed the additive
guard; applying/backfilling twice, resetting the local demo, and running both previous-main and new APIs
against the upgraded database passed. **70 selected iOS tests passed**, covering Chat/browser preservation,
account boundaries, shopping and watches. After the final redirect handling change, **24 focused iOS tests
passed**, including all 15 fallback tests and the real local API/Postgres/worker flow with rendered retailer
fixtures. The price-comparison screen was captured and visually inspected. Test synchronization now waits
for WebKit's committed document and settled scroll position instead of reading the preceding frame.

The opt-in live retailer probe read PlayStation's rendered split-element price in about **1.4 seconds**;
that measures the browser step only. Microsoft's Xbox page exposed no usable price in the bounded read
and correctly stayed unresolved. These are live external-page observations, not a guarantee that every
retailer returns a price. Generic non-console extraction, multiple-retailer continuation, uncertain
currency, cross-host redirects and cancellation are covered with controlled fixtures. No live model
inference, physical-device or TimescaleDB run is claimed for this local change.

Logs and the inspected screenshot are in `build/watch-browser/` (ignored local artifacts). The shared
checkout retains concurrent work; reconciliation was done separately at `/tmp/agora-watch-current-main`
against `origin/main` `6a86e2f`. The fallback and automatic-watch changes remain **local and uncommitted**:
no production deployment or distributed iOS build is claimed. Browser fallback requires the app to be open;
the normal scheduled backend checks continue independently.


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

## Automatic item-image defaults — October 18, 2026

PR [#35](https://github.com/saharshBhargava/agora/pull/35) supersedes the required-choice flow. The backend
selects the best relevant image for new searches and cached results, and adopts existing saved candidates
at startup. Manual choices, uploaded photos and explicit removals are preserved; versions fence stale jobs.
The `best_match` status retains candidate evidence without claiming an exact SKU match.

Native source displays the server-selected image and also supplies an immediate default when an older
server only returns alternatives. This fixes thumbnails left empty while Other images already has photos.
Alternatives remain optional under Change image. A rebuilt app is required for the new display behavior.

Validation: 604 backend tests passed before integrating the current wishlist release, then all 650 passed
on the integrated isolated checkout. PR Postgres/TimescaleDB, Docker and release rehearsal checks passed.
Live ordinary-account checks on disposable PostgreSQL automatically selected and served PS5 and Xbox
manufacturer images without a selection request. All eight final native tests passed, including
the older-server case where alternatives exist but no main asset was assigned. Both post-merge CI database
suites passed 650 tests. Production was verified at `d818b2791a05fc92e3667715437dff2ac4172a3f`, migration
0019 with no pending migrations. The [deploy run](https://github.com/saharshBhargava/agora/actions/runs/39115437795)
passed, and anonymous image access returned 401. The backend is live; distributing the native changes
requires rebuilding the app.

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

## Home category carousels — local, October 18, 2026

Home now places Wishlist first below the scan action, followed by Running low, Suggested for you and
Upcoming trips. Category cards are replaced by headings and horizontally scrolling, snapping rows.
All active wishlist items, low-stock items, suggestions and upcoming scheduled trips are included instead
of short previews. Product rows reuse the authenticated image store with circular clipping; trips use
circular date badges. Existing image editing, category destinations, errors and restock planning remain
available. Labels and image sizes adapt to Dynamic Type. No API or stored-data changes are involved.

Validation: the simulator build and all 93 selected iOS CI tests passed. A subsequent row-height correction
passed the focused render check; standard and accessibility-size Home captures were visually inspected
using temporary local fixtures, which were then removed. Logs: `/tmp/agora-home-carousel-tests.log` and
`/tmp/agora-home-carousel-render-final.log`; captures: `build/home-carousel/`. No production deployment
or distributed iOS build is claimed.

## Lists carousels and store grouping — local, October 18, 2026

Lists now reuses Home's circular-image carousel components for inventory, shopping-list items, the watch
list and suggestions. Shopping lists are grouped by merchant identity (including separate locations), with
unassigned lists under Any store. Each list retains its own name, remaining count and checklist link;
empty and fully checked lists remain accessible. New list creation is available directly in the Lists toolbar.

Inventory previews and the inventory list put zero quantities first, then items below their restock levels,
ordered by quantity relative to that level; unknown quantities come last. This uses recorded stock and
restock levels, not the run-out forecast API. Existing household selection, refresh, item details, image
editing in detail screens, wishlist/suggestion destinations and reviewed trip planning remain available.
No API, persisted-data or seed changes are involved. A rebuilt app is required.

Validation: the isolated simulator build and all **95 selected iOS tests** passed, including restock-order
and store-grouping checks. The final copy correction passed the focused render test; standard and
accessibility-size captures were inspected. Logs: `/tmp/agora-lists-isolated-tests.log` and
`/tmp/agora-lists-render-final.log`; captures: `build/lists-carousel/`. Validation used
`/tmp/agora-lists-verification` to exclude concurrent Capture changes that blocked the initial shared
checkout build. No production deployment or distributed iOS build is claimed.

## Existing inventory image recovery — local, October 18, 2026

Existing active inventory now repairs missing image bindings at worker startup and household inventory
loads. Empty results older than seven days retry automatically, and startup revisits old search-version
misses without bypassing the current negative cache. Jobs reuse the suggestions/watch image discovery
and automatic selection pipeline. Explicit selections, removals, photos and successful images remain
preserved. Demo backfill repairs missing bindings with labeled sample imagery and makes no web searches.

Visible native thumbnails continue checking after the initial 90-second search window and retry transient
load failures while the app is active. The shared cache and account/household invalidation still apply.

Validation: **679 backend tests**, Ruff, diff checks and **9 iOS image tests** passed. The simulator image
render was inspected, and the demo CLI reset passed on a fresh disposable local database. A live online
probe used an ordinary disposable local account with existing unresolved Barilla spaghetti and PS5 items:
worker startup queued both, selected Walmart/PlayStation source images automatically, and served authenticated
image bytes with HTTP 200 without manual searches/selections. Logs: `/tmp/agora-inventory-images-backend.log`,
`/tmp/agora-inventory-images-ios.log`, `/tmp/agora-inventory-image-live.log`; simulator results:
`/tmp/agora-inventory-images.xcresult`. No migration, production deployment or distributed app build is claimed.

## Simplified scan and review flow — local, October 18, 2026

The home carousel change was committed as `0b85b3b` and pushed to `origin/feat/home-carousels` before
scan work began. That branch retains the reconciled native dependencies described above; it was not
merged into main or deployed.

Native Capture now emphasizes Scan items, Choose photos and Scan a shelf, with Files under Import and
short capture guidance. Camera photos/videos and supported imports share automatic recognition followed
by explicit review. Multiple imports are queued for individual review; PDFs remain view-only. Recent scans
replaces the main media grid and derives review/save status from existing account-bound local metadata.
Review uses compact selection/quantity rows, expandable details, uncertain-item labels and a persistent
Add N items button. Success offers View inventory, Scan more or Review next scan. Store input stays usable
while identification runs; existing observed-total behavior, model/demo disclosures and idempotent save
recovery are preserved. No new stored-data format, backend endpoint, migration or seed is introduced.

Validation: all **119 selected simulator tests passed**, covering capture, inventory, authentication,
images, shopping, watches and trips. The final label/copy adjustment passed **9 focused tests**. Standard
landing/review/success captures and accessibility-size landing/review captures were inspected, including
scrolled item rows.
Logs: `/tmp/agora-scan-validation-isolated.log`, `/tmp/agora-scan-final-render.log`; captures:
`build/scan-flow/`. An earlier run was interrupted before test startup by concurrent use of the shared
simulator; validation was completed on a separate simulator. Physical camera/microphone hardware and
live credentialed model calls were not exercised. The scan changes are local source, not a distributed app.


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


## Existing inventory image recovery deployed — October 18, 2026

PR [#39](https://github.com/saharshBhargava/agora/pull/39) merged as
`343f183e406dd28db6390e3e6893883254e2b41a`. PR PostgreSQL/TimescaleDB suites, Docker build and
upgrade/rollback rehearsal passed, followed by green main CI and the
[managed deployment](https://github.com/saharshBhargava/agora/actions/runs/39133567814). Read-only public
readiness verified that exact running commit, TimescaleDB enabled, migration 0019 and no pending migrations.
The isolated release checkout passed all 679 backend tests and Ruff.

Missing-image repair, automatic retries for old inventory search misses, and demo-image backfill are live.
No production reset or test writes were performed. The native continued-polling improvement remains local
and needs an app rebuild; this release does not distribute an iOS build. Earlier local-only backend notes
for this feature are superseded by this deployment verification.


## Automatic inventory images at app startup — local, October 18, 2026

The native app now preloads image descriptors and bytes for the full returned household inventory as
soon as inventory loads, including offscreen and archived items. Four concurrent one-read tasks prevent
pending searches from holding up other items. Foreground passes revisit pending work every 15 seconds;
ready results share the existing cache with visible thumbnails. New and renamed items join automatically.
Account/household changes invalidate old work and clear private images. The deployed backend continues
to own online discovery and automatic selection; no additional backend release or migration is needed.

Image editor sheets, thumbnail tap/long-press editing, Change image buttons, alternative selection,
photo upload, removal and manual search controls have been removed from the native app. It settles on
the automatic result. Existing stored overrides and the older-client selection API remain compatible.

Validation on a checkout reconciled with main through PR #40: 42 inventory/shopping/image simulator
tests passed, followed by all 11 image tests after extending startup coverage. The startup test mounted
only the session synchronizer (no thumbnails), fetched all 12 images including an archived item, picked
up an initially pending offscreen image automatically after 15 seconds, loaded a newly added item, and
cleared images on sign-out. Pending-first batch and authenticated transport regressions also passed.
Logs: `/tmp/agora-startup-images-tests.log`, `/tmp/agora-startup-images-final.log`; results:
`/tmp/agora-startup-images-final.xcresult`. The tested source was applied back to the shared checkout
and compared byte-for-byte. A rebuilt iOS app is required; no app distribution is claimed.
