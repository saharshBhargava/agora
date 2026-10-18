# Deployment: how releases work and how anyone can fix them

The API runs on Render and the database on Tiger Cloud. Releases are driven entirely from GitHub, so **anyone
with write access to this repo can ship, check, roll back or restart production. Nobody needs a Render or
Tiger login** (the free Render workspace can't invite teammates anyway). [Current state](current-state.md)
records what was last verified live.

## Existing resources

| Resource | Value |
|---|---|
| API origin | `https://agora-api-yq3m.onrender.com` (`/readyz`, [`/docs`](https://agora-api-yq3m.onrender.com/docs), `/openapi.json`) |
| Render service | `agora-api`, `srv-dba2ram1egvs739549ug` (Free compute, Hobby workspace), Blueprint `exs-dba2p92jnfac73e4kfu0` |
| Image | `rootDir: backend`, `dockerfilePath: ./Dockerfile`, `dockerContext: .` (relative to `rootDir`; never `./backend`) |
| Process | FastAPI + in-process worker; on boot: `app.migrate` → `app.seed` (catalog + designated demo) → Uvicorn |
| Database | Tiger Postgres + TimescaleDB, media stored in the DB (`AGORA_STORAGE_BACKEND=db`) |
| Releases | `.github/workflows/deploy.yml`, driven by the Render API (Render's own auto-deploy is turned off) |
| Monitor | `.github/workflows/keep-warm.yml`, every 10 min: wakes the free instance, red on outage, and starts a release when production is behind main (never retries a failed one) |
| Backups | `.github/workflows/db-backup.yml`, daily, encrypted, kept 14 days as workflow artifacts |

## The release pipeline

```
PR ──► backend CI: ruff · pytest (Postgres 17 + TimescaleDB) · Docker image from render.yaml
       └─ release-rehearsal: migration guard · previous release's DB upgraded by this branch ·
          new code AND previous release smoke-tested on it (proves deploy and rollback are safe)
merge to main ──► backend CI again ──green──► deploy workflow
       1. nothing under backend/ or render.yaml changed since the live release? → no build (saves Render minutes)
       2. Render builds that exact commit; new migrations apply on boot
       3. Render switches traffic only when the new instance passes /readyz (which fails if a migration
          is missing). Build, migration or startup failure → previous release keeps serving, job goes RED
       4. read-only smoke checks on production → failure → automatic rollback to the previous release, RED
```

- **Where to look:** the commit's checks on GitHub, the repo's **Deployments → production** panel, or
  `gh run list --workflow deploy.yml`. Every run writes a summary of what happened and what is live.
- **One release at a time.** A merge during a release waits; a burst of merges builds only the newest.
- **Docs-only or iOS-only commits don't trigger a release** (backend CI path filters, then the unchanged check).
- `/readyz` returns `commit` (the running Git SHA) and `migrations` (`latest`, `pending`). It answers 503
  while any migration this build expects is missing, so a half-migrated release never receives traffic.

### Commands anyone with write access can run

Actions → **deploy** → *Run workflow*, or from a terminal:

```bash
gh workflow run deploy.yml -f action=status
```

```bash
gh workflow run deploy.yml -f action=deploy -f ref=<sha-or-branch>
```

```bash
gh workflow run deploy.yml -f action=rollback
```

```bash
gh workflow run deploy.yml -f action=restart
```

`rollback` without a ref returns to the most recent earlier release Render still has. With `-f ref=<sha>`
it returns to that release, if still retained (Render keeps only recent builds). Otherwise use
`action=deploy -f ref=<known-good sha>`. Watch any run with `gh run watch`.

## When a release fails

The job summary says which case it is. Production is already safe in every case; your job is to fix forward.

| Red step says | What happened | Do this |
|---|---|---|
| `build_failed` | Docker build failed. Production unchanged | Read the error lines in the summary; reproduce with the CI `image` job |
| `update_failed` | The new instance failed to boot or never passed `/readyz`: usually a migration or startup error. Production unchanged | Error lines are in the summary. A migration that failed rolled back its own transaction; earlier files in the same release may have applied |
| `live but failing checks` + rolled back | Deployed, then smoke failed. Code was rolled back, **the database was not** | Fix forward. Because migrations must be backward compatible (below), the previous code runs fine on the new schema |
| `Managed releases not configured` | `RENDER_API_KEY` secret missing | One-time setup below |
| `Render rejected RENDER_API_KEY` | Key revoked or expired | The Render owner creates a new key and updates the secret |

Agents: after merging backend work, run `gh run watch` on the deploy run (or check it a few minutes later)
before reporting done. A red run is yours to fix; production keeps serving the last good release meanwhile.

## When production is down

The keep-warm run goes red. Run `action=status` to see the live deploy and checks, then `action=restart`.
If the latest release is the cause, use `action=rollback`. A free instance that was asleep takes about a
minute to answer; that alone isn't an outage.

## Changing the database safely

Releases apply migrations to the live database **while the previous release is still serving**, and rollback
never undoes SQL. So every migration must work with both the old and the new code. CI enforces this
(`.github/scripts/check_migrations.py` and the release rehearsal):

- Add a new `backend/migrations/NNNN_name.sql` with the next free number. Never edit a merged one; the runner
  checksums them and the release would fail to boot.
- **Allowed freely:** create tables/indexes/views; add nullable columns, or `NOT NULL DEFAULT ...` columns;
  add constraints and policies; backfill with `UPDATE`.
- **Needs expand → contract:** dropping or renaming a table/column, changing a type, `SET NOT NULL`, deleting
  rows. Release 1 adds the new shape and makes the code use it. Release 2 (after release 1 is live) removes the
  old shape, in a migration containing `-- agora: allow-breaking <why the old code no longer needs it>`.
- New household data also needs demo rows and an idempotent backfill in `ensure_demo_account` (see CLAUDE.md).

Example: add a column. Commit `ALTER TABLE inventory_items ADD COLUMN notes text;`, use it in the code, merge.
The pipeline migrates and releases it.

## One-time setup

About 5 minutes, done once by the owners. Without these the pipeline still tests and monitors, but can't release, roll back or back up.

1. **Render owner:** Account Settings → API Keys → create a key.
2. **Repo admin (Saharsh):** Settings → Secrets and variables → Actions → *New repository secret*:

| Secret | Value | Enables |
|---|---|---|
| `RENDER_API_KEY` | the Render key | releases, rollback, status, restart |
| `AGORA_DEMO_PASSWORD` | Render → Environment → `AGORA_DEMO_PASSWORD` | signed-in smoke checks (read-only, demo account) |
| `AGORA_DATABASE_URL` | the Tiger connection string | daily backups |
| `AGORA_BACKUP_PASSPHRASE` | a long random phrase; **also store it in the team password manager** | backup encryption; restores need it |

Nothing else is needed: within about 30 minutes the keep-warm monitor notices production is behind main and
starts the release itself (it runs on GitHub's servers, no one's computer). The first managed release turns
Render's own auto-deploy off. Secrets are only readable inside workflow runs, never by collaborators. Optional
hardening: move them into the `production` environment, limited to the `main` branch.

## Backups and restoring

Every day, `db-backup` exports the whole database read-only, encrypts it (AES-256-GCM, scrypt key) and keeps it
14 days as an artifact. Encryption makes it safe on this public repo. If Tiger becomes unavailable, or you
just want production data locally:

```bash
gh run download --name db-backup-<run id> --dir backups
```

```bash
cd backend && AGORA_BACKUP_PASSPHRASE='<passphrase>' uv run python -m app.tools.local_demo --tunnel --import-snapshot ../backups/agora-db.snapshot
```

That serves the backed-up data from your laptop with the same code (SETUP.md "Plan B"). To move to a new
hosted Postgres instead: import into it with `app.tools.snapshot import`, then point `AGORA_DATABASE_URL` in
Render at it. Import replaces the target's data, so never aim it at a database you want to keep. If Tiger
only hit its storage cap, it turns read-only, and a fresh export (`gh workflow run db-backup.yml`) still works.

## Free-tier budget

The pipeline is sized to stay well inside every free plan:

| Service | Limit | This setup uses |
|---|---|---|
| GitHub Actions | Free and unmetered for standard runners on **public** repos; ~20 concurrent jobs (5 macOS) | CI on PRs/merges, a few seconds every 10 min for keep-warm, 1 backup/day. **If the repo goes private** (2,000 min/month, macOS counts 10x): change keep-warm to every 30 min and run iOS CI on PRs only |
| Render Free | 750 instance hours/month (one always-on service ≈ 744), limited build minutes, may restart anytime | One service; builds only when backend code changed, and only the newest of a burst. **Don't add preview environments or a second service**: they share the 750 hours |
| Tiger Free | 750 MiB storage per service, shared compute | Read-only smoke checks and one export per day; photos are deleted after review |

## Local fallback

`cd backend && uv run python -m app.tools.local_demo --tunnel` runs the same release on a laptop: Docker
TimescaleDB, or an embedded Postgres when Docker is missing. Add `--database-url "<tiger url>"` to serve live
data while Render is down, or `--import-snapshot <file>` for a backup. See SETUP.md "Plan B".

## What is still manual or unverified

- The pipeline's first managed release, rollback and backup run will be the first live exercise. Until a
  green deploy run is recorded in current-state, treat them as configured, not proven.
- Tiger's own backups/PITR on this plan, and a restore into a new Tiger service, are untested.
- No staging environment. The release rehearsal on a throwaway database stands in for one.
- GitHub branch protection (required checks/reviews) is unverified; an admin can enable it in Settings → Branches.
