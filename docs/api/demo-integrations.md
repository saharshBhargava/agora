# Designated account integrations

Sign in with `POST /v1/dev/login`, JSON `{"handle":"demo","password":"<private password>"}`.
The password is the existing Render `AGORA_DEMO_PASSWORD`, shared privately rather than committed.
Response: `{"access_token":"...","token_type":"bearer","expires_at":<Unix seconds>}`.
Send `Authorization: Bearer <access_token>` on subsequent calls. Wrong/missing password returns 401.
Google sign-in is optional; verified addresses in `AGORA_DEMO_GOOGLE_EMAILS` map to this same account.

Every route below checks the server-owned `users.is_demo` flag within `db.scoped`. Ordinary accounts get
403, anonymous calls 401. The flag itself is never returned or writable. Nothing calls Google or a model
provider. No API/provider keys are needed beyond the account password.

| Route | Request | Result |
|---|---|---|
| `GET /v1/demo/profile` | Bearer token | `{id, display_name}`; eligibility for built-in native integrations |
| `GET /v1/demo/calendar/events` | Bearer token | Latest 100 events: `{id,title,description,location,start,end,timezone}` |
| `POST /v1/demo/calendar/freebusy` | `{start,end,timezone}` | `{busy:[{start,end}],timezone}` |
| `POST /v1/demo/calendar/events` | Window plus `title`, optional `description`/`location`, `confirmed:true` | 201 `{created:true,id}` |

Timestamps must be aware RFC3339 values, end after start by at most 31 days, offsets consistent with the
IANA timezone. Event creation requires an `Idempotency-Key` (8–128 printable ASCII characters). Reuse the
same key and identical body when retrying; a changed body returns 422. Missing approval returns 409.
Events are persisted in the account-private Agora calendar, not Google. Existing `/v1/calendar/freebusy`
and `/v1/calendar/events` also dispatch designated-account calls here. Normal-account routes use Google.

Native built-in chat supports representative Calendar check/schedule requests (sample grocery trip tomorrow
at 19:00 UTC, shown for explicit approval). Captions and recognition return fixed grocery fixtures and
ignore source media; the app discloses this before review. They do not perform general AI inference.
Saving reviewed recognition uses the existing inventory endpoint with `provider:"builtin"` and
`model:"agora-sample-v1"`. That provider is accepted only for the designated account. Server-uploaded
scans also bypass configured real vision providers for that account. Ordinary provider behavior is unchanged.

Signing out clears the saved session; expiry requires another password sign-in. The app revalidates
eligibility on restore and model use, cancels stale account work, and binds saved tokens to the API origin.
