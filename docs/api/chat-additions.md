# Chat additions — MVP

Three native tools share the authenticated stores used by the Lists screens:

| Tool | Required arguments | Optional arguments | Persistence |
|---|---|---|---|
| `shopping_list_add` | `title`, `listId` | `quantity`, `unit` | `POST /v1/lists/{id}/items` |
| `wishlist_add` | `title` | `quantity` | `POST /v1/wishlist` |
| `inventory_add` | `title` | `quantity`, `unit` | `POST /v1/inventory` |

`shopping_context` reads fresh inventory, wishlist feedback and open shopping lists before the task can
add anything. The app supplies household identity; model arguments cannot override it. Model output is
validated before dispatch. Account/household changes cancel work and clear the conversation context.
Both Gemini and OpenAI-compatible chat providers receive the same tools. Explicit additions need no
second approval. Recommendations continue through the existing suggestion flow.

Names are 1–120 characters, units 1–20. Shopping quantities default to 1 and must be positive and at most
1,000. Wishlist quantities default to 1 and must be integers 1–99. Inventory quantity may be omitted
(unknown) or be 0–10,000; omitted units become `unit`. Inventory addition never updates existing stock.
Chat asks for the destination/list when ambiguous; if no list exists, users create one in Lists first.
No list creation, quantity changes, browser/photo extraction, undo or new result-card UI is included.

## Inventory create compatibility

`POST /v1/inventory` accepts an optional `Idempotency-Key`; chat always supplies it. Identical keyed
retries return the original 201 item, and changed bodies return 422 `idempotency_key_reused`. Concurrent
keyed creates with the same case/whitespace-normalized active item name return 409
`already_in_inventory` without changing stock. This conservative check does not perform fuzzy matching
or unit conversion. Existing form requests without a key retain their behavior.

All three routes authorize the destination before reading a replay, and save the response atomically with
the mutation using the existing idempotency table. No migration is needed. The native tool key is stable
for the task and validated arguments. New-task repeats also encounter the existing-name duplicate check.
Normal audit and notification behavior is preserved; replay emits no additional mutation.

Confirmed writes update shared stores. Duplicate responses say the item already exists. Network/server
failures and Stop during a write report that it may have saved, rather than claiming success or retrying
automatically. The metadata-only task journal continues to flag interrupted work after relaunch.

## Built-in demo

The server-verified demo uses a small, disclosed text grammar with the same tools and real private-account
persistence. Examples: `Add 2 cartons of milk to inventory`, `Add a coffee grinder to my wishlist`, and
`Add eggs to my Weekend groceries list`. The demo accepts one item per message and numeric quantities;
ordinary accounts use their configured model. Media is not used by the demo grammar. Demo seed/backfill
adds Brown rice, an Electric kettle wishlist item and a Weekend groceries list once, preserving later edits.

See [wishlist](wishlist.md) and [shopping lists](forecasts-and-lists.md) for route-specific behavior.
