# "Purchased from" and "Purchased on": API contract

For wiring the Swift upload screen's **Purchased from** (store) and **Purchased on** (date) fields to the
backend. Setup for the shared server is in [SETUP.md](../../SETUP.md). Every example below was captured from
the running server (IDs shortened only where marked).

## 1. Base URL and sign-in

**Base URL.** Set `AGORA_API_BASE_URL` in `Config/Local.xcconfig` (gitignored; copy it from
`Config/Local.xcconfig.example`), for example `AGORA_API_BASE_URL = https:/$()/agora-api.onrender.com`.
`AgoraClient` reads it from `Info.plist` and only accepts **HTTPS** origins:

| Environment | Base URL |
|---|---|
| Shared dev deploy | The Render URL from [SETUP.md](../../SETUP.md), e.g. `https://agora-api.onrender.com`. The first request after idle can take ~1 min |
| Backend on your Mac (simulator or device) | `cloudflared tunnel --url http://localhost:8000` → `https://<random>.trycloudflare.com` (free, no account; the URL changes each run) |

To run the backend locally, see `backend/README.md` → "Run locally". If you'd rather skip Docker, point
`AGORA_DATABASE_URL` at a free Tiger Cloud service.

**Sign-in from iOS: nothing to add.** `AgoraClient` already sends the Google ID token from native Google
Sign-In as `Authorization: Bearer <id token>`. The deployed backend (`AGORA_AUTH_MODE=google`) verifies it against
the iOS client ID and maps it to the user's Agora account. On `401`, refresh the ID token and retry once.

**Sign-in for curl, the API docs page, or a client without Google sign-in (e.g. desktop).** On demo and local
deploys, exchange a seeded handle (`kedar` or `saharsh`) for a token. On a demo deploy only those work; locally
any `[a-z0-9_]{3,32}` handle creates an account.

```http
POST /v1/dev/login
Content-Type: application/json

{"handle": "kedar"}
```
```json
200
{"access_token": "eyJhbGciOiJIUzI1NiIs…", "token_type": "bearer", "expires_at": 1792323170}
```

Send `Authorization: Bearer <access_token>` on every other call. Dev tokens last 12 h. Every endpoint accepts
either kind of token.

Errors are always `application/problem+json`:

```json
404
{"type": "https://agora.app/problems/not_found", "title": "not_found", "status": 404,
 "detail": "No such merchant.", "request_id": "85c0a698f3ba4008bfd64b5d8933c59b"}
```

`title` is a stable machine code; `detail` is safe to show to the user.

## 2. Endpoints

| Method & path | Purpose |
|---|---|
| `GET /v1/merchants?q=<text>&limit=10` | Search stores by name (exact, then prefix, then fuzzy). Empty `q` lists your household's stores, then global ones |
| `POST /v1/merchants` | Find-or-create a store. `201` = created, `200` = an equivalent store already existed (use its `id`) |
| `GET /v1/merchants/{id}` | Fetch one store |
| `POST /v1/scans` | Upload, with optional form fields `purchased_from_merchant_id` and `purchased_on` |
| `GET /v1/scans/{id}` | Scan with `purchased_from` and each detection's effective store |
| `POST /v1/scans/{id}/review` | Each decision may carry `purchased_from_merchant_id` and/or `purchased_on` (per-product overrides; `null` = none) |
| `PATCH /v1/scans/{id}` | Change or clear the whole upload's store and/or date, before or after review |
| `PATCH /v1/scans/{id}/detections/{detection_id}` | Change, clear, or reset one product's store and/or date |
| `GET /v1/inventory`, `GET /v1/inventory/{id}` | Items carry `last_purchased_from` and `last_purchased_on`; detail adds `purchase_history` |
| `PATCH /v1/inventory/{id}` | `preferred_merchant_id`: the store you *want* to buy from, kept separate from history |

### Merchant object

```json
{
  "id": "4a7653b9-dad3-431a-9bf8-856f20a273a8",
  "name": "Trader Joe's",
  "locality": "U District",
  "kind": "grocery",
  "is_small_business": false,
  "website": null,
  "scope": "household",
  "household_id": "f3afef9d-bf5d-4083-9694-0466f46caf6f"
}
```

- `id` is a stable UUID. It never changes and is safe to cache locally next to your `CaptureItem`.
- `scope`: `global` stores are the shared catalog (Safeway, PCC…). `household` stores were created by someone in
  your household and are visible only to it.
- `locality` is optional and tells branches apart ("Safeway" vs "Safeway · Ballard"). Show it when present.
- `kind`: `grocery | big_box | online | local | other` (default `other`).

Scans, detections and items embed a short form, `MerchantRef`: `{"id", "name", "locality", "scope"}`.

## 3. Picking or creating a store

Suggested UI: a search field calling `GET /v1/merchants?q=` as the user types (debounce ~250 ms). If there's no
good match, offer "Add “<text>”", which calls `POST /v1/merchants`.

```http
GET /v1/merchants?q=safe
```
```json
200
[{"id": "6d5f2079-8e17-4f9a-8dba-e1c0107100d9", "name": "Safeway", "locality": null, "kind": "grocery",
  "is_small_business": false, "website": "https://www.safeway.com", "scope": "global", "household_id": null}]
```

```http
POST /v1/merchants
{"name": "Trader Joe's", "kind": "grocery", "locality": "U District"}
```
```json
201
{"merchant": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "kind": "grocery",
              "is_small_business": false, "website": null, "scope": "household", "household_id": "f3afef9d-…"},
 "created": true}
```

**Duplicates.** Names are compared ignoring case, spacing, apostrophes and punctuation, together with the locality.
Posting an equivalent name returns the existing store with `200` and `"created": false` instead of making a copy.
If a global store matches, the global one wins.

```http
POST /v1/merchants
{"name": "trader joes", "locality": "u-district"}
```
```json
200
{"merchant": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", …}, "created": false}
```

Treat `200` and `201` the same way: take `merchant.id`. Validation: `name` is 1–80 characters and needs a letter or
digit, `locality` is ≤ 80 characters, and `website` must be `https://…`.

## 4. Uploading with a store

`multipart/form-data`, fields:

| Field | Required | Notes |
|---|---|---|
| `files` | yes | 1–12 photos (JPEG/PNG/WebP, ≤ 10 MB each) **or** one MP4/MOV (≤ 80 MB). Convert HEIC to JPEG first. PDFs aren't accepted |
| `purchased_from_merchant_id` | no | Store UUID from §3 |
| `purchased_on` | no | Purchase (receipt) date, `YYYY-MM-DD`. Not in the future, at most two years back. Separate from `captured_at`, since the photo may be taken days after shopping |
| `location_id` | no | Fridge/Pantry ID from `GET /v1/me` → `households[].locations` |
| `captured_at` | no | ISO-8601 **with offset**, within the last 30 days. Defaults to upload time |
| `household_id` | no | Defaults to your first household |

Header `Idempotency-Key` is required (8–128 characters). **Use `CaptureItem.id.uuidString`.** Then a retry after a
dropped connection returns the original scan (`Idempotent-Replay: true`) instead of creating a second one. Reusing
a key with different content returns `422 idempotency_key_reused`.

```json
202
{
  "id": "8c09ae03-3dd9-40ce-8137-cf49d6b31dd4",
  "status": "uploaded",
  "captured_at": "2026-10-17T23:32:50.747581Z",
  "media_kind": "photos",
  "frame_count": 1,
  "purchased_from_merchant_id": "4a7653b9-dad3-431a-9bf8-856f20a273a8",
  "purchased_from": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
  "purchased_on": "2026-10-15",
  "detections": [],
  "...": "other scan fields omitted here"
}
```

Processing is asynchronous. Either poll `GET /v1/scans/{id}` until `status` is `needs_review`, `confirmed` or
`failed`, or listen on `GET /v1/events` (SSE; your `CaptionSSEByteDecoder` already parses this format) for
`event: scan.updated` with that `id`.

## 5. Per-product stores, dates and corrections

Each detection reports its **effective** store and date:

```json
{
  "id": "a44ce7b4-cc4a-4b9e-8aac-10b8b2fa2040",
  "label": "large eggs",
  "quantity": 9.0,
  "confidence": 0.9,
  "review": "proposed",
  "purchased_from_merchant_id": "4a7653b9-dad3-431a-9bf8-856f20a273a8",
  "purchased_from": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
  "merchant_override": false,
  "purchased_on": "2026-10-15",
  "purchased_on_override": false
}
```

`merchant_override` / `purchased_on_override`: `false` means "inherits the upload's value". `true` means this
product has its own value, which may be `null` (explicitly none).

**At review**, for a haul from two stores on two days:

```http
POST /v1/scans/8c09ae03-…/review
{"decisions": [
  {"detection_id": "26002cb6-…", "action": "accept"},
  {"detection_id": "a44ce7b4-…", "action": "accept",
   "purchased_from_merchant_id": "6d5f2079-8e17-4f9a-8dba-e1c0107100d9", "purchased_on": "2026-10-16"}
]}
```

The response's eggs detection then has `"purchased_from": {"name": "Safeway", …}, "merchant_override": true`
and `"purchased_on": "2026-10-16", "purchased_on_override": true`. Leave a key out to inherit; send `null` for
"none".

**After the fact**, at any time while the scan is `needs_review` or `confirmed`:

| Goal | Request |
|---|---|
| Change the whole upload's store | `PATCH /v1/scans/{id}` `{"purchased_from_merchant_id": "<uuid>"}` |
| Change the whole upload's date | `PATCH /v1/scans/{id}` `{"purchased_on": "2026-10-15"}` |
| Clear either | `PATCH /v1/scans/{id}` `{"purchased_from_merchant_id": null}` or `{"purchased_on": null}` |
| Give one product its own store / date | `PATCH /v1/scans/{id}/detections/{d}` `{"purchased_from_merchant_id": "<uuid>", "purchased_on": "2026-10-16"}` (either or both) |
| Mark one product "no store" / "no date" | `PATCH /v1/scans/{id}/detections/{d}` `{"purchased_from_merchant_id": null}` / `{"purchased_on": null}` |
| Put one product back on the upload's values | `PATCH /v1/scans/{id}/detections/{d}` `{"inherit": ["purchased_from", "purchased_on"]}` (either or both) |

Send only the fields you're changing. Both PATCHes return the full updated scan. An empty body, or a field that
is both set and listed in `inherit`, is a `422`. Upload-level changes never touch products with their own
override. For confirmed scans, purchase history updates immediately.

## 6. On the inventory side

Purchase origin and preferred store are separate: you might prefer PCC but bought this batch at Safeway.

```http
GET /v1/inventory/d41729d8-…
```
```json
{
  "id": "d41729d8-93f4-4e32-a681-adb559f3961e",
  "display_name": "2% milk",
  "quantity": 1.5,
  "preferred_merchant_id": null,
  "last_purchased_from": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
  "last_purchased_on": "2026-10-15",
  "purchase_history": [
    {"merchant": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
     "purchased_on": "2026-10-15", "observed_at": "2026-10-17T23:32:50.747581Z", "quantity": 1.5,
     "scan_id": "8c09ae03-…", "detection_id": "26002cb6-…"}
  ],
  "...": "daily series, observations etc. omitted here"
}
```

`purchase_history` has one entry per confirmed upload where that product had a store and/or a date, newest
purchase first (by `purchased_on`, else upload time). Either `merchant` or `purchased_on` can be `null`, but not
both. `observed_at` is when the photo was taken.
`PATCH /v1/inventory/{id}` with `{"preferred_merchant_id": "<uuid>" | null}` sets the preference.

## 7. Permissions

- Any signed-in user can search global stores and their own household's stores, and can create stores. New stores
  are always household-scoped.
- Nobody can create, rename or delete **global** catalog entries through the API. Postgres row-level security and
  grants enforce this, not just the route code, and tests cover it.
- A household's stores are invisible to other households. Attaching another household's store ID, or a store from
  your *other* household, returns `404 not_found` ("No such merchant.").
- All changes are recorded in the hash-chained audit log (`scan.store_changed`, `scan.detection_store_changed`,
  `merchant.created`).

## 8. Migration

`backend/migrations/0005_purchase_origins.sql` (applied automatically on boot):

- `merchants`: adds `household_id` (null = global), `locality`, `created_by`, and generated `normalized_name` /
  `normalized_locality`. Adds unique indexes per scope and row-level security (`SELECT` global + own household;
  `INSERT` own household only).
- `scans.purchased_from_merchant_id`, `scans.purchased_on` (date)
- `scan_detections.purchased_from_merchant_id` + `merchant_override`, `purchased_on` + `purchased_on_override`
- `inventory_items.preferred_merchant_id`
- New `inventory_purchase_origins` table (one row per confirmed detection with a store and/or date, with
  `merchant_id` and `purchased_on` columns, household-scoped by RLS)

`0004_media_objects.sql` is unrelated to this feature: it lets deploys keep upload frames in Postgres so no bucket
account is needed.

## 9. Swift checklist

- [ ] Store picker: `GET /v1/merchants?q=` and "Add" via `POST /v1/merchants` (accept 200 or 201, use `merchant.id`)
- [ ] Save `merchant.id` with the local `CaptureItem` (it's stable)
- [ ] Purchased-on date picker (default today; send `YYYY-MM-DD` in the user's local calendar)
- [ ] Upload with `purchased_from_merchant_id`, `purchased_on`, `Idempotency-Key: CaptureItem.id.uuidString`, JPEG frames
- [ ] Review screen: optional per-product store/date; send a key only when the user changed it
- [ ] Edit later: `PATCH /v1/scans/{id}` and `PATCH /v1/scans/{id}/detections/{d}`
- [ ] Decode `purchased_from` / `last_purchased_from` as optional `MerchantRef`; `purchased_on` / `last_purchased_on` as optional dates
