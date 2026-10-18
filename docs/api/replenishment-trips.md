# Replenishment trips

All endpoints require the normal Agora Bearer credential. Migration `0015_replenishment_trips.sql` is
required. Calendar access stays on the phone: these endpoints persist an approved reservation and the
device's reported result, and make no Calendar or model requests.

## Flow

1. Call the existing `POST /v1/lists/generate` with an `Idempotency-Key`, then fetch `GET /v1/lists`.
2. On the phone, check primary Calendar free/busy and choose a future slot for each nonempty store list.
3. Show the list and exact proposed event details for user review.
4. Reserve the approved trip with `POST /v1/trips`, using one key for that approval. If the response is
   lost, reload `GET /v1/trips` to recover the durable reservation before proposing another request.
5. Use the reservation's `id` as the native Calendar task ID and derive the request key with
   `CalendarCall.requestKey(taskID: trip.id)`, using its exact event fields for the existing Calendar
   create/recovery flow. Keep that key through retries and restarts.
6. Report the result with `PATCH /v1/trips/{id}/outcome`, then refetch trips. A reservation alone does
   not indicate that an event was created. An uncertain write remains blocked until the same event is
   verified; do not create a new event or report failure to clear uncertainty.

The designated account uses its existing private Calendar implementation for free/busy and event
creation. Ordinary accounts use their native Calendar connection. The persistence API behaves identically
for both and never creates simulated events for ordinary users.

## Fetch trips

`GET /v1/trips?household_id=UUID` returns an array, newest reservation first, including completed and
failed history. Omit `household_id` to use the user's first household. Household members see the same
trips and `mine` identifies the current user's reservations. Foreign households return 404.

```json
{
  "id": "7f63dbdd-ff22-434e-a4fb-f76c9722984d",
  "household_id": "149f4b14-21dc-40bc-ab69-e7a89731e746",
  "list_id": "838932ed-85c0-4bab-8054-4dfbe3f3c443",
  "user_id": "03b1846c-74e0-4415-9912-b2674f263a44",
  "mine": true,
  "list_name": "PCC groceries",
  "start": "2026-10-20T17:00:00-07:00",
  "end": "2026-10-20T17:45:00-07:00",
  "timezone": "America/Los_Angeles",
  "title": "Groceries at PCC",
  "description": "Pick up milk and apples.",
  "location": "PCC Community Markets",
  "status": "reserved",
  "event_id": null,
  "event_url": null,
  "created_at": "2026-10-18T01:00:00Z",
  "updated_at": "2026-10-18T01:00:00Z"
}
```

`list_name` is the approved list's name at reservation time. The exact submitted `start` and `end`
strings, including offsets and fractional precision, survive database storage and refetch. This keeps
the native Calendar request fingerprint stable through a restart. Event content is household-visible;
no Calendar credentials are stored in trips.

## Reserve

`POST /v1/trips`, required `Idempotency-Key` (8–128 printable ASCII characters), returns 201 and a Trip.

```json
{
  "list_id": "838932ed-85c0-4bab-8054-4dfbe3f3c443",
  "list_updated_at": "2026-10-18T00:59:01.123456Z",
  "start": "2026-10-20T17:00:00-07:00",
  "end": "2026-10-20T17:45:00-07:00",
  "timezone": "America/Los_Angeles",
  "title": "Groceries at PCC",
  "description": "Pick up milk and apples.",
  "location": "PCC Community Markets"
}
```

Use `updated_at` from the reviewed `GET /v1/lists` or `GET /v1/lists/{id}` as `list_updated_at` without
rounding. The list must belong to the user's household, be open, have an unchecked item and still have
that exact version. Any list metadata or item change requires another review. `timezone` must be an IANA
zone; both explicit timestamp offsets must agree with its DST rules. Timestamps use RFC3339 with seconds
and optional 1–6 fractional digits. Duration must be positive and at most four hours; start must be in
the future and end within 30 days. Title is required (1–200 characters, nonblank); description defaults to
empty (max 4000), location defaults to empty (max 500). Extra fields are rejected.

The transaction serializes reservations per user and locks the list against concurrent edits/reservations.
A list can have only one reserved, unknown, or future scheduled trip across all household members. The
same user's active trip windows cannot overlap, including across different households. Adjacent windows
are allowed. Failed and past scheduled trips allow a new reservation. Reserved/unknown trips continue
blocking the list even after their original time passes; an uncertain external write must be reconciled.

Retrying the same key/body returns the original 201 reservation snapshot with `Idempotent-Replay: true`,
even if an outcome was subsequently reported. Refetch trips for its current status. A reused key with a
different body returns 422 `idempotency_key_reused`.

Other errors use RFC 7807: 400 `idempotency_key_required`; 404 `not_found`; 409 `trip_exists`,
`trip_overlap`, `list_changed`, `list_closed`, `list_empty`, `duplicate_request`; 422 `invalid_trip_time` or `invalid_request`.
On `list_changed`, refetch and review. On `trip_exists`, refetch trips and display the existing reservation.
On `trip_overlap`, choose another slot. Validation/conflict responses create no reservation or Calendar event.
If another operation concurrently claims the same request key, `duplicate_request` rolls back the entire
write. This also applies to private Calendar event creation. Retry with the same key to resolve the result;
a key claimed for different input returns `idempotency_key_reused`.

## Report outcome

`PATCH /v1/trips/{id}/outcome` requires the reservation owner's credential and returns the current Trip.
Other members can read it but receive 404 when trying to mutate it. No idempotency header is required:
repeating an identical outcome is a no-op and returns the same result.

```json
{"status":"scheduled","event_id":"confirmed-provider-event-id","event_url":"https://calendar.google.com/calendar/event?eid=..."}
```

Allowed statuses are `scheduled`, `outcome_unknown`, and `failed`. A scheduled outcome requires a nonblank
`event_id` (max 1024); optional `event_url` must use HTTPS (max 2048). Other statuses cannot include event
details. The device reports `failed` only when it knows the Calendar write did not happen. Timeouts or
ambiguous results require `outcome_unknown`. Ordinary accounts' provider IDs are device-reported, not
independently verified by this backend; verification happens in the native Calendar connection.

| Current status | Allowed next status |
| --- | --- |
| reserved | scheduled, outcome_unknown, failed |
| outcome_unknown | scheduled after verifying the original event |
| scheduled | identical scheduled result only |
| failed | identical failed result only |

Disallowed transitions or altered terminal event details return 409 `invalid_trip_transition`.
There is no automatic expiration, cancellation, rescheduling or Calendar deletion endpoint. A trip's
scheduled status does not mark its list items purchased or checked.

Every state change writes an audit action with identifiers/status only and emits household SSE
`trip.updated` (resource ID is the trip ID); refetch trips when received. Replays add no duplicate audit
entries. RLS grants household reads and owner-only inserts/updates. User, household and list deletion
cascade to trips. Existing database snapshot export/import automatically includes trip rows, including
Calendar references; exported snapshots contain personal data and follow the tool's existing handling rules.

Demo seed/reset adds a realistic scheduled trip linked to the same stored private Calendar event.
Boot/sign-in backfill is idempotent and leaves existing trip and Calendar history intact.

## Private Calendar recovery

`GET /v1/demo/calendar/events/by-request?key=ORIGINAL_CALENDAR_REQUEST_KEY` is an authenticated,
designated-account-only read. A verified original result returns 200 `{"created":true,"id":"UUID"}`.
No stored request returns 404 `not_found`. A key belonging to another operation returns 409
`idempotency_key_reused`; an unavailable/missing referenced event returns 409 `outcome_unknown`.
Ordinary accounts return 403 `integration_unavailable`. The query reads the user's original
`calendar.event` idempotency record and verifies the event is still visible to that user; it never
creates an event and does not search titles or the capped recent-events feed. Keys do not expire.
Preexisting private Calendar results are classified during migration using their saved response and
owned event reference, preserving their recovery history.

The native client must compute the same Calendar request key from the reserved trip ID. For a reserved
trip, a confirmed absent result permits the original create/recovery flow with the same key and fields,
after refreshing free/busy. An unknown trip permits read-only verification of the original event.
An unavailable lookup or mismatch must remain uncertain and must never permit a new Calendar write.
