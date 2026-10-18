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

## 8. Before judging

- **Wake the server.** Render's free tier sleeps after about 15 idle minutes, and the first request then takes
  about a minute. Open `/healthz` five minutes before you present. Optionally, point a free uptime monitor at
  `/healthz` every 5 minutes to keep it awake all weekend.
- **Make the scan demo wifi-proof.** Run your demo scans once with Gemini or Perceptron. Then, from a laptop, run
  `cd backend` and `AGORA_DATABASE_URL=<tiger url> uv run python -m app.tools.export_replay`. Commit
  `backend/seed/replay/`. If the venue network fails, set `AGORA_VISION_PROVIDER=replay` and the same photos
  give the same results offline.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deploy fails at boot | Check Render's **Logs**. A config error names the exact variable. A missing or wrong `AGORA_DATABASE_URL` is the usual cause |
| `/readyz` shows `"timescale": false` | The database isn't Tiger (or the extension is off). Everything still works, with plain-SQL fallbacks |
| Google says the app is blocked or access denied | Saharsh adds that Google account under **Audience > Test users** |
| Home says inventory isn't available | `AGORA_API_BASE_URL` isn't set in `Config/Local.xcconfig`, or isn't `https://` with no path |
| Inventory fails to load after signing in | `AGORA_GOOGLE_IOS_CLIENT_ID` on Render doesn't match the app's client ID, or the server is still waking up |
| A scan fails with `no_replay_fixture` | No vision key is set and that photo wasn't pre-recorded. Add the Gemini key (step 4) |

## If a free tier runs out

Nothing in the code is tied to these providers. Switching only means changing environment variables, for
example moving the database to Neon or Supabase, or hosting on Railway, Koyeb, Fly.io or a laptop with a
`cloudflared` tunnel. The full table is in [backend/README.md](backend/README.md#switching-when-something-runs-out).
