# Merging Dibs into main: audit summary and plan

Status: **Phase A executed on `merge/dibs-phase-a`** (side-by-side land). Later phases remain backlog.
Date: 2026-10-18. Sources: original audits on `dibs-mock-demo` plus this Phase A PR.

## Where the two apps stand

| | Team app (main) | Dibs (this branch) |
|---|---|---|
| iOS | `Agora/` SwiftUI, Swift 5, `dev.agora.browserchat`, team `8N46NST49L`, GoogleSignIn, committed `Agora.xcodeproj` | `ios/` SwiftUI, Swift 6, `dev.dibs.app`, XcodeGen (`ios/project.yml`), ~10.9k lines, 289 tests |
| Backend | `backend/` FastAPI + Postgres/Timescale, RLS, `/v1/*`, Bearer (Google ID token or `/v1/dev/login` demo JWT) | `server/` Node/Fastify + WS, `/api/*`, in-memory + JSON snapshot, ~2.8k lines, 212 tests |
| Web | none | `web/` Next.js static export served by the Dibs server (guest join/claim), 135 tests |
| Hosting | Render free `agora-api` (rootDir `backend`), Tiger Postgres, deploy on merge, keep-warm | laptop + ngrok via `scripts/demo-server.sh` (verified end to end); `railway.json` never deployed |
| Identity | Google / demo login, households (one member each, no invites yet) | none: typed name + per-run person id |
| Payments | one-shot token `charge`, mandates/intents, simulation only for the demo account | hold → incremental → reverse → capture per claimer + simulated Visa Direct payout, test PANs |

## Merge mechanics (verified)

- `git merge-tree origin/main HEAD` is clean. Dibs adds ~253 files in new folders and changes only `.gitignore`; nothing changed on both sides. Main has no root `README.md`, `Dockerfile` or `package.json`, so no root collisions.
- Main's CI and deploy ignore Dibs paths (`backend.yml`: `backend/**`, `render.yaml`; `ios.yml`: `Agora/**`, `Config/**`, `assets/**`). Nothing breaks; Dibs simply gets no CI until it has its own workflow.
- Trap: Dibs's root Node `Dockerfile`. Render only ignores it because `render.yaml` pins `rootDir: backend`. Keep `render.yaml` untouched; nest Dibs later (below).

## Decisions

1. **Before the demo: Option A, side by side.** Low risk, ~2–3 h. No restructuring, no new deploys.
2. **Hosting for the demo: laptop + tunnel.** The "no second Render service" rule is soft (per the user), but Render free still doesn't fit: instances sleep after ~15 min (drops the live WebSocket mid-shop) and the free disk is wiped on restart (loses runs and simulated holds). After the demo: Railway with a volume, or a paid Render instance with a disk.
3. **Wish page: Dibs-server proxy to the team backend**, using the demo login (`POST /v1/dev/login`, env `TEAM_API_BASE_URL` + `AGORA_DEMO_PASSWORD`) and `GET /v1/lists?status=open` (`source=="user"`, unchecked), `GET /v1/wishlist/suggestions`, `GET /v1/forecasts/runouts?within=7d`. CORS is off on main and Google tokens are pinned to Agora's client id, so the server proxies; the password never reaches clients. Fallback: suggestions from Dibs run history. (Built env-gated on this branch; the live hookup is a merge-day step.)
4. **After the demo: Option B (Dibs as a "Shop together" tab in the Agora app)**, then main-side features, and only then consider Option C (porting the Dibs server to FastAPI/Postgres).

## Phase 0 — on this branch, before the demo (in progress)

- Item quantity (×N, merge, stepper) — done (`4102c33`, `2918099`, `08e7f53`).
- Add Wish page (board 11 on the design canvas; `GET /api/runs/:id/wish-picks`; iOS `WishView`) — in progress.
- Security quick fix — in progress: random shopper id per run, per-person secret key on REST + WS, redact `authId` / PANs from every outgoing run, scope price-request routes.
- Full test suites green, two-account run on the phone, push `dibs-mock-demo`.

## Phase A — side-by-side merge into main (~2–3 h, low risk)

1. `git merge origin/main` into the Phase A branch (re-verified clean on 2026-10-18), run all suites.
2. Move the root `README.md` (titled "Dibs") to `docs/dibs/README.md`; refresh its stale parts (it still says stub detection/pricing and Railway). Link it from `docs/current-state.md` with a short Dibs section; add a Dibs section to `CLAUDE.md` / `AGENTS.md` (how to run, env vars, that Dibs is not on Render).
3. Add `.github/workflows/dibs.yml`, path-filtered to `server/** web/** ios/** scripts/{dev,demo-server,smoke}.sh package.json pnpm-*`: `pnpm install --frozen-lockfile && pnpm -r test && scripts/smoke.sh`; a macOS job `brew install xcodegen && xcodegen -s ios/project.yml && xcodebuild test -scheme Dibs`.
4. Decide on the 6 untracked `docs/screenshots/*.jpg` (commit or ignore).
5. One env naming scheme for Gemini if Dibs ever shares a host: main uses `AGORA_GEMINI_API_KEY`, Dibs `GEMINI_API_KEY`.
6. Open a PR into main; merge on green. Merging to main is a release on this repo (auto-deploy is backend-only, so Dibs paths deploy nothing).

## After the demo

**Phase 1 — nest and harden (S–M).** Move to `dibs/ios`, `dibs/server`, `dibs/web`, `dibs/scripts` (~10 files of path edits: Dockerfile, .dockerignore, railway.json, pnpm-workspace, root package.json, scripts, README, CI). Server cancel-run / leave-run that release holds. Rate limits on `/agent-step`. Token payments (no PANs on the server, M6).

**Phase 2 — Dibs as a tab in the Agora app (Option B, ~1.5–2 days).**
- Move `ios/Dibs/*` under `Agora/Dibs/` (minus Dibs's `@main`), mount its `RootView` as a tab with `.preferredColorScheme(.light)` on that subtree.
- Resolve 5 type collisions (`BrowserCall`, `BrowserError`, `BrowserPolicy`, `BrowserToolExecutor`, `HomeView`) and keep one `BrowserScripts.js`; better: give Agora's browser an unattended mode (`allowedDomains`, unattended actions, image/font block list, HTTP status capture) and delete Dibs's copies.
- Chain `onOpenURL` so `dibs://` reaches Dibs and Google sign-in callbacks still reach GoogleSignIn; add the `dibs` scheme and `DIBS_SERVER_URL` to Agora's config.
- iPad/landscape handling (Agora targets iPhone + iPad, all orientations).
- Move the 289 tests into `AgoraTests/` and add them to `ios.yml`'s allowlist; build the Swift 6 code under Agora's Swift 5 mode and run the full suite.
- Use the Agora session for the join name (M1), wish sources directly from the Agora client (M2, no server proxy needed), settle write-back (M3), merchant identity (M5).

**Phase 3 — features on main.** Household invites (migration 0017+, RLS, demo seed) so a run can start from a household (M4); orders and spend entries for captured shares (M7); push notifications for wish added / last call / charged (M8); demo-account gating for simulated payments once runs belong to accounts (M10, required by main's CLAUDE.md).

**Phase 4 — only if runs need history or cloud hosting: Option C.** Port runs/claims/settle to FastAPI + Postgres (~4–6 dev-days): start with the pure core (`money`, `run`, `settle` + their 101 tests, a near 1:1 port), then routes/WS/timers; migration `0017_dibs_runs.sql` (~200 lines) with RLS, demo rows, audit/notify. Hard parts: guests without accounts vs RLS (needs run-scoped capability tokens), WS fan-out and the frame relay inside uvicorn, restart-safe last-call timers, per-run settle locks, Pillow instead of sharp.

## Port lists (effort)

**Dibs → main:** split/tax math (S), receipt read + match + fix (M–L), hold-lifecycle payments + resumable settle (M), QFC page parser + unattended browser worker + 429 backoff (M–L; note main's rule that model text is never a price source — the deterministic parser qualifies, the Gemini `/extract` fallback does not), on-device "item landed" trigger for Capture (M), robust live socket client pattern (M), shared cart/claims/wishes/last call = the product (L), Gemini model fallback chain (S), join link + QR invite (S), browser hardening for unattended use (S).

**Main → Dibs:** sign-in and account names (M; S inside B), wish sources (M; S–M inside B), inventory + list write-back after settle (`POST /v1/inventory/recognitions` with `Idempotency-Key dibs-<runId>-<personId>`, `PATCH /v1/lists/{id}/items/{item}`; no backend change, S–M), household roster for invites (M + main feature), merchant identity for the run store (S), token payments + idempotency (S–M), orders/spend history (M), pushes (M), CI discipline (S), demo-account isolation (S).

## Open questions for the team

1. Is Option A's PR (side by side, no deploy impact) OK to land before the demo, or after?
2. Who owns household invites on main (needed for "start a run from my household")?
3. Paid hosting for the Dibs server after the demo: Railway volume or Render paid + disk?
