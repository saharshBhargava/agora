# Setup: getting Agora running for the demo

Everything here is free and needs no credit card. Budget about 30 minutes, mostly waiting for deploys. Do the
steps in order: step 3 needs the URL from step 2.

| # | Account | Needed for | Required? |
|---|---|---|---|
| 1 | [Tiger Cloud](https://console.cloud.timescale.com) | Database (Postgres + TimescaleDB) | Yes |
| 2 | [Render](https://render.com) | Hosting the API | Yes |
| 3 | [Google Cloud](https://console.cloud.google.com) | Google sign-in + Calendar. **The iOS app won't get past onboarding without it** | Yes, for the iOS app |
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
   - Leave `AGORA_PERCEPTRON_API_KEY`, `AGORA_GOOGLE_CLIENT_ID` and `AGORA_GOOGLE_CLIENT_SECRET` blank for now.
3. **Apply**. When the deploy is live, open `https://<your-service>.onrender.com/readyz`. You should see
   `{"ok": true, "timescale": true, ...}`. **Write this URL down**: steps 3 and 6 need it.

Everything else is preset in `render.yaml`: demo mode, a generated token secret, database-backed photo storage,
seeding the demo accounts on boot, and a generated Google token-encryption key.

## 3. Google sign-in + Calendar: Google Cloud (about 10 min)

The iOS app requires a Google Calendar connection before anything else, so this one isn't optional for iOS.
No billing account is needed.

1. console.cloud.google.com: create a project, e.g. "Agora".
2. **APIs & Services > Library**: enable **Google Calendar API**.
3. **Google Auth Platform**:
   - **Branding**: app name "Agora", plus your email as support and developer contact.
   - **Audience**: External, publishing status **Testing**. Under **Test users**, add the Google account of
     everyone who will sign in (each teammate, and the account on the demo phone). Only listed accounts can
     sign in while in Testing.
   - **Data access**: add the scopes `openid`, `email`, `.../auth/calendar.events` and
     `.../auth/calendar.freebusy`.
4. **Clients > Create client**, of type **Web application**. Under **Authorized redirect URIs** add exactly
   `https://<your-service>.onrender.com/v1/integrations/google/callback`. Create it and copy the **Client ID**
   and **Client secret**.
5. Back in Render: service, then **Environment**. Set `AGORA_GOOGLE_CLIENT_ID` and `AGORA_GOOGLE_CLIENT_SECRET`,
   then save. Render redeploys. The redirect URI and the encryption key are already handled; don't set
   or change `AGORA_GOOGLE_TOKEN_KEY` by hand.

In Testing mode, Google expires Calendar consent after 7 days, so you may need to reconnect during a long
weekend. That's fine for the hackathon.

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

In Xcode, select the **Agora** target, then **Build Settings**, then the user-defined setting `AGORA_API_BASE_URL`.
Set it to `https://<your-service>.onrender.com` for both Debug and Release, with no trailing slash. It has to be
HTTPS. If you regenerate the Xcode project, set it again.

## 7. Check it works

Run these in a terminal (they work in any shell; replace the host):

```bash
curl -s https://<your-service>.onrender.com/readyz
```

```bash
curl -s -X POST https://<your-service>.onrender.com/v1/dev/login -H "content-type: application/json" -d "{\"handle\":\"kedar\"}"
```

The second call returns an `access_token`. The seeded demo accounts are `kedar` and `saharsh`, each with three
weeks of fridge/pantry history. Interactive API docs are at `https://<your-service>.onrender.com/docs`. Then, on
the phone: open the app, choose **Connect Google Calendar**, approve, and you're in.

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
| `503 google_not_configured` in the app | `AGORA_GOOGLE_CLIENT_ID` / `AGORA_GOOGLE_CLIENT_SECRET` aren't set on Render yet |
| Google says `redirect_uri_mismatch` | The redirect URI in Google Cloud must exactly match `https://<your-service>.onrender.com/v1/integrations/google/callback` |
| Google says the app is blocked or access denied | Add that Google account under **Audience > Test users** |
| The app says the API URL is invalid | `AGORA_API_BASE_URL` must be `https://...` with no path |
| A scan fails with `no_replay_fixture` | No vision key is set and that photo wasn't pre-recorded. Add the Gemini key (step 4) |

## If a free tier runs out

Nothing in the code is tied to these providers. Switching only means changing environment variables, for
example moving the database to Neon or Supabase, or hosting on Railway, Koyeb, Fly.io or a laptop with a
`cloudflared` tunnel. The full table is in [backend/README.md](backend/README.md#switching-when-something-runs-out).
