# Dibs hybrid: SwiftUI app, Dibs server, Gemini names, browser agent prices

Status: draft rev 2 for approval. Date: 2026-10-17. Builds on `2026-10-17-dibs-design.md` (rev 5); nothing in that spec changes unless this one says so.

Rev 2 changes: every screen moves to the SwiftUI app (not only the shopper camera); the browser-agent price fallback is the core of the pipeline; wishes start from a suggestion screen; wishers can delete their own wishes; the team's backend supplies households, suggestions and inventory; a list of missing interactions is added.

## Decision

- **Client:** the team's SwiftUI app (`Agora/`) for everyone: shopper and claimers. The current web app stays as the fallback demo path and is not extended further.
- **Run state and money:** the Dibs Node server stays the authority for runs, chips, claims, splits, holds and settle. Its 116 tests cover the money logic.
- **Household data:** the team's FastAPI backend and Postgres database supply who is in the house, wish suggestions, run-out forecasts and inventory. Dibs does not copy them.

## The pipeline for each item (the key part)

1. **Detect, on the phone.** A class-agnostic trigger notices that a new object landed in the cart and is still for one second, with no hand in frame, and draws the box. See "Detection" below.
2. **Name, with Gemini.** The crop goes to the Dibs server, and Gemini Flash names the item and reads a shelf tag or sticker price if one is visible.
3. **Price, with the browser agent when Gemini has none.** The server queues a price request. The app's existing Gemini browser agent opens the store's site, searches the item name, and posts back `{cents, url}`. The chip shows "Finding price…" until then. Claimers can claim before the price lands; the cap check runs again when it does.
4. **Fallbacks, in order:** a server-side Gemini search lookup if the agent fails or exceeds 45 seconds, then the shopper's fix sheet.

The browser agent runs on the shopper's phone by default, so the demo needs no laptop. A teammate's phone can run it instead, to keep the shopper's screen free.

## Wishes

- **Add a wish opens its own screen**, not a sheet over the claim screen.
  - **Running low:** items the team backend's run-out forecast lists for this household, with the reason ("about 2 days left").
  - **Suggested for you:** the backend's ranked wishlist suggestions, with their reasons.
  - **Type it yourself:** a text field at the top for anything not in the lists.
  - One tap adds a wish and returns to the claim screen.
- **Delete a wish.** The person who made it can delete it from its chip, as can the shopper. Today the server lets only the shopper delete wishes.
- **When the shopper adds the item,** the wish turns into the real chip and the wisher keeps the claim, as today.
- **After settle,** items each person paid for are reported to the team backend as purchases, so the inventory and forecasts stay current. This closes the loop: what you buy feeds the next run's suggestions.

## Detection: is an iPhone fast enough, and which model

- Speed is fine. A small YOLO model on the Neural Engine is commonly reported at 30 to 60 fps on recent iPhones; Dibs needs about 2 decisions per second.
- The limit is what the model knows. Standard YOLO (COCO, 80 classes) has no class for most packaged groceries, so it cannot be the namer. Gemini names; the detector only triggers and draws the box.
- **Primary trigger:** Apple Vision foreground segmentation (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+, no model file) compared against the last settled cart, plus hand pose (`VNDetectHumanHandPoseRequest`) to pause while a hand is in frame.
- **Optional:** YOLO-World exported to Core ML with a custom vocabulary, if the team wants "YOLO" in the pitch. Measure both on 15 drops and keep whichever catches more.

## Data: whose database holds what

| Data | Lives in | Why |
|---|---|---|
| Runs, chips, claims, holds, settle | Dibs server (in memory with a JSON snapshot) | Already built and tested; one run lasts an hour |
| Users, households, members | Team backend (Postgres) | Google sign-in already exists; a household is the house |
| Wish suggestions, run-out forecasts, inventory | Team backend | Already built from scans |
| Purchases after settle | Team backend, written by the app | Feeds inventory and forecasts |

- A Dibs run gets created with the household's members from the team backend, so nobody types a name.
- Moving runs into Postgres is not needed for the hackathon. It becomes worth it only if runs need history across server restarts on Render, where the disk is not persistent.

## Missing interactions to build

Wishes:
- The wisher deletes their own wish.
- The wisher edits a wish's name.

Run lifecycle:
- The shopper cancels a run before checkout, which releases every hold.
- A claimer leaves a run before checkout, which releases their hold and drops their claims.
- A claimer lowers their cap. Raising it already exists in the over-cap sheet.
- Rejoining from a second device or after reinstalling. Today identity lives on one device.

Items:
- Quantity: "2 × eggs" as one chip with a count, claimable per unit, instead of two chips.
- Uneven split: claim 1 of 3 units, instead of only even splits.
- The shopper adds an item by name without the camera, for something already bagged.
- A "Finding price…" state on the chip while the browser agent works, with the agent's source link once it lands.

Notifications and history:
- Push notifications for: your wish was added, last call started, you were charged.
- Past runs: what you paid and for what, with the receipt photo.
- Disputes after settle: "That wasn't mine" sends a note to the shopper. No automatic refund.

## Phases (each one is demoable on its own)

1. **SwiftUI client on the current server.** Start, Join, Claim, Shopper with a native camera streaming frames, and Settle, matching the design canvas. Sign-in and household come from the team backend. This fixes the Safari camera problem.
2. **Wish screen and wish delete.** Suggestions and running-low items from the team backend, manual entry, and deleting your own wish (server change plus tests).
3. **Browser-agent prices.** The price request queue on the server, the agent's price-worker mode in the app, the "Finding price…" state, and the server-side Gemini fallback.
4. **On-device detection.** The Vision trigger sends crops to a new `POST /api/runs/:id/crops`; the server-side detector is bypassed for that run.
5. **Missing interactions,** in this order: cancel run, leave run, quantity, purchases written to inventory, push notifications, history, the rest.
6. **Optional:** YOLO-World Core ML, if it beats the Vision trigger.

## Risks and fallbacks

- **Every housemate needs the app.** Fine for the demo, since the team owns the phones. For real users, an App Clip opened from the shared link removes the install.
- **Signing and installing builds on demo phones takes time.** Fallback: the current web app, which already runs the whole flow.
- **The browser agent is slow or blocked by the store's site.** The server-side Gemini lookup takes over after 45 seconds, then the fix sheet.
- **Vision's mask may merge a new item with items already in the cart.** Compare against the settled mask; tap-to-identify is the fallback.
- **The team backend is down.** The wish screen still offers manual entry, and the run works without suggestions.

## Open questions for the team

1. Can the app be installed on every demo phone today (developer account, signing)?
2. Pitch "YOLO" by name, or "on-device detection"? This decides phase 6.
3. Host the Dibs server on Render beside the team backend, or keep the ngrok link for now?

A full task-by-task plan for phase 1 follows approval.
