# Setup: getting Agora running for the demo

Everything here is free and needs no credit card. Budget about 20 minutes, mostly waiting for deploys. Do the
steps in order: step 6 needs the URL from step 2.

| # | Account | Needed for | Required? |
|---|---|---|---|
| 1 | [Tiger Cloud](https://console.cloud.timescale.com) | Database (Postgres + TimescaleDB) | Yes |
| 2 | [Render](https://render.com) | Hosting the API | Yes |
| 3 | The team's existing Google Cloud project (Saharsh's) | Google sign-in + Calendar on the phone | Already set up; just add test users |
| 4 | [Google AI Studio](https://aistudio.google.com/apikey) | Gemini key for real fridge/pantry recognition | Recommended |
| 5 | Perceptron (ask at their sponsor table) | Perceptron vision instead of Gemini | Optional |

**What to send back to Kedar's coding session when you're done:** just the Render URL (it's public, not a secret).
With it, the deploy can be smoke-tested end to end and the keep-warm job pointed at it. Never send the Tiger
connection string or any API key; those only ever go into Render.

Never paste keys into the repo, chat or Slack. They go only into Render's environment settings (and the iOS
app's own Settings screen for the on-device Gemini key).

---

## 1. Database: Tiger Cloud (about 3 min)

1. Sign up at console.cloud.timescale.com and create a service on the **Free** plan. If you're asked for a
   region, pick a US West one.
2. Open the service, then **Connect**, and copy the connection string. It looks like
   `postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require`. Use the direct URL, not a pooler URL.

The schema and demo data are created automatically on first boot; there's nothing to run by hand.

## 2. API: Render (about 10 min, mostly build time)

1. Sign in to Render with GitHub. **New > Blueprint**, then choose `saharshBhargava/agora`. Render reads
   `render.yaml` from the repo. If Render can't see the repo, the repo owner (Saharsh) has to grant Render's
   GitHub app access to it.
2. Render asks for the variables marked as secrets:
   - `AGORA_DATABASE_URL`: the Tiger connection string from step 1.
   - `AGORA_GEMINI_API_KEY`: from step 4 if you have it already; otherwise leave it blank for now.
   - Leave `AGORA_PERCEPTRON_API_KEY` blank unless you have one.
3. **Apply**. When the deploy is live, open `https://<your-service>.onrender.com/readyz`. You should see
   `{"ok": true, "timescale": true, ...}`. **Write this URL down**: step 6 needs it.

Everything else is preset in `render.yaml`:
- demo mode, with a generated dev-token secret
- Google sign-in, using the iOS client ID from `Config/Agora.xcconfig`
- database-backed photo storage
- the demo accounts seeded on boot, and sample history for every newly created account

## 3. Google sign-in + Calendar (about 2 min)

The phone signs in with Google and talks to Google Calendar directly. The backend only checks the Google ID
token the phone sends for inventory calls. The Google Cloud project and iOS OAuth client already exist; their
public IDs are in `Config/Agora.xcconfig`, and `render.yaml` uses the same client ID. While the OAuth app is in
**Testing**, only listed accounts can sign in, so:

- **Saharsh** (project owner): Google Cloud console, then **Google Auth Platform > Audience > Test users**. Add
  the Google account of every teammate and of the demo phone.

That's all. There's no web client, client secret or redirect URL to configure. If you ever switch to your own
Google Cloud project, follow "One-time Google Cloud setup" in `backend/README.md`, then set
`AGORA_GOOGLE_IOS_CLIENT_ID` in Render to the new client ID, since it must match the app's. In Testing mode,
Google expires Calendar consent after 7 days, so you may need to sign in again during a long weekend.

## 4. Gemini key (about 2 min)

1. aistudio.google.com/apikey, then **Create API key**.
2. Render, then **Environment**: set `AGORA_GEMINI_API_KEY` and save. Backend scans now use Gemini vision. Without a key
   they only work for pre-recorded replay fixtures, and the server logs a warning instead of crashing.
3. The iOS chat agent uses its own Gemini key, entered in the app's **Settings** tab. It can be the same key.

## 5. Perceptron (optional)

If the Perceptron sponsor gives you a key, set these in Render: `AGORA_PERCEPTRON_API_KEY=<key>`,
`AGORA_VISION_PROVIDER=perceptron`, `AGORA_VISION_FALLBACK=gemini`. If Perceptron errors or times out,
Gemini takes over for that frame automatically.

## 6. Point the iOS app at it

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set:

```xcconfig
AGORA_API_BASE_URL = https:/$()/<your-service>.onrender.com
```

The `$()` is intentional: it stops xcconfig from treating `//` as a comment. Leave the Google client lines as
they are unless you use your own Google project. Rebuild. Calendar and chat work without this; the Home screen's
inventory needs it.

## 7. Check it works

Run these in a terminal (they work in any shell; replace the host):

```bash
curl -s https://<your-service>.onrender.com/readyz
```

```bash
curl -s -X POST https://<your-service>.onrender.com/v1/dev/login -H "content-type: application/json" -d "{\"handle\":\"kedar\"}"
```

The second call returns an `access_token` for the seeded demo account `kedar` (or `saharsh`), with three weeks
of fridge/pantry history. Use it for curl, the interactive docs at `https://<your-service>.onrender.com/docs`,
or a desktop client without Google sign-in. Then, on the phone: sign in with Google and approve Calendar. Your
Google account becomes its own Agora account, with sample history so Home isn't empty.

## 8. Keep it alive until the demo

| Risk over the next ~15 hours | Likelihood | What protects you |
|---|---|---|
| Render free server **sleeps** after 15 idle min (first request then takes ~1 min) | Certain, unless pinged | `keep-warm` workflow (below) + an uptime monitor + opening `/healthz` 5 min before presenting |
| Render **restarts** the free server at any time | Occasional | Harmless: all state is in the database, and in-flight scans resume from the job queue |
| Render **monthly hours** (750) or bandwidth run out | Very unlikely in a day | Plan B below |
| A last-minute merge to `main` **auto-deploys a bad build** | Real: other sessions are merging PRs | Freeze deploys (below) |
| Tiger free service **storage** (750 MiB) fills up | Very unlikely: photos are deleted after review, and the demo data is a few MB | `/readyz` keeps working; snapshot + Plan B |
| Tiger free service **pauses or misbehaves** (free plan is beta; idle behaviour isn't documented) | Unlikely | Keep-warm pings also hit the database; snapshot + Plan B |
| **Gemini free quota** runs out. Reported free limits vary (roughly 100–1,500 requests/day per project), and each photo in a scan is one request | **The most likely failure** if you test a lot | Separate keys per use (below); replay fixtures; the cache never re-bills the same photo |
| Google test-user consent expires (7 days in Testing) | Not within a day | Sign in again |

**Do these now:**

1. **Keep it awake.** Two layers:
   - Ask Saharsh (repo admin) to add the repository variable `AGORA_API_URL` = your Render URL, under
     **Settings > Secrets and variables > Actions > Variables**. `.github/workflows/keep-warm.yml` then pings it
     every 10 minutes. GitHub can delay scheduled runs, so also:
   - Create a free uptime monitor (e.g. UptimeRobot, no card) on `https://<your-service>.onrender.com/healthz`
     every 5 minutes.
2. **Spread the Gemini quota.** Quotas are per Google Cloud project, so create keys in **different projects**:
   - one for the backend (`AGORA_GEMINI_API_KEY` in Render)
   - one for the iOS chat agent (app Settings)
   - one spare that nobody uses until demo time

   Test scans with 1–3 photos, not 12. If a key hits its limit, paste the spare into Render; it redeploys in
   about a minute. As a last resort, set `AGORA_GEMINI_MODEL=gemini-flash-lite-latest` (higher free limits).
3. **Record the demo scans once** with a real key, then make them replayable offline. From `backend/`:
   `AGORA_DATABASE_URL=<tiger url> uv run python -m app.tools.export_replay`, then commit `backend/seed/replay/`.
   Setting `AGORA_VISION_PROVIDER=replay` then gives identical results for those photos with no API calls.
4. **Freeze 2–3 hours before presenting.** Render service, then **Settings > Auto-Deploy: Off**. Note the commit
   on the **Events** tab, and tag it so you can always go back:

   ```bash
   git tag demo-ready <commit> && git push origin demo-ready
   ```

   Render only rolls back to the last two deploys, so the tag is your real undo button.
5. **Snapshot the data** after your final rehearsal (and again before presenting). It includes everything you
   created while testing:

   ```bash
   cd backend && uv run python -m app.tools.snapshot export ../demo-snapshot.zip --database-url "<tiger url>"
   ```

   Keep `demo-snapshot.zip` on two laptops. It's personal demo data, so don't commit it.
6. **Record backup videos** of each flow early, while everything works.

## 9. Plan B: run everything on a laptop

If hosting fails, a laptop runs the identical backend: same code, migrations, demo accounts, Google sign-in
and features. The iOS app talks to it as if it were the hosted server. Prepare one laptop (ideally the Mac you
demo from) **today**, so Plan B is a single command later.

One-time prep (macOS):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

```bash
brew install cloudflared
```

Docker Desktop is optional. Without it the script uses an embedded Postgres it downloads itself; that one has no
TimescaleDB, and the app switches to its plain-SQL path automatically. Then clone the repo, and from
`backend/`, run it once to check it works:

```bash
uv run python -m app.tools.local_demo --tunnel
```

It starts the database, runs migrations, seeds the demo accounts and starts the API on `http://localhost:8000`.
`--tunnel` adds a public `https://….trycloudflare.com` URL (free, no account) and writes it into
`Config/Local.xcconfig`. Rebuild the iOS app in Xcode and it uses the laptop. A `backend/.env` with
`AGORA_GEMINI_API_KEY=...` enables real scans; without it, only replay fixtures work.

Which command to use, by what failed:

| What failed | Do this (from `backend/`) | Data you'll see |
|---|---|---|
| Render only (database still up) | `uv run python -m app.tools.local_demo --tunnel --database-url "<tiger url>"` | Everything, live |
| Render **and** Tiger | `uv run python -m app.tools.local_demo --tunnel --import-snapshot ../demo-snapshot.zip` | Everything up to your last snapshot |
| Venue wifi | Use a phone hotspot for the laptop and phone, then either command above | Same |
| No internet at all | Google sign-in, Calendar and Gemini chat can't work on any setup. Scans and inventory work locally with replay fixtures (`AGORA_VISION_PROVIDER=replay`). The iOS app currently only accepts HTTPS backends, so show this via `http://localhost:8000/docs` or the backup video | Seeded data + replayed scans |

Each `--tunnel` run gets a new URL. Rebuild the iOS app after starting it (the script updates the config for you).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deploy fails at boot | Check Render's **Logs**. A config error names the exact variable. A missing or wrong `AGORA_DATABASE_URL` is the usual cause |
| `/readyz` shows `"timescale": false` | The database isn't Tiger (or the extension is off). Everything still works, with plain-SQL fallbacks |
| Google says the app is blocked or access denied | Saharsh adds that Google account under **Audience > Test users** |
| Home says inventory isn't available | `AGORA_API_BASE_URL` isn't set in `Config/Local.xcconfig`, or isn't `https://` with no path |
| Inventory fails to load after signing in | `AGORA_GOOGLE_IOS_CLIENT_ID` on Render doesn't match the app's client ID, or the server is still waking up |
| A scan fails with `no_replay_fixture` | No vision key is set and that photo wasn't pre-recorded. Add the Gemini key (step 4) |
| Scans fail with `provider_rate_limited` | Gemini quota hit: paste the spare key (section 8, step 2) or switch to `replay` |
| `local_demo` says port in use | Another server is on 8000: add `--port 8001` |

## If a free tier runs out

Nothing in the code is tied to these providers. Switching only means changing environment variables, for
example moving the database to Neon or Supabase, or hosting on Railway, Koyeb, Fly.io or a laptop with a
`cloudflared` tunnel. The full table is in [backend/README.md](backend/README.md#switching-when-something-runs-out).
