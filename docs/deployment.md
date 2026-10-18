# Deployment and recovery — actual configuration and limits

Verified October 17, 2026 PDT. [Current-state snapshot](current-state.md) records exact source/live commits,
database versions, schema and test evidence. [SETUP.md](../SETUP.md) is for recreating the environment;
it is not necessary to recreate services or credentials for routine development.

## Existing resources

| Resource | Current value |
|---|---|
| API origin | `https://agora-api-yq3m.onrender.com` |
| Service dashboard | [agora-api](https://dashboard.render.com/web/srv-dba2ram1egvs739549ug) |
| Render service / Blueprint IDs | `srv-dba2ram1egvs739549ug` / `exs-dba2p92jnfac73e4kfu0` |
| Live application release verified | `f65cf0eccd2da9661f2d1220e861cbd9ff765997`; deployment `dep-dba3tcajnfac73e8l9t0` |
| Deployment source | GitHub `saharshBhargava/agora`, branch `main`, root `backend` |
| Docker paths | `dockerfilePath: ./Dockerfile`, `dockerContext: .`, relative to `rootDir: backend` |
| Compute / workspace | Render Free web service / Hobby workspace; these are separate plan concepts |
| Database/media | Existing Tiger Postgres + TimescaleDB; `AGORA_STORAGE_BACKEND=db`; no R2 bucket required |
| Process layout | FastAPI plus in-process worker in the same service, `AGORA_RUN_WORKER_IN_PROCESS=true` |
| Auth/seeding | `AGORA_ENV=demo`, `AGORA_AUTH_MODE=google`, password demo enabled; seed on boot, seed-new-users off |
| Readiness / auto-deploy | `/readyz`; **After CI Checks Pass** in live settings and `checksPass` in Blueprint |

Do not restore Docker context `./backend`: it previously resolved to `backend/backend` and failed the build.
`.github/scripts/build_render_image.py` makes CI build the same effective paths as Render.

## Normal backend and DB update sequence

1. Review and merge changes into `main`. GitHub Actions runs the workflows whose path filters match.
   Backend CI runs Ruff, pytest against Postgres 17 and TimescaleDB 17, and the actual Blueprint Docker build.
   Relevant iOS changes also build and run the selected simulator tests and capture onboarding.
2. Render is configured to wait for the commit's checks, then build/deploy automatically. It requires a
   connected Git provider; the live service has Git credentials linked to the owner's account.
   **The latest verified release was manually triggered. A separate fully automatic merge-to-live test
   has not been recorded. Do not state that it was proven just because the setting is enabled.**
3. The new Docker container runs `python -m app.migrate`, then `python -m app.seed` when seed-on-boot is true,
   then starts Uvicorn and the in-process worker. See [Dockerfile](../backend/Dockerfile).
4. Migrations apply new, numbered SQL files to the **existing Tiger database**. They are checksummed,
   advisory-locked and individually transactional. Applied files are not rerun; editing one causes startup
   to fail. A Python model/router change does not generate a schema migration automatically.
5. Hosted seeding keeps the catalog and one designated demo current through idempotent backfills. It does
   not reset rehearsed inventory/history or seed ordinary users.
6. Render checks the new instance before switching traffic. The API URL stays the same.

Routine code/schema updates should not need a new account, service, password or database. New secret values
still go through Render Environment; Blueprint `sync:false` fields prompt at initial creation, not every
sync. Never put a DSN, password, JWT secret, provider key or deploy-hook URL into Git or public logs.

Render does not auto-deploy a commit with **zero detected CI checks** in checks-pass mode. Docs-only
commits can therefore advance main without a new image; that is not evidence of a broken backend.
The image SHA displayed in Render, not the newest GitHub SHA, identifies the running release.
Manual deploys can bypass the normal CI wait, so verify the intended commit's checks before using them.

## Failure behavior: what is and is not automatic

| Failure | Behavior / required response |
|---|---|
| CI fails | Automatic deploy does not proceed. Fix the code/check; do not assume the failed change is live. |
| Image build fails | Existing running image is not replaced. Inspect build logs and correct paths/dependencies. |
| New app fails startup/readiness | Render keeps traffic on existing instances and cancels an unhealthy new deploy after its timeout, subject to shared-DB compatibility. |
| App is live but a user flow is wrong | No functional auto-revert. A person must deploy a fix, revert in Git, or select a retained successful Render deployment. |
| Existing instance fails health checks | Render can stop routing to it and restart it. Restarting the same code is not a rollback to an older release. |
| A migration fails | That SQL file's transaction rolls back; successful earlier files remain applied. Startup does not continue. |
| Migration succeeds but breaks compatibility/data | No automatic database undo. Older app instances can also break against the changed database. A forward repair or DB recovery may be needed. |

`/readyz` performs a database `SELECT 1`; it checks reachability, not every table, permission, login, model,
checkout or inventory query. No automatic post-deploy business-flow smoke tests or functional rollback were
added. A Git revert/Render rollback changes application code, **not Tiger schema or data**.

Use additive migrations compatible with the previous running app. Add/migrate usage before removing old
columns in a later release. Never use demo reset or snapshot import as an automatic deployment repair.

## Recovery reference — not actions performed by this documentation update

- **App-only regression:** inspect logs and live SHA; choose a retained successful image in Render's Deploys
  page, or revert the code and release a fix. Dashboard rollback disables auto-deploy; reenable it deliberately
  after the bad source is fixed. Artifact retention is plan-dependent, not a permanent archive.
- **Before app rollback:** check whether the current DB remains compatible with the older app. Rolled-back
  images execute their own startup command, including their migration/seed checks; do not assume that repairs DB state.
- **DB incident:** identify what committed, preserve evidence and assess a forward repair. Tiger supports
  backups/PITR, but this account's exact retention, restore permissions and a restore rehearsal were not
  verified. Recovery can create a fork and require changing the backend DSN; it is not an automatic Render rollback.
- **Snapshot/local fallback:** `app.tools.snapshot export` creates a private data archive. **Import replaces
  the target's application data.** Use an isolated local target for rehearsals; never point import at hosted
  Tiger without explicit authorization. Local launcher/tunnel instructions are in SETUP; do not assume a
  prepared snapshot, spare model key or fallback Mac already exists.

## Verification after an authorized release

Record the observed commit, time, migration state and results, rather than assuming a merge deployed.

1. Inspect Render Deploys: intended SHA, successful/live state and trigger.
2. Check public `/readyz` (200 and expected Timescale state) and `/openapi.json` for expected routes.
3. Obtain a demo token privately via `POST /v1/dev/login`; never print/store its password or token in logs.
4. Check `/v1/demo/profile`, `/v1/me`, `/v1/inventory`, `/v1/demo/calendar/events` and Calendar availability.
   Anonymous protected requests must return 401. Use tests on a disposable DB for mutations/isolation;
   do not create live orders or reset the account merely to produce a green smoke-test log.
5. Confirm only the intended new migrations were added. Update this record/current-state/PR handoff when
   behavior changes. Test counts and seed counts are dated evidence, not immutable production assertions.

## Access and remaining operational work

- People with GitHub merge rights can release code and migrations indirectly through the configured flow.
  This does **not** grant Render/Tiger dashboard, secrets, recovery or database-admin access.
- The Render workspace was checked: **Hobby**, which cannot invite additional members. Team dashboard
  access requires Pro or higher; a paid workspace does not itself upgrade Free service compute.
- No teammate Render/Tiger invitations or individual DB access were configured in this setup. Existing
  Tiger project membership was not audited; invitations made separately by the owner are not assumed absent.
- The Git provider credential is currently owner-linked. No alternate shared deployment identity or protected
  GitHub manual-deploy/rollback workflow with Render API credentials has been built.
- GitHub branch protection could not be inspected with the available non-admin repository access. Required
  reviews/check enforcement are **unverified**, not confirmed disabled.
- Staging/preview DB, tested backup recovery, shared incident ownership, functional smoke/rollback automation
  and alert routing are unfinished operational work, not completed features. Do not silently implement them
  or change plans, access, billing or credentials while working an unrelated task.
- Free Render instances can sleep and hit usage limits. The ten-minute keep-warm workflow only checks
  readiness and scheduled Actions can be delayed; it is not guaranteed uptime or a DB backup. Tiger's
  current billing/trial/retention limits still need owner verification.

## Provider references

Checked October 17, 2026; provider rules can change. These describe platform behavior, not proof that a
specific account option has been enabled:

- [Render deploys and CI gating](https://render.com/docs/deploys)
- [Render health checks](https://render.com/docs/health-checks)
- [Render rollbacks](https://render.com/docs/rollbacks)
- [Render workspace membership](https://render.com/docs/team-members)
- [Render Free limitations](https://render.com/docs/free)
- [Tiger backups and recovery](https://www.tigerdata.com/docs/deploy/tiger-cloud/tiger-cloud-aws/high-availability/backup-restore)
