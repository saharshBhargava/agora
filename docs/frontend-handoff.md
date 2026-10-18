# Frontend hosting handoff

Deployment walkthrough: [SETUP.md](../SETUP.md). API contracts: [api/](api/).
Pending UI work: [frontend-requests.md](frontend-requests.md).

## Current deployment record

As of October 17, 2026, the owner has created Tiger Cloud and Render accounts. Database/API resource setup
is in progress; no live API URL has been supplied or verified in this session. Replace the fields below
after deploying; examples are not working hosts.

| Field | Actual value |
|---|---|
| Public API origin (no path) | Pending Render deployment |
| API root | `<origin>/v1` |
| Health / database readiness | `<origin>/healthz` / `<origin>/readyz` |
| Interactive docs / OpenAPI | `<origin>/docs` / `<origin>/openapi.json` |
| Deployed commit | Pending; copy from Render Events |
| Last successful smoke test | Pending |
| Google test-user access | Owner must add each tester in the existing Google Cloud project |
| Demo Google address | Owner must configure `AGORA_DEMO_GOOGLE_EMAILS` in Render |
| Live scan provider | Pending backend Gemini or Perceptron key |

Keep this record public and free of passwords, API keys and bearer tokens. Update it when the deployment
changes so teammates and resumed agents have one place to find the live configuration.

## Message to send to the frontend team

Fill in the origin after `/readyz` returns HTTP 200. Share the demo password only through a private
credential channel if the team needs it for API testing.

```text
Agora backend:
Origin: https://<actual-render-host>.onrender.com
API root: https://<actual-render-host>.onrender.com/v1
Docs: https://<actual-render-host>.onrender.com/docs
OpenAPI: https://<actual-render-host>.onrender.com/openapi.json

iOS setup:
1. Pull main. Copy Config/Local.xcconfig.example to Config/Local.xcconfig.
2. Set AGORA_API_BASE_URL = https:/$()/<actual-render-host>.onrender.com
   Use only the origin: no /v1 suffix. Leave Google overrides commented.
3. Have the project owner add your Google account as an OAuth test user.
4. Rebuild in Xcode, sign in with Google, approve Calendar, then open Home.

API auth: Authorization: Bearer <fresh Google ID token from the SDK>.
There is no shared Agora API key. Use an ID token, not a Google access token.
For populated data, use the designated demo Google account (shared privately).
Your ordinary Google account starts with an empty household.

Chat/caption Gemini key: configure separately in app Settings.
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

1. Deploy `main` using `render.yaml`; store the direct Tiger URL and backend vision key in Render Environment.
2. Confirm readiness, demo API login, `/v1/me` and inventory; then test native Google sign-in and a real scan.
3. Fill the deployment record above with the actual public origin, deployed commit and test time.
4. Set GitHub Actions repository **variable** `AGORA_API_URL` to the origin (not a secret; no `/readyz` suffix).
   The existing keep-warm workflow uses it. It is not guaranteed uptime; see SETUP.md for demo preparation.
5. Send the filled message to the frontend team and provide test-user access. Keep secrets in the provider
   dashboards/password manager, not in this file or a frontend build.
6. When upgrading backend features, read [pr-handoff.md](pr-handoff.md) and current `main` first; don't
   reuse an old migration number or reapply a merged PR.

Provider references: [Render Blueprints](https://render.com/docs/infrastructure-as-code),
[Render free service limits](https://render.com/docs/free),
[Google ID token verification](https://developers.google.com/identity/sign-in/ios/backend-auth).
