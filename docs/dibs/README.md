# Dibs

Dibs watches a shopper's basket with a phone camera, turns each item into a chip, and lets friends lift chips into their own tray so the bill splits itself. Every claimer's cap is a real card authorization; at settle, each share is captured and the rest is released.

Dibs lives beside Agora in this repository: the native iPhone app is the **Dibs tab of the Agora app** (sources in `Agora/Dibs/`, tests in `AgoraTests/Dibs*.swift`), the Node server is in `server/` (Fastify + WebSocket, JSON snapshot storage) and the web claimer/shopper is in `web/` (Next.js static export served by the server; web join links keep working). It has its own server and its own people, and does not use Agora's backend, accounts or Render service. Run every command below from the repository root.

In the live setup (`scripts/demo-server.sh`), the shopper's iPhone finds items on device with Apple Vision, the server names each crop with Gemini, the phone's hidden browser reads the price from qfc.com, claimers join on the web or in the app, and payments are simulated Visa authorizations and captures. Stub modes (three fixed props, a fixed price table) remain for offline testing.

## Run locally

```sh
pnpm install
scripts/dev.sh          # server on :3000 (tsx watch) + Next dev on :3001; Ctrl-C stops both
```

Open `http://localhost:3001`. Production shape (one port, web served by the server):

```sh
pnpm -C web build && pnpm -C server build && node server/dist/index.js   # http://localhost:3000
scripts/smoke.sh        # builds, starts on a free port, checks /, /join, /api/runs; nonzero on failure
pnpm -r test
```

Web screens work without the server at `?mock=1` (props in `web/public/props/`).

Live demo server (Gemini vision, QFC prices from the iOS price worker, 5 s last call, the same item seen again counted as ×2 on its row, simulated payments, port 3000):

```sh
scripts/demo-server.sh https://<tunnel>   # or PUBLIC_URL=https://<tunnel> scripts/demo-server.sh
```

It rebuilds web and server when they are stale, reads `GEMINI_API_KEY` from `server/.env` (never printed), refuses to start if port 3000 is taken, and prints the URL. Add `SIM_FAIL_CAPTURE=Marcus` in front to show a partly settled run.

The "+ Wish" page (`GET /api/runs/:id/wish-picks`) suggests items from this server's past runs at the same store. To also show the household's shopping list, wishlist suggestions and run-out forecasts from the team API (`backend/` on main), put `TEAM_API_BASE_URL` and `AGORA_DEMO_PASSWORD` in `server/.env` (see Env flags). The server signs in as the API's demo account, caches answers for 60 s, and falls back to run history when the API is slow (4 s) or down.

### Native iOS app (the Agora app's Dibs tab)

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # AGORA_BUNDLE_ID, DEVELOPMENT_TEAM, DIBS_SERVER_URL (gitignored)
ruby scripts/generate-project.rb && open Agora.xcodeproj  # scheme Agora; Dibs is the cart tab
```

`DIBS_SERVER_URL` is empty in `Config/Agora.xcconfig`, so the tab falls back to `http://localhost:3000`; set it in `Config/Local.xcconfig` to the tunnel URL for a real phone (it reaches the app as Info.plist `DibsServerURL`). `dibs://join?run=…` links open the Dibs tab on its join screen. Launch arguments: `-DibsAutoShop YES` starts a run and opens the shopper camera, `-DibsDebugCrops YES` shows detection crops, `-DibsAutoRemove YES` removes items that leave the frame (off by default), `-DibsStoreSetup YES` picks the QFC store in the price browser (off by default). Tests run with Agora's: `xcodebuild test -project Agora.xcodeproj -scheme Agora -destination 'platform=iOS Simulator,name=<iPhone>'` (Dibs classes are `AgoraTests/Dibs*`; fixtures are `Fixtures/dibs-*.json`).

### Camera demo: drop order matters

With `VISION=stub`, the camera path uses a deterministic stub. When a dropped item does not clearly match a prop photo, the stub names the next prop in drop order for that run: eggs, then towels, then milk, then eggs again. Drop the eggs, the towels and the milk in that order. A whole-frame lighting or exposure change re-baselines the detector and adds no chip. If the camera misbehaves, switch the shopper to `?mock=1` (the "Use sample items" link) and tap the items instead.

### Replacing the placeholder props

The prop images are generated placeholders. To use real photos: put `eggs.jpg`, `towels.jpg`, `milk.jpg` in `server/assets/props/` (and copy them to `web/public/props/`), then regenerate frame fixtures with `pnpm -C server exec tsx scripts/make-frames.ts`. Skip `scripts/make-props.ts`, which only draws the placeholders.

## Who can act in a run

Person ids are public: every run snapshot lists them, because the UI needs them. So an id alone proves nothing.

- **Keys.** `POST /api/runs` returns `{runId, shopperId, key}` and `POST /api/runs/:id/join` returns `{personId, key, auth}`. Each key is 32 random bytes (base64url). The server keeps only its SHA-256, in `DATA_DIR/keys.json`, never in the run. The web app keeps keys in `localStorage` (`dibs.key.<runId>.<personId>`); the iOS app keeps them in `UserDefaults` (`dibs.key.<runId>`).
- **REST.** Every action sends the actor's key in `x-dibs-key`, and the key must belong to the `personId` (or `byPersonId`) the request names: raise, wish (`chips/text`), `wish-picks`, and the shopper routes (`chips/:id/fix`, `quantity`, `putback`, `checkout`, `back`, `confirm`). `POST /chips`, `/receipt` and `/receipt/fix` need the shopper's key. A missing or wrong key gets `403 {"error":"not allowed"}`; a claimer's own key on a shopper route gets `403 {"error":"shopper only"}`.
- **WebSocket.** Connect with `/ws?run=&person=&key=`. A missing or wrong key closes with 1008 `not allowed`.
- **Price requests.** Each browser-agent lookup belongs to the run whose chip asked for it. Only that run's shopper key may list it (`GET /api/price-requests` with `x-dibs-run: <runId>` and `x-dibs-key`) or answer it (`/extract`, `/agent-step`, the direct POST); found prices are reused only within the same run. Anyone can create a run, so a key for some other run is not enough.
- **Reads.** `GET /api/runs/:id` stays public and read-only. Every run that leaves the server, over REST or WebSocket, is redacted: `authId` is null, and `payoutPan` and `payout.recipientPan` are masked to `•••• 1111`.
- **Old runs.** A run created before keys existed has none, so nobody can act in it: REST answers `410` "This run was started before an update. Start a new run." and the socket closes with 1008 `old run`. Start a new run.

## Env flags

| Flag | Demo value | Meaning |
| --- | --- | --- |
| `DETECTOR` | `diff` | Server-side detection for the web shopper camera (frame differencing). The iOS app detects on device and sends `detect: false`. |
| `VISION` | `gemini` | Identification and receipt reading: `gemini` (needs `GEMINI_API_KEY`) or `stub` (the three known props; the default). |
| `GEMINI_API_KEY` | in `server/.env` | Google AI Studio key. Never printed or committed. |
| `GEMINI_MODEL`, `GEMINI_FAST_MODEL` | built-in lists | Comma lists of models tried in order (busy or missing models fall through; a 429 pauses and retries). The fast list reads price pages. |
| `PRICE` | `agent` | Comma list tried in order: `agent` (the phone's hidden browser on the store site, read by a deterministic page parser and then the fast model), `gemini` (search grounding; needs a paid key), `stub` (a fixed table; the default). |
| `STORE_NAME` | `QFC` | Store for new runs and price lookups (default `costco`). |
| `STORE_AREA` | `Seattle, WA 98105` | Area named in `PRICE=gemini` lookups. |
| `PRICE_DIRECT_POST` | unset | `1` re-enables `POST /api/price-requests/:id` with a raw price (tests only; the app never uses it). |
| `DUPLICATE_MS` | `86400000` (demo script) | Window in which the same product counts as the same item (see `MERGE_DUPLICATES`). |
| `PAYMENTS` | `sim` | Payments provider. `sim` is the simulator (approval code 888888). |
| `LAST_CALL_MS` | `5000` | Length of last call after Check out (default 10000). |
| `PORT` | `3000` | Listen port. Railway sets it. |
| `PUBLIC_URL` | none | Public origin used in the join QR code (`/api/runs/:id/qr`). When unset, the QR uses the request's `x-forwarded-proto` and `host`. |
| `DATA_DIR` | `server/.data` | Where runs (`runs.json`) and the payments simulator's authorizations (`sim-payments.json`) are kept, so a restart can still settle. |
| `RAISE_CAP` | on | Set `off` to disable raising a cap. |
| `MERGE_DUPLICATES` | `1` (demo script) | `1`: when the camera identifies a product already in the cart, that chip's quantity goes up by one (×2, ×3, up to 20) instead of adding a second chip; no "Added twice?" card. A wish waiting for the product takes the new item instead. Unset: a same-name item within `DUPLICATE_MS` (default 5000) becomes its own chip with the "Added twice? Keep both / Remove one" card. |
| `MERGE_WINDOW_MS` | `3000` | With `MERGE_DUPLICATES=1`: a detection that starts within this long of the chip's last count is the same item seen twice (a merged box, a double tap) and does not count again. |
| `TEAM_API_BASE_URL` | none | Origin of the team household API, e.g. the Render `agora-api` service (`https://…onrender.com`; a trailing `/v1` is fine). HTTPS only, except `http://localhost`. Unset: the wish page uses run history only. |
| `AGORA_DEMO_PASSWORD` | none | With `TEAM_API_BASE_URL`: the password for `POST /v1/dev/login` as `demo`. It is the same value as the API service's own `AGORA_DEMO_PASSWORD` (Render → agora-api → Environment, or ask whoever deployed it). Never logged or returned. |
| `SIM_FAIL_CAPTURE` | none | With `PAYMENTS=sim`, a comma list of claimer names (case-insensitive, e.g. `Marcus,Priya`) whose capture and incremental fail at settle, so the run ends partly settled with "Retry Marcus". Checked on each Confirm, so clear it and restart to let Retry succeed. |

## Hosting

The demo runs on a laptop: `scripts/demo-server.sh https://<tunnel>` behind an HTTPS tunnel (ngrok or similar). Do not add a Render service for Dibs: the repository's Render account is reserved for `agora-api` (see the root `CLAUDE.md`), and a free instance would sleep mid-run and lose its disk. The root `Dockerfile` belongs to Dibs; Render ignores it because `render.yaml` pins `rootDir: backend`.

### Optional: Railway (not deployed)

The repo root `Dockerfile` and `railway.json` (healthcheck `/api/health`) are all it needs. Use a volume for `DATA_DIR`.

```sh
npm i -g @railway/cli
railway login
railway init                      # new project
railway up                        # builds the Dockerfile and deploys
railway variables --set DETECTOR=diff --set VISION=stub --set PRICE=stub --set PAYMENTS=sim --set LAST_CALL_MS=5000
railway domain                    # prints the HTTPS URL
railway variables --set PUBLIC_URL=https://<that-domain>
railway up                        # redeploy so PUBLIC_URL takes effect
curl https://<that-domain>/api/health
```

State is in memory with a JSON snapshot; a redeploy loses runs, so create the run after the last deploy.

## Install on phones

HTTPS is required for the camera, which the tunnel (or Railway) provides. The native app (the Agora app's Dibs tab) is the main shopper path; the steps below are the web (Add to Home Screen) path.

1. Create a run: `curl -X POST https://<domain>/api/runs` returns `runId`, `shopperId` and the shopper's `key`.
2. Shopper phone: open `https://<domain>/shopper?run=<runId>&person=<shopperId>#key=<key>` in Safari (the page saves the key and drops it from the address bar; the fragment never reaches the server), Share, Add to Home Screen, then open it from the home screen and allow the camera. Starting the run on the phone itself ("Start a run") needs no key in the link. On this phone set Settings → Display & Brightness → Auto-Lock → Never (the page also holds a screen wake lock where Safari allows it). Clip it above the basket.
3. Judge B phone: open `https://<domain>/join?run=<runId>&name=B`, tap Join (cap $40), then Start claiming, then Add to Home Screen.
4. Judge A phone: leave it on the Join screen. Claimers scan the QR from `https://<domain>/api/runs/<runId>/qr` (open it on the laptop) to land on `/join?run=<runId>`.
5. Run the full loop on the real devices over a real basket before the demo.

## The 90-second demo

This script uses the stub props (`VISION=stub PRICE=stub`). With the live setup, use real items and a receipt that lists them.

Props: a basket with the shopper phone clipped above it; two team-owned iPhones for judges with the web app on the home screen, one on the Join screen (cap preset to $40) and one pre-joined as B; a printed receipt that matches the props exactly (eggs $8.72, paper towels $23.99, milk $4.29, tax included, total $37.00); three real items with our own price stickers; a laptop running the price worker in the iOS Simulator and mirroring the phones. Last call set to 5 seconds for the demo. The run is seeded with the shopper only; B joins before the judges arrive; A joins on camera.

- 0:00 Hand judge A the Join phone. "Tap Join." "$40 held · approval 888888" appears (the simulator's code; in real mode, the sandbox's own). "That authorization is live on the Visa Acceptance sandbox. Everything you claim comes out of it." Judge A taps Start claiming; the held badge stays in the claim header.
- 0:10 Teammate drops the eggs into the basket under the clipped phone. Both judge phones show the basket live; two seconds later a chip appears with the eggs' photo and "$8.72". "Nobody scanned anything. The cart is being watched."
- 0:20 Judge A lifts the eggs into their tray. Ring: full with a notch. "Your share $8.72 · $31.28 room."
- 0:30 Judge B lifts the same eggs. Ring splits into two initials. Both phones: "$4.36". "That's the split. It happened before Jake paid, and it's backed by two authorizations."
- 0:40 Judge B lifts the paper towels into their tray. "$23.99." Judge A lifts the eggs out, then back in. "$8.72, then $4.36 again. Leaving is just lifting out."
- 0:55 Teammate drops the milk in, nobody claims it. Teammate taps Check out. The "Last call" countdown, five seconds, lock. The milk silently stays with Jake.
- 1:05 Teammate photographs the printed receipt. Settle: three lines matched with confidence. Confirm & charge. Judge A: $4.36 captured, "$35.64 released · settles tonight". Judge B: $28.35 captured, "$11.65 released · settles tonight". Shopper: "Jake gets back $32.71" (simulated Visa Direct), which is exactly $4.36 + $28.35.
- 1:20 "Your cap isn't a setting, it's an authorization. Four Visa Acceptance calls: authorize, incremental when you raise your cap, capture for your share, reverse the rest. Payout is simulated; in production it's a Visa Direct push through a licensed partner."

Arithmetic check: A's room after claiming eggs alone is $40.00 - $8.72 = $31.28; B's room after eggs and towels is $40.00 - $32.71 = $7.29. At settle A's share is $4.36 (released $35.64), B's is $4.36 + $23.99 = $28.35 (released $11.65). Payout $32.71. Milk $4.29 stays with Jake. Receipt total $37.00.

## Hour-0 Cybersource gate

Standalone sandbox check (authorize, incremental, partial reversal, capture) against `apitest.cybersource.com`; prints each status and which processor the sandbox uses. Decline test card: expiry year 1998.

```sh
CYBS_MERCHANT_ID=... CYBS_KEY_ID=... CYBS_SHARED_SECRET=... pnpm -C server exec tsx scripts/payments-gate.ts
```

See `.env.example`. If the incremental is rejected, keep `RAISE_CAP=off` in real mode.

## What is simulated

- Payments: `PAYMENTS=sim` is an in-process simulator (approval code 888888); no Cybersource call is made. Test cards: expiry year 1998 (or `42423482938483873`) declines at join; `4000000000000002` is a payments outage at join; `4000000000000341` holds fine at join but every capture and incremental fails at settle (partly settled; Retry keeps failing). On the web, `/join?run=<id>&failcapture=1` joins with that card.
- Detection: the iOS app uses Apple Vision foreground instances on device (class-agnostic, so a low-contrast or touching item may need a tap); the web shopper uses frame differencing on the server.
- Identification and receipt reading: Gemini with `VISION=gemini`; with `VISION=stub`, stubs keyed to the three props and `server/assets/receipt.json`.
- Prices: QFC's own search page read in the shopper phone's hidden browser with `PRICE=agent`; the receipt sets the final price. With `PRICE=stub`, a fixed table.
- Payout to the shopper: simulated Visa Direct; production would push through a licensed partner.
- Storage: in memory with a JSON snapshot, no database. The payments simulator keeps its authorizations in the same data dir, and a restart reschedules any run's last-call lock.
