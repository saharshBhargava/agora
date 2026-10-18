# Frontend requests

Features the backend already supports and that are waiting for a UI. Each section links to its API contract.
Add new sections at the end.

---

## Requested frontend features: wishlist

**Backend status:** done. **API contract:** [docs/api/wishlist.md](api/wishlist.md). **For:** iOS (desktop
can follow the same layout).

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

- The app already subscribes to `GET /v1/events` (SSE). On an event with `type == "wishlist.updated"`,
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

---

## Requested frontend features: agent approvals, mandates and kill switch

**Backend status:** done. **API contract:** [docs/api/agent-commerce.md](api/agent-commerce.md). **For:** iOS
(desktop can follow the same layout).

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
