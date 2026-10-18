# SDD ledger — plan: docs/superpowers/plans/2026-10-17-dibs-mock-demo.md

Spec: docs/superpowers/specs/2026-10-17-dibs-design.md (rev 5). Branch: dibs-mock-demo, started at 369c2f4 (merge-base with main a5465c2).
Scope this run: demo-critical path Tasks 1, 2, 3, 4, 5, 6, 7A, 7B, 8, 9, 10, 11, 12 (+4B script). Task 0 (Claude Design artifact) and post-demo Tasks 13, 14, 15 deferred.

## Preflight scan

| Pair / task | Produces → consumes | Finding |
|---|---|---|
| 2 → 3 | splitChip, capAllows, roomFor → run.ts | consistent names/signatures |
| 3 → 5 | Run, ReceiptState, PersonSettle, sharesFor → settle.ts | consistent; Run.payout typed PayoutRecord from Task 4, which comes after 3 |
| 4 → 3 | PayoutRecord → types.ts | ordering: Task 3 references a Task 4 type |
| 4 → 5, 7A | PaymentsProvider, TestCard, AuthResult | consistent |
| 6 → 7A/7B | VisionProvider, Detector, PriceProvider, seedRun | consistent; readReceipt returns raw lines, 5 parses them |
| 5 ↔ 6 | ReceiptLine (isTax) vs readReceipt raw lines | consistent via parseReceiptLines |
| 7A → 7B | index.ts, protocol.ts modified by both | sequential, fine |
| 3 → 8 | types.ts synced to web/lib/types.ts | types.ts imports PayoutRecord from payments; sync copy would break |
| 7A/7B → 9,10,11 | REST + WS protocol | consistent |
| 1 | .gitignore additions | repo .gitignore already has backend entries; append, don't replace |
| 6 | fixtures composite assets/props/eggs.jpg | placeholder props needed before real photos (Task 12) |
| 12 | Dockerfile | repo already has backend/Dockerfile; ours goes at repo root, separate |
| 0 | Claude Design artifact before Task 8 | needs user approval to publish; deferred |
| Each task self-consistency | tests vs code vs files | checked 1–12: no internal contradiction found |

## Preflight rulings

- Ruling: Dibs server lives in a new Node `server/` and `web/`, separate from the teammates' Python FastAPI `backend/` that landed on main — the approved spec and plan chose Node; `backend/` is the original inventory product — if wrong, two backends coexist and Dibs routes would later be ported to FastAPI.
- Ruling: `PayoutRecord` is declared in `server/src/types.ts` (Task 3) and re-exported by `payments/provider.ts` (Task 4), so types.ts has no imports and the web sync copy stays self-contained — fixes the 3→4 ordering and 3→8 sync conflicts — if wrong, a type moves files.
- Ruling: Task 0 (publishing a Claude Design artifact) is deferred; Task 8–11 implementers build a clean design-token CSS themselves from the spec's screen descriptions — publishing an artifact is outward-facing and the user hasn't seen it — cost if wrong: a visual re-skin pass later.
- Ruling: Task 4B (Cybersource gate script) is written now but not run; no sandbox credentials exist in the repo — cost if wrong: none, it runs at hackathon hour 0.
- Ruling: Placeholder prop images in Task 6 are generated programmatically (distinct colored/textured images per prop) until real photos replace them in Task 12 — keeps fixtures deterministic — cost if wrong: re-generate fixtures from real photos.
- Ruling: `.superpowers/` is already git-ignored by its own .gitignore; no change needed.

## Progress
Task 1+2: review — spec ✅, approved; 1 Important (plan-mandated): float Math.ceil(sum*(1+taxRate)) off by a cent at boundaries.
Ruling: fix roomFor with integer basis points — Math.ceil(sum * (10000 + Math.round(taxRate*10000)) / 10000) — global constraint "no floats touch money" outranks the plan's formula — cost if wrong: none, identical at taxRate 0.
Task 1+2: minor (deferred): allocateTax returns zeros when lines sum to 0 but tax > 0; splitChip with duplicate claimer ids; no packageManager pin; esbuild ignored-builds warning (to be resolved in Task 6 with pnpm.onlyBuiltDependencies for esbuild and sharp).
Task 1+2: fix round 1/5 (1 addressed, 0 open; commits eedefdc..905b9a7)
Task 1+2: minor (deferred): regression test doesn't fail on old formula; add roomFor([100],1000,0.1)===890 (carried into Task 3 dispatch); basis points quantize rates beyond 4 decimals.
Task 1: complete (commits 369c2f4..e98c681, review clean)
Task 2: complete (commits e98c681..905b9a7, review clean after 1 fix round)
Ruling: Task 3 over-cap test raises cap to 6000, not 5000 — the plan's arithmetic was wrong (872+2399+2399=5670 > 5000) — cost if wrong: none.
Ruling: Chip gains `addedAt: number` (needed for the 5000 ms duplicate window) — later tasks building Chips must set it — cost if wrong: one field.
Ruling: "Mine" at Locked needs no claim; unclaimed items simply stay with the shopper (payout = sum of claimer captures) — matches spec Roles — cost if wrong: none for settle math.
Task 3: review — needs fixes; 1 Important (leave resurrects removed chip). Minor setChipLive-after-lock guard folded into round 1.
Task 3: minor (deferred): dead branch in resolveWish slot logic; overCap goes stale when a flagged person frees room by leaving another chip, and refreshOverCap evaluates removed/putBack chips; fixChip rename doesn't re-run wish/duplicate checks; only first matching wish resolves; punctuation-only names normalize to empty; tests lack taxRate>0, immutability assertion, setAuthorization overCap re-eval, unclaimed for dropped chips.
Ruling: identification uses Gemini Flash as the primary real provider (VISION=gemini); Perceptron is optional — user instruction 2026-10-17 "we don't super need perceptron, whatever model works best" — cost if wrong: a provider swap behind the same interface.
Task 3: fix round 1/5 (2 addressed, 0 open; commits 17b7b5c..ad4a011)
Task 3: minor (deferred): fixChip name branch and setChipPrice have no accepting guard after lock (receipt overrides prices at settle, so low impact); renaming a wish doesn't re-run resolveWish.
Task 3: complete (commits 905b9a7..ad4a011, review clean after 1 fix round)
Task 4+4B: review — spec ✅, approved; 2 Important in gate script (amounts assume incremental succeeded; RAISE_CAP ignores reversal/capture). Sent as fix round 1 with 2 cheap minors.
Task 4+4B: minor (deferred): exit code 1 on missing creds; incrementAuth method name unverified until sandbox run; redundant onlyBuiltDependencies + allowBuilds; no tests at exactly 100000, authorize >100000, unknown-id capture/reverse; authorize declines >100000 (unrequested, harmless).
Task 4+4B: fix round 1/5 (3 addressed, 0 open; commits 4058b90..afab893)
Task 4+4B: minor (deferred): gate WARNING text overclaims ("not supported by this account") when request shapes are unverified; auth-failure exit path doesn't print SETTLE_FLOW; `ok` is transport-level only, body status unchecked; authorized total inferred rather than read from the response.
Task 4: complete (commits ad4a011..8ddd083, review clean)
Task 4B: complete (commits 8ddd083..afab893, review clean after 1 fix round)
Ruling: ReceiptState gains optional `mine?: number[]` for shopper-owned lines; a declined-incremental capture is terminal (captured, owedCents>0) and the run is partlySettled — matches spec Money row — cost if wrong: one field.
Task 5: review — spec ✅, approved, no Critical/Important.
Task 5: minor (deferred): payout error swallowed without a recorded reason; fixReceiptLine can pair non-live chips; a chip that loses its line keeps priceSource 'receipt'; dead code in a settle test and a weak persist-ordering assertion; no plural handling in matcher.
Task 5: complete (commits afab893..aab7a7a, review clean)
Ruling: Detector.push is async (Promise<DetectEvent[]>), serialized internally — sharp decoding is async — later tasks await it — cost if wrong: none.
Task 6: review — spec ✅, approved, no Critical/Important.
Task 6: minor (deferred): detector baseline is the first frame forever (no lighting adaptation; pre-existing items never reported); slow drift counts as still; non-integer scale can overshoot frame edge by 1 px; unknown hint silently returns eggs; env mutation in tests without finally; generator scripts have no package.json entry and an undocumented order (props before frames).
Task 6: complete (commits aab7a7a..d31da24, review clean)
Ruling: shopper-only routes are fix, putback, checkout, back, confirm, and WS remove/undoRemove; receipt and receipt/fix are ungated because the brief gives them no personId — Settle screen is shopper-driven in the UI — cost if wrong: add personId to two routes.
Task 7A: review — needs fixes; 4 Important (late price overwrites receipt price; snapshot failure crash; settle overwrite races + ungated raise; identify throw strands chip) + spec gap (436/436 assertion). Sent as fix round 1.
Task 7A: minor (deferred): in-memory raiseCounter repeats refs after restart; concurrent raises over-authorize; join strands a hold if lock lands mid-authorize; lock timers not rescheduled after restart; dropped-during-identify returns 200; no-op updates still snapshot/broadcast; no body validation (500 instead of 400); empty socket sets leak; WS remove/undoRemove shopper-only untested.
Task 7A: fix round 1/5 (5 addressed, 0 open; commits 747053f..9936f0d)
Task 7A: minor (deferred): raise gates state only at entry (a lock during the incremental await isn't re-checked); lock-timer try/catch untested.
Task 7A: complete (commits 657858a..9936f0d, review clean after 1 fix round)
Task 7B: review — spec ✅ approved; 2 Important (tap retries an in-flight identify; retry hit-test untested). Sent as fix round 1 with queue-bound minor.
Task 7B: minor (deferred): dropFrames only on the lock-timer path, conns/live/relay not cleared on run end; invalid JPEG logs every frame; identifyChip collapses specific errors into 'cart closed'; "live first" intermediate null price not asserted.
Task 7B: fix round 1/5 (3 addressed, 0 open; commits a39a057..898eee0)
Ruling: detector frame coalescing is safe — DiffDetector settles on frame `at` timestamps and compares to the previous frame, so skipped intermediate frames delay but cannot prevent a settle; coalescing only kicks in when a push takes > 500 ms — cost if wrong: a missed chip, recoverable by tap-to-identify.
Task 7B: minor (deferred): early return in onFrame loop skips `running=false` (harmless after dropFrames); stacked JSDoc on PipelineDeps; server frame tests depend on 80 ms pacing; tap on in-flight chip gives no feedback.
Task 7B: complete (commits 9936f0d..898eee0, review clean after 1 fix round)
Ruling: web styling uses CSS variables only, no Tailwind — fewer moving parts, tokens already defined — cost if wrong: add Tailwind later; web pins TypeScript ^5.9 (TS 7 breaks Next path resolution) while server stays on 7.
Task 8: review — needs fixes; 4 Important (no useRun test; dev WS URL unset; stale GET re-sync can clobber pushed run; send drops silently). Sent as fix round 1.
Task 8: minor (deferred): error message never cleared; lastCallEndsAt doesn't sync from run; raw "Failed to fetch"; no request timeout; contrast below AA for accent text; token gaps for chips/sheets; join test lacks decline/missing-run; parseInt accepts "40abc".
Task 8: fix round 1/5 (4 addressed, 0 open; commits ce2d9b5..a7b4fae)
Task 8: minor (deferred): `connected` not reset on id change; "Reconnecting…" shows during the first connect.
Task 8: complete (commits 898eee0..a7b4fae, review clean after 1 fix round)
Ruling: a `Board` component wraps Grid and Tray in one dnd-kit context (dragging between them needs a shared context); Chip/Ring take a `people` prop; dev preview page kept until Task 12 then deleted — cost if wrong: none.
Task 9: review — needs fixes; 4 Important (Enter bypasses cap/undo; Pointer+Touch sensor overlap; tray-origin overlay squashed + duplicate lifted source; dev route in prod). Sent as fix round 1.
Ruling: dnd-kit uses MouseSensor + TouchSensor (delay 200, tolerance 5) instead of PointerSensor + TouchSensor; touch-action pan on grid chips, none while dragging — dnd-kit's recommended combination, keeps swipe-to-scroll — cost if wrong: retune on device in Task 12.
Task 9: minor (deferred): drop of an already-held chip is a silent no-op instead of a pulse; no vibrate on tray-chip lift; GridChip not memoized; 9 px ring initials low contrast; aria-label omits over-cap; tests mock useDndMonitor so Board/DragOverlay unexercised; Board trayChips/_t escape hatch.
Task 9: fix round 1/5 (4 addressed, 0 open; commits c39027d..8edd6bb)
Task 9: minor (deferred): undo-of-leave re-claims without a client room check (server refuses over cap anyway); touch-action on overlay doesn't affect an in-progress gesture (TouchSensor handles it).
Task 9: complete (commits a7b4fae..8edd6bb, review clean after 1 fix round)
Task 10: review — needs fixes; 3 Important (identify-failed hint doesn't re-fire on repeats; sticky "Reconnecting…"; untested remove/undo, fixChip save, no-frames-when-disabled). Sent as fix round 1.
Ruling: useRun gains `errorEvent: {reason, seq}` (seq increments per server error) so repeated identical errors re-trigger UI; `error` kept for compatibility — cost if wrong: one extra field.
Task 10: minor (deferred): live-view div has role=button without keyboard handler; keyboard users can't reach FixChipSheet (Enter claims); FixChipSheet not truly modal; Camera send prop loosely typed.
Task 10: fix round 1/5 (3 addressed, 0 open; commits f55bc6d..900400a)
Task 10: minor (deferred): useRun's sticky `error` field still set by send() (Task 11 must use errorEvent + connected instead); flow tests stub Board so drop geometry is browser-verified only; FixChipSheet listener re-registers on inline onClose; stale concern text in report; check test hooks restore fake timers and prototype stubs.
Task 10: complete (commits 8edd6bb..900400a, review clean after 1 fix round)
Task 11: review — needs fixes; 3 Important (missing person doesn't redirect; claimer "Retry" reads as dead button; Pair/Mine not disabled in flight) + known approvalCode gap. Sent as fix round 1.
Ruling: Person gains `approvalCode` set by setAuthorization (join and raise), copied into the settle record — the demo line "approval 888888" needs it — cost if wrong: one field across server and web types.
Task 11: minor (deferred): Wish and Raise share one busy flag; notOnReceipt alias redundant; receipt 409/502 shown as raw server text; dead partlySettled branch in canConfirm; full loop hand-tested with keyboard Enter, not touch drag.
Task 11: fix round 1/5 (5 addressed, 0 open; commits 923bf89..0e9a3a9). Controller verified over HTTP: join → claim → checkout → receipt → confirm gives settle approvalCode 888888, capture 872, release 3128, payout 872 simulated.
Task 11: minor (deferred): setAuthorization storage has no direct unit test (covered by HTTP check); no-op raise returns approvalCode ''.
Task 11: complete (commits 900400a..0e9a3a9, review clean after 1 fix round)
Ruling: Task 12 builds and verifies locally (Dockerfile, railway.json, README, dev script, production build served by the server); the actual `railway up` and phone install are left to the user — publishing to an external service needs their account — cost if wrong: the user runs two commands.
Task 12: review — spec ✅ approved; 1 Important (smoke.sh pipefail + grep -q SIGPIPE flake). Sent as fix round 1 with dev.sh cleanup minor.
Task 12: minor (deferred): Docker image never built (no Docker locally) — Dockerfile read-verified only; demo env duplicated in Dockerfile and README; railway.json repeats CMD.
Task 12: fix round 1/5 (2 addressed, 0 open; commits fddb672..aff43b4)
Task 12: minor (deferred): dev.sh job control could SIGTTIN a dev server that reads the TTY (manual check); crash after health shows "(request)" not "server exited".
Task 12: complete (commits 0e9a3a9..aff43b4, review clean after 1 fix round)
Final review: with fixes — C1 camera path misnames props with placeholder stub; I1 approval code flashes on Join; I2 $0 share shows Settling forever; I3 no wake lock / camera re-acquire; I4 restart breaks sim settle + lock timers; I5 fixChip unguarded post-lock (upgrades a Task 3 deferred minor); I6 duplicate detection dead in real paths. Plus minors M1–M10 and pre-demo triage.
Ruling: C1 — keep the camera path, make the stub deterministic for the scripted demo (an inconclusive identify returns the next prop in drop order eggs → towels → milk, per run), re-baseline the detector instead of emitting when the change covers >60% of the frame, and document ?mock=1 as the fallback — cost if wrong: real photos still needed for a fully honest camera demo.
Ruling: I4 — SimPayments persists its auth map in the data dir and seeds ids with a time-based prefix; lock timers rescheduled on boot — cost if wrong: none for the mock demo.
Final fix wave: commits aff43b4..a13d371; re-review: all findings addressed, no new Critical/Important.
Final: parked — detector 60% re-baseline uses changed-pixel bbox, so a stray edge pixel or a big item near the lens can swallow a real drop — Ruling: real but non-load-bearing for the mock demo (tap-to-identify and ?mock=1 recover); fix by gating on changed-pixel fraction — cost if wrong: a missed chip mid-demo.
Final: parked — AbortSignal.timeout missing on iOS Safari < 16 makes every request fail — Ruling: team phones are current; 3-line AbortController fallback later — cost if wrong: an old phone can't join.
Final: parked — hinted (mock) identifies also move the stub's drop-order cursor — Ruling: pure mock runs never consult it; cursor follows props actually placed — cost if wrong: none in practice.
