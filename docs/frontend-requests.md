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
