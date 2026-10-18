# Dibs: design spec

Status: revision 5, after an outside review (36 findings, 29 accepted). Core loop approved by the team on 2026-10-17 for a mock demo build. Payout simulated.
Date: 2026-10-17. Event: DubHacks 2026, Visa track.

Review record: three-round adversarial polish (scores 5.0, 6.0, 5.7), four independent hostile reviews (explainability, interaction state machine, Cybersource/Visa audit, builder check), a line-by-line consistency pass, and one outside AI review. Raw results are in `research_notes/Unique Visa hackathon commerce concepts/` (`polish_loop_live_cart.json`, `dibs_spec_hostile_review.json`).

## The pitch (say this, nothing more)

One housemate goes to the store. Everyone else joins the run, and each of their cards gets a hold for their cap, say $40. The shopper's phone sits on the cart, watching it. Every item that lands in the cart shows up on everyone's phone as a chip with a photo and a price. Drag a chip into your tray to claim it. If three people claim the same chip, it splits three ways. At the register the shopper pays once, snaps the receipt, and everyone's exact share is captured from the hold they already placed. Nobody chases anybody.

One line: **Call dibs on the cart. Nobody chases a cent.**

What is ours, if a judge asks: the claim happens before the purchase, in a physical store, every claimer's claim is backed by a card authorization placed before the trip, and whatever nobody claims can be put back. Receipt splitters (Splitwise, Tab, EasySplit) split after the purchase with IOUs. Group orders (Uber Eats) split before purchase but online. Bulk-share apps (Bulkshare) coordinate Costco packs over chat with no money attached. Cino (Balderton-backed) splits a card payment at purchase by preset ratios. Say "new combination," never "new primitive."

Honest footnotes, said only if asked: if the camera misses an item the shopper taps it; prices are final at the receipt; in the rare case a receipt price pushes a share past a cap and the cap can't be raised, the small remainder shows as owed.

## The one rule

Your tray is what you pay for. Lift a chip and drop it in your tray to claim it. Lift it out to leave. The same chip in several trays splits evenly. Your cap has to cover everything in your tray at full price, in case you end up alone on it.

Everyone drags. Only the shopper runs the cart.

## Glossary (use only these words in UI copy and in the pitch)

- **Run**: one shopping trip. Has a shopper and claimers.
- **Chip**: one item in the cart, shown as photo, name, price.
- **Grid**: the cart, shown as a two-row grid of chips. Everyone sees the same grid.
- **Tray**: your slice of the grid. The chips you are paying for.
- **Lift**: press a chip for 200 ms until it rises. The only way a chip moves.
- **Claim**: drop a lifted chip in your tray. **Leave**: lift a tray chip and release it outside the tray.
- **Wish**: an item you typed that isn't in the cart yet. Grey chip with your initial.
- **Remove**: shopper only. Lift a chip and drop it on the Remove zone. 5-second undo.
- **Cap**: the amount you authorized when you joined. On screen: "held".
- **Room**: your cap minus the full price of everything in your tray. What you can still claim.
- **Last call**: the 10 seconds after the shopper taps Checkout (5 seconds in the demo). **Locked**: nothing moves.
- **Confirm & charge**: the shopper's one irreversible tap, after the receipt is read.

## Roles

- **Shopper**: in the store, runs the cart, phone clipped to it. Places **no hold** and has **no cap check**. Claims like anyone else; the shopper's claims and the items nobody claimed come out of the shopper's own register payment. Payout to the shopper = the sum of the claimers' captures, to a test card number recorded on the shopper at run creation.
- **Claimers**: everyone else. Each places one authorization for their cap at join. They may join at any time until Locked. They do not have to watch live; chips stay claimable until Locked.

## The loop (4 steps)

1. **Add.** The shopper's phone is clipped to the cart, camera pointing down into it, streaming the whole trip. Nobody takes pictures of anything. A cheap detector watches every frame for a new object that lands in the cart, holds still for a second, and is not a hand (frame differencing in the mock; YOLO-World or Perceptron video tracking in real mode, see Technical decisions). That settled frame is cropped to the object and saved as the chip's photo and evidence. The crop goes to the identification model (Gemini Flash; Perceptron optional) once, which names the product, reads the price sticker, and reads a barcode if one is visible. The chip appears grey ("identifying") on the shopper's screen and goes live on every phone as soon as it has a name, within about 2 seconds. If the sticker was readable the price is on it; otherwise it is badged "~$?" and the price fills in later from the price worker (Saharsh's Gemini browser app, see Technical decisions), labeled "price from web". If the camera misses something, the shopper taps the item in the live view and it is identified from that frame through the same pipeline; a tap on a chip that failed to identify retries it. There is no hold-up ritual and no shutter. The receipt price is always final at settle.
   **The stream and the chips are different things.** Claimers see the live cart (a low-rate JPEG stream, about 2 frames per second, no WebRTC) so the run feels live and watchable. They claim by lifting chips, never by touching the video, so a laggy or jumpy frame can never break a claim. Frames are only sent while the run is open, the camera sees the cart and nothing else, and frames are deleted at lock except the one saved per chip.
2. **Claim.** Lift a chip, drop it in your tray. The ring on the chip shows who is in. Shares are equal among claimers. Lift a tray chip out to leave; when the last claimer leaves, the chip is simply open again. A claim that would exceed your room springs back with "Over your cap. Raise it?"; raising it is an incremental authorization. If a price arrives later and puts a tray over its cap, that chip gets an over-cap badge and the prompt "Raise your cap or leave"; if it is still over at lock, settle uses the share-above-authorization path below.
   **Wish** (the request direction, kept minimal): a claimer types an item and it appears in the grid as a grey wish chip with their initial. The shopper sees "Priya wants bagels" in the grid. When a matching item lands in the cart, the wish turns into the live chip already in Priya's tray, with a 3-second undo, provided it fits her room; if it doesn't, the chip is open and Priya sees "Bagels arrived, $X, over your cap". A wish typed by the shopper has no claimer. No shelf highlighting, no push notifications; the grid is the only channel.
3. **Checkout.** The shopper taps Checkout. Everyone sees "Jake is checking out, last call" with a countdown. Last call gives identifying chips time to resolve; any still identifying at lock are dropped with a note. Then the run locks. Only now does the shopper see the unclaimed list, each item defaulting to **Mine** with a one-tap **Put back**. "Back to cart" reopens the run and clears every Put back. The shopper pays at the register with their own card and photographs the receipt.
4. **Settle.** The identification model reads the receipt and matches each line to a chip, showing confidence. Unmatched lines are paired with a tap or marked Mine, and a put-back item that still appears on the receipt is offered as Mine ("forgot to put back"). A chip with no receipt line is marked "Not on receipt" but keeps its claims until Confirm & charge, so the shopper can still pair it. Receipt prices replace sticker prices; a separate tax line is spread across matched lines in proportion. The shopper taps Confirm & charge. Each claimer's share is captured and the rest of their authorization is reversed. Everyone sees one line: "Captured $4.36 (settles tonight) · $35.64 released · approval 888888". The shopper sees "Reimbursed $32.71 (simulated Visa Direct)". If any claimer's calls fail, the run shows "Partly settled" with that person marked "Retry", and Confirm & charge retries only them.

## State machines (small, and the whole interaction depends on them)

Run: `Open → LastCall → Locked → Receipt → Settled | PartlySettled`. "Back to cart" from LastCall or Locked returns to Open and clears Put back flags. Joins, claims and leaves are refused once Locked, with the toast "cart closed"; an in-flight drop springs back.

Chip: `Wish | Identifying → Open ⇄ Claimed{set of people} → Locked → Matched | Unmatched → Settled`, plus `Removed` with a 5-second undo that restores the chip with its claims intact, and a `PutBack` flag set by the shopper at Locked. Leaving removes you from the set; an empty set is Open. Naming an identifying chip (by retry or by the shopper typing a name) makes it Open. Claims are a set, never a count; the claim call is idempotent, so lifting a chip you already hold and dropping it on the tray just pulses the tray chip.

Claimer money: `Joined(authId) → Settling → Reversed → Captured`, or `Settling → Incremented → Captured` when the share exceeds the authorization, or `Settling → Reversed` (terminal) when the share is $0, or `Settling → Failed` (retryable). Each step's result is stored before the next call, so a restart or a second Confirm & charge resumes exactly where it stopped and never repeats a completed call.

## Money

Every call is a Visa Acceptance (Cybersource) gateway call except the payout. Say "authorization", "capture", "reversal" to judges; say "held", "captured", "released" on screen. Never say "the hold is real": the sandbox never talks to an issuer, so nothing is held or released on a real card; "released" means the reversal was accepted. Say "live sandbox authorizations on the Visa Acceptance Platform; in production the issuer places the hold."

| Moment | Call | On screen |
|---|---|---|
| Join | `POST /pts/v2/payments`, `capture=false`, `authorizationOptions.authIndicator="0"` (pre-authorization, Visa's "estimated authorization"), amount = cap, test card with month and year, fixed sandbox billing address | "$40 held · approval 888888" (simulator) or the sandbox's own approval code or transaction id |
| Claim / leave | None. Server-side draw-down against the authorized amount | share and room update instantly |
| Raise cap | `PATCH /pts/v2/payments/{id}`, `additionalAmount` = delta. Enabled in real mode only if the hour-0 gate shows the processor accepts it; otherwise raise-cap is off in real mode and the demo never uses it | hold grows |
| Settle, per claimer | 1) `POST /pts/v2/payments/{id}/reversals` for authorized minus share, 2) `POST /pts/v2/payments/{id}/captures` for the share. Share of $0: full reversal only, using the authorized amount from the authorization response | "Captured $4.36 (settles tonight) · $35.64 released" |
| Share above the authorization | `PATCH` incremental for the difference, then capture. If declined: capture the authorized amount, show the remainder as owed, and mark the run Partly settled | "Captured $40.00 · $1.12 owed" |
| Payout to shopper | Simulated and labeled, single Visa story. The server writes a payout record shaped like a Visa Direct `pushfundstransactions` request (`businessApplicationId "FD"`, amount = sum of captures, recipient = the shopper's test card) and shows it. A real Visa Direct sandbox call (two-way SSL plus message-level encryption) is a stretch after hour 20 | "Reimbursed $32.71 (simulated Visa Direct)" |

Not usable for the payout: Venmo and Cash App have no public API for sending money between people. Stripe Terminal is a card reader for in-person payments and does not move money to a person. Stripe Connect test mode is the only fallback if a judge-visible real transfer ever becomes necessary.

Rules, in cents: receipt line price replaces the sticker price; a separate tax line is allocated pro rata across matched lines by their pre-tax amount; per chip, floor the split, then give the leftover cents one each to the earliest claimers; tray preview and capture use the same function so they always agree. Room = cap minus the full price of priced chips in your tray times (1 + local tax rate); unpriced chips count $0 until priced.

Hour-0 gate for owner B: a standalone script (written before the hackathon) runs authorize (authIndicator 0) → incremental → partial reversal → capture against `apitest.cybersource.com` with the official SDK and prints statuses. Record which processor simulator the sandbox account uses and whether the incremental was accepted. Decline test card for rehearsal: expiry year 1998.

Spoken once if asked: in production captured funds land in the merchant account and a licensed partner pays the shopper over Visa Direct; in the sandbox they are payment records; incremental authorization is permitted by Visa when the final amount is unknown, and acquirer enablement depends on merchant category.

## Screens (4)

1. **Join**: scan the shopper's QR, see the preset cap, tap Join, watch "$40 held" appear with the approval code. One judge phone starts here in the demo.
2. **Cart (shopper)**: the live view on top with a small "watching" pulse while an item is being identified; tap the view to identify what's under your finger; the grid; the tray drawer; Checkout. Lifting any chip reveals the Remove zone over the live view. Tap a chip to fix its name or price (shopper only). At Locked: the unclaimed list with Mine / Put back and Back to cart.
3. **Cart (claimer)**: the live cart view on top, small, with "live" and the shopper's name (tap to enlarge, nothing else); the grid; the tray drawer with "$40 held · $4.36 your share · $31.28 room"; a Wish button.
4. **Settle**: receipt lines matched to chip photos with confidence and tap-to-fix; the put-back list; one line per person with Retry where a call failed; the payout line; Confirm & charge (shopper only).

## Gestures and the ring

- Lift is press-and-hold 200 ms with a haptic and a scale-up. A swipe without the hold scrolls the grid.
- Detection pauses while the cart is changing (a hand in frame in real mode; any moving change in the mock) and resumes when the cart is still.
- When a chip is lifted, the tray expands to the bottom 40% of the screen and shows the resulting total live. Releasing anywhere else springs back.
- Resting tray is a drawer showing count and total. Every claim or leave shows a 3-second Undo toast that performs the opposite action.
- Grid chips always show the full price small. Tray chips show your share large with a "÷2" badge. Chips with "~$?" are claimable, count $0 against the cap, and reflow shares when priced, with an over-cap badge if the new price breaks the rule.
- Ring: one claimer is a full ring with a visible open notch (never reads as "taken"). Up to three claimers: equal segments in each person's color with an initial; your own segment is thicker. Four or more: a count in the center, long-press for names.
- Duplicates: the same item identified within 5 seconds asks the shopper "Added twice? Keep both / Remove one". A chip can carry a quantity badge "×2"; equal split applies to the line total.

## Edge cases (decided)

- Late joiner: sees every chip; may claim until Locked.
- Two people drop at once: the server is the authority; both succeed.
- Someone leaves a chip you share: your share goes up but can never break your cap, because the cap rule already covered the full price.
- Shopper removes a claimed chip: everyone sees it grey out with "Jake removed the eggs"; totals animate down; 5-second undo.
- Identification fails: "Couldn't identify. Tap it again or name it" on the shopper's screen; the chip stays identifying until named, and is dropped at lock if still unnamed.
- Receipt line with no chip: tap to pair or mark Mine. Chip with no receipt line: "Not on receipt"; its claims are released only at Confirm & charge.
- Authorization declined at join: that person cannot join; the run continues.
- Network drop: chips and claims live on the server; the client re-syncs. The settle step stores each person's progress and resumes without repeating a completed call.
- Slow claimer connection: the server sends only the latest frame and drops stale ones, so chips and claims stay instant while the video stutters.
- Stray claim in the last second: mitigated by lift, Undo toast, last call, and an in-app banner at Locked reading "Your tray is $23.50 across 4 items". Post-lock disputes are out of scope for the demo.

## Later, after the core loop works (not in the 36 hours)

- **Fridge suggestions**: a phone walkthrough of the fridge seeds wish chips for the next run. Same wish mechanic, different source.
- **Social**: the only social layer that survived review is the one already in the core loop: the people claiming are present and are the source of the money. The ring with initials, racing for the last share, and watching a chip you claimed split as others join. If anything is added later, it stays inside the run: a shared end-of-run card ("Jake's Costco run: $84.12, 4 people"). No feeds, points, leagues, or leaderboards; every version of those was judged to hurt.
- **Native wrapper**: the SwiftUI shell wraps the web app in a WKWebView for an App Store story.

## What is cut, and why

- Dragging boxes off the video: a laggy frame would break a claim mid-drag. Chips are the claim surface; the stream is for watching.
- The hold-up or shutter ritual: taking a picture of each item defeats the point. Detection is continuous, with tap-the-view as the only manual fallback. The reviewers rated continuous detection the riskiest vision job, so the hour-2 gate tests it first, and the mock demo ships with frame differencing on fixed props.
- Push-drag requests into the shopper's view with shelf highlighting: NeedAnything, Runerra and Buy4Me ship this; a typed wish covers the real need.
- Per-item holds: 25 pending charges on a debit card; replaced by one authorization per claimer.
- Hold on the shopper: money would go in a circle.
- A second authorization as the raise-cap fallback: it breaks the one-authorization model and doubles the settle accounting. If the processor rejects incremental authorization, raise-cap is simply off in real mode.
- Fridge-camera pre-fill and habit suggestions: a second vision pipeline that never touches the money moment. Later.
- Browser-agent shopping: out of the pitch; the agent's only job is price lookup.
- Feeds, leaderboards, profiles, history, custom split ratios: cut.
- Raise-cap and the put-back beat: out of the 90-second demo (both still built; put-back is the silent default screen at Locked).

## The 90-second demo (numbers reconcile; cap $40; every price under $40)

Props: a basket with the shopper phone clipped above it; two team-owned iPhones for judges with the web app on the home screen, one on the Join screen (cap preset to $40) and one pre-joined as B; a printed receipt that matches the props exactly (eggs $8.72, paper towels $23.99, milk $4.29, tax included, total $37.00); three real items with our own price stickers; a laptop running the price worker in the iOS Simulator and mirroring the phones. Last call set to 5 seconds for the demo. The run is seeded with the shopper only; B joins before the judges arrive; A joins on camera.

- 0:00 Hand judge A the Join phone. "Tap Join." "$40 held · approval 888888" appears (the simulator's code; in real mode, the sandbox's own). "That authorization is live on the Visa Acceptance sandbox. Everything you claim comes out of it."
- 0:10 Teammate drops the eggs into the basket under the clipped phone. Both judge phones show the basket live; two seconds later a chip appears with the eggs' photo and "$8.72". "Nobody scanned anything. The cart is being watched."
- 0:20 Judge A lifts the eggs into their tray. Ring: full with a notch. "Your share $8.72 · $31.28 room."
- 0:30 Judge B lifts the same eggs. Ring splits into two initials. Both phones: "$4.36". "That's the split. It happened before Jake paid, and it's backed by two authorizations."
- 0:40 Judge B lifts the paper towels into their tray. "$23.99." Judge A lifts the eggs out, then back in. "$8.72, then $4.36 again. Leaving is just lifting out."
- 0:55 Teammate drops the milk in, nobody claims it. Teammate taps Checkout. "Last call" banner, five seconds, lock. The milk silently stays with Jake.
- 1:05 Teammate photographs the printed receipt. Settle: three lines matched with confidence. Confirm & charge. Judge A: "Captured $4.36 · $35.64 released". Judge B: "Captured $28.35 · $11.65 released". Shopper: "Reimbursed $32.71 (simulated Visa Direct)", which is exactly $4.36 + $28.35.
- 1:20 "Your cap isn't a setting, it's an authorization. Four Visa Acceptance calls: authorize, incremental when you raise your cap, capture for your share, reverse the rest. Payout is simulated; in production it's a Visa Direct push through a licensed partner."

Arithmetic check: A's room after claiming eggs alone is $40.00 − $8.72 = $31.28; B's room after eggs and towels is $40.00 − $32.71 = $7.29. At settle A's share is $4.36 (released $35.64), B's is $4.36 + $23.99 = $28.35 (released $11.65). Payout $32.71. Milk $4.29 stays with Jake. Receipt total $37.00.

## Technical decisions (made; override if the team disagrees)

**Detect and identify: two jobs.** Detection (something new settled in the cart) runs on every frame and must be cheap: in the mock it is frame differencing on the cart region; in real mode it is YOLO-World (open-vocabulary YOLO, prompted with "grocery item, package, carton, bag, bottle, hand") via ONNX on the server, or Perceptron's native video tracking over 3-second windows, whichever catches more of the 15 test drops at the hour-2 gate. Plain COCO-trained YOLO is not an option: it has no class for most groceries. The detected box, once still for one second and not a hand, is snapshotted and cropped; that crop is the chip's photo and the evidence frame. Identification (what is it, what does the sticker say) runs once per detected item on the crop, through Gemini Flash, which the team already has a key for. Perceptron is optional: if it is available and beats Gemini at the hour-2 gate, swap it in behind the same interface. Barcodes are a free extra: if one is visible in the crop, the scanner pins the identity. Nobody is asked to find a barcode. The shipping path for the mock demo is frame differencing plus the stub identifier on three fixed props; the real detectors are post-demo work behind flags.

**Price: sticker, then worker, then receipt.** Sticker OCR when readable. Otherwise the server posts a price request, and the existing SwiftUI Gemini browser agent (Saharsh's app, running in the iOS Simulator on the demo laptop as a "price worker") polls for open requests, browses the store's site, and posts back the price and the page URL. In worker mode it auto-approves browser actions on the store's domain, so the lookup runs unattended; the live preview still shows the agent browsing. The chip is labeled "price from web". A server-side Gemini call with search grounding is the fallback when no worker is connected. The chip is live and claimable while the price is pending. The receipt price is always final at settle.

**Devices at the table.** Shopper phone clipped to the cart, streaming in Safari. Two claimer phones held by judges, joined by QR (a laptop browser tab can stand in for one). A laptop running the iOS Simulator with the price worker, also mirroring the phones as a backup display.

**Platform: web app first, installed to the phone's home screen.** It runs on any phone with no Xcode signing, the camera works in mobile Safari over HTTPS, a QR code opens the claimer screen directly, and four people can iterate on one codebase. The existing SwiftUI shell is the price worker now and the native wrapper later.

**Stack.** Next.js (React) PWA for shopper, claimer and settle screens, with dnd-kit for lift-and-drop on touch. Node backend with WebSockets for the run state and the frame relay; in-memory state with a JSON snapshot for the mock demo, Postgres later. Gemini Flash for identification and receipt reading (Perceptron optional). Cybersource REST SDK for Node against the sandbox. Deployed on Railway as one service, which gives HTTPS for the camera. Setup on a phone: open the Railway URL in Safari, Share, Add to Home Screen.

**Mock demo first.** The first build is the full loop with everything that can be faked faked: three fixed props, a seeded run, frame-differencing detection, a stub identifier and price table, and a realistic payments simulator. Then the real detector, Perceptron, the price worker and Cybersource are switched on one at a time behind flags.

## Build (4 people, 36 hours)

Assumptions recorded for the builders: expo-table judging with judges handling team-owned iPhones running the web app from the home screen, with screen mirroring as backup; the Visa track accepts any public payment API as the DH25 text did, with the Cybersource sandbox as the primary rail (confirm against the DH26 Devpost text; see open questions); Gemini is the allowed fallback for any vision job if Perceptron misses the gate.

Demo-critical path, in order: payments simulator and money math; run state; API; grid and tray; shopper and claimer screens; settle; deploy; rehearse. Everything else (real detectors, Cybersource, price worker, wish UI, rings beyond three) comes after the demo path runs on three devices.

- **A, vision**: the frame stream (2 fps JPEG over the socket); detection (frame differencing in the mock; YOLO-World or Perceptron video in real mode; pause while the cart is changing); identification on the crop (name, sticker OCR, barcode); receipt OCR matched only against this run's chips, with confidence and tap-to-fix; tuned on the three props. Hour-2 gate: drop each prop into the basket five times; detection must fire within 2 s on 13 of 15 drops, and Perceptron must return the right name under 1.5 s, else identification moves to Gemini and detection stays on frame differencing.
- **B, payments and state**: the run and chip state machines, split math in cents, resumable settle, the payments simulator, the standalone Cybersource gate script (run at hour 0), then the Cybersource provider via the official SDK (authorize with authIndicator 0, incremental, reversal, capture); approval code and transaction id back to the UI.
- **C, app**: one shared Grid and Tray component (lift, claim, leave, ring at n=1,2,3,5, over-cap spring-back, undo toasts) used on both Cart screens; the four screens in the Next.js PWA; the camera stream and live view; QR join; Railway deploy and home-screen install on three iPhones.
- **D, demo and price worker**: props and stickers, the printed receipt designed to the money rules, the price worker mode in the SwiftUI app, the 90-second script, screen mirroring, 15 rehearsals, backup video, Devpost write-up with the prior-art sentence.

Milestones: hour 0, B's gate script. Hour 2, A's detection and identification gate. Hour 12, authorize → reversal → capture end to end and a chip appearing from a drop into the basket. Hour 20, full loop with ugly UI. Hour 24, feature freeze. Hours 24 to 32, reliability: lighting, glare, two judges dropping at once, ring at every n. Hours 32 to 36, run the demo 15 times.

## Open questions only the team can answer

1. What does the DubHacks 2026 Visa track text actually require? If it scores a specific Visa Developer API, B's rail changes.
2. Is a Perceptron API key with enough quota in hand, and which model and endpoint?
3. Three iPhones (or two plus a laptop tab), and a Mac with Xcode for the Simulator price worker?

## Spikes to run before the build (throwaway, in parallel, half a day)

1. **Detect and identify**: frame differencing on a phone clip of three drops fires three times; Perceptron on the three crops returns the right name and sticker price under 1.5 s.
2. **Price**: the existing browser agent given "Kirkland eggs 24 ct, costco.com" returns a price and a source URL within 45 s.
3. **Bill**: the standalone gate script on the Cybersource sandbox: authorize (authIndicator 0) → incremental → partial reversal → capture, statuses printed.
