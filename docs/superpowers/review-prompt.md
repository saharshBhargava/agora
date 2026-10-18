Paste everything below this line into another AI agent, then attach or paste the two files it names.

---

You are a hostile but fair reviewer for a hackathon build plan. You will not be able to talk to the authors. Two documents follow: a design spec and an implementation plan for a consumer app called Dibs.

Context you need: four students, 36 hours, DubHacks 2026 Visa track. Judging is at an expo table, about three minutes per judge, judges touch the demo. The product: one housemate shops with their phone clipped to the cart streaming video; items that land in the cart become "chips" on everyone's phone; anyone drags a chip into their tray to claim it; the same chip in several trays splits evenly; each claimer placed one card authorization (a "cap") when they joined; at the end a receipt is scanned, each person's exact share is captured, and the rest is released. The payout to the shopper is deliberately simulated.

Your job is to find what would break, confuse, or fail to build. Do not propose new features. Do not suggest changing the product idea. Check only these things, in this order:

1. Loop completeness. Walk the four steps (Add, Claim, Checkout, Settle) as each role: shopper, claimer who joins late, claimer who leaves a chip, claimer who never opens the app. At every step, is the next state defined? List any transition the spec leaves undefined or defines twice in conflicting ways.
2. Money arithmetic. Recompute every number in the 90-second demo from the stated prices ($8.72 eggs, $23.99 paper towels, $4.29 milk, $40 caps). Confirm each "captured" and "released" figure and the payout. Flag any number that does not reconcile.
3. Payments realism. For each row of the Money table, say whether that call exists in the Cybersource REST sandbox as described (pre-authorization via authIndicator 0, incremental authorization via PATCH, partial authorization reversal, capture for less than the authorized amount). Flag any claim a payments engineer would correct, and any place the demo could fail live.
4. Spec-versus-plan contradictions. Every behavior in the spec should map to a task in the plan, and every type, endpoint, or event name used in one task should be defined in an earlier task with the same name. List mismatches with the exact names.
5. Explainability. Read only the sections "The pitch" and "The one rule". Explain the product back in two sentences. Then list any sentence in the pitch that the rest of the spec contradicts.
6. Thirty-six-hour feasibility. Name the three tasks most likely to blow the schedule and say why. Name anything in the plan that is not needed for the 90-second demo.

Report format, nothing else:
- One numbered finding per line, grouped under the six headings above.
- Each finding: severity (blocker, major, minor), the exact quoted phrase from the document, the problem in one sentence, the fix in one sentence.
- End with a single line: SHIP, FIX-THEN-SHIP, or RETHINK, and one sentence of reasoning.

If a heading has no findings, write "none" under it. Do not pad.

Files to review: `docs/superpowers/specs/2026-10-17-dibs-design.md` and `docs/superpowers/plans/2026-10-17-dibs-mock-demo.md`.
