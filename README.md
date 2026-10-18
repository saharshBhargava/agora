# Dibs

Dibs watches a shopper's basket with a phone camera, turns each item into a chip, and lets friends lift chips into their own tray so the bill splits itself. Every claimer's cap is a real card authorization; at settle, each share is captured and the rest is released.

This is the mock demo: detection is frame differencing on three fixed props, identification and prices are stubs, and payments run on a simulator.

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

### Camera demo: drop order matters

With `VISION=stub`, the camera path uses a deterministic stub. When a dropped item does not clearly match a prop photo, the stub names the next prop in drop order for that run: eggs, then towels, then milk, then eggs again. Drop the eggs, the towels and the milk in that order. A whole-frame lighting or exposure change re-baselines the detector and adds no chip. If the camera misbehaves, switch the shopper to `?mock=1` (the "Use sample items" link) and tap the items instead.

### Replacing the placeholder props

The prop images are generated placeholders. To use real photos: put `eggs.jpg`, `towels.jpg`, `milk.jpg` in `server/assets/props/` (and copy them to `web/public/props/`), then regenerate frame fixtures with `pnpm -C server exec tsx scripts/make-frames.ts`. Skip `scripts/make-props.ts`, which only draws the placeholders.

## Env flags

| Flag | Demo value | Meaning |
| --- | --- | --- |
| `DETECTOR` | `diff` | Detection mode. `diff` is frame differencing; real detectors are not wired yet. |
| `VISION` | `stub` | Identification and receipt reading. `stub` returns the three known props. |
| `PRICE` | `stub` | Price source. `stub` is a fixed price table. |
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

## Deploy to Railway

The repo root `Dockerfile` and `railway.json` (healthcheck `/api/health`) are all it needs.

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

HTTPS is required for the camera, which Railway provides.

1. Create a run: `curl -X POST https://<domain>/api/runs` returns `runId` and `shopperId`.
2. Shopper phone: open `https://<domain>/shopper?run=<runId>&person=<shopperId>` in Safari, Share, Add to Home Screen, then open it from the home screen and allow the camera. On this phone set Settings → Display & Brightness → Auto-Lock → Never (the page also holds a screen wake lock where Safari allows it). Clip it above the basket.
3. Judge B phone: open `https://<domain>/join?run=<runId>&name=B`, tap Join (cap $40), then Start claiming, then Add to Home Screen.
4. Judge A phone: leave it on the Join screen. Claimers scan the QR from `https://<domain>/api/runs/<runId>/qr` (open it on the laptop) to land on `/join?run=<runId>`.
5. Run the full loop on the real devices over a real basket before the demo.

## The 90-second demo

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
- Detection: frame differencing on three fixed props, not a trained detector.
- Identification, receipt reading and prices: stubs keyed to the three props and `server/assets/receipt.json`.
- Payout to the shopper: simulated Visa Direct; production would push through a licensed partner.
- Storage: in memory with a JSON snapshot, no database. The payments simulator keeps its authorizations in the same data dir, and a restart reschedules any run's last-call lock.
