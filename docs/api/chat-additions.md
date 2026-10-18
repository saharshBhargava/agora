# Chat additions — MVP

Four native tools share the authenticated stores used by the Lists screens:

| Tool | Required arguments | Optional arguments | Persistence |
|---|---|---|---|
| `shopping_list_create` | `name` | — | `POST /v1/lists` |
| `shopping_list_add` | `title`, `listId` | `quantity`, `unit` | `POST /v1/lists/{id}/items` |
| `wishlist_add` | `title` | `quantity` | `POST /v1/wishlist` |
| `inventory_add` | `title` | `quantity`, `unit` | `POST /v1/inventory` |

`shopping_context` reads fresh inventory, wishlist feedback and open shopping lists before the task can
create a list or add anything. The app supplies household identity; model arguments cannot override it. Model output is
validated before dispatch. Account/household changes cancel work and clear the conversation context.
Both Gemini and OpenAI-compatible chat providers receive the same tools. Explicit additions need no
second approval. Recommendations continue through the existing suggestion flow.

Names are 1–120 characters, units 1–20. Shopping quantities default to 1 and must be positive and at most
1,000. Wishlist quantities default to 1 and must be integers 1–99. Inventory quantity may be omitted
(unknown) or be 0–10,000; omitted units become `unit`. Inventory addition never updates existing stock.
Chat asks for the destination/list when ambiguous. Explicit requests to create a shopping list use
`shopping_list_create` with a name of 1–80 characters (default phrasing: `Shopping list`). The tool returns
the persisted `id`, `name` and `status: saved`; then `shopping_list_add` can add each requested item to that
ID. Lists created through chat are unassigned to a store and appear immediately in the shared Lists UI.
A matching open, unassigned list is returned as `already_exists` with its ID; no list or items are erased.
Creating a list does not schedule a Calendar trip or purchase anything. Quantity changes, browser/photo
extraction, undo and new result-card UI are not included.

## Consumption forecast context

`shopping_context` also reads `GET /v1/forecasts/runouts?within=7d` for the selected household. Its result
adds `runout_window_days: 7`, `runout_forecast_status: "available" | "unavailable"`, and `runout_forecasts`.
Each entry identifies an inventory item and its unit, with a `forecast` containing method, confidence,
status, rate per day, estimated quantity, run-out date/range, reading count, history span and explanation.
Forecasts that do not match the freshly read item's last observation are omitted.

Gemini and OpenAI-compatible chat models are instructed to read this tool for running-out questions,
describe estimates with their confidence, distinguish typical-use assumptions from consumption history,
and never invent rates or dates. An absent item is not proof of sufficient stock; it has no current
prediction in this seven-day window. Forecast failures preserve the rest of shopping context and report
`unavailable`. The consumption calculation remains on the backend; the model explains the evidence.
The built-in demo chat retains its existing grammar; demo forecasts are available in Home/item detail.

## Inventory create compatibility

`POST /v1/inventory` accepts an optional `Idempotency-Key`; chat always supplies it. Identical keyed
retries return the original 201 item, and changed bodies return 422 `idempotency_key_reused`. Concurrent
keyed creates with the same case/whitespace-normalized active item name return 409
`already_in_inventory` without changing stock. This conservative check does not perform fuzzy matching
or unit conversion. Existing form requests without a key retain their behavior.

All four routes authorize the destination before reading a replay, and save the response atomically with
the mutation using the existing idempotency table. No migration is needed. The native tool key is stable
for the task and validated arguments. New-task repeats also encounter the existing-name duplicate check.
Normal audit and notification behavior is preserved; replay emits no additional mutation.

Confirmed writes update shared stores. Duplicate responses say the item or list already exists. Network/server
failures and Stop during a write report that it may have saved, rather than claiming success or retrying
automatically. The metadata-only task journal continues to flag interrupted work after relaunch.

## Built-in demo

The server-verified demo uses a small, disclosed text grammar with the same tools and real private-account
persistence. Create a list with `Create a shopping list called Weekend`, then add items. Examples: `Add 2 cartons of milk to inventory`, `Add a coffee grinder to my wishlist`, and
`Add eggs to my Weekend groceries list`. The demo accepts one item per message and numeric quantities;
ordinary accounts use their configured model. Media is not used by the demo grammar. Demo seed/backfill
adds Brown rice, an Electric kettle wishlist item, a Weekend groceries list and a Sunday farmers market
list with apples and sourdough once, preserving later edits and archiving.

See [wishlist](wishlist.md) and [shopping lists](forecasts-and-lists.md) for route-specific behavior.


### Automatic replenishment context

The server now maintains shopping lists after stock updates and every six hours, independently of chat.
`shopping_context.shopping_lists` includes each list's `source`, `store` label (or null), and each line's
`unit`, `checked` flag and saved `explanation`, in addition to IDs, titles and quantities. Gemini and the
other chat providers can explain which stock reading or consumption forecast prompted the list and why
its store was selected. They must read fresh context and may not take credit for background-created lists.
Explicit list creation uses `shopping_list_create`; background creation does not
require a new model tool or a provider key. See [background rules](forecasts-and-lists.md#automatic-background-replenishment).

## Shopping-list create compatibility

`POST /v1/lists` accepts an optional `Idempotency-Key`; chat supplies a stable task/argument key.
Household and merchant access are checked before replay. Identical keyed retries return the original
201 response, changed bodies return 422 `idempotency_key_reused`, and a different key for the same
case/whitespace-normalized open name and store returns 409 `already_exists`. Household locking serializes
concurrent creation; response, audit and list save are atomic. Forms without keys retain their behavior.
Closed lists do not block new creates. Native Stop/account changes discard late responses, and uncertain
writes require checking Lists rather than automatic retries. No schema migration is required.
