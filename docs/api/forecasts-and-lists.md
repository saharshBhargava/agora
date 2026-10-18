# Run-out forecasts and shopping lists API

Agora forecasts when each tracked item will run out from its scan history ("your fridge is a time series"),
and turns upcoming run-outs into shopping lists grouped by store. Every forecast carries its evidence and a
plain-language explanation, and every line the system or the agent adds to a list says why it's there.

All routes need `Authorization: Bearer <token>` and return RFC 7807 `application/problem+json` errors.
Changes publish events on `GET /v1/events`: `forecast.updated` (id = household) after a recompute, and
`list.updated` (id = list) whenever a list or one of its lines changes.

The examples below were captured from the app running against the seeded three-week demo history (`kedar`
dev account, time zone `America/Los_Angeles`, captured on Friday 17 Oct 2026 at 17:38 PDT). IDs and
timestamps will differ. Long responses are trimmed where marked.

## Contents

- [Endpoints](#endpoints)
- [How forecasts are made](#how-forecasts-are-made)
- [Forecast shape](#forecast-shape)
- [Run-outs](#run-outs)
- [Forecast on the item detail](#forecast-on-the-item-detail)
- [Shopping lists](#shopping-lists)
- [Generating lists from run-outs](#generating-lists-from-run-outs)
- [Errors](#errors)
- [Security notes](#security-notes)

## Endpoints

| Route | What it does |
|---|---|
| `GET /v1/forecasts/runouts?within=7d` | Items that run out within the window, soonest first, with forecast, explanation and suggested store |
| `GET /v1/inventory/{id}` | Item detail. Now includes `forecast` (or `null` before the first reading) |
| `GET /v1/lists?status=open` | Lists with their lines. Repeat `status` for several (`open`, `done`, `archived`) |
| `POST /v1/lists` | Create a list, optionally for a store |
| `GET /v1/lists/{id}` | One list |
| `PATCH /v1/lists/{id}` | Rename, change store, or set `status` to `open` / `done` / `archived` |
| `POST /v1/lists/{id}/items` | Add a line (free text, or linked to an inventory item or product) |
| `PATCH /v1/lists/{id}/items/{item_id}` | Edit a line, or tick it off with `checked` |
| `DELETE /v1/lists/{id}/items/{item_id}` | Delete a line (204) |
| `POST /v1/lists/generate` | Build per-store lists from upcoming run-outs. **`Idempotency-Key` required** |

`household_id` is optional on every route and defaults to your first household.

## How forecasts are made

The math is in `backend/app/core/forecast.py` (pure functions, unit-tested in `tests/test_forecast_core.py`).

1. **Daily series.** `app/timeseries.py` regularizes irregular scans into one end-of-day level per day
   (`time_bucket_gapfill` + `locf` on TimescaleDB, `generate_series` on plain Postgres), and counts the
   readings on each day. Only days with readings are used for slopes, so carried-forward days don't drag the
   rate towards zero when scans are sparse.
2. **Segment at restocks.** A jump up bigger than reading noise (more than 0.25 units *and* 15% of the level)
   starts a new depletion segment. Readings after an item first hits zero are ignored within a segment.
3. **Rate.** Theil–Sen slope (median of pairwise slopes) per segment, so one misread can't move it. Segments
   are combined with recency weights (half-life 14 days).
4. **Cold start.** Until an item has 8 informative readings, a category prior scaled by household size is
   blended in: `r = (k·r_prior + n·r_obs) / (k + n)` with `k = 3`. With one reading only, the prior is used
   alone (`method: "prior"`).
5. **Run-out** = last reading's time + last quantity / rate. The interval comes from the quartiles of pairwise
   slopes within segments, widened by the disagreement between segments. Run-outs more than a year out get
   no date.

Forecasts are recomputed by the job queue after every confirmed scan and manual reading (for the items
touched), and nightly at 10:00 UTC for every household. Every recompute is kept in the
`consumption_forecasts` hypertable, so "forecast vs actual" can be charted later. Reads always use the latest
one, with `status`, `qty_now` and `explanation` worked out at request time in your time zone.

## Forecast shape

```json
{
  "computed_at": "2026-10-18T00:38:37.356749Z",
  "method": "theil_sen",
  "status": "runs_out",
  "confidence": "high",
  "rate_per_day": 0.1861,
  "rate_lo": 0.1717,
  "rate_hi": 0.1982,
  "qty_now": 1.059,
  "last_observed_at": "2026-10-17T19:19:00Z",
  "last_quantity": 1.1,
  "runout_at": "2026-10-23T17:10:27.985845Z",
  "runout_lo": "2026-10-23T08:31:11.957210Z",
  "runout_hi": "2026-10-24T05:04:59.835119Z",
  "n_obs": 21,
  "n_segments": 3,
  "span_days": 20.0,
  "restock_qty": 1.48,
  "explanation": "2% milk will run out on Fri. Based on 21 scans over 20 days, you use about one every 5.4 days."
}
```

| Field | Meaning |
|---|---|
| `method` | `theil_sen` (own history), `blended` (history + category prior), `prior` (one reading, prior only), `insufficient` (no rate) |
| `status` | `out` (probably already out), `runs_out` (has a date), `steady` (not being used up, or not within a year), `unknown` (`insufficient`) |
| `confidence` | `low` / `medium` / `high`, from the amount of history and the width of the rate interval. `prior` is always `low` |
| `rate_per_day`, `rate_lo`, `rate_hi` | Use per day in the item's `unit`, with an interval. `null` when `insufficient` |
| `qty_now` | Estimated amount on hand right now, projected from the last reading |
| `last_observed_at`, `last_quantity` | The reading the run-out is anchored to |
| `runout_at`, `runout_lo`, `runout_hi` | When it runs out, earliest and latest plausible. `null` if not within a year |
| `n_obs`, `n_segments`, `span_days` | The evidence: readings used, depletion runs, days covered |
| `restock_qty` | Typical amount added at a restock (median of past jumps); drives `suggested_quantity` |
| `explanation` | One or two sentences, safe to show as-is. Interval days are omitted when they'd repeat the date |

Example explanations for each state. The first two are from the seeded demo above; the rest are the exact
output for the fixtures in `tests/test_forecast_core.py` (viewed on Friday 16 Oct 2026, 8pm PDT):

- `Greek yogurt will run out on Tue. Based on 21 scans over 20 days, you use about one every 4.2 days.`
- `Sparkling water will run out on Tue (Tue–Wed). Based on 21 scans over 20 days, you use about 1.3 a day.`
- `Strawberries probably ran out (last seen yesterday). Based on 5 scans over 4 days, you use about one every 4 days.`
- `No run-out expected for olive oil. Based on 10 scans over 9 days, the level has held steady.`
- `Rice won't run out for a long while. Based on 20 scans over 19 days, you use about 0.01 lb/day.`
- `Yogurt will run out on Tue (Sun–Oct 24). Based on 2 scans over 1 day plus typical use while history is short, you use about one every 2.5 days.`
- `Butter will run out around Tue (Sun–Oct 25), assuming typical use for a 2-person household (about one every 3.3 days). Scan it a few more times to personalize this.`
- `Not enough history to forecast jam yet. Scan it a couple more times.`

## Run-outs

### `GET /v1/forecasts/runouts?within=7d`

`within` is `1d` to `90d` (default `7d`). Returns active items whose latest forecast runs out before
`as_of + within`, soonest first; items that have probably already run out come first. Each has:

- `item`: the same shape as `GET /v1/inventory` rows.
- `forecast`: as above.
- `suggested_quantity`: top-up to `par_level` if set, else the typical restock (`restock_qty`, rounded), else 1.
- `suggested_merchant` + `merchant_basis`: the item's `preferred_merchant_id` (`"preferred"`), else the store
  it was last bought at from the purchase history (`"last_purchase"`), else `null`.
- `on_list_id`: an open shopping list that already has this item unticked, or `null`.

Response (trimmed to the first 2 of 8):

```json
{
  "household_id": "27f2d32f-3c9d-4c4d-8f78-de27291d2a4e",
  "within_days": 7,
  "as_of": "2026-10-18T00:38:37.514340Z",
  "runouts": [
    {
      "item": {
        "id": "bfa8de09-9163-4e03-986b-84f575e623b8",
        "household_id": "27f2d32f-3c9d-4c4d-8f78-de27291d2a4e",
        "display_name": "strawberries",
        "category": "produce",
        "location_id": "b38dcfd9-6813-4861-868b-7520f00fedd9",
        "unit": "unit",
        "par_level": null,
        "status": "active",
        "product_id": "8143e4a6-dca0-43b1-9435-14a7495d783b",
        "quantity": 0.1,
        "observed_at": "2026-10-17T19:19:00Z",
        "source": "scan",
        "preferred_merchant_id": null,
        "last_purchased_from": null,
        "last_purchased_on": null
      },
      "forecast": {
        "computed_at": "2026-10-18T00:38:37.356749Z",
        "method": "theil_sen",
        "status": "runs_out",
        "confidence": "high",
        "rate_per_day": 0.3667,
        "rate_lo": 0.338,
        "rate_hi": 0.3943,
        "qty_now": 0.019,
        "last_observed_at": "2026-10-17T19:19:00Z",
        "last_quantity": 0.1,
        "runout_at": "2026-10-18T01:51:44.641178Z",
        "runout_lo": "2026-10-18T01:24:11.177034Z",
        "runout_hi": "2026-10-18T02:25:05.067452Z",
        "n_obs": 21,
        "n_segments": 4,
        "span_days": 20.0,
        "restock_qty": 1.7,
        "explanation": "Strawberries will run out today. Based on 21 scans over 20 days, you use about one every 2.7 days."
      },
      "suggested_quantity": 2.0,
      "suggested_merchant": null,
      "merchant_basis": null,
      "on_list_id": null
    },
    {
      "item": { "display_name": "baby spinach", "…": "…" },
      "forecast": {
        "status": "runs_out",
        "runout_at": "2026-10-18T17:10:10.452320Z",
        "explanation": "Baby spinach will run out tomorrow. Based on 21 scans over 20 days, you use about one every 3 days.",
        "…": "…"
      },
      "suggested_quantity": 1.0,
      "suggested_merchant": null,
      "merchant_basis": null,
      "on_list_id": null
    }
  ]
}
```

## Forecast on the item detail

`GET /v1/inventory/{id}` has a new `forecast` field with the shape above (trimmed):

```json
{
  "id": "0ff7a238-ac17-49d2-95ad-b5455aa9288e",
  "display_name": "2% milk",
  "quantity": 1.1,
  "observed_at": "2026-10-17T19:19:00Z",
  "daily": ["…"],
  "observations": ["…"],
  "purchase_history": [],
  "series_engine": "postgres",
  "forecast": {
    "computed_at": "2026-10-18T00:38:37.356749Z",
    "method": "theil_sen",
    "status": "runs_out",
    "confidence": "high",
    "rate_per_day": 0.1861,
    "runout_at": "2026-10-23T17:10:27.985845Z",
    "runout_lo": "2026-10-23T08:31:11.957210Z",
    "runout_hi": "2026-10-24T05:04:59.835119Z",
    "explanation": "2% milk will run out on Fri. Based on 21 scans over 20 days, you use about one every 5.4 days.",
    "…": "…"
  }
}
```

`forecast` is `null` for an item with no readings yet. After a scan is confirmed the forecast lands within a
second or two (it's computed by the worker); refetch on the `forecast.updated` event.

## Shopping lists

### List shape

```json
{
  "id": "530c12f7-0be5-4369-94ab-8b898bfc923b",
  "household_id": "27f2d32f-3c9d-4c4d-8f78-de27291d2a4e",
  "name": "Party supplies",
  "merchant": null,
  "status": "open",
  "source": "user",
  "needed_by": null,
  "open_count": 0,
  "items": [],
  "created_at": "2026-10-18T00:38:37.660906Z",
  "updated_at": "2026-10-18T00:38:37.660906Z",
  "completed_at": null
}
```

- `source`: `user` (made by hand) or `generated` (by `POST /v1/lists/generate`).
- `merchant`: the store, as `{id, name, locality, scope}`, or `null`.
- `needed_by`: the earliest `needed_by` among unticked lines: the deadline for the trip.
- `open_count`: unticked lines. `items` are ordered unticked first, then by `needed_by`, then by age.
- `GET /v1/lists` returns open lists first, soonest `needed_by` first (at most the 100 most recent).

### Line shape

| Field | Meaning |
|---|---|
| `title`, `quantity`, `unit`, `note` | What to buy. `unit` is `null` for plain counts |
| `inventory_item_id`, `product_id` | Links, when known |
| `reason` | `runout` (generated), `manual` (user), `agent` (on-device agent), `price_drop` (reserved for price alerts) |
| `added_by` | `user`, `agent` or `system` |
| `explanation` | Always present unless `added_by` is `user` |
| `merchant`, `merchant_basis` | Where it'll probably be bought and why: `preferred`, `last_purchase`, or `list` (the list's own store) |
| `needed_by` | Forecast run-out when the line was added |
| `checked`, `checked_at` | Ticked off |

### `POST /v1/lists`

```json
{"name": "Party supplies"}
```

→ `201` with the list shape above. `merchant_id` is optional; if you send one without a `name`, the list is
named after the store (`"Safeway"`, or `"Safeway (Ballard)"` with a locality). With neither, it's
`"Shopping list"`. A household can have 50 open lists.

### `POST /v1/lists/{id}/items`

Free text:

```json
{"title": "Birthday candles", "quantity": 2, "note": "blue ones"}
```

```json
{
  "id": "6b22a9a2-6be2-46de-84b1-f390d46f92b6",
  "list_id": "530c12f7-0be5-4369-94ab-8b898bfc923b",
  "title": "Birthday candles",
  "inventory_item_id": null,
  "product_id": null,
  "quantity": 2.0,
  "unit": null,
  "note": "blue ones",
  "reason": "manual",
  "added_by": "user",
  "explanation": null,
  "merchant": null,
  "merchant_basis": null,
  "needed_by": null,
  "checked": false,
  "checked_at": null,
  "created_at": "2026-10-18T00:38:37.670635Z",
  "updated_at": "2026-10-18T00:38:37.670635Z"
}
```

Linked to an inventory item (title, unit and product are filled in):

```json
{"inventory_item_id": "f6da474a-1bec-4428-b3d2-1dd8f51d1a66", "quantity": 12}
```

```json
{
  "id": "093d9491-204e-476b-be40-350c9080054f",
  "title": "sparkling water",
  "inventory_item_id": "f6da474a-1bec-4428-b3d2-1dd8f51d1a66",
  "product_id": "64863aec-90bd-40a3-a7ea-548697317362",
  "quantity": 12.0,
  "reason": "manual",
  "added_by": "user",
  "…": "…"
}
```

From the on-device agent, which must say why (audited with actor `agent`):

```json
{"title": "Paper plates", "added_by": "agent", "explanation": "You're hosting Saturday and have none left."}
```

→ a line with `"reason": "agent", "added_by": "agent"`.

Rules: send a `title`, `inventory_item_id` or `product_id`; `quantity` is above 0 and at most 1000; a list
holds 200 lines; the same inventory item can't be on one list twice unticked (`409 already_on_list`).

### `PATCH /v1/lists/{id}/items/{item_id}`

Send only what changed: `title`, `quantity`, `unit`, `note`, `checked`.

```json
{"checked": true}
```

```json
{"id": "6b22a9a2-6be2-46de-84b1-f390d46f92b6", "checked": true, "checked_at": "2026-10-18T00:38:37.700368Z", "…": "…"}
```

### `DELETE /v1/lists/{id}/items/{item_id}`

`204`, no body.

### `PATCH /v1/lists/{id}`

```json
{"status": "done"}
```

```json
{"id": "530c12f7-0be5-4369-94ab-8b898bfc923b", "name": "Party supplies", "status": "done", "open_count": 2,
 "completed_at": "2026-10-18T00:38:37.715772Z", "…": "…"}
```

`done` and `archived` lists are read-only until set back to `open` (`409 list_closed`). Lists are never
deleted.

## Generating lists from run-outs

### `POST /v1/lists/generate`

Headers: `Idempotency-Key: <8-128 chars>` (required). Body (all optional):

```json
{"within_days": 7, "include_unassigned": true, "household_id": null}
```

For every item that runs out within `within_days` (1-30, default 7):

1. If it's already unticked on an open list, it's skipped (`already_on_list`). Running generate again only
   adds what's new.
2. Otherwise it goes to a list for its store: `preferred_merchant_id`, else the store it was last bought at,
   else a store-less **Groceries** list (or skipped as `no_store` with `include_unassigned: false`).
3. The line is added to that store's open *generated* list, creating one if needed. It gets
   `reason: "runout"`, `added_by: "system"`, `needed_by` = the forecast run-out, the suggested quantity, and
   an explanation: the forecast's sentence plus the store reason.

Response (`200`; the Groceries list trimmed to 1 of 7 lines):

```json
{
  "lists": [
    {
      "id": "46dc52d5-47ee-4304-8b5a-667aa0aa51e0",
      "household_id": "27f2d32f-3c9d-4c4d-8f78-de27291d2a4e",
      "name": "Safeway",
      "merchant": {"id": "b3a28eec-5ec7-4085-967e-5e678335b495", "name": "Safeway", "locality": null, "scope": "global"},
      "status": "open",
      "source": "generated",
      "needed_by": "2026-10-18T01:51:44.641178Z",
      "open_count": 1,
      "items": [
        {
          "id": "039999e6-9a62-4ddd-a1fb-df43fa466791",
          "list_id": "46dc52d5-47ee-4304-8b5a-667aa0aa51e0",
          "title": "strawberries",
          "inventory_item_id": "bfa8de09-9163-4e03-986b-84f575e623b8",
          "product_id": "8143e4a6-dca0-43b1-9435-14a7495d783b",
          "quantity": 2.0,
          "unit": null,
          "note": null,
          "reason": "runout",
          "added_by": "system",
          "explanation": "Strawberries will run out today. Based on 21 scans over 20 days, you use about one every 2.7 days. Your usual store is Safeway.",
          "merchant": {"id": "b3a28eec-5ec7-4085-967e-5e678335b495", "name": "Safeway", "locality": null, "scope": "global"},
          "merchant_basis": "preferred",
          "needed_by": "2026-10-18T01:51:44.641178Z",
          "checked": false,
          "checked_at": null,
          "created_at": "2026-10-18T00:38:37.599704Z",
          "updated_at": "2026-10-18T00:38:37.599704Z"
        }
      ],
      "created_at": "2026-10-18T00:38:37.599704Z",
      "updated_at": "2026-10-18T00:38:37.599704Z",
      "completed_at": null
    },
    {
      "id": "76a53e78-0e1c-4743-8e24-3e5d72aa06fa",
      "name": "Groceries",
      "merchant": null,
      "source": "generated",
      "needed_by": "2026-10-18T17:10:10.452320Z",
      "open_count": 7,
      "items": [
        {
          "title": "baby spinach",
          "quantity": 1.0,
          "reason": "runout",
          "added_by": "system",
          "explanation": "Baby spinach will run out tomorrow. Based on 21 scans over 20 days, you use about one every 3 days.",
          "merchant": null,
          "merchant_basis": null,
          "needed_by": "2026-10-18T17:10:10.452320Z",
          "…": "…"
        }
      ],
      "…": "…"
    }
  ],
  "added": 8,
  "skipped": []
}
```

An item last bought elsewhere gets `"merchant_basis": "last_purchase"` and an explanation ending
`Last bought at QFC.`

Retrying with the **same key and body** returns the stored response with header `Idempotent-Replay: true`
and does no work. The same key with a different body is `422 idempotency_key_reused`. A **new key** after
everything is listed:

```json
{
  "lists": [],
  "added": 0,
  "skipped": [
    {"inventory_item_id": "bfa8de09-9163-4e03-986b-84f575e623b8", "title": "strawberries",
     "reason": "already_on_list", "list_id": "46dc52d5-47ee-4304-8b5a-667aa0aa51e0"},
    {"inventory_item_id": "322c18b1-1fe5-4631-909c-9097df2eeda6", "title": "baby spinach",
     "reason": "already_on_list", "list_id": "76a53e78-0e1c-4743-8e24-3e5d72aa06fa"}
  ]
}
```

(trimmed to 2 of 8). Ticking a line off frees that item to be generated again.

## Errors

| Status | `title` | When |
|---|---|---|
| 400 | `idempotency_key_required` | `POST /v1/lists/generate` without a valid `Idempotency-Key` |
| 404 | `not_found` | List, line, inventory item, product, merchant or household not found or not yours |
| 409 | `already_on_list` | The inventory item is already unticked on this list |
| 409 | `list_closed` | Changing a `done` or `archived` list. Reopen it first |
| 409 | `list_full` / `too_many_lists` | 200 lines per list / 50 open lists per household |
| 409 | `duplicate_request` | A concurrent generate with the same key is still running; retry |
| 422 | `invalid_within` | `within` isn't `1d`-`90d` |
| 422 | `idempotency_key_reused` | Same `Idempotency-Key`, different body |
| 422 | `invalid_request` | Schema validation (unknown fields are rejected), or null for a required field |

Captured examples:

```json
{"type": "https://agora.app/problems/invalid_within", "title": "invalid_within", "status": 422,
 "detail": "within must look like '7d', between 1d and 90d.", "request_id": "30d77850e11548b3a252eef38d1b7f2f"}
```

```json
{"type": "https://agora.app/problems/already_on_list", "title": "already_on_list", "status": 409,
 "detail": "That item is already on this list.", "request_id": "e900b18b83c949e0b98a5333cc1ed54b"}
```

```json
{"type": "https://agora.app/problems/list_closed", "title": "list_closed", "status": 409,
 "detail": "This list is done. Reopen it to change it.", "request_id": "e830e3e2868f41c8a317f2bfdfc4abdc"}
```

## Security notes

- `consumption_forecasts`, `shopping_lists` and `shopping_list_items` have row-level security limited to the
  caller's households. A composite foreign key keeps every line in its list's household, and linked inventory
  items and stores are checked against the list's household.
- Forecast history is append-only for the request role (`SELECT, INSERT` only). Lists can't be deleted, only
  archived. Lines can.
- Recompute jobs run as a member of the household (`db.scoped`), so RLS bounds the worker like a request. The
  nightly fan-out is the only cross-household step, and it only enqueues jobs.
- Agent and system lines must carry an explanation (checked by the API and by database constraints).
- Audit entries record only actions, enums and counts, never titles, notes or explanations:
  `list.created`, `list.updated` (field names and status), `list.item_added` (actor `agent` for agent lines),
  `list.item_updated` (field names), `list.item_removed`, `list.generated` (window and counts).
- SSE events carry only `{household_id, type, id}`. Clients refetch through the API.
