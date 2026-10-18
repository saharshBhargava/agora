# Merged-work handoff for returning agents

Updated October 17, 2026 PDT. **The original pending PRs are finished and merged.** This file is a
reconciliation/history guide, not a list of PRs still waiting for implementation or deployment.
Read [current state](current-state.md) first and [deployment](deployment.md) before operational work.

## Before continuing a five-hour-old checkout

Fetch origin, inspect your own local changes, compare with current main, and integrate main without
throwing work away. Do not push an old branch as a replacement for main, reopen a duplicate of merged work,
or restore obsolete migrations/auth clients just because your old tests expected them.

Observed older local checkouts were left intact:

| Branch/checkpoint | Already superseded by | Required reconciliation |
|---|---|---|
| `feat/forecasts-lists` at `f4d9b01` | PR #9 plus demo/client/hosting integration | Use `0010_forecasts*`, current demo backfills and shared client; do not reapply `0007_forecasts*` |
| `feat/agent-commerce` at `44de6e8` | PR #10 and payment retry fix #18 | Use `0011`/`0012`, demo-only simulation and stable provider charge keys |
| `claude/wishlist-61fedc` at `3fd2ce1` | PR #4 and later shared-client/demo work | Wishlist API is already merged; inspect the remaining UI requests rather than recreating the backend |

These are dated observations, not instructions to delete/reset those branches or an exhaustive list of
current agents. New migration numbers and branch state must always be checked again on current main.

## Merged PR record

| PR | Work now on main | Preserve when reconciling |
|---|---|---|
| [#4](https://github.com/saharshBhargava/agora/pull/4) | Wishlist, suggestions, feedback, priority ranking | Existing contract/lifecycle; wishlist UI is separate work |
| [#5](https://github.com/saharshBhargava/agora/pull/5), [#8](https://github.com/saharshBhargava/agora/pull/8) | Shared Agora client, reconciled native identity | One `Agora/API/AgoraClient.swift`; #17 later adds demo bearer selection |
| [#7](https://github.com/saharshBhargava/agora/pull/7) | Local launcher, snapshots, keep-warm | Local fallback tools exist; no claim that recovery was rehearsed or a snapshot already exists |
| [#9](https://github.com/saharshBhargava/agora/pull/9) | Forecasts and shopping lists, `1dba30f400825000a07ec78ee4fb24b09e254d07` | Renumbered migrations + demo backfill; native forecast/list UI remains requested |
| [#10](https://github.com/saharshBhargava/agora/pull/10) | Commerce policy, mandates, intents, kill switch, budgets/spend, `b218ca8684a3c7c7a1d8400a6a4398825b0e438b` | Demo-only payments; ordinary users fail closed until a real provider exists |
| [#11](https://github.com/saharshBhargava/agora/pull/11) | One designated demo account, `7e1d26dd469fb61ce34c8c18ee9f021b97ac80ed` | Server-owned `users.is_demo`; ordinary hosted users get no synthetic history |
| [#12](https://github.com/saharshBhargava/agora/pull/12), [#13](https://github.com/saharshBhargava/agora/pull/13) | Initial hosting docs, DB verification and integration handoff | Earlier deployment status was later superseded; use the current-state record |
| [#14](https://github.com/saharshBhargava/agora/pull/14) | HS256 subject allowlist, `d6bac9d122ebe902735cfcfccd8f704ffbd115a6` | A demo signing secret cannot authenticate an arbitrary `google:*` subject |
| [#15](https://github.com/saharshBhargava/agora/pull/15) | Render Docker path fix, `dd3db60869697a81145e58d2a6651066b75cb20b` | Root `backend`, Dockerfile `./Dockerfile`, context `.`; CI reads Blueprint paths |
| [#16](https://github.com/saharshBhargava/agora/pull/16) | Shared live URL/frontend handoff, `28060c2d78f07e91c3945e06bd0a83f86dae66b1` | Keep checked-in public origin; local overrides stay untracked |
| [#17](https://github.com/saharshBhargava/agora/pull/17) | Password-first native demo, built-in integrations, private Calendar and iOS CI, `f65cf0eccd2da9661f2d1220e861cbd9ff765997` | Google optional for demo; preserve server eligibility/session boundaries and migration `0013` |
| [#18](https://github.com/saharshBhargava/agora/pull/18) | Charge idempotency across rolled-back proposals, `c32e2ddac460825d230aa5a4b8c337b6aca2bae2` | Proposal charge keys derive from user + client key, not a newly generated DB intent ID |
| [#19](https://github.com/saharshBhargava/agora/pull/19) | Verified live demo handoff, `860dc1cda617da0263015dd314d90f6fe8745d66` | Documentation-only; actual running image remains #17's commit |

PR numbers are not merge-order timestamps: #18 merged before #17. The live #17 image includes #18's fix.
No original pending PR was left open at the documentation audit. Check GitHub for PRs opened subsequently.

## Additional changes already integrated on main

- `4d7886a`: model-agnostic Gemini/OpenAI-compatible connections, profiles, feature assignments and shared
  caption/recognition services under `Agora/Models/`. Do not revert to Gemini-only feature controllers.
- `862f900`: Gemini-compatible inventory generation schema and actionable recognition errors. Local
  validation still enforces lengths/counts; do not reintroduce unsupported generation-schema constraints.
- `1154abc`: preserve readable brand, variant and package size in reviewed inventory names; unknown details
  stay empty, and older recognition results remain decodable. New prompts inspect labels across frames.
- `69dba6d` recorded the **six-hour refresh** requirement; `7bc3f8e` then implemented it: backend
  replenishment jobs at 00/06/12/18 UTC (`0014_wishlist_refresh.sql`), `POST /v1/wishlist/refresh`, and the
  native Wishlist/Suggested views under `Agora/Shopping/`. Live retailer price monitoring is still deferred.
- Capture/inventory integration includes shared account/household-scoped persistence, purchase stores/dates,
  reviewed metadata-only saves, and safe request retries. Preserve these when integrating an older UI branch.

## Migration reconciliation — never apply both versions

| Old unmerged filename | Final filename on main |
|---|---|
| `0007_forecasts.sql` | `0010_forecasts.sql` |
| `0007_forecasts.timescale.sql` | `0010_forecasts.timescale.sql` |
| `0007_agent_commerce.sql` | `0011_agent_commerce.sql` |
| `0008_spend_hypertable.timescale.sql` | `0012_spend_hypertable.timescale.sql` |

`0009_demo_account.sql` preceded the forecast/commerce integration. `0013_calendar_events.sql` is now
merged and applied to Tiger. Gaps in migration numbers are intentional; do not fill them by restoring old
branch files. Merged SQL is immutable and checksummed. Inspect main and open PRs before choosing the next number.

If a **disposable branch-local development DB** already applied obsolete filenames, recreate that dev DB
before testing the renamed set. This is not permission to recreate/reset Tiger, import over hosted data,
edit the production migration ledger, or rename SQL that already shipped.

## Current demo/auth/client behavior

- Username **`demo`**, private Render `AGORA_DEMO_PASSWORD`; visible profile Alex Rivera / `alexrivera`.
  Native Welcome has **Sign in to demo**. Google and model-provider keys are not prerequisites.
- Google is an optional alternate entry only if a verified address is configured in `AGORA_DEMO_GOOGLE_EMAILS`.
  The repo contains public Google client IDs, not a Gmail password or provider key.
- `CalendarConnection` selects origin-bound demo session or Google identity; `AgoraClient` asks it for the
  appropriate Bearer token. Preserve account-change cancellation and Keychain storage; no password persistence.
- Demo chat/captions/recognition use built-in `agora-sample-v1` fixtures with truthful disclosures, not real
  inference. Calendar persists private Agora events and requires approval/idempotency for creation.
- Demo server scans bypass configured real vision providers. Ordinary accounts retain their configured
  model/Calendar flows; they cannot enable built-in recognition by sending a provider field.
- Hosted `app.seed` fills the catalog + one designated demo, not `kedar`/`saharsh` histories. Those legacy
  histories/examples are dev/test fixtures. `ensure_demo_account` adds new feature data without resetting history.
- Payment simulation applies only to `is_demo_user(...)`, even if a real provider is injected/configured.
  Ordinary Agora checkout returns `503 payments_unavailable`; no fake charge/order/spend is recorded.
- `agent.updated` can identify the user on pause/resume without a changed intent. Clients must refetch agent state.

Contracts: [demo](api/demo-integrations.md), [commerce](api/agent-commerce.md),
[forecasts/lists](api/forecasts-and-lists.md), [wishlist](api/wishlist.md).

## Deployment and validation record

The first build at `99fadec` failed because Docker context resolved to `backend/backend`. The corrected
Blueprint later deployed `d6bac9d`, which was the first verified live image. It is historical, not the latest.

Current verified live image is `f65cf0e`, manually deployed October 17 at 8:36 PM PDT and verified at 8:38 PM:
login, profile, 12 inventory items, 3 private Calendar events and availability passed without Google/model
credentials. Anonymous demo profile returned 401. Migration `0013` and demo rows were rechecked read-only
in this documentation audit; no hosted reset or real payment was performed.

Both post-merge CI runs on `f65cf0e` passed:
[Postgres/TimescaleDB/Docker](https://github.com/saharshBhargava/agora/actions/runs/39094132788),
[24 selected iOS tests + onboarding capture](https://github.com/saharshBhargava/agora/actions/runs/39094132758).
Earlier local validation for #17 had 238 backend tests plus a successful **local** demo reset; #9/#10 had
smaller test totals at their earlier checkpoints. Those historical totals are not current CI assertions.
Real Google consent/model-provider/physical-device flows and DB backup restoration are not claimed tested.

See [deployment.md](deployment.md) for CI-gated auto-deploy configuration, manual recovery, DB rollback
limits and access gaps. Do not interpret a configured auto-deploy setting as a recorded hands-off test,
or a repository merge as proof that a new image is live.

## Wishlist and suggestion integration (after the snapshot above)

Wishlist UI, model-backed ideas and six-hour replenishment jobs include the password-only demo changes.
The refresh-state migration is `0014_wishlist_refresh.sql`; `0013_calendar_events.sql` is already merged and
must not be renamed. Demo backfill preserves both Calendar events and shopping refresh state. The built-in,
server-verified demo model also supports Shopping suggestions without external model calls.
