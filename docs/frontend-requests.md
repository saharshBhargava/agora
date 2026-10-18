# Frontend implementation and remaining requests

Read [current state](current-state.md) before using this backlog. It separates live APIs, implemented UI,
simulations and unimplemented requirements. Do not treat a requested screen as already shipped.

## Demo sign-in is implemented

Pull main and rebuild. Welcome has a username/password form: username `demo`, password shared privately
from Render `AGORA_DEMO_PASSWORD`. Google is optional. No external provider keys are needed for the
sample account. Chat, captions and capture recognition use fixed sample results; Calendar uses private
persisted Agora events. See [the contract](api/demo-integrations.md) and [frontend handoff](frontend-handoff.md).
Do not replace this with a mandatory Google gate or send sample-account media to a real model provider.
Ordinary-account Google/model configuration and existing feature requests below still apply.

## Remaining frontend requests

Features the backend already supports and that are waiting for a UI. Each section links to its API contract.
Add new sections at the end.
Resuming older work: read the [PR integration handoff](pr-handoff.md) and sync `origin/main` first.

---

## Requested frontend features: wishlist

**Status:** backend and iOS implemented. **API contract:** [docs/api/wishlist.md](api/wishlist.md).
Home opens Wishlist and Suggested for you; `Agora/Shopping/` contains the shared store, views, model-backed
idea service and chat tools. Desktop can follow the same contract.

The wishlist is a priority queue that both the user and the on-device agent add to. Agent suggestions wait
for an explicit decision, and the user can rate them with a thumbs up or down.

### 1. Wishlist screen, sorted by priority

- Load `GET /v1/wishlist`. Show items **in the order returned**. The server has already sorted them, so
  don't re-sort on the client.
- Each row shows:
  - `title`, with `quantity` when it's more than 1
  - `target_price_cents` formatted as currency, if set
  - `needed_by` as a relative date ("in 2 days"), if set
  - the first one or two `priority_reasons` as small caption text (e.g. "Needed in 2 days · Added by you")
  - a pin glyph when `pinned` is true
  - an agent badge when `source == "agent"`
- Tapping a row opens the detail and edit view (section 5).
- Show history (purchased and removed) behind a toggle, using
  `GET /v1/wishlist?status=purchased&status=removed`.
- Empty state: suggest adding something.

### 2. Manual add form

Send `POST /v1/wishlist`.

| Field | Control | Notes |
|---|---|---|
| Title | Text field | Required. 120 characters max |
| Quantity | Stepper | 1-99 |
| Target price | Currency field | Send as integer cents |
| Needed by | Date picker | Optional |
| Category | Text field or picker | Optional |
| Notes | Multiline text | Optional |
| Priority | Segmented control | Optional. 1-5 |
| Pin | Toggle | Optional |

- Optional: "Link to an inventory item", picked from `GET /v1/inventory`. Sends `inventory_item_id`, which
  lets the list show "Running low".
- On `409 already_on_wishlist`, tell the user it's already on the list or waiting as a suggestion, and offer
  to open it.

### 3. Suggestion cards

Load `GET /v1/wishlist/suggestions`, either as a section above the list or as its own tab with a badge
showing the count.

Each card shows:

- `title` and `quantity`
- `rationale`, the agent's explanation. This is the main text on the card
- `evidence` as small chips (`kind` icon plus `detail`)
- `confidence` as a subtle meter or percentage
- `target_price_cents`, if set
- `priority_reasons`

Each card has three clearly different actions. Rejecting must look and feel different from accepting:

| Button | Call | Style |
|---|---|---|
| **Accept** | `POST /v1/wishlist/{id}/accept` | Primary. The item moves onto the wishlist |
| **Reject** | `POST /v1/wishlist/{id}/reject` | Destructive. Opens a reason picker (below) |
| **Not now** | `POST /v1/wishlist/{id}/snooze` | Secondary. Opens snooze options (below) |

**Reject reason picker** (required before sending):

| Label | `reason_code` |
|---|---|
| Not interested | `not_interested` |
| Already have it | `already_have` |
| Too expensive | `too_expensive` |
| Wrong item | `wrong_item` |
| Other | `other` |

Add an optional comment field (500 characters max). Tell the user the agent won't suggest this again for
30 days.

**Snooze options:**

| Label | Body |
|---|---|
| Tomorrow | `{"days": 1}` |
| Next week | `{"days": 7}` |
| In a month | `{"days": 30}` |
| Pick a date | `{"until": "<ISO time with offset>"}` |

A snoozed card disappears and comes back on its own. Optionally, show snoozed cards under "Snoozed" using
`?include_snoozed=true`.

**Undo:** after a decision, show a short toast ("Added to wishlist", "Rejected", "Snoozed until Oct 24").
There is no backend undo yet; ask the backend team if you need one.

### 4. Thumbs up / down

- Show thumbs on every agent item: suggestion cards, and agent-sourced rows in the list and history.
  Feedback is allowed on an agent item whatever its status.
- Read the current state from `my_feedback` (`"up"`, `"down"` or `null`).
- Tap a thumb: `POST /v1/wishlist/{id}/feedback` with `{"rating": "up"}` or `{"rating": "down"}`.
- Tap the active thumb again: `DELETE /v1/wishlist/{id}/feedback` to clear it.
- On thumbs down you can offer the same reason chips (`reason_code`), but they're optional.
- Thumbs don't move the item between states. Make sure the UI doesn't imply that they do. Thumbs teach the
  agent; Accept and Reject decide.
- Don't show thumbs on user-added items. The server returns `409 not_a_suggestion` for them.

### 5. Edit, priority and pin

Send `PATCH /v1/wishlist/{id}` with only the fields that changed.

- Editable fields: title, notes, quantity, target price, needed by, category.
- **Priority:** five levels (Lowest, Low, Normal, High, Highest), mapped to 1-5. "Normal" can send
  `priority: null`.
- **Pin:** a toggle or swipe action that sends `{"pinned": true}`. Pinned items always sort to the top.
- Both apply instantly. Refetch the list or use the returned item, because the score and reasons change.

### 6. Mark purchased and remove

- **Purchased:** a swipe action or checkbox on active rows. Calls `POST /v1/wishlist/{id}/purchased`.
- **Remove:** a swipe-to-delete on active rows. Calls `DELETE /v1/wishlist/{id}` and returns the item with
  status `removed`; nothing is hard-deleted.
- Suggestions can't be deleted. Use Reject or Not now instead (the server returns `409 invalid_transition`).

### 7. Live refresh

- The current iOS shopping store refreshes on foreground, local mutations and every 30 seconds while active.
  A future shared `GET /v1/events` (SSE) subscriber can replace polling. On `type == "wishlist.updated"`,
  refetch the wishlist and suggestions. The event carries only the item `id`, so you can refetch just
  `GET /v1/wishlist/{id}` if you prefer.
- This keeps two household members' phones in sync, and makes agent suggestions appear without a manual
  refresh.

### 8. Errors

- Errors are RFC 7807. Switch on `title` (e.g. `invalid_transition`, `already_on_wishlist`) and show
  `detail` to the user. `detail` is written to be safe to display.
- A `409 invalid_transition` usually means another device already acted. Refetch and update the UI.

### Out of scope for this request

- How the agent decides what to suggest. That's on-device: it reads `GET /v1/wishlist/agent-context` and
  calls `POST /v1/wishlist/suggestions` with an `Idempotency-Key`.
- Checkout and purchase flows.


## Requested frontend feature: offline demo fallback (iOS, small)

**Status:** done on iOS. `AgoraClient.validOrigin` accepts `http://localhost`, `http://127.0.0.1`,
`http://*.local`, and private LAN IPs in **DEBUG** builds only; Release stays HTTPS-only.
`Info.plist` already sets `NSAllowsLocalNetworking` (and local HTTP exceptions). Simulator:
`AGORA_API_BASE_URL = http:/$()/localhost:8000`. Phone on the same hotspot: Mac LAN IP or `.local` name.

**Why:** if venue internet and hosting both fail, the backend can still run on the demo Mac
(`uv run python -m app.tools.local_demo`, see SETUP.md, Plan B) without requiring a tunnel.

Ordinary-account Google sign-in, Calendar and real model chat still need internet. The password demo uses
its configured Agora API for login, Calendar and data, and built-in model responses. This fallback covers inventory, scans (with replay
fixtures), merchants and the wishlist.

---

## Requested frontend features: agent approvals, mandates and kill switch

**Backend status:** done. **API contract:** [docs/api/agent-commerce.md](api/agent-commerce.md). **For:** iOS
(desktop can follow the same layout).

**iOS status (2026-10-18):** built in the Dibs app: the Spending page (home → Your household → Spending, and
Settings → Spending limits) with the approval inbox, budget and spend, spending authority (grant/revoke), recent
requests and the pause/resume switch; the approval sheet; "Buy with the assistant" on wanted wishlist items; and the
chat tool `purchase_request` (Agora checkout, approval in the chat's card). Not built yet: the merchant picker for
mandates, the "Show revoked and expired" toggle, week/store spend toggles, budget editing, and live refresh from
`GET /v1/events`.

The agent now asks the backend before it spends money or acts for the user. The backend answers allow, needs
approval or deny, and always says why in plain language. The user needs four things: a sheet to approve or
reject requests, a way to grant and revoke spending authority (mandates), a view of spend against budgets,
and a pause button that stops everything at once.

### 1. Approval sheet

Shown when an intent comes back `decision: "needs_approval"` (the agent is waiting), and from an inbox
loaded with `GET /v1/agent/intents?status=proposed`.

- **Header:** `title`, the amount (`amount_cents` as currency) and `merchant_name`. Add a small "Agora
  checkout" label when `execution == "agora"`, since the server charges on approval.
- **Why the agent wants this:** `rationale` as body text.
- **What it looked at:** `evidence` as a short list, with an icon per `kind` (`inventory_low`,
  `runout_forecast`, `purchase_history`, `wishlist`, `price`, `product_page`, `calendar`, `other`) and the
  `detail` text.
- **Why it's asking you:** `decision_reasons`, **verbatim and in order**. The first reason is always the
  main one, so give it the most weight. Don't rewrite these strings: they're written for users, and the audit
  trail refers to them. Use `reason_codes` only for styling, e.g. a warning tint for `over_budget`,
  `over_txn_cap`, `over_period_cap`, `duplicate_recent` and `duplicate_unknown`.
- If `payload.url` is set, add a "View product page" link that opens in the in-app browser.
- **Buttons:**
  - **Approve** calls `POST /v1/agent/intents/{id}/approve`. For an Agora checkout the response is already
    `succeeded` (or `failed` with an `error_code`), so show that result instead of "Approved".
  - **Reject** calls `POST /v1/agent/intents/{id}/reject` with an optional `reason_code` from a short picker:
    Too expensive (`too_expensive`), Don't need it (`not_needed`), Wrong item (`wrong_item`), Wrong store
    (`wrong_merchant`), Other (`other`).
- Show `approval_expires_at` as "Expires in 23 h". After it passes, hide Approve: the server returns
  `409 approval_expired`.
- When `mine` is false (another household member's agent), show the sheet read-only, e.g. "Waiting for
  Sam". Actions would return `403 not_your_intent`.
- For `decision: "deny"`, don't show a sheet. Show a one-line notice with the first reason, e.g. "Blocked:
  Your agent already asked to buy 3 things in the last hour…".

### 2. Agent activity

A list from `GET /v1/agent/intents`, newest first, for a "what has my agent done" screen.

- Each row: `title`, amount, and a status chip: `proposed` "Waiting for you", `approved` "Approved",
  `executing` "In progress", `succeeded` "Done", `failed` "Failed", `outcome_unknown` "Check this",
  `rejected` "Rejected" (or "Blocked" when `decided_by == "policy"`), `cancelled` "Cancelled".
- Show who decided: `decided_by` `policy` is "Allowed by your mandate" or "Blocked by your settings",
  `user` is "You approved" or "You rejected", `kill_switch` is "Cancelled by pause".
- Highlight `outcome_unknown` rows: "This order may or may not have gone through. Check the store before
  buying again."
- Tapping a row opens the approval sheet layout, read-only.

### 3. Mandate editor

Settings → Agent → Spending mandates. Load `GET /v1/agent/mandates`, with a "Show revoked and expired"
toggle for `include_inactive=true`.

- Each card shows `label`, the scope ("Ballard Market · dairy, produce", or "Any store · any category"), the
  limits ("Up to $50 per purchase · $150 per week"), "Asks above $30" when `require_confirm_above_cents` is
  set, and the expiry ("Expires Nov 17"). Add a progress bar of `spent_this_period_cents` against
  `max_per_period_cents` for the current `period`.
- Swipe or tap to revoke: `DELETE /v1/agent/mandates/{id}`.
- **New mandate** form (`POST /v1/agent/mandates`):

| Field | Control | Notes |
|---|---|---|
| Name | Text field | Required, 60 characters max |
| Stores | Multi-select from `GET /v1/merchants?q=` | Optional. None means any store |
| Categories | Chips | Optional. None means any category |
| Per purchase | Currency field | Required. Send integer cents |
| Per period | Currency field + day/week/month picker | Optional. At least the per-purchase limit |
| Ask me above | Currency field | Optional |
| Expires | Picker: 7 days, 30 days, 90 days, 1 year | Send `expires_in_days` |

- Mandates only apply at the "Buy within mandate" autonomy level. If the user's level is lower, show a note
  under the list ("Your agent asks before every purchase. Switch to Buy within mandate to use these.") with a
  shortcut to the autonomy setting (`PATCH /v1/me/settings`, `autonomy_level`).

### 4. Spend and budget view

- Load `GET /v1/spend?period=month&group=category`, with segmented controls for week/month and
  category/store (`group=merchant`). Show `total_cents` and a bar per entry in `groups`.
- Budgets come back in the same response (`budgets`) and from `GET /v1/budgets`. Give each a progress bar:
  `spent_cents`, plus `pending_cents` drawn lighter ("$8.98 pending"), against `limit_cents`. When
  `remaining_cents` is negative, show it as over budget in a warning color.
- Add or edit budgets with `POST /v1/budgets` (`period`, optional `category`, `limit_cents`) and
  `PATCH /v1/budgets/{id}` (`limit_cents`, or `status: "archived"` to remove one). On `409 budget_exists`,
  open the existing budget instead.
- Caption under the budgets: "Your agent asks before going over a budget."

### 5. Pause button

- A prominent **Pause agent** control on the agent screen, ideally also in the agent chat header. It calls
  `POST /v1/agent/pause` with no confirmation dialog, because stopping should be instant. Show the result:
  "Agent paused. 2 mandates revoked, 1 request cancelled." If `in_flight > 0`, add "1 action was already in
  progress in the browser and may still finish."
- While `GET /v1/agent/state` returns `paused: true`, show a banner on the agent screens ("Your agent is
  paused") with a **Resume** button (`POST /v1/agent/resume`). After resuming, remind the user that mandates
  stay revoked and offer to open the mandate editor.
- Tapping Pause should also stop the agent's current task on the device (the existing `AgentCoordinator`
  stop path), since the server can't recall a step that is already running.

### 6. Live refresh

- On `GET /v1/events`, refetch on `agent.updated` (intents and mandates), `budget.updated` and
  `spend.updated`. A household member's agent can create requests about shared money, so this keeps both
  phones current.
- Drive the inbox badge from `pending_approvals` in `GET /v1/agent/state`.

### 7. Errors

- Errors are RFC 7807. Switch on `title` and show `detail`, which is written to be safe to display.
- A `409 invalid_transition` usually means another device already acted, or the user paused. Refetch the
  intent and update the sheet.

### Out of scope for this request

- How the agent proposes intents and reports outcomes. That's `AgentCoordinator`'s job; see "Fitting the iOS
  agent" in the API contract.
- Adding real payment methods. Agora checkout uses simulated test tokens for now.

---

Backend URL and accounts for testing: see [SETUP.md](../SETUP.md). The "Purchased from / on" contract is in
[docs/api/purchased-from.md](api/purchased-from.md).

---

## Automatic replenishment lists — implemented October 18, 2026

The backend creates and maintains store-grouped lists after stock updates and every six hours, including
recorded zeroes, restock-threshold items and fresh seven-day consumption forecasts. Native Home/Lists and
shopping trips read these through the existing foreground refresh. No trip-planning or chat action is
needed to create them. Chat receives list stores, sources, checked flags and explanations. User edits,
checks/removals, restocks and the agent pause are handled as documented in the
[API contract](api/forecasts-and-lists.md#automatic-background-replenishment).
This supersedes older descriptions of list creation as exclusively a one-tap operation.

## Requested frontend features: run-outs and shopping lists

**Native implementation update (October 18, 2026):** Home's Running low carousel now combines seven-day
consumption predictions with recorded zeroes/restock thresholds. Lists use the same ordering; item detail
shows date/range, consumption rate, estimated remaining quantity, confidence and evidence. Gemini chat can
read these forecasts through `shopping_context`. Foreground refresh uses the existing 30-second cadence;
new quantities invalidate old predictions. The horizon toggle, projection chart and SSE-specific refresh
below remain follow-up proposals. See [native behavior](api/forecasts-and-lists.md#native-consumption-predictions).

**Backend status:** done. **API contract:** [docs/api/forecasts-and-lists.md](api/forecasts-and-lists.md).
**For:** iOS first; the laptop/desktop view can reuse the same screens.

This is the hero demo moment: "your fridge is a time series". The app shows when each item will run out,
explains why it thinks so, and turns that into a shopping list per store in one tap.

### 1. "Running out soon" card on the home screen

- Load `GET /v1/forecasts/runouts?within=7d`. Show rows **in the order returned** (soonest first; items that
  have probably run out are first).
- Each row: item name, a day chip from `forecast.runout_at` in the user's time zone ("Today", "Tomorrow",
  "Thu"), and the range from `runout_lo`/`runout_hi` when it spans different days ("Wed–Fri").
- Colour by `forecast.status`: `out` = red ("Probably out"), `runs_out` within 2 days = amber, otherwise
  neutral.
- Tapping a row opens the item detail (section 2).
- If `on_list_id` is set, show a small "On list" tick instead of an add button.
- Otherwise show an add button: `POST /v1/lists/{id}/items` with `{"inventory_item_id": …, "quantity":
  suggested_quantity}` to a list the user picks, or run "Make my lists" (section 3).
- Empty state: "Nothing's running out this week."
- A 3-day / 7-day / 14-day toggle maps to `within=3d|7d|14d`.

### 2. Forecast on the item detail screen

`GET /v1/inventory/{id}` now has `forecast` (or `null` before the first reading).

- Headline: `forecast.explanation`, shown as-is. It's written for users and is safe to display. Example:
  "2% milk will run out on Fri. Based on 21 scans over 20 days, you use about one every 5.4 days."
- On the existing quantity chart (`daily`), draw a dashed projection from (`last_observed_at`,
  `last_quantity`) down to zero at `runout_at`, with a shaded band between `runout_lo` and `runout_hi`.
  This is the money shot for the demo, so please make it look good.
- Show `confidence` as a subtle badge (Low / Medium / High). For `method: "prior"`, add the hint "Scan it a
  few more times to personalize this" (it's already in the explanation; a badge is optional).
- `status: "steady"` → no projection line; `status: "unknown"` → hide the forecast block, show the
  explanation as a hint.

### 3. "Make my lists" button

- On the run-outs card and the Lists tab: one button that calls `POST /v1/lists/generate` with
  `{"within_days": 7}` and a fresh `Idempotency-Key` (a UUID) **per tap**. Reuse the same key if you retry
  the same tap after a network error.
- On success, show a toast from the response: "Added 8 items to 2 lists" (`added`, `lists.length`). When
  `added == 0` and everything was skipped as `already_on_list`: "Everything's already on a list."
- Navigate to the Lists tab, or to the list if exactly one came back.

### 4. Lists tab

Implemented in the native **Home → Shopping lists & trips** screen: **New list** accepts a name and
optional store using the shared store picker. Creating it opens the saved checklist; **Add item** accepts
a name, positive quantity, optional unit and notes. These use the existing authenticated list APIs, and
manual lists with unchecked items participate in reviewed trip planning. List history, editing and
inventory autocomplete below remain follow-up work.

- `GET /v1/lists` (open lists). Show **in the order returned** (most urgent trip first).
- Each list card: `name`, store (`merchant.name` + locality), `open_count`, and "Needed by Thu" from
  `needed_by`. Generated lists can carry a small "Auto" tag (`source == "generated"`).
- "New list" button: `POST /v1/lists` with an optional name and store (reuse the store picker from the
  "Purchased from" feature, see [purchased-from.md](api/purchased-from.md)).
- A "Done" / "History" segment can load `?status=done&status=archived`.

### 5. List screen

- Lines in the order returned: unticked first, by `needed_by`.
- Each line: checkbox, `title`, `quantity` (+ `unit` if present), `note`. If `explanation` is present, show
  a small "Why?" disclosure with it, and a badge for `added_by` = `system` ("From run-outs") or `agent`
  ("Suggested by Agora"). Every non-user line has an explanation. This is part of the trust story, so
  don't hide it entirely.
- Tick: `PATCH /v1/lists/{id}/items/{item_id}` with `{"checked": true}` (or `false` to untick). Ticked lines
  move to the bottom, greyed out.
- Swipe to delete: `DELETE /v1/lists/{id}/items/{item_id}` (204).
- Quick add field at the bottom: `POST /v1/lists/{id}/items` with `{"title": "..."}`. Offer
  autocomplete from inventory items and send `inventory_item_id` instead when one is picked.
- Edit sheet: title, quantity, unit, note via `PATCH` with only the changed fields.
- List menu: rename, change store, "Mark done" (`PATCH /v1/lists/{id}` `{"status": "done"}`), "Archive".
  Done/archived lists are read-only; show a "Reopen" button (`{"status": "open"}`).

### 6. Live refresh

- On SSE `type == "forecast.updated"`: refetch run-outs and, if open, the item detail. This arrives a second
  or two after a scan is confirmed, so the forecast visibly updates after a review. Worth showing in the demo.
- On `type == "list.updated"`: refetch that list (`GET /v1/lists/{id}`, the event `id`) or the Lists tab.

### 7. Errors

- RFC 7807: switch on `title`, show `detail`.
- `409 already_on_list`: "Already on this list". Refetch.
- `409 list_closed`: another device finished the list. Refetch and show it read-only.
- `422 invalid_within`: a client bug. Only send `Nd`, 1–90.

### Out of scope for this request

- Scheduling is available from Home → Plan shopping trips; see the replenishment-to-Calendar section below.
- Checkout from a list, and turning ticked lines into purchases/restocks (receipts, P1 follow-up).
- Price-drop lines (`reason: "price_drop"` is reserved).

---

## Six-hour replenishment refresh and shopping ideas

**Status:** replenishment scheduling, wishlist management, suggestions and reviewed price-watch UI are
implemented. User-entered targets stay distinct from verified source offers; unsupported merchant evidence
cannot trigger a matching-price claim. See [price watches](api/price-watches.md).
See [backend refresh design](backend-spec.md#45-prices-deals-small-businesses).

- Replenishment checks run through backend jobs at 00:00, 06:00, 12:00 and 18:00 UTC, including while the
  app is closed when the worker is available. Missed intervals are coalesced when work resumes.
- Suggested for you shows last successful replenishment check, next scheduled check and failures separately.
  **Check stock** invokes `POST /v1/wishlist/refresh` with a stable key for retries.
- **Find ideas** uses the model assigned to Shopping suggestions in Settings, with structured output and
  inventory evidence. It sends inventory names/quantities and feedback to that connection, never media or
  Calendar credentials. It runs on demand; it is not the six-hour backend job.
- Accept, reject with a reason, snooze, feedback, edit, pin, priorities, mark purchased and remove all use
  existing wishlist endpoints. Failed refreshes retain previous results; account/household switches clear
  shopping state and discard stale responses.
- Price-watch checks run every six hours plus initial/manual checks. Saving an active wishlist item or
  accepting a suggestion starts the first check automatically. **Lists → Watch list** opens the wishlist
  with its Add item action. Targets are optional. Rows show current source prices and target comparisons,
  and **Prices and watch settings** opens details and optional refinements. There is no separate activation.
- The client reloads watches after wishlist mutations and polls pending checks every two seconds for at
  most 90 seconds. Account/household changes cancel polling. Work continues in the backend afterwards.
- The wishlist toolbar opens **Price watches** and **Offer inbox**. Detail shows last successful/next check,
  failures vs no matches, explicit verification gaps, current vs historical offers, evidence and retailer link.
- Push permission is requested after explicit opt-in; denial or unavailable APNs does not hide the inbox.
  Alert taps open the watch after authenticated loading. Account/household changes clear watch/inbox state.
- Research can refine searches and follow source links within server-enforced budgets. When it reports
  `interaction_urls`, the latest confirmed run shows **Needs browser review**. An explicit tap opens the
  shared browser privately and selects Chat; no model action or purchase starts automatically.

## Replenishment to Calendar

**Status:** implemented in iOS and the backend. Contract: [replenishment trips](api/replenishment-trips.md).

Home's **Plan shopping trips** and **Plan a restock trip** open the store lists and trip planner. The planner
generates lists from the next seven days of run-outs, including preferred/last-purchased stores, then loads
all existing open lists. Users choose a 1–14-day Calendar search window, daily shopping hours, and a duration
including travel. The earliest deadlines are planned first, in non-overlapping free Calendar slots. A trip
that would finish after its list's deadline has a visible warning; unavailable slots stay unscheduled.
Store opening hours and travel routes are not inferred.

**Review trip** shows the exact title, time, timezone, store and item notes. **Add to Calendar** checks
availability again, reserves the reviewed list version on the backend, creates the event, and persists its
outcome. Ordinary accounts use the primary Google Calendar directly; the designated account uses its private
Agora Calendar. Planning alone creates no Calendar events. No invitations are sent.

Saved trips appear on Home and in Shopping trips after app restart. A reserved trip can be reviewed again
to finish the same saved request; recovery first looks for the original event and keeps its deterministic
identity. Uncertain outcomes offer **Check Calendar status**, which only reads the provider and never
creates another event. When that read finds no matching event—or a reserved slot can no longer finish—
**Release reservation** reports `failed` so the list can be planned again. Do not auto-release on
timeouts. Account or household switches invalidate reviews and pending local state.

Store lists can be opened and items checked/unchecked with their replenishment explanations visible.
This does not increment inventory or record a purchase. Existing wishlist and shopping suggestion flows
remain separate. Trip/list data refreshes on foreground, local changes and periodic polling; the backend
also publishes `trip.updated` for future SSE clients.

Trip reservations and private Calendar creation return `409 duplicate_request` if another operation wins
the same request key concurrently; the losing write is rolled back. Preserve the original key on retry
and reload trips to recover saved state. A key already used for different input returns
`422 idempotency_key_reused`.

Price-watch capability responses include `discovery_status` (`available` or `search_not_configured`).
A reasoning model is optional: enabled providers can search the product title and verify source pages
deterministically. The client retains support for older `model_not_configured` responses and does not
interpret a failed capability request or service 404 as provider availability. Scheduled research uses
server settings; foreground model credentials remain on the phone. Demo prices remain explicitly simulated.

## Automatic item images

Inventory, Home, wishlist/suggestions, shopping lists and watch/offer views use shared thumbnails. The app
shows the server's selected image for exact and best-match results. When an older server only supplies
usable alternatives, it displays a default immediately instead of leaving the main thumbnail empty.
The app settles on the automatic image. Image chooser sheets, tap/long-press editing, photo upload,
removal, alternative-selection and search-refinement controls have been removed. Previously saved
choices remain respected by the compatible backend.

The backend automatically selects from new searches and cached results and adopts existing candidate-only
items at startup. It preserves source evidence and every manual override. Inventory-linked items inherit
the selected image. Source URLs and sanitized image bytes are saved; the app loads authenticated API copies.
See [the contract](api/item-images.md) and [current deployment state](current-state.md). Native source passed
eight focused simulator tests, including the alternatives-only main-thumbnail regression; rebuilding the
app is required to distribute these client changes.

Existing-inventory recovery now repairs missing bindings, retries expired empty results, and revisits old
search-version misses at startup. Visible thumbnails continue checking beyond the first 90-second batch
while the app is active, including automatic retries after connection failures. The local change passed
nine image simulator tests; see the current-state record for backend and live-search verification.
The subsequent native startup change preloads the entire household inventory before thumbnails appear,
using four concurrent reads per pass and revisiting pending work while active. New and renamed items
join automatically; account and household changes stop prior work and clear private imagery.

## Shared-browser price fallback — implemented locally

After normal multi-retailer research finishes without a usable price, an ordinary-account watch can
request a final hidden check in the existing Chat browser. The runner waits while Chat owns a page,
uses the same web view, and yields on human interaction, new chat work, account change or app inactivity.
It runs only while the app is open. It does not automatically show the browser or switch tabs.

Watch list/detail screens show waiting/checking/completed/unavailable states and persisted current prices
with an optional-target comparison. Browser observations disclose that condition, stock and delivery need
retailer confirmation; they do not generate verified offer alerts. Private/challenge pages can expose a
manual review action. Demo accounts never open external pages. See the [API contract](api/price-watches.md#final-fallback-in-the-shared-chat-browser).
Both migration 0019/backend changes and a rebuilt iOS app are required; this is not a deployment claim.

The missing-watch row now uses `automatic_watches` from the watch-list response. A successful empty
response from an older backend shows that automatic checks are unavailable; network failures and unloaded
state remain distinct. An absent watch is never represented as an indefinitely running preparation step.


## Chat additions MVP — implemented locally, October 18, 2026

Chat can add items to existing shopping lists, the active wishlist and new inventory entries. Explicit
requests save immediately; ambiguous destinations are clarified and duplicates leave quantities unchanged.
Shared screens update after confirmed saves. Existing suggestions remain a separate acceptance flow.
See [chat additions](api/chat-additions.md) for argument limits, demo examples and retry behavior.
List creation from chat, existing-stock changes, browser/photo extraction and undo remain outside this MVP.
