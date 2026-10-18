# Dibs Mock Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working end-to-end Dibs demo on three phones: the shopper's phone streams the cart continuously, items that land in it become chips automatically (frame differencing in the mock; YOLO-World or Perceptron video in real mode), claimers watch the live cart and lift chips into trays, shares split live, checkout locks, a receipt settles each person's share through a payments provider, and the shopper's payout is shown as a simulated Visa Direct push.

**Architecture:** One Node process (`server/`) owns the run state machine, the money math, the frame relay, and four swappable providers (detector, vision, price, payments), each shipped first as a realistic simulator and later as the real integration behind an environment flag. A Next.js static export (`web/`) is served by that same process and talks to it over REST and one WebSocket per phone. Deployed as a single Railway service so the camera gets HTTPS.

**Tech Stack:** Node 20+, TypeScript strict, pnpm workspaces, Fastify + `ws`, vitest, `sharp` (frame decode for the mock detector), Next.js 15 (app router, `output: "export"`), React 19, dnd-kit, Tailwind, `qrcode`, `@zxing/browser` (barcode extra), `onnxruntime-node` + YOLO-World ONNX (flagged), Perceptron hosted API (flagged), Gemini (fallback, flagged), `cybersource-rest-client` (flagged).

**Spec:** `docs/superpowers/specs/2026-10-17-dibs-design.md`

**Demo-critical path:** Tasks 1, 2, 3, 4, 5, 6, 7A, 7B, 8, 9, 10, 11, 12. Tasks 0 and 4B are prep. Tasks 13, 14, 15 are post-demo, behind flags. Within Tasks 9 and 11, the wish UI and the ring at n≥3 are last.

## Global Constraints

- All money is integer cents. No floats touch a price, share, authorization or capture.
- UI copy and server event names use only the glossary words: run, chip, grid, tray, lift, claim, leave, wish, remove, cap/held, room, last call, locked, confirm & charge.
- On screen: "held", "captured", "released". Never "paid" or "charged". Captures show "(settles tonight)".
- The server is the authority for every claim, leave, remove, lock and settle. Clients render state; they never compute money for anything that is sent to a provider.
- Settle is resumable: each claimer's progress is stored before the next provider call, with `clientReferenceInformation.code = "<run>-<person>-<step>"`; a second confirm never repeats a completed call.
- Providers are selected by env with these exact values and defaults: `DETECTOR=diff|yolo|perceptron` (default `diff`), `VISION=stub|gemini|perceptron` (default `stub`; real mode uses `gemini`, Perceptron optional), `PRICE=stub|native|agent` (default `stub`), `PAYMENTS=sim|cybersource` (default `sim`), `RAISE_CAP=on|off` (default `on`; set `off` in real mode if the hour-0 gate shows the processor rejects incremental authorization).
- `LAST_CALL_MS` env: default `10000`; the demo runs with `5000`; tests set `50`.
- Camera requires HTTPS in mobile Safari. Local dev uses `https://localhost` via a self-signed cert or the Railway preview URL.
- The stream is JPEG frames at 2 fps, 640 px wide, quality 0.6, sent over the shopper's WebSocket and relayed to claimers. The server keeps only the latest frame per run; frames are never stored except the one saved per chip; everything buffered is discarded at lock.
- Claims are made on chips only. No client ever maps a touch on the video to a claim. The shopper has no cap check.
- Demo numbers (seeded run): eggs $8.72, paper towels $23.99, milk $4.29, caps $40.00, tax included in line prices (`taxRate 0`), approval code `888888` in simulator mode.

## Review Focus

1. A claimer's socket falls behind on frames (venue Wi-Fi): the server skips the frame for that client instead of queuing it, so chips and claims stay instant while the video stutters. Test in Task 7B.
2. Two claimers drop the same chip within the same second: the claim set contains both once, never a doubled share. Test in Task 3.
3. A claimer leaves a chip you share: your share rises but your tray can never exceed your cap, because the room check uses full price. Test in Task 3.
4. A claim, leave or join arrives after Locked: refused with reason `cart closed`, state unchanged. Test in Task 3.
5. A receipt line matches no chip, or a chip has no receipt line, or a put-back chip appears on the receipt: lines are held as unmatched for tap-to-fix and claims are kept until confirm. Test in Task 5.
6. A settle call fails for one claimer: the others complete, the run is `partlySettled`, and a second confirm retries only the failed person without repeating any completed call. Test in Task 5.

---

### Task 0: UI design in Claude Design (no code)

Before Task 8, produce the four screens (Join, Cart shopper, Cart claimer, Settle) as a Claude Design artifact: Artifact quickstart with intent `design`, then a design built on the default design system. Deliverable: the artifact URL recorded at the top of `web/README.md`, plus the exported color tokens and type scale pasted into `web/app/globals.css` as CSS variables. The design must show: the ring at n=1 (full ring with an open notch), n=2, n=3 (initials) and n=5 (count in center); a wish chip (grey, initial); a `~$?` chip; an over-cap badge; the tray drawer resting and expanded with the header "held · your share · room"; the live view small (claimer) and large (shopper); the Settle screen with a Retry line. Tasks 8 to 11 implement these screens exactly.

### Task 1: Workspace scaffold

**Files:**
- Create: `package.json` (pnpm workspace root), `pnpm-workspace.yaml`, `server/package.json`, `server/tsconfig.json`, `server/vitest.config.ts`, `server/src/index.ts` (empty bootstrap), `server/test/smoke.test.ts`, `.gitignore` (add `node_modules/`, `web/out/`, `server/dist/`, `server/.data/`, `.env`)

- [ ] **Step 1: Write the failing smoke test** `server/test/smoke.test.ts`: `expect(1 + 1).toBe(2)`.
- [ ] **Step 2: Scaffold** root workspace with `pnpm init`, `pnpm-workspace.yaml` listing `server` and `web`; `server` with `typescript`, `vitest`, `tsx`, `@types/node`; `tsconfig` strict, `module: NodeNext`, `target: ES2022`.
- [ ] **Step 3: Run** `pnpm -C server test` → PASS 1 test.
- [ ] **Step 4: Commit** `chore: scaffold pnpm workspace with server and vitest`.

### Task 2: Money math

**Files:**
- Create: `server/src/money.ts`, `server/test/money.test.ts`

**Interfaces:**
- Produces: `splitChip(priceCents: number, claimerIdsByClaimTime: string[]): Map<string, number>` (floor, leftover cents one each to the earliest claimers; sums exactly to `priceCents`; empty list → empty map).
- Produces: `roomFor(trayFullPricesCents: number[], authorizedCents: number, taxRate: number): number` (`authorizedCents - Math.ceil(sum * (1 + taxRate))`, may be negative).
- Produces: `capAllows(trayFullPricesCents: number[], candidateFullPriceCents: number, authorizedCents: number, taxRate: number): boolean` (`roomFor([...tray, candidate], authorized, taxRate) >= 0`; callers pass only priced chips).
- Produces: `allocateTax(lineCents: number[], taxCents: number): number[]` (pro rata by line amount, floor, leftover cents to the largest lines first; sums exactly to `taxCents`).
- Produces: `personTotals(chips: {priceCents: number, claimers: string[]}[]): Map<string, number>`.

- [ ] **Step 1: Write failing tests**: `splitChip(872, ['a','b'])` → `{a: 436, b: 436}`; `splitChip(800, ['a','b','c'])` → `{a: 267, b: 267, c: 266}`; `splitChip(2399, ['b'])` → `{b: 2399}`; sum equals price for `splitChip(1001, ['a','b','c'])`; `roomFor([872], 4000, 0)` → 3128; `roomFor([872, 2399], 4000, 0)` → 729; `capAllows([872, 2399], 2399, 4000, 0)` → false; `capAllows([], 3999, 4000, 0.1)` → false; `allocateTax([800, 2200], 271)` → `[72, 199]` and sums to 271; `personTotals` with eggs shared by a and b and towels solo b → `{a: 436, b: 2835}`.
- [ ] **Step 2: Run** `pnpm -C server test money` → FAIL, functions not defined.
- [ ] **Step 3: Implement** in `server/src/money.ts`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): money math in cents with largest-remainder split and tax allocation`.

### Task 3: Run and chip state machines

**Files:**
- Create: `server/src/run.ts`, `server/src/types.ts`, `server/test/run.test.ts`

**Interfaces:**
- Consumes: Task 2 `splitChip`, `capAllows`, `roomFor`.
- Produces (`server/src/types.ts`): `RunState = 'open'|'lastCall'|'locked'|'receipt'|'settled'|'partlySettled'`; `ChipState = 'wish'|'identifying'|'open'|'claimed'|'locked'|'matched'|'unmatched'|'settled'|'removed'`; `Chip = {id, name, priceCents: number|null, priceSource: 'sticker'|'web'|'receipt'|'none', photoUrl: string|null, region: Box|null, quantity: number, claimers: string[] /*ordered by claim time*/, state: ChipState, wishedBy: string|null, duplicateOf: string|null, putBack: boolean, dropped: boolean, overCap: string[] /*personIds whose tray broke the rule when a price arrived*/, removedAt: number|null}`; `Box = {x, y, w, h}`; `Person = {id, name, initial, isShopper: boolean, authorizedCents: number|null, authId: string|null, payoutPan: string|null}`; `ReceiptLine = {text: string, cents: number, quantity: number, isTax: boolean}`; `ReceiptState = {lines: ReceiptLine[], matches: {chipId: string, lineIndex: number, confidence: number}[], unmatchedLines: number[]}`; `SettleStep = 'joined'|'settling'|'incremented'|'reversed'|'captured'|'failed'`; `PersonSettle = {step: SettleStep, shareCents: number, capturedCents: number, releasedCents: number, owedCents: number, approvalCode: string|null, captureId: string|null, error: string|null}`; `Run = {id, state, store: string, shopperId, people: Person[], chips: Chip[], taxRate: number, lastCallEndsAt: number|null, receipt: ReceiptState|null, settle: Record<string, PersonSettle>, payout: PayoutRecord|null}` (`PayoutRecord` from Task 4).
- Produces (`server/src/run.ts`, all pure, `now: number` injected, every function returns a new `Run` or `{error}`): `createRun(shopper: Omit<Person,'isShopper'|'authorizedCents'|'authId'>, store: string, payoutPan: string, now): Run`; `join(run, person): Run | {error: 'cart closed'}` (the server authorizes first and never calls `join` on a decline); `setAuthorization(run, personId, authorizedCents, authId): Run`; `addChip(run, chip: Pick<Chip,'id'|'name'|'priceCents'|'priceSource'|'photoUrl'|'region'|'quantity'>, now): Run` (state `identifying` when `name` is empty, else `open`; same normalized name within 5000 ms sets `duplicateOf`; an open wish with the same normalized name is replaced by this chip with the wisher in `claimers` only if `capAllows` passes for the wisher, otherwise the wisher is added to `overCap`); `setChipLive(run, chipId, name, priceCents, priceSource, now): Run` (identifying → open; resolves a matching wish as above); `setChipPrice(run, chipId, priceCents, priceSource): Run` (for each claimer whose tray now fails `roomFor >= 0`, add them to `overCap`; clear `overCap` entries that pass again); `claim(run, chipId, personId, now): Run | {error: 'cart closed'|'over cap'|'unknown chip'|'not claimable'}` (idempotent; `wish` and `identifying` chips are `not claimable`; the shopper skips the cap check; others use `capAllows` over their priced tray chips); `leave(run, chipId, personId): Run | {error: 'cart closed'|'unknown chip'}` (an empty claimer set returns the chip to `open`); `removeChip(run, chipId, now): Run`; `undoRemove(run, chipId, now): Run | {error: 'undo expired'}` (5000 ms, claims intact); `wish(run, personId, name, now): Run` (`wishedBy` null for the shopper); `fixChip(run, chipId, name?, priceCents?, now): Run` (shopper only, enforced by the server; naming an identifying chip calls `setChipLive`; a price change calls `setChipPrice`); `checkout(run, now, lastCallMs): Run`; `lock(run, now): Run` (only from `lastCall` once `now >= lastCallEndsAt`; identifying chips get `dropped: true`; other live chips → `locked`); `backToCart(run): Run` (from `lastCall` or `locked` → `open`, clears `lastCallEndsAt`, un-locks chips, clears every `putBack`); `putBack(run, chipId): Run` (only when `locked`); `sharesFor(run): Map<personId, number>` (`splitChip` per claimed, non-removed, non-putBack chip, shopper included); `roomsFor(run): Map<personId, number>`; `unclaimed(run): Chip[]` (live chips with no claimers, excluding wishes).

- [ ] **Step 1: Write failing tests** covering: claim then second identical claim leaves `claimers` length 1; claims from `a` and `b` give shares 436/436; `b` leaves → `a` share 872 and `roomsFor` a = 3128; last claimer leaving returns the chip to `open`; the shopper claims the towels with no authorization and no error; claim refused `over cap` (caps 4000, tray already 872 + 2399, candidate 2399); claim of a `wish` chip → `not claimable`; claim after `lock` → `cart closed`; join after lock → `cart closed`; `setAuthorization` to 5000 then the same claim succeeds; `removeChip` then `undoRemove` at +4000 ms restores claims; at +6000 ms → `undo expired`; `addChip` same name within 5000 ms sets `duplicateOf`; `wish('bagels')` by `a` then `addChip('Bagels', 500)` puts `a` in `claimers`; the same with a $50 bagel chip leaves `a` out and in `overCap`; `wish` by the shopper has `wishedBy null`; `setChipPrice` on a `~$?` chip that breaks `a`'s room adds `a` to `overCap`; `fixChip` with a name on an identifying chip makes it `open`; `lock` before `lastCallEndsAt` is a no-op; `lock` marks an `identifying` chip `dropped`; `putBack` only works when locked, `sharesFor` then excludes it, and `backToCart` clears it; `unclaimed` returns the milk.
- [ ] **Step 2: Run** `pnpm -C server test run` → FAIL.
- [ ] **Step 3: Implement** `types.ts` and `run.ts` (immutable updates; return new objects).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): run and chip state machines with claims as sets`.

### Task 4: Payments provider interface and simulator

**Files:**
- Create: `server/src/payments/provider.ts`, `server/src/payments/sim.ts`, `server/test/payments-sim.test.ts`

**Interfaces:**
- Produces: `interface PaymentsProvider { authorize(ref: string, card: TestCard, amountCents: number): Promise<AuthResult>; incremental(ref, authId, deltaCents): Promise<AuthResult>; reverse(ref, authId, amountCents): Promise<{status: 'REVERSED', reversedCents: number}>; capture(ref, authId, amountCents): Promise<{status: 'PENDING', captureId: string}>; payout(ref, recipientPan: string, amountCents): Promise<PayoutRecord> }`; `TestCard = {number: string, expMonth: number, expYear: number}`; `AuthResult = {status: 'AUTHORIZED'|'DECLINED', authId: string, approvalCode: string, authorizedCents: number}`; `PayoutRecord = {simulated: true, businessApplicationId: 'FD', amountCents, recipientPan, requestId}`.
- Produces: `class SimPayments implements PaymentsProvider` with approval code `888888`, 22-digit numeric `authId`, decline when `expYear === 1998` or card `42423482938483873`, `capture` rejects with `Error('capture exceeds authorized')` when amount > remaining authorized, `reverse` rejects when amount > remaining, `incremental` adds to `authorizedCents` only for an id created by `authorize` (pre-authorization), returns `DECLINED` when the new total would exceed 100000, and `authorize` rejects with `Error('simulated outage')` when `card.number === '4000000000000002'` (used to test the failed-settle path by swapping cards in tests).
- Produces: `getPayments(): PaymentsProvider` in `provider.ts` reading `process.env.PAYMENTS` (`sim` default; `cybersource` wired in Task 14).

- [ ] **Step 1: Write failing tests**: authorize 4000 → AUTHORIZED, approvalCode `888888`, authId length 22; authorize with expYear 1998 → DECLINED; incremental +500 → authorizedCents 4500; incremental pushing past 100000 → DECLINED; reverse 3564 then capture 436 → REVERSED 3564 and PENDING; capture 4001 on a 4000 auth → throws; payout 3271 → `{simulated: true, businessApplicationId: 'FD'}`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): payments provider interface with realistic simulator`.

### Task 4B: Standalone Cybersource gate script (prep, no provider dependency)

**Files:**
- Create: `server/scripts/payments-gate.ts`, `.env.example` (`CYBS_MERCHANT_ID`, `CYBS_KEY_ID`, `CYBS_SHARED_SECRET`)
- Modify: `server/package.json` (add `cybersource-rest-client`)

**Interfaces:**
- Produces: a script, independent of the app code, that runs against `apitest.cybersource.com`: authorize with `processingInformation.capture=false`, `processingInformation.authorizationOptions.authIndicator="0"`, `orderInformation.amountDetails {totalAmount: "40.00", currency: "USD"}`, `paymentInformation.card {number: "4111111111111111", expirationMonth: "12", expirationYear: "2031"}`, `orderInformation.billTo {firstName: "Test", lastName: "Dibs", address1: "1 Market St", locality: "San Francisco", administrativeArea: "CA", postalCode: "94105", country: "US", email: "test@example.com"}`, `clientReferenceInformation.code "gate-1"`; then `PATCH` incremental `additionalAmount "5.00"`; then partial reversal `"40.64"`; then capture `"4.36"`. Prints each status and id and the processor name from the response, and ends with the recommended `RAISE_CAP` value.

- [ ] **Step 1: Write** the script (no test; it is itself the test).
- [ ] **Step 2: Run** with sandbox credentials if available now; otherwise at hackathon hour 0. Record the output in `README.md`.
- [ ] **Step 3: Commit** `chore(server): standalone Cybersource sandbox gate script`.

### Task 5: Receipt matching and resumable settle

**Files:**
- Create: `server/src/settle.ts`, `server/test/settle.test.ts`

**Interfaces:**
- Consumes: Task 2, Task 3 (`sharesFor`, `ReceiptState`, `PersonSettle`), Task 4 (`PaymentsProvider`).
- Produces: `parseReceiptLines(raw: {text, cents, quantity}[]): ReceiptLine[]` (marks `isTax` when the text matches `/\btax\b/i`).
- Produces: `matchReceipt(run: Run, lines: ReceiptLine[]): ReceiptState` (normalized token overlap against this run's live chip names, wishes and removed chips excluded, threshold 0.5; a put-back chip that matches a line leaves the line in `unmatchedLines`; tax lines are never matched).
- Produces: `applyReceipt(run, receipt: ReceiptState): Run` (stores `receipt` on the run; allocates any tax line across matched lines with `allocateTax`; receipt price (plus its tax share) replaces each matched chip's price with `priceSource 'receipt'`; matched chips → `matched`, other live chips → `unmatched`, **claims kept**; run → `receipt`).
- Produces: `fixReceiptLine(run, lineIndex, target: {chipId: string} | 'mine'): Run` (reads `run.receipt`; pairing moves the line into `matches` and the chip to `matched`; `'mine'` removes the line from `unmatchedLines` and records it as the shopper's).
- Produces: `settle(run, provider: PaymentsProvider, ref: (personId: string, step: string) => string, persist: (run: Run) => Promise<void>): Promise<Run>`: releases claims on chips still `unmatched`; for each claimer not yet `captured`/`reversed`-terminal: if `share > authorized` → `incremental`, on DECLINED capture `authorized` and set `owed`; else `reverse(authorized - share)` then `capture(share)`; share 0 → `reverse(authorized)` only (terminal); every step result is written to `run.settle[personId]` and `persist`ed before the next call; a thrown provider error sets `step 'failed'` with the message and continues with the next claimer; the shopper is skipped; when every claimer is terminal, `payout` is called for the sum of captures to the shopper's `payoutPan` and the run becomes `settled`, otherwise `partlySettled`; calling `settle` again processes only non-terminal people and never repeats a completed step.

- [ ] **Step 1: Write failing tests** on a run built from `seedRun` plus explicit joins and chips: `matchReceipt` maps `KS EGGS 24CT 8.72` → eggs with confidence ≥ 0.5, `PAPER TOWEL 12PK 23.99` → towels, `2% MILK 4.29` → milk, an extra `BANANAS 1.99` → unmatched; a put-back milk chip leaves the milk line unmatched; `applyReceipt` on a run whose eggs chip was added with sticker 850 sets 872 and `priceSource 'receipt'` and keeps the claims; with lines `EGGS 8.00`, `TOWELS 22.00`, `TAX 2.71` the chips become 872 and 2399; `fixReceiptLine` pairs the bananas line to a chip; `settle` with a recording provider calls, in order, `reverse(3564)`, `capture(436)` for `a`, `reverse(1165)`, `capture(2835)` for `b`, then `payout(3271)`, and the run is `settled`; share-above-auth calls `incremental` first; declined incremental → `owedCents > 0`, capture of the authorized amount, run `partlySettled`; a provider that throws on `b`'s reversal leaves `a` captured, `b` `failed`, run `partlySettled`, and a second `settle` with a working provider makes exactly `reverse(1165)`, `capture(2835)`, `payout(3271)` and no calls for `a`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): receipt matching with tax allocation and resumable settle`.

### Task 6: Detector, vision and price providers (mock), seeded run

**Files:**
- Create: `server/src/vision/provider.ts`, `server/src/vision/stub.ts`, `server/src/vision/detect.ts`, `server/src/vision/detect-diff.ts`, `server/src/price/provider.ts`, `server/src/price/stub.ts`, `server/src/seed.ts`, `server/assets/props/{eggs,towels,milk}.jpg` (placeholders until Task 12), `server/assets/receipt.json`, `server/test/fixtures/frames/` (generated), `server/scripts/make-frames.ts`, `server/test/providers-stub.test.ts`
- Modify: `server/package.json` (add `sharp`)

**Interfaces:**
- Produces: `interface VisionProvider { identify(imageBase64: string, hint?: string, region?: Box): Promise<{name: string, priceCents: number|null, cropBase64: string, confidence: number, barcode: string|null}>; readReceipt(imageBase64: string): Promise<{text: string, cents: number, quantity: number}[]> }`; `getVision()` by `VISION` env.
- Produces (`detect.ts`): `type DetectEvent = {kind: 'newItem', at: number, region: Box, frameBase64: string} | {kind: 'changing'}`; `interface Detector { push(frame: {jpegBase64: string, at: number}): DetectEvent[] }`; `getDetector()` by `DETECTOR` env.
- Produces (`detect-diff.ts`): `class DiffDetector implements Detector { constructor(opts: {settleMs: number /*1000*/, minChangedFraction: number /*0.04*/}) }`: decodes each frame with `sharp` to a 64 px grayscale thumbnail, diffs against the last stable thumbnail, emits `changing` while the changed region keeps moving, and exactly one `newItem` (with the bounding box of the changed pixels scaled to frame pixels) once the change has been still for `settleMs`; the new frame then becomes the stable baseline.
- Produces: `interface PriceProvider { lookup(name: string, store: string): Promise<{cents: number, sourceUrl: string}|null> }`; `getPrice()` by `PRICE` env.
- Produces: `StubVision.identify` returns the prop named in `hint` when given; otherwise compares the crop to the three prop images (`sharp` 32 px thumbnails, mean absolute difference) and returns the closest, defaulting to eggs when the difference is inconclusive; `readReceipt` ignores the image and returns `assets/receipt.json`. `StubPrice` table: eggs 872, towels 2399, milk 429, else null.
- Produces: `seedRun(now): Run` with shopper Jake only (`payoutPan '4111111111111111'`), store `costco`, `taxRate 0`, no chips, no claimers. Claimers A and B join through the API.
- Produces: `make-frames.ts` writes `fixtures/frames/empty.jpg` and `eggs-{moving1,moving2,still}.jpg` by compositing `assets/props/eggs.jpg` (scaled to a quarter of the frame) onto the empty basket image at shifting then fixed positions.

- [ ] **Step 1: Write failing tests**: `StubVision.identify('', 'eggs')` name contains `Eggs`, priceCents 872; `StubVision.identify(cropOfEggsFixture)` name contains `Eggs`; `readReceipt` returns 3 lines summing to 3700; `StubPrice.lookup('mochi','costco')` → null; `seedRun` has 1 person and 0 chips; `DiffDetector` fed `empty` ×6 emits nothing, then `moving1`, `moving2` emit `changing`, then `still` ×3 over 1000 ms emits exactly one `newItem` whose `region` covers the composited eggs; a further `still` emits nothing.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): diff detector, stub vision and price providers, seeded demo run`.

### Task 7A: REST API, run store, and the run WebSocket (no frames yet)

**Files:**
- Create: `server/src/index.ts` (Fastify + `ws`), `server/src/store.ts` (in-memory runs with JSON snapshot to `server/.data/runs.json` on every change; `persist` is what `settle` receives), `server/src/protocol.ts`, `server/test/server.test.ts`
- Modify: `server/package.json` (add `fastify`, `@fastify/static`, `@fastify/cors`, `ws`, `qrcode`)

**Interfaces:**
- Produces REST: `POST /api/runs` → `{runId, shopperId}` (seeded); `POST /api/runs/:id/join {name, card: TestCard, capCents}` → `{personId, auth: AuthResult}` or `409 {error: 'declined'}` (authorize, then `join` + `setAuthorization`); `POST /api/runs/:id/raise {personId, capCents}` → `AuthResult` (refused `403` when `RAISE_CAP=off`; calls `incremental` for the delta, then `setAuthorization`); `POST /api/runs/:id/chips {imageBase64, hint?}` → chip (test hook and mock prop buttons: `addChip` identifying → `identify` → `setChipLive` with the sticker price or null → if null, `price.lookup` asynchronously → `setChipPrice`); `POST /api/runs/:id/chips/text {name, byPersonId}` → `wish`; `POST /api/runs/:id/chips/:chipId/fix {personId, name?, priceCents?}` (shopper only); `POST /api/runs/:id/chips/:chipId/putback {personId}`; `POST /api/runs/:id/checkout {personId}`; `POST /api/runs/:id/back {personId}`; `POST /api/runs/:id/receipt {imageBase64}` → `readReceipt` → `parseReceiptLines` → `matchReceipt` → `applyReceipt`, returns `ReceiptState`; `POST /api/runs/:id/receipt/fix {lineIndex, target: {chipId} | 'mine'}`; `POST /api/runs/:id/confirm {personId}` → the run (`settled` or `partlySettled`; a second call retries); `GET /api/runs/:id/qr` → PNG of the claim URL; `GET /api/runs/:id` → `Run`. Shopper-only routes check `personId === shopperId` and return `403` otherwise.
- Produces WS at `/ws?run=<id>&person=<id>`: client → server `{t:'claim'|'leave'|'remove'|'undoRemove', chipId}`; server → all `{t:'run', run}` on every change, `{t:'error', reason}` to the sender on refusal, `{t:'lastCall', endsAt}`, `{t:'locked'}`. The server schedules `lock` at `lastCallEndsAt` (`LAST_CALL_MS`).
- Serves `web/out` statically at `/` (Task 12 builds it).

- [ ] **Step 1: Write failing tests** with Fastify `inject` and a `ws` client, `LAST_CALL_MS=50`: create run → join A and B (two authorizations) → `chips` with hint `eggs` → claim from A and B over WS → `GET` shows shares 436/436; `raise` for A to 5000 → `authorizedCents 5000` on the person; `raise` with `RAISE_CAP=off` → 403; `fix` by B → 403; after `checkout`, wait 60 ms, a claim → `{t:'error', reason:'cart closed'}`; `putback` on the milk; `receipt` with an empty image returns the seeded lines matched; `confirm` returns a `settled` run with `settle[A].capturedCents 436`, `settle[B].capturedCents 2835`, milk not captured, `payout.simulated === true`; a second `confirm` returns the same run and the simulator's call log has not grown.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** index, store, protocol. **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): REST and WebSocket API for runs`.

### Task 7B: Frame relay, detector orchestration, tap-to-identify

**Files:**
- Create: `server/src/relay.ts`, `server/src/pipeline.ts`, `server/test/relay.test.ts`, `server/test/pipeline.test.ts`
- Modify: `server/src/index.ts`, `server/src/protocol.ts`

**Interfaces:**
- Consumes: Task 6 `Detector`, `VisionProvider`, `PriceProvider`; Task 3 `addChip`, `setChipLive`, `setChipPrice`.
- Produces (`relay.ts`, pure): `shouldSendFrame(bufferedAmount: number, limit = 200_000): boolean`; the relay keeps only the latest frame per run and skips a client whose socket `bufferedAmount` exceeds the limit.
- Produces (`pipeline.ts`): `identifyPipeline(deps, runId, frameBase64, region, retryChipId?: string): Promise<void>`: creates an `identifying` chip with the crop as `photoUrl` (data URL) and the `region`, or reuses `retryChipId`; calls `identify(frame, undefined, region)`; on success `setChipLive(name, stickerPriceOrNull, 'sticker'|'none')`, then if the price is null runs `price.lookup` asynchronously and `setChipPrice(cents, 'web')`; on failure leaves the chip identifying and sends `{t:'error', reason:'identify failed'}` to the shopper.
- Produces WS additions: shopper → server `{t:'frame', jpegBase64, at}` at 2 fps (ignored unless the run is `open` or `lastCall`) and `{t:'identifyAt', x, y}` (a 200 px box around the tap on the latest frame; if the tap lands inside an existing identifying chip's `region`, that chip is retried); server → claimers `{t:'frame', jpegBase64, at}`; server → all `{t:'identifying', region}` while the pipeline runs. One `Detector` per run; `newItem` → `identifyPipeline`; `changing` → nothing. All buffered frames are discarded at lock.

- [ ] **Step 1: Write failing tests**: `relay.test.ts`: `shouldSendFrame(0)` true, `shouldSendFrame(250_000)` false. `pipeline.test.ts` with stub providers: a `newItem` on the eggs fixture produces a live chip named like `Eggs` with price 872 and `priceSource 'sticker'`; with a stub whose sticker read returns null, the chip goes live with `priceCents null` first and gets 872 with `priceSource 'web'` after the lookup resolves; a failing identify leaves the chip `identifying`; `identifyAt` inside that chip's region retries it to `open`. Server test addition: the shopper socket sends the fixture frames (`empty` ×6, `moving1`, `moving2`, `still` ×3 at 500 ms spacing with injected timestamps) → a chip goes live and claimer A received at least one `{t:'frame'}`; frames after lock are ignored.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(server): frame relay, detector orchestration, tap-to-identify`.

### Task 8: Web scaffold, shared types, socket client, Join screen

**Files:**
- Create: `web/` (Next.js 15, app router, TypeScript, Tailwind, `output: 'export'`), `web/lib/api.ts`, `web/lib/socket.ts`, `web/lib/types.ts` (generated copy of `server/src/types.ts`), `web/scripts/sync-types.ts`, `web/test/types-sync.test.ts`, `web/app/globals.css` (tokens from Task 0), `web/app/page.tsx` (Start a run → shopper), `web/app/join/page.tsx` (`?run=&name=&cap=`), `web/components/HeldBadge.tsx`, `web/test/join.test.tsx` (vitest + testing-library)

**Interfaces:**
- Produces: `pnpm -C web sync-types` copies `server/src/types.ts` to `web/lib/types.ts`; `types-sync.test.ts` fails if the two files differ.
- Produces: `useRun(runId, personId): {run, send(msg), lastFrame, error}` in `socket.ts` (reconnects, re-syncs via `GET /api/runs/:id`, keeps only the latest frame).
- Produces: `api.join(runId, name, capCents)` using the fixed sandbox test card `{number: '4111111111111111', expMonth: 12, expYear: 2031}`; a hidden query `?decline=1` uses `expYear 1998`. Join page reads `?run=`, `?name=` (default "A"), `?cap=` (default 4000).

- [ ] **Step 1: Write failing tests**: rendering Join with a mocked `api.join` resolving `authorizedCents 4000, approvalCode '888888'` shows `$40.00 held · approval 888888`; `types-sync` test passes only when the files match.
- [ ] **Step 2: Run** `pnpm -C web test` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Verify in the browser pane**: `pnpm -C web dev`, open `/join?run=<seed>`, tap Join, see the held badge.
- [ ] **Step 6: Commit** `feat(web): Next.js scaffold, shared types, run socket, Join screen`.

### Task 9: Grid, Chip, Ring, Tray with lift-and-drop

**Files:**
- Create: `web/components/Chip.tsx`, `web/components/Ring.tsx`, `web/components/Grid.tsx`, `web/components/Tray.tsx`, `web/components/UndoToast.tsx`, `web/lib/share.ts` (client preview of `splitChip` and `roomFor`, same algorithms, display only), `web/test/ring.test.tsx`, `web/test/tray.test.tsx`, `web/test/chip.test.tsx`

**Interfaces:**
- Produces: `<Ring claimers={Person[]} me={personId} />`: n=0 none; n=1 full ring with an open notch (`data-notch`); n≤3 equal segments with initials, own segment thicker; n≥4 count in center.
- Produces: `<Chip chip me />`: photo, name, full price small; `×n` badge when `quantity > 1`; `~$?` badge when `priceCents` is null; an over-cap badge when `me` is in `chip.overCap`; grey with the wisher's initial when `state === 'wish'`; dimmed when `identifying`; "you're in" fill when `me` is a claimer; wish and identifying chips are not liftable.
- Produces: `<Grid chips me onLift />` two-row grid, newest at the leading edge with a 600 ms pulse; press-and-hold 200 ms (dnd-kit `PointerSensor` with `activationConstraint: {delay: 200, tolerance: 5}`) starts a drag; plain swipe scrolls.
- Produces: `<Tray chips me authorizedCents taxRate expanded onClaim onLeave />`: resting drawer "N items · $X.XX"; header "$40.00 held · $4.36 your share · $31.28 room" (shopper: "N items · $X.XX" only); expands to 40% height while a chip is lifted; shows the resulting share and room live; drop outside → spring back; drop inside → `onClaim` and a 3-second `UndoToast` whose action calls `onLeave`; lifting a tray chip and releasing outside → `onLeave` and an `UndoToast` whose action calls `onClaim`. Tray chips show share large with a `÷n` badge; `~$?` chips count $0.
- Produces: `<UndoToast label onUndo ms={3000} />`.

- [ ] **Step 1: Write failing tests**: Ring renders a notch at n=1, two segments with initials `A`,`B` at n=2, a center count `5` at n=5; Chip shows `×2` for quantity 2, `~$?` for null price, a grey initial for a wish, and the over-cap badge when `me` is in `overCap`; Tray header reads `$40.00 held · $4.36 your share · $31.28 room` for eggs shared by two with a 4000 authorization and excludes a `~$?` chip from the total; a claim drop renders an Undo toast.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Verify in the browser pane** at mobile viewport: lift works only after the hold; a swipe scrolls; a wish chip does not lift.
- [ ] **Step 6: Commit** `feat(web): grid, chip ring, tray with lift-and-drop`.

### Task 10: Shopper screen

**Files:**
- Create: `web/app/shopper/page.tsx` (`?run=&person=&mock=`), `web/components/Camera.tsx`, `web/components/LiveView.tsx`, `web/components/RemoveZone.tsx`, `web/components/UnclaimedList.tsx`, `web/components/FixChipSheet.tsx`, `web/test/shopper.test.tsx`

**Interfaces:**
- Consumes: Task 7A/7B API, Task 9 components.
- Produces: `Camera` uses `getUserMedia({video: {facingMode: 'environment'}})`, draws to an offscreen canvas at 640 px wide every 500 ms, and sends `{t:'frame', jpegBase64, at}` over the run socket while the run is `open` or `lastCall`; the preview shows the local video with the `identifying` region outlined and a "watching" pulse; tapping the preview sends `{t:'identifyAt', x, y}` in frame pixels. In `?mock=1` mode, three prop buttons `Eggs`, `Towels`, `Milk` post the prop image with `hint` for demos without a basket. No shutter and no dwell ring.
- Produces: `LiveView` renders `lastFrame` from `useRun` (`<img>` swapped per frame) with a "live" dot and the shopper's name; used small on the claimer screen (Task 11).
- Produces: lifting any chip reveals `RemoveZone` over the live view; drop → `remove` with `UndoToast` 5000 ms → `undoRemove`. Tap a chip → `FixChipSheet` (name, price) → `chips/:id/fix`; a `duplicateOf` chip shows "Added twice? Keep both / Remove one"; an identifying chip shows "Couldn't identify. Tap it again or name it" after a pipeline error.
- Produces: Checkout → `POST /checkout`, shows the last-call banner with countdown; at `locked`, `UnclaimedList` with `Mine` (default) and `Put back` (→ `putback`) per item, and `Back to cart` → `POST /back`.

- [ ] **Step 1: Write failing tests**: with a mocked socket, `Camera` sends a `frame` message within 600 ms of mounting (fake timers, canvas mocked); in `?mock=1`, pressing `Eggs` calls `api.addChip(runId, {hint: 'eggs'})` and the chip appears in the grid when the mocked socket emits the run; `UnclaimedList` renders `Mine` and `Put back` for the milk when the run is locked.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Verify on a phone over HTTPS** (Task 12 URL or local cert): clip the phone over a basket, drop in a prop, the chip appears on a second device within 2 s without touching the phone; tapping the view on a missed item creates a chip.
- [ ] **Step 6: Commit** `feat(web): shopper screen with continuous cart stream, remove zone, checkout`.

### Task 11: Claimer and Settle screens

**Files:**
- Create: `web/app/claim/page.tsx` (`?run=&person=`), `web/app/settle/page.tsx` (`?run=&person=`), `web/components/ReceiptMatch.tsx`, `web/components/SettleLines.tsx`, `web/components/WishSheet.tsx`, `web/test/claim.test.tsx`, `web/test/settle.test.tsx`

**Interfaces:**
- Produces: Claim page with `LiveView` small at the top (tap toggles large/small, nothing else), then the grid and tray; over-cap drop springs back with toast `Over your cap. Raise it?` → `POST /raise` with cap + $20 (hidden when `RAISE_CAP=off`); an over-cap badge on a tray chip shows "Raise your cap or leave"; `WishSheet` posts `chips/text` (last in the task); an in-app banner at `locked`: "Your tray is $X.XX across N items".
- Produces: Settle page: the shopper photographs the receipt (`Camera` reuse, single frame) or in `?mock=1` taps `Use printed receipt`, which calls the same `POST /receipt` with an empty image (the stub reader returns the seeded lines); `ReceiptMatch` lists lines with chip thumbnails and confidence, unmatched lines offer `Pair…` / `Mine` (→ `receipt/fix`); `Confirm & charge` (shopper only) → `POST /confirm`; `SettleLines` renders per person `Captured $4.36 (settles tonight) · $35.64 released · approval 888888`, `Captured $40.00 · $1.12 owed` for the owed case, and `Retry` for `failed` (→ `POST /confirm` again); the shopper line `Reimbursed $32.71 (simulated Visa Direct)`; a `partlySettled` run shows "Partly settled".

- [ ] **Step 1: Write failing tests**: Claim page shows the over-cap badge text for a chip whose `overCap` includes `me`; Settle renders the three lines from a mocked `settled` run with the exact copy above, and `Retry` plus "Partly settled" for a mocked `partlySettled` run.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Verify the full loop on three browser tabs** (shopper `?mock=1`, A, B): add eggs, A and B claim, B claims towels, A leaves and re-claims eggs, milk unclaimed, checkout, last call, lock, printed receipt, confirm, lines show 4.36 / 28.35 / 32.71.
- [ ] **Step 6: Commit** `feat(web): claimer and settle screens`.

### Task 12: Build, serve, deploy to Railway, install on phones

**Files:**
- Create: `Dockerfile` (multi-stage: build `web` static export, build `server`, run `node server/dist/index.js` serving `web/out`), `railway.json`, `README.md` (run locally, deploy, add to home screen, demo script, env flags), `scripts/dev.sh` (runs server with `tsx watch` and `next dev` together), `server/assets/props/*.jpg` (real photos of the three props)

- [ ] **Step 1: Local full build**: `pnpm -C web build && pnpm -C server build && node server/dist/index.js` → `http://localhost:3000/` serves the landing page; `curl localhost:3000/api/runs -X POST` returns a run.
- [ ] **Step 2: Deploy**: `railway init`, `railway up`; set `DETECTOR=diff VISION=stub PRICE=stub PAYMENTS=sim LAST_CALL_MS=5000`; confirm the HTTPS URL loads.
- [ ] **Step 3: Phones**: open `<url>/shopper?run=…` on the shopper phone, Add to Home Screen; pre-join B; scan `GET /api/runs/:id/qr` from the A phone; run the Task 11 loop on real devices with the camera over a real basket.
- [ ] **Step 4: Commit** `chore: Dockerfile, Railway config, README with demo script`.

### Task 13: Real detection and identification (flagged, post-demo)

**Files:**
- Create: `server/src/vision/perceptron.ts`, `server/src/vision/gemini.ts`, `server/src/vision/detect-yolo.ts`, `server/src/vision/detect-perceptron.ts`, `server/scripts/vision-gate.ts`, `server/assets/clips/fifteen-drops/*.jpg` (recorded frame sequence), `server/test/vision-real.test.ts` (skipped unless `PERCEPTRON_API_KEY` set)

**Interfaces:**
- Produces: `PerceptronVision implements VisionProvider` using the hosted API with a JSON-schema response `{name, price, confidence, barcode}` and a box for the crop; `GeminiVision` with the same prompt via `gemini-2.5-flash` (or newer) vision; `getVision()` selects by `VISION`.
- Produces: `YoloWorldDetector implements Detector` (`detect-yolo.ts`): runs a YOLO-World ONNX model with `onnxruntime-node` on each frame with the prompts `grocery item, package, carton, bag, bottle, hand`; a box of a non-hand class that overlaps no tracked box by more than 0.5 IoU and stays within 10 px for 1000 ms emits `newItem`; a `hand` box emits `changing`. `PerceptronDetector implements Detector` (`detect-perceptron.ts`): buffers frames into 3-second windows, sends each to Perceptron's video endpoint asking for tracked objects that entered the cart region and whether a hand is present, and emits the same events. `getDetector()` selects by `DETECTOR`.
- Produces: `vision-gate.ts` runs both gates from the spec: identification on the three prop photos 5 times each (p95 < 1500 ms, 3/3 names) and detection on the recorded 15-drop frame sequence for each detector (13/15 fire within 2 s). Prints the results and the recommended `VISION` and `DETECTOR` values.

- [ ] **Step 1: Write the gated tests** asserting name and latency on `assets/props/eggs.jpg`, and each real detector emitting one `newItem` for the first drop of the recorded sequence.
- [ ] **Step 2: Implement** the providers and detectors. **Step 3: Run the gate script**; record the result and the chosen env values in `README.md`.
- [ ] **Step 4: Commit** `feat(server): Perceptron identification, YOLO-World and Perceptron detectors, Gemini fallback, gates`.

### Task 14: Real payments provider: Cybersource sandbox (flagged, post-demo)

**Files:**
- Create: `server/src/payments/cybersource.ts`, `server/test/payments-real.test.ts` (skipped unless `CYBS_MERCHANT_ID` set)

**Interfaces:**
- Produces: `CybersourcePayments implements PaymentsProvider` via `cybersource-rest-client`, using exactly the payloads from Task 4B: `authorize` → `POST /pts/v2/payments` (capture=false, authIndicator "0", amount, USD, card with month and year, fixed billTo, `clientReferenceInformation.code=ref`); `incremental` → `PATCH /pts/v2/payments/{id}` with `orderInformation.amountDetails.additionalAmount`; `reverse` → `POST /pts/v2/payments/{id}/reversals`; `capture` → `POST /pts/v2/payments/{id}/captures`; `approvalCode` from `processorInformation.approvalCode` else the transaction `id`; `payout` stays simulated. `RAISE_CAP` is set from the Task 4B result.

- [ ] **Step 1: Write the gated test** mirroring the Task 4 sequence against the sandbox.
- [ ] **Step 2: Implement.** **Step 3: Run** with credentials; record the processor simulator name and the `RAISE_CAP` decision in `README.md`.
- [ ] **Step 4: Commit** `feat(server): Cybersource sandbox payments provider`.

### Task 15: Price worker (the existing SwiftUI Gemini browser agent) and fallback (post-demo)

**Files:**
- Create: `server/src/price/native.ts`, `server/src/price/agent.ts`, `server/test/price-native.test.ts`, `server/test/price-agent.test.ts` (skipped unless `GEMINI_API_KEY` set)
- Modify: `Agora/Agent/AgentCoordinator.swift` (worker mode: poll, run, parse, post; auto-approve `browser_act` on the store's domain), `Agora/App/SettingsView.swift` (server URL, store domain, "Price worker" toggle), `Agora/Storage/SettingsStore.swift` (persist them), `AgoraTests/BrowserTests.swift` (worker parsing test)

**Interfaces:**
- Produces REST: `GET /api/price-requests?open=1` → `[{id, runId, chipId, name, store}]`; `POST /api/price-requests/:id {cents, sourceUrl}` → `setChipPrice(cents, 'web')`, broadcasts the run.
- Produces: `NativePrice implements PriceProvider`: `lookup` creates a request and resolves when a worker posts a result, or returns null after 45 s; `AgentPrice implements PriceProvider`: one Gemini call with Google Search grounding returning `{cents, sourceUrl}` or null within 20 s. `getPrice()` selects by `PRICE`; `native` falls back to `agent` on timeout when a key is present.
- Produces (Swift): worker mode polls every 3 s; for each request it runs the existing agent loop with the task "Find the current listed price of `<name>` on `<store>` and reply with only JSON {\"cents\": number, \"url\": string}", auto-approves `browser_act` while the page host ends with the configured store domain, parses the final assistant message as JSON, and posts it; the live preview stays visible.

- [ ] **Step 1: Write failing tests**: `NativePrice.lookup` resolves with 872 after a simulated `POST /api/price-requests/:id {cents: 872}`; times out to null at 45 s with fake timers; Swift: parsing `{"cents": 872, "url": "https://www.costco.com/x"}` from a message with surrounding text; gated `AgentPrice` test returns 500–2000 cents and a `costco.com` URL.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** the server side, then the Swift worker mode. **Step 4: Run** → PASS, including `xcodebuild test` for `AgoraTests`.
- [ ] **Step 5: Verify**: Simulator app in worker mode fills a `~$?` chip on a phone within 45 s.
- [ ] **Step 6: Commit** `feat: native Gemini browser agent as price worker, grounded fallback`.

---

## Self-review notes (revision 3, after the outside review)

- Accepted and fixed: shopper cap exemption (Task 3); Claimed → Open on last leave (Task 3); over-cap after late pricing via `overCap` (Tasks 3, 9, 11); wish conversion runs the cap check (Task 3); `backToCart` clears put-backs (Task 3); identifying → open through `fixChip` and retry (Tasks 3, 7B); claims kept until confirm (Task 5); resumable settle with per-person stored steps and `partlySettled` (Tasks 3, 5, 7A, 11); `$0` share terminal at Reversed (Task 5); "room" replaces the ambiguous "left" (Tasks 2, 9); `TestCard` has a month and the full sandbox payload is specified (Tasks 4, 4B, 8, 14); raise-cap in real mode gated by `RAISE_CAP` instead of a second authorization (Global, 7A, 14); "released" and sandbox-funds wording (spec); approval code 888888 labeled simulator-only (spec); `seedRun` seeds the shopper only and A and B join through the API (Tasks 6, 7A, 12); `setAuthorization` after join and raise (Tasks 3, 7A); `ReceiptState` stored on the run and `fixReceiptLine` reads it (Tasks 3, 5, 7A); `payoutPan` on the shopper (Tasks 3, 6); chip goes live before the price lookup (Tasks 3, 7A, 7B); `identifyAt` wired to the pipeline with retry (Task 7B); mock receipt button uses the documented endpoint (Task 11); fixtures composite the real prop image (Task 6); settle errors surface as `failed` steps with Retry (Tasks 5, 11); the gate script is a standalone prep task (4B); claim and leave drops have Undo toasts (Task 9); tax-line allocation is specified and tested (Tasks 2, 5); Task 7 split into 7A and 7B; a demo-critical path is stated at the top.
- Already covered before the review: incremental support is gated at hour 0 (spec); real detectors are post-demo and flagged (Task 13); Task 14 depends on the gate (4B).
- Deliberately not changed: the pitch still says every item shows up as a chip and that nobody chases anybody; the manual tap and the rare owed remainder are honest footnotes under the pitch, not pitch sentences, because a 20-second pitch cannot carry its own exceptions.
- Type consistency: `Run`, `Chip`, `Person`, `Box`, `ReceiptLine`, `ReceiptState`, `PersonSettle` defined once in Task 3 and synced to the web in Task 8; `AuthResult`, `PayoutRecord`, `TestCard` in Task 4; `DetectEvent` in Task 6; consumed by Tasks 5, 7A, 7B, 9, 10, 11, 13, 14, 15 under the same names.
