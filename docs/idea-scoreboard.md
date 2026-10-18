# Idea scoreboard

Every idea discussed in the planning chat, what happened to it, and why. Last updated 2026-10-17.

Judging method for rounds 1 and focus test: three hostile judges per idea (a prior-art hunter with web search, a cynical UW junior, a DubHacks expo judge from Visa), each told to kill when uncertain. Survivors were rebuilt by a defender and faced a final executioner.

## What is being built (the base)

- **Original plan** (docs/Dubhacks Planning 1.md): video inventory with Perceptron, categories and stores, consumption rates, calendar trips, per-store lists, price alerts, recommendations, in-store price comparison, three autonomy tiers.
- **Built so far** (commit 55c54ce): SwiftUI app where Gemini drives an in-app web browser, with live preview, human takeover, and one-tap approval before every action.

Honest read: the base scores on Technical Execution (20%) and Trust & Responsibility (15%). It does not yet score on Innovation (25%). Video-to-pantry apps already shipped in 2026 (Shelfze, Pantry AI, Pantrio), autonomy tiers are Visa's own vocabulary, and 2026 hackathons already awarded EcoBite, NeighborFridge, Sunday, Tab and Project Lend.

## Still alive

| Idea | One line | Status | Main risk |
|---|---|---|---|
| **Dibs** (team's current pick, spec written) | Call dibs on the cart. The shopper holds items up to the camera, chips appear on everyone's phone, drag a chip into your tray to claim it, the same chip in several trays splits evenly, every claimer's share is captured from an authorization placed at join. Spec: docs/superpowers/specs/2026-10-17-dibs-design.md | Polished to 6/10 over three rounds, then four hostile reviews resolved; awaiting team approval | Novelty is a new combination, not a new primitive; the shopper still pays at the register and the payout is simulated |
| Toppled (round 2) | Party snack-tower Jenga: the camera prices the tower as it grows, whoever knocks it over pays the host a capped share | Survived executioner, 7/10 | Soft snacks don't stack; "loser pays" can feel petty |
| Cleaned Out (round 2) | Dorm cook-off where the emptiest plate wins and the losers split the winner's grocery receipt by how much food they left | Survived executioner, 6/10 | Vote measures flavor popularity, not cooking; settlement takes time to explain |

## Killed by hostile judges

| Idea | Killer argument |
|---|---|
| Focus card (focus mode for groceries, ad-free, list-only card, blur lens) | Privacy.com already sells grocery-only cards; Amazon sponsored-product blockers and Ruko exist; "not on your list" at a real register is a mocked decline; an anti-ads pitch makes a Visa judge uneasy because retailers are Visa's customers. All three judges said the blur-the-shelf lens is the only part worth keeping. The defender's best rebuild (camera prices your list and sets a real Visa hold, gold glow for treats you can still afford, buddy approves off-list items) still self-scored about 5/10: the student can tap a different card, and the lens has research prior art (ShoppingCoach, CHI 2024; US patent 10553032). Keep the lens as a demo technique for a different core. |
| Listcard / Slip (handwritten list is the card) | The paper ends up with the runner, who has no reason to use its controls; reads as Math Sandbox reused; Kando Errands already does no-fronting errand cards |
| Per Slice, Slice, Bites (pay for the slices you ate) | Petty; Splitwise with a camera; Amazon Just Walk Out for a pizza box |
| Dinner Cap Table (bring food = equity) | Same petty camera-at-dinner setup with double the vision risk |
| Fridge Futures (short your roommate's spinach) | Gambling optics for Visa; needs daily fridge video |
| Fridge Court (fridge charges roommate who ate your leftovers) | Devpost project Craven already did the camera-catches-thief part; surveillance vibe |
| Dibs Run, Tagalong (errand run with scoped holds) | NeedAnything, Runerra, Kando Errands, Buy4Me, GrocerMate exist |
| Over/Under (worst cart-total guess pays) | One joke; register already prints the total |
| Tag Witness (video proves overcharges) | Homework for 80 cents; staged demo |
| Reach-In (round 2 rerun) | Killed 3-0 in round 2, but the round-2 brief told judges the errand run was already dead, so treat this as biased. Its core now lives on inside Live Cart |
| House Board (round 2 rerun) | Killed 3-0: relies on an item-level decline at a register, and handwriting on a surface reads as Math Sandbox |
| Sour Clock / Bite Bounty (paid food dares) | Camera is a disguised tap-out button; Double Dog, Monster Dare and Bounty (2026 winner) exist; One Chip Challenge safety optics |
| Potluck Bouncer, Table Stakes, Sink Surge, Last Dibs, Enryo, Pledge Plate, Bean Vote, Locked Ten, Toppler | Killed in round 2; see adversarial_round2_results.json |

## Rejected by the team in discussion (not agent-judged)

Demand Book (merchants bid on run-out dates), runway-only inventory, neighbor demand pooling, caregiver delegated commerce, Strava for your fridge, eating-well reward points, lifestyle alignment score, personal inflation index, shrink audit, resale value view, self-serve shelf store, groceries billed like a utility, diaspora pantry finder, proof-of-empty-fridge allowance, crowd price index, edit-your-future-shelf ordering, agent that phones small stores.

## Social or competition layer

Settled by round 2, with all judges agreeing: a social layer helps only when the other people are physically present and are the source of the money (rival plates, tower players, friends claiming the same item). Feeds, leagues, personal bests, cross-group leaderboards and goal scores hurt: a judge can't experience them in 3 minutes, they slide into health or shame charts, and with money attached a ranking reads as betting.

## What the judges consistently rewarded

1. A physical prop the judge handles in the first 10 seconds.
2. Money moving as a visible punchline of something the camera sees, not as reconciliation afterward (Minty's tooth stock).
3. Visa controls that actually run in a sandbox: caps, holds, partial capture, void, token suspend, mandate approval prompts.
4. Something a 20-year-old would do unprompted on a Friday night.

## What the judges consistently killed

Utility or friction-removal pitches over solved problems, item-level declines at a physical register, card issuing to friends, paper-plus-camera interfaces, surveillance of roommates, betting between friends, and anything where an agent deciding or buying is the core.

## Cheap upgrades to the base regardless of the core

These do not make the idea novel, but they make the base stronger and fit what is already built:

- **Card plus camera gives consumption without logging.** Visa purchases are the inflow, the shelf scan is the stock, and the difference is consumption. This is the honest answer to "how do you know my consumption rate."
- **The approval sheet becomes a visible mandate.** Rules you set once (cap, categories, ask above $X), enforced with a default of no.
- **Runway as the hero inventory view.** Days of coffee left, with uncertainty shown when the camera count is unsure.
