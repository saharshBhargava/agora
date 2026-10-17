# "Purchased from": API contract

For wiring the Swift upload screen's **Purchased from** field to the backend. Every example below was captured from
the running server (IDs shortened only where marked).

## 1. Base URL and sign-in

Set it in Xcode as the user-defined build setting `AGORA_API_BASE_URL` (read via `AgoraAPIBaseURL` in
`Info.plist`). The app only accepts **HTTPS** origins, so use one of:

| Environment | Base URL |
|---|---|
| Shared dev deploy | The Render URL once deployed from `render.yaml`, e.g. `https://agora-api.onrender.com` (first request after idle can take ~1 min) |
| Backend on your Mac (simulator or device) | `cloudflared tunnel --url http://localhost:8000` → `https://<random>.trycloudflare.com` (free, no account; the URL changes each run) |

Run the backend locally with `backend/README.md` → "Run locally". If you'd rather skip Docker, point
`AGORA_DATABASE_URL` at a free Tiger Cloud service.

Auth for dev and demo: exchange a handle for a bearer token. Seeded handles are `kedar` and `saharsh`. On a demo
deploy only those work; locally any `[a-z0-9_]{3,32}` handle creates an account.

```http
POST /v1/dev/login
Content-Type: application/json

{"handle": "kedar"}
```
```json
200
{"access_token": "eyJhbGciOiJIUzI1NiIs…", "token_type": "bearer", "expires_at": 1792323170}
```

Send `Authorization: Bearer <access_token>` on every other call. If the backend runs with
`AGORA_AUTH_MODE=google`, use the `ags_…` session token from the Google Calendar onboarding instead (see
`backend/README.md`). Every endpoint here accepts either. Tokens last 12 h; on `401` sign in again. Store the
token in the Keychain like the Gemini key (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). When we move to a real
identity provider, only the login step changes.

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
| `POST /v1/scans` | Upload, with optional form field `purchased_from_merchant_id` |
| `GET /v1/scans/{id}` | Scan with `purchased_from` and each detection's effective store |
| `POST /v1/scans/{id}/review` | Each decision may carry `purchased_from_merchant_id` (a per-product override; `null` = no store) |
| `PATCH /v1/scans/{id}` | Change or clear the whole upload's store, before or after review |
| `PATCH /v1/scans/{id}/detections/{detection_id}` | Change, clear, or reset one product's store |
| `GET /v1/inventory`, `GET /v1/inventory/{id}` | Items carry `last_purchased_from`; detail adds `purchase_history` |
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
  "detections": [],
  "...": "other scan fields omitted here"
}
```

Processing is asynchronous. Either poll `GET /v1/scans/{id}` until `status` is `needs_review`, `confirmed` or
`failed`, or listen on `GET /v1/events` (SSE; your `CaptionSSEByteDecoder` already parses this format) for
`event: scan.updated` with that `id`.

## 5. Per-product stores and corrections

Each detection reports its **effective** store:

```json
{
  "id": "a44ce7b4-cc4a-4b9e-8aac-10b8b2fa2040",
  "label": "large eggs",
  "quantity": 9.0,
  "confidence": 0.9,
  "review": "proposed",
  "purchased_from_merchant_id": "4a7653b9-dad3-431a-9bf8-856f20a273a8",
  "purchased_from": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
  "merchant_override": false
}
```

`merchant_override: false` means "inherits the upload's store". `true` means this product has its own value,
which may be `null` (explicitly no store).

**At review**, for a haul from two stores:

```http
POST /v1/scans/8c09ae03-…/review
{"decisions": [
  {"detection_id": "26002cb6-…", "action": "accept"},
  {"detection_id": "a44ce7b4-…", "action": "accept",
   "purchased_from_merchant_id": "6d5f2079-8e17-4f9a-8dba-e1c0107100d9"}
]}
```

The response's eggs detection then has `"purchased_from": {"name": "Safeway", …}, "merchant_override": true`.
Leave the key out to inherit; send `null` for "no store".

**After the fact**, at any time while the scan is `needs_review` or `confirmed`:

| Goal | Request |
|---|---|
| Change the whole upload's store | `PATCH /v1/scans/{id}` `{"purchased_from_merchant_id": "<uuid>"}` |
| Clear the whole upload's store | `PATCH /v1/scans/{id}` `{"purchased_from_merchant_id": null}` |
| Give one product its own store | `PATCH /v1/scans/{id}/detections/{d}` `{"purchased_from_merchant_id": "<uuid>"}` |
| Mark one product "no store" | `PATCH /v1/scans/{id}/detections/{d}` `{"purchased_from_merchant_id": null}` |
| Put one product back on the upload's store | `PATCH /v1/scans/{id}/detections/{d}` `{"inherit_from_scan": true}` |

Both PATCHes return the full updated scan. Sending both fields, or neither, is a `422`. Changing the upload's store
never touches products that have their own override. For confirmed scans, purchase history updates immediately.

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
  "purchase_history": [
    {"merchant": {"id": "4a7653b9-…", "name": "Trader Joe's", "locality": "U District", "scope": "household"},
     "observed_at": "2026-10-17T23:32:50.747581Z", "quantity": 1.5,
     "scan_id": "8c09ae03-…", "detection_id": "26002cb6-…"}
  ],
  "...": "daily series, observations etc. omitted here"
}
```

`purchase_history` has one entry per confirmed upload where that product had a store, newest first.
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
- `scans.purchased_from_merchant_id`
- `scan_detections.purchased_from_merchant_id` + `merchant_override`
- `inventory_items.preferred_merchant_id`
- New `inventory_purchase_origins` table (one row per confirmed detection with a store, household-scoped by RLS)

`0004_media_objects.sql` is unrelated to this feature: it lets deploys keep upload frames in Postgres so no bucket
account is needed.

## 9. Swift checklist

- [ ] Store picker: `GET /v1/merchants?q=` and "Add" via `POST /v1/merchants` (accept 200 or 201, use `merchant.id`)
- [ ] Save `merchant.id` with the local `CaptureItem` (it's stable)
- [ ] Upload with `purchased_from_merchant_id`, `Idempotency-Key: CaptureItem.id.uuidString`, JPEG frames
- [ ] Review screen: optional per-product store; send the key only when the user changed it
- [ ] Edit later: `PATCH /v1/scans/{id}` and `PATCH /v1/scans/{id}/detections/{d}`
- [ ] Decode `purchased_from` / `last_purchased_from` as optional `MerchantRef`
