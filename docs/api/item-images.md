# Item images

Inventory, wishlist/suggestion and shopping-list item responses include `image_path`, a relative Agora API
path returning an image descriptor. Native watch cards and offers use their parent wishlist image; this is
the matched or user-selected image of the watched item, not evidence of current retailer stock.

Items without a relevant downloaded image show a neutral “No matching image found” placeholder.
Demo artwork is labeled as sample imagery and never counts as an exact match. Product discovery is asynchronous and
never blocks creating/saving an item. Native recognition still saves metadata only; retaining a photo is a
separate, explicit action in **Change image**. Tap or long-press an item's thumbnail for the same image editor.

## Routes

| Route | Behavior |
|---|---|
| `GET /v1/item-images/{kind}/{item_id}` | Authenticated, household-scoped descriptor; kind is `inventory`, `wishlist`, or `list` |
| `PUT /v1/item-images/{kind}/{item_id}` | Select a photo or discovered candidate, clear an image, or request automatic discovery; `Idempotency-Key` required |
| `GET /v1/item-images/assets/{id}` | Authenticated image bytes; private photos and sample assets require household membership |
| `GET /v1/item-images/fallback/{name}` | Public, cacheable bundled PNG illustration; fixed category names only |

Descriptor example:

```json
{
  "status": "ready",
  "match_status": "exact",
  "display_path": "v1/item-images/assets/00000000-0000-0000-0000-000000000001",
  "fallback": "milk",
  "asset": {
    "id": "00000000-0000-0000-0000-000000000001",
    "path": "v1/item-images/assets/00000000-0000-0000-0000-000000000001",
    "source_url": "https://manufacturer.example/product",
    "attribution": "Product image from source website",
    "match_kind": "product",
    "verification": {
      "version": 2, "status": "exact", "basis": "gtin",
      "requested": {"name": "Product name", "gtin": "00036000291452"},
      "observed": {"name": "Product name", "gtins": ["00036000291452"]},
      "image_binding": "Product.image", "visual_check": "not_performed"
    }
  },
  "choices": [],
  "user_selected": false,
  "inherited": false,
  "version": 1
}
```

`status` is `queued`, `ready`, or `fallback` for transport compatibility. `display_path` is null when no
accepted image exists. `match_status` is `exact`, `best_match`, `user_confirmed`, `demo`, or `unresolved`; only `exact`
establishes an automatic source-backed product match. `identity`, `missing_identity`, and `unresolved_reason`
explain what is known. Unresolved reasons include `search_pending` and `no_verified_match`.
`best_match` means the server automatically selected its best relevant image without claiming an exact SKU
verification. It returns `status: ready`, `asset` and `display_path`, with `user_selected: false`.
Each alternative in `choices` includes a readable `title`; these are optional overrides under **Change image**.
No confirmation or product-version selection is required to display an image.
An uploaded photo or explicit choice is user-confirmed, not automatically verified.
`asset` is nullable. `match_kind` distinguishes `product`, `representative`, and `photo`. Each automatic asset
includes `verification` with version 2, exact or candidate status, match basis, requested/observed attributes, image binding,
and visual-check outcome. This records source evidence, not a guarantee that published metadata or packaging
is current. Old assets without this evidence are hidden from automatic display and candidate selection. Source attribution records
provenance; it is not a claim that the source grants a particular license.

Selection bodies are strict and mode-specific:

```json
{"mode":"representative"}
{"mode":"automatic"}
{"mode":"candidate","asset_id":"00000000-0000-0000-0000-000000000001"}
{"mode":"photo","photo":"<base64 JPEG, PNG or WebP>"}
```

Photos must decode to at most 5 MB, are resized to a maximum 512-pixel side and re-encoded without EXIF.
Images must have an 80-pixel minimum side after resizing, an aspect ratio at most 4:1, and at most 500 KB
stored size. Native Photos selection prepares a resized JPEG first. Unknown or another item's candidate
IDs are rejected. User choices are preserved across item edits and background work. Returning to automatic
mode restores inheritance for linked list/wishlist items; repeat searches are subject to a one-minute
cooldown when repeating automatic discovery without changing identity. Successful retries with the same key return the original result without another asset or job.

## Discovery and persistence

Migration `0017_item_images.sql` creates assets, household image bindings and a shared lookup lease/cache.
Migration `0018_exact_item_images.sql` adds identity and verification evidence, invalidates earlier automatic
product matches and queues re-verification. Explicit choices and demo artwork are preserved.
Additive triggers queue `image.resolve` jobs for new items and identity changes, including recognition saves,
agent suggestions and generated lists. Existing items receive a one-time backfill. A watch product-link
change invalidates its parent's automatic image. Deleted items cascade their bindings; household deletion
also removes private assets. Public product thumbnails are shared by full product identity, variant, source URL and verification version; private photos
never enter that cache. Snapshot import suppresses creation triggers, restores images verbatim, backfills
older snapshots, and requeues pending image work.

Linked wishlist/list items inherit inventory imagery unless explicitly overridden with a selected image or
product identity. Catalog identity may inform matching, but catalog image URLs cannot bypass verification. A 90-day positive cache and seven-day negative cache avoid repeated work; explicit
Search for product images can retry a negative result. A two-minute lease deduplicates concurrent requests for
the same identity. Waiting jobs defer up to three times; ordinary job failures have two attempts. The
existing API-process or standalone worker repairs missing pending jobs at boot (including jobs consumed
by an older release during deployment) and executes them; no additional service or periodic schedule is used.

Discovery reuses `PriceSearchProvider`, `WebSearchRouter`, the public page reader and the Gemini or
OpenAI-compatible reasoning transport configured for watches. With a configured reasoning model, the agent
chooses `web_search`, `web_fetch`, and `select_image`. Without one, search and extraction run deterministically.
Neither path uses phone model credentials. A known product page can be read without search credentials.

Each attempt has a 90-second deadline, at most two searches, six provider requests, six page reads,
six research model turns, three image downloads and up to three visual-check calls. Only known manufacturer pages, supplied product URLs, discovered URLs
and native-extracted candidate IDs are accepted. The model cannot bypass identity checks.

Every nonempty item name is searchable, including short names, generic items and non-English text.
Brand, model, size and barcode are optional search refinements, never eligibility requirements. Two bounded
queries can expand aliases (for example PS5 → PlayStation 5), or add product-image terms. These hints do
not restrict discovery to known products. The server always evaluates results against the original identity.

JSON-LD `Product.image`, descriptive image alt text and Open Graph images supply candidates. Banners,
logos, accessories and explicit conflicting attributes are filtered out. Distinct titles/versions are
prioritized before alternate angles. Manufacturer landing-page hints help PS5 and Xbox Series X even
when their pages omit JSON-LD. Generic “Milk” is searched and receives the best relevant result; this does not change the item’s saved brand or identity.

A valid matching GTIN or consistent complete product identity can establish an automatic exact match.
A precise branded product name bound to structured Product metadata (or an exact named product on its
known official page) can establish a `product_name` match with `scope: named_product`; this is not a claim
of SKU/barcode verification. Extra/unspecified variants remain `candidate` evidence with
`scope: name_candidate`. Social metadata is always candidate evidence. Both kinds can be selected automatically;
selection never upgrades the underlying verification evidence. Specified attributes must agree, including
quantities and equivalent units. Ranking prefers exact identity, known official sources, structured metadata,
and standard versions over unspecified special editions, bundles or refurbished variants. Distinct products
are downloaded before repeat angles. Users can optionally choose another image, refine the text, or upload a photo.

Discovery returns evidence already collected after 60 seconds, reserving the remainder of the 90-second
job deadline for image downloads. Each search has a 15-second limit. Known pages are read first so a slow
search service does not discard useful evidence. Cache keys include search version 3, so earlier negative
results cannot suppress the broader search.

When a reasoning model is configured, the sanitized public image bytes are also inspected for product,
variant, readable label conflicts, logos/accessories and collages. An uncertain, inconsistent or malformed
visual result rejects the candidate. Visual inspection can veto a metadata match but cannot rescue a failed
identity check. Without a model, only source metadata is verified and evidence explicitly records
`visual_check: not_performed`. The OpenAI-compatible model must support image input for this check; an
unsupported model leaves the image unresolved. Private user uploads never go through this model call.

Page content and model output remain untrusted. Unsupported sources stay unresolved; relevant candidates receive an automatic default.

Image downloads validate and pin public DNS addresses, verify TLS for the source hostname, revalidate
redirects, refuse private network targets, cap bytes and decode/re-encode the actual image. Merchant/image
requests carry no account tokens, model keys or user cookies. API image bytes use private/no-store caching;
the native store caches in memory and clears on account/household changes. Its transport accepts only
UUID-based Agora asset paths, so credentials cannot be sent to an image's external source.

Every selection writes an audit event without personal content and emits `image.updated`. Job completion
also emits `image.updated`; version checks prevent stale work replacing a renamed item or user override.
Native visible thumbnails poll pending work for up to 90 seconds and retain a neutral unavailable placeholder on errors.
The local native recovery change continues checking while visible and active; it requires a rebuilt app.

The designated demo account receives deterministic Agora illustrations and never makes external image
searches. Seed/backfill is idempotent and preserves user overrides. The image editor labels sample and
representative imagery truthfully.

## Supplying exact product details

The native image editor supports the following request. Identity fields are stored separately from the item
name and remain household-scoped; renaming the item invalidates their use so old details cannot identify a
new item. Empty optional fields should be omitted. Pack count must be an integer from 1 to 1000; barcode
check digits are validated. Product identity is accepted only in automatic mode. Existing idempotency,
authorization and version checks apply to identity changes and all resulting jobs.

```json
{
  "mode": "automatic",
  "identity": {
    "name": "Fairlife Whole Milk",
    "brand": "Fairlife",
    "variant": "Whole",
    "size": "52 fl oz",
    "pack_count": 1
  }
}
```

Optional `model`, `color`, and `gtin` fields support appliances/electronics and barcode identification.
A GTIN identifies the product even when other details are unknown, but cannot override contradictory
provided attributes. Stored quantity (how many the household owns) is never treated as package size/count.
The legacy `representative` selection mode now clears the image; the app labels that action “Remove image”.
The public category illustration endpoints remain available for compatibility, but unresolved descriptors
have no display image and ordinary app thumbnails do not use that artwork as product imagery.

## Automatic defaults for existing items

At worker startup, existing unresolved bindings with usable saved candidates receive the best image without
new web searches. This is idempotent, emits `image.updated`, and increments the binding version so an old
worker cannot undo the selection. Explicit choices, removals and photos are preserved. New searches and
shared-cache results use the same ranking. No additional schema migration is needed. Clients must render
a version-2 candidate asset when the descriptor says `best_match`, and retain **Change image** as an override.

Active inventory also repairs missing image bindings at worker startup and when `GET /v1/inventory` loads
the household. Empty automatic results older than seven days are queued again during those checks.
Startup retries unresolved inventory from older search versions when no current lookup cooldown exists.
The same bounded online discovery, cache, automatic selection and authenticated image bytes used for
suggestions and watches handle these jobs; users need not edit or recreate an existing inventory item.
Recovery is idempotent and preserves ready images, photos, explicit removals and saved alternatives.
Demo seed/backfill repairs missing inventory bindings with labeled sample illustrations, without web searches.
