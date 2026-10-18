# Frontend hosting handoff

Deployment walkthrough: [SETUP.md](../SETUP.md). API contracts: [api/](api/).
Pending UI work: [frontend-requests.md](frontend-requests.md).

## Current deployment record

As of October 17, 2026, Render is **Live** at `https://agora-api-yq3m.onrender.com`, backed by Tiger with
TimescaleDB. The database is initialized through migrations `0011`/`0012`; the single designated demo
account retains its inventory/history and has commerce data. The public health/readiness, docs and
OpenAPI endpoints returned HTTP 200. Demo password sign-in and authenticated profile, inventory, lists,
wishlist, forecasts, agent state, mandates, intents, budgets and spend all returned HTTP 200.
Unauthenticated profile/inventory/agent-state requests returned 401. No payments were made.

The existing keep-warm workflow is configured with repository variable `AGORA_API_URL`; a manual run
passed. Native Google sign-in/Calendar consent and a real Gemini recognition still need device testing.
Normal hosted boot checks pending migrations and ensures demo data idempotently.

| Field | Actual value |
|---|---|
| Public API origin (no path) | `https://agora-api-yq3m.onrender.com` |
| API root | `https://agora-api-yq3m.onrender.com/v1` |
| Health / database readiness | `/healthz` / `/readyz` at that origin; verified HTTP 200 |
| Interactive docs / OpenAPI | [Docs](https://agora-api-yq3m.onrender.com/docs) / [OpenAPI](https://agora-api-yq3m.onrender.com/openapi.json) |
| First verified live commit | `d6bac9d122ebe902735cfcfccd8f704ffbd115a6`; see Render Events for subsequent deploys |
| Last successful smoke test | Public health, demo login and authenticated reads: October 17, 2026 |
| Google test-user access | Owner must add each tester in the existing Google Cloud project |
| Demo Google address | Not configured; owner must select the address and set `AGORA_DEMO_GOOGLE_EMAILS` in Render |
| Recognition keys | Current iOS Capture uses its Settings Gemini key; optional server `/v1/scans` falls back to replay until a backend key is added |

Keep this record public and free of passwords, API keys and bearer tokens. Update it when the deployment
changes so teammates and resumed agents have one place to find the live configuration.

## Message to send to the frontend team

This message is ready to copy. Share the demo password only through a private credential channel if the
team needs it for API testing; retrieve it from Render Environment, `AGORA_DEMO_PASSWORD`.

```text
Agora backend:
Origin: https://agora-api-yq3m.onrender.com
API root: https://agora-api-yq3m.onrender.com/v1
Docs: https://agora-api-yq3m.onrender.com/docs
OpenAPI: https://agora-api-yq3m.onrender.com/openapi.json

iOS setup:
1. Pull main; the shared config already has the live API URL.
2. Remove/update any old AGORA_API_BASE_URL override in Config/Local.xcconfig.
   The current value is https:/$()/agora-api-yq3m.onrender.com (no /v1 suffix).
3. Have the project owner add your Google account as an OAuth test user.
4. Rebuild in Xcode, sign in with Google, approve Calendar, then open Home.

API auth: Authorization: Bearer <fresh Google ID token from the SDK>.
There is no shared Agora API key. Use an ID token, not a Google access token.
Google access to the populated demo account awaits the owner's demo-email selection.
API testers can use POST /v1/dev/login with handle demo and the Render demo password.
Your ordinary Google account starts with an empty household.

Chat/caption/Capture recognition Gemini key: configure in app Settings.
Backend scan provider keys and database credentials stay on the server.
Free hosting can take about a minute to wake after being idle.
```

## Public Google configuration

The checked-in defaults in [Config/Agora.xcconfig](../Config/Agora.xcconfig) already contain:

```text
AGORA_GOOGLE_IOS_CLIENT_ID=875535919816-pt11h5vsprq94mktf5of9ltfbu529evl.apps.googleusercontent.com
AGORA_GOOGLE_REVERSED_CLIENT_ID=com.googleusercontent.apps.875535919816-pt11h5vsprq94mktf5of9ltfbu529evl
iOS bundle ID=dev.agora.browserchat
```

These are public identifiers. The backend's `AGORA_GOOGLE_IOS_CLIENT_ID` must equal the app's client ID.
The native Calendar flow needs no Google client secret or backend redirect URL. Calendar access tokens
remain on the phone; inventory calls use Google ID tokens. The backend validates them and creates/maps the
Agora account. Call `GET /v1/me` to obtain household IDs rather than hardcoding seeded UUIDs.

## API integration checklist

- Use the shared `AgoraClient` for native authenticated JSON requests; it obtains the current ID token.
  Pass paths such as `v1/me` to this client; it appends them to the origin.
- Start with `GET /v1/me`, `GET /v1/households` and `GET /v1/inventory`.
- Use the deployed OpenAPI schema for exact request/response shapes. Feature behavior and UI decisions are
  documented under `docs/api/` and `docs/frontend-requests.md`.
- Supply a fresh `Idempotency-Key` for operations that require it, and reuse the same key for a retry of
  that operation. Check the endpoint contract for requirements.
- API failures use RFC 7807 `application/problem+json`. Retain `X-Request-ID` when reporting a failure;
  exclude credentials and personal request content from bug reports.
- For browser clients, ask the backend owner to allow the exact frontend origin in `AGORA_CORS_ORIGINS`.
  This setting is a JSON array. CORS does not add support for a web OAuth audience: the current hosted
  authentication is configured for the native iOS client. Coordinate web auth before connecting a browser.
- Test ordinary and demo accounts separately. Only the designated demo account gets seeded history and
  simulated external effects. Never enable `AGORA_SEED_NEW_USERS` on a hosted service.

## Owner's completion checklist

1. Completed: `main` deployed using `render.yaml`, Tiger credentials remain in Render, public and
   authenticated read checks passed, and `AGORA_API_URL` is set with a successful keep-warm run.
2. Remaining: add testers in the existing Google project, select the populated demo Google address if
   needed, then test native Google sign-in/Calendar and real Capture recognition with an app Settings key.
3. Optional: add a backend Gemini/Perceptron key in Render for the separate server `/v1/scans` flow.
4. Update this deployment record when the host or access setup changes. Keep-warm is not guaranteed
   uptime; see SETUP.md for demo preparation.
5. Send the message above to the frontend team and provide test-user access. Keep secrets in the provider
   dashboards/password manager, not in this file or a frontend build.
6. When upgrading backend features, read [pr-handoff.md](pr-handoff.md) and current `main` first; don't
   reuse an old migration number or reapply a merged PR.

Provider references: [Render Blueprints](https://render.com/docs/infrastructure-as-code),
[Render free service limits](https://render.com/docs/free),
[Google ID token verification](https://developers.google.com/identity/sign-in/ios/backend-auth).
