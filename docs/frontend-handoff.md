# Frontend hosting handoff

Verified state: [current-state.md](current-state.md). Operations/recovery: [deployment.md](deployment.md).
Deployment recreation: [SETUP.md](../SETUP.md). API contracts: [api/](api/).
Pending UI work: [frontend-requests.md](frontend-requests.md).

## Current deployment record

As of October 17, 2026, Render is **Live** at `https://agora-api-yq3m.onrender.com`, backed by Tiger with
TimescaleDB. The database is initialized through migration `0013`; the single designated demo
account retains its inventory/history and has commerce data and three private Calendar events (dated
observations, not fixed counts). Public health/readiness, docs and OpenAPI endpoints returned HTTP 200. Demo password sign-in and authenticated profile, inventory, lists,
wishlist, forecasts, agent state, mandates, intents, budgets and spend all returned HTTP 200.
Password-only integration verification also passed for `/v1/demo/profile`, Calendar event listing and
availability. Anonymous demo-profile access returned 401. No payments were made.

The existing keep-warm workflow is configured with repository variable `AGORA_API_URL`; a manual run
passed. Native Google sign-in/Calendar consent and a real Gemini recognition still need device testing.
Normal hosted boot checks pending migrations and ensures demo data idempotently. Releases now go through
the GitHub deploy workflow ([deployment](deployment.md)): merging backend work to main deploys it, and
`/readyz` reports the running `commit`. If the app needs a backend feature that isn't live yet, check the
latest deploy run rather than assuming the merge shipped. Both post-merge backend and selected iOS
CI checks passed for the live commit; see the current-state record for links and boundaries.

| Field | Actual value |
|---|---|
| Public API origin (no path) | `https://agora-api-yq3m.onrender.com` |
| API root | `https://agora-api-yq3m.onrender.com/v1` |
| Health / database readiness | `/healthz` / `/readyz` at that origin; verified HTTP 200 |
| Interactive docs / OpenAPI | [Docs](https://agora-api-yq3m.onrender.com/docs) / [OpenAPI](https://agora-api-yq3m.onrender.com/openapi.json) |
| Repository baseline at audit | `860dc1cda617da0263015dd314d90f6fe8745d66` (#19, docs only); this docs update also advances main without changing app code |
| Latest verified live commit | `f65cf0eccd2da9661f2d1220e861cbd9ff765997` ([PR #17](https://github.com/saharshBhargava/agora/pull/17)); live password/Calendar check at 8:38 PM PDT, October 17 |
| First verified live commit | `d6bac9d122ebe902735cfcfccd8f704ffbd115a6`; see Render Events for subsequent deploys |
| Last successful smoke test | Public health, demo login and authenticated reads: October 17, 2026 |
| Google test-user access | Owner must add each tester in the existing Google Cloud project |
| Demo sign-in | Username `demo`; password is Render Environment → `AGORA_DEMO_PASSWORD`, shared privately by the owner |
| Demo Google address | Optional alternate sign-in via `AGORA_DEMO_GOOGLE_EMAILS`; unnecessary for demo testing |
| Demo provider keys | None. Built-in chat/captions/recognition and account-private Calendar; simulated checkout |
| Ordinary account provider keys | Configure real model connections in Settings; Google Calendar uses Google consent |

Keep this record public and free of passwords, API keys and bearer tokens. Update it when the deployment
changes so teammates and resumed agents have one place to find the live configuration.

## Message to send to the frontend team

This message is ready to copy. Share the demo password only through a private credential channel if the
team needs it for app or API testing; retrieve it from Render Environment, `AGORA_DEMO_PASSWORD`.

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
3. Rebuild in Xcode. On Welcome, enter username demo and the privately shared password.
4. Tap Sign in to demo. No Google sign-in or provider API keys are required.

Demo API auth: POST /v1/dev/login {handle: demo, password: <private password>};
use the returned access_token in Authorization: Bearer <token>.
The app stores the session token in Keychain, never the password.
Demo chat/captions/recognition use built-in sample responses, not real AI inference.
Demo Calendar events are stored inside Agora; no real Google events are created.

Google remains an optional alternative. Your ordinary Google account starts empty.
For ordinary accounts: add Google test-user access, approve Calendar and configure
real model connections in Settings. Use a Google ID token for Agora API auth.
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
For ordinary accounts, the native Calendar flow needs no Google client secret or backend redirect URL.
Calendar access tokens remain on the phone; Agora calls use Google ID tokens. The password demo uses its
Agora session token and private Calendar instead; never send its requests/media to Google as a fallback. The backend validates them and creates/maps the
Agora account. Call `GET /v1/me` to obtain household IDs rather than hardcoding seeded UUIDs.

## API integration checklist

- Use the shared `AgoraClient` for native authenticated JSON requests; it obtains the current demo session token or Google ID token.
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
2. Demo: share the Render demo password privately. Rebuild from main and use the password form.
   Google and model-provider setup are optional for testing ordinary accounts.
3. Optional for ordinary accounts: add a backend Gemini/Perceptron key in Render for the separate
   server `/v1/scans` flow. Designated demo scans continue using built-in results regardless of these keys.
4. Update this deployment record when the host or access setup changes. Keep-warm is not guaranteed
   uptime; see SETUP.md for demo preparation.
5. Send the message above to the frontend team and provide the demo password privately; provide Google test-user access only for ordinary-account testing. Keep secrets in the provider
   dashboards/password manager, not in this file or a frontend build.
6. When upgrading backend features, read [pr-handoff.md](pr-handoff.md) and current `main` first; don't
   reuse an old migration number or reapply a merged PR.

Provider references: [Render Blueprints](https://render.com/docs/infrastructure-as-code),
[Render free service limits](https://render.com/docs/free),
[Google ID token verification](https://developers.google.com/identity/sign-in/ios/backend-auth).

## What frontend access does not grant

The live origin, public client IDs and private demo password are enough for the password demo path after
rebuilding main. They do not grant Render/Tiger administrative access. The Render workspace is Hobby;
no additional teammate cloud invitations were configured in this setup. See [deployment access](deployment.md#access-and-remaining-operational-work).
Do not distribute database credentials, JWT signing secrets or backend provider keys to make the app connect.
The full wishlist/forecast/list/commerce screens and six-hour refresh remain separate work where marked in
[frontend requests](frontend-requests.md); the existence of populated API data is not proof of a finished UI.

## Native chat workspace — October 18, 2026

The chat screen uses `Agora/Chat/` for conversation state, row rendering, attachments, dictation and
navigation; `AgentCoordinator` owns execution and `BrowserSession` continues to own the single `WKWebView`.
Messages publish text independently, so streaming does not replace the transcript. Both network adapters
stream visible text; tool calls execute only after the complete response passes validation. Gemini thought
parts and signatures remain inside the adapter's continuation data and are never rendered as progress.

The history sheet searches titles and messages, supports rename/archive/delete, and keeps each chat's draft,
attachments and model context. This history is **in memory for the signed-in session**, not synchronized to
Agora or restored after relaunch. Sign-out/account changes clear all chats. The existing durable task journal
still detects interrupted execution without storing prompts, page contents, credentials or attachments.

Attach up to four photos, PDFs or UTF-8 text files. Photos are resized; PDFs send extracted text, not page
images. The composer previews/removes individual attachments and retains a draft when a request cannot
start. Demo accounts retain their built-in sample/media disclosures. The microphone uses native Speech
recognition and requests microphone/speech permission; transcription is editable and never sends itself.

Browser presentation and dragging are user-owned. One mounted viewport moves between thumbnail, hidden,
full workspace and wide-screen side pane. Hiding retains the page; **Chat menu → Show Browser** restores it.
Touching the expanded page pauses conflicting execution; Continue refreshes browser ownership before the
next turn. Approval cards retain pending/approved/rejected/expired state. Stop immediately invalidates the
run; late model events cannot append content or dispatch tools. Uncertain Calendar writes still require
checking the Calendar before retrying.

`ChatFixtures` is used only by render tests; it never populates an ordinary account. `ChatInterfaceTests`
covers message identity, cancellation, draft/context restoration, attachments, approval expiry, Markdown,
scroll following, and browser identity/input/scroll/cookie preservation across the actual SwiftUI layouts.
Physical-device dictation and live credentialed provider requests require separate device verification.

### Gemini chat request correction — October 18, 2026

Simulator logs at 01:40:33 PDT show `gemini-flash-latest:streamGenerateContent` returning HTTP 400.
A credential-free request with the app's shopping-tool schema reproduced Google's rejection of
`additionalProperties` in `functionDeclarations[].parameters`. The Gemini adapter now uses
`parametersJsonSchema`, with the same schema normalization as the OpenAI-compatible adapter, so JSON
Schema constraints are retained and legacy uppercase types become lowercase. See Google's
[function declaration contract](https://ai.google.dev/api/generate-content#FunctionDeclaration).
The corrected credential-free request reaches the authentication gate (403); this verifies removal of
that wire-format rejection, not successful authenticated inference. Existing logs intentionally omit
provider response bodies, prompts and credentials.

The chat welcome artwork/text and suggestion cards are removed. The composer uses one compact row that
expands for multiline text, with 16 points of bottom padding to separate it from the tabs.

Validation: four focused provider/schema simulator tests passed in the isolated chat checkout; the
shared working checkout built successfully. Live authenticated inference remains unverified.

## Shared-browser price fallback — local integration

`ChatWorkspace.watchBrowser` uses the existing `ChatWorkspace.browser`; it must not instantiate a separate
web view. `WatchRefresh` refreshes active work and invokes the runner only in the foreground. The server
must return a pending `browser_fallback` after its normal research has finished. Claim/result endpoints
require authentication, idempotency keys and the current run/criteria version. See the
[price-watch contract](api/price-watches.md#final-fallback-in-the-shared-chat-browser).

Keep Chat/human ownership and account invalidation in place. Browser evidence is a persisted price
comparison with a visible source/disclosure, not a verified offer alert. The designated demo does not run
this fallback. Migration 0019 and a rebuilt native app are required; local tests do not establish production
availability. No extra hosting service or model credentials are needed for this native reader.


## Chat additions MVP

Chat now supports explicit additions to existing shopping lists, the active wishlist and new inventory
items. Reads and saves use the shared authenticated stores, and confirmed results appear in Lists.
An ambiguous list/destination is clarified; existing items are reported without changing quantities.
The tools, retry/error behavior and built-in demo examples are documented in
[chat additions](api/chat-additions.md). No list creation or browser/photo extraction is included.

## Capture and scan review — native source, October 18, 2026

Capture now starts with **Scan items**, **Choose photos**, an Import menu and **Scan a shelf** for video.
The native camera retains its Use Photo / Retake confirmation. Camera captures and imported photos/videos
enter the same automatic identification and explicit inventory-review flow. Multiple imports are reviewed
one at a time with Review next scan or Skip to next scan; closing the batch leaves the media in Recent scans.
PDFs remain viewable documents and are not sent for inventory recognition.

Review keeps the captured media, progress and model/media disclosures visible. Item rows expose selection
and quantity, with name/category/unit/existing-item matching under Edit details. Low-confidence items show
Check this item. Store entry remains optional and usable during identification; date and storage location
are expandable. A persistent Add N items to inventory button retains the existing metadata-only, idempotent
save. Unconfirmed saves show Check save status; successful saves offer View inventory and Scan more.
Updating an existing inventory item records the observed total rather than incrementing its quantity.

Recent scans shows Needs review, Check save status or Added to inventory from existing local recognition
records. Saved reviews remain bound to their original account and household. Media/captions/sharing remain
available from each scan's menu. Unsaved recognition edits are not persisted by closing review; reopening
identifies the original media again. No API, schema or demo-data changes are needed for this UI flow.

## Consumption predictions — native source, October 18, 2026

Running low now includes items predicted to run out within seven days even without a restock level.
Item details show the estimated date/range, daily use, remaining quantity and confidence, distinguishing
typical-use assumptions from personal history. Home, Lists and inventory share prioritization; recorded
zeroes stay labeled Out of stock, while predictions use uncertain wording. The existing forecast API,
worker and demo history are reused. A rebuilt app is required; no backend deployment is needed.

Gemini and other configured chat providers receive these predictions when reading `shopping_context`.
They explain the backend's consumption estimate rather than generating an unsupported rate or date.
See [the forecast contract](api/forecasts-and-lists.md#native-consumption-predictions) for freshness and
fallback behavior. The built-in demo chat retains its existing grammar.
