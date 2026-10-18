# Pending PR integration handoff

Updated October 17, 2026 (America/Los_Angeles). Read this before resuming older feature branches.

## Forecasts and shopping lists — PR #9

Current main includes the dedicated demo account from PR #11. The forecast branch now incorporates it and
backfills forecasts and a realistic shopping list for an existing demo account without resetting its history.
The demo coverage test remains mandatory for every new household/user table.

The unmerged forecast migrations were renamed from `0007_forecasts*` to `0010_forecasts*`, after main's
`0009_demo_account.sql`. Do not restore the old migration names or edit any migration once merged. An old
branch-local development database that already ran `0007_forecasts*` must be recreated before using the
renamed files; never apply both sets against the same database.

API contract: [forecasts and lists](api/forecasts-and-lists.md). UI requirements remain in
[frontend requests](frontend-requests.md). Sync from origin/main before continuing feature work; do not
overwrite the consolidated Google ID-token AgoraClient with the deleted AgoraAPIClient implementation.

PR #9 merged as `1dba30f400825000a07ec78ee4fb24b09e254d07`. Validation: 136 tests passed against local
Postgres 16; GitHub's Postgres 17, TimescaleDB 17 and Docker image jobs all passed on integration head `1db59a5`.

## Agent commerce — PR #10

The commerce integration includes current main, forecasts/lists, the dedicated demo account, and hosting
handoff PR #12 (`66e63cd98f4ec91de7e264552357b9ac75492dae`). Its final merge/check state is available on
[PR #10](https://github.com/saharshBhargava/agora/pull/10); this handoff ships with that PR.

Migration mapping for old commerce branches:

| Old unmerged migration | Final migration |
|---|---|
| `0007_agent_commerce.sql` | `0011_agent_commerce.sql` |
| `0008_spend_hypertable.timescale.sql` | `0012_spend_hypertable.timescale.sql` |

Recreate branch-local development databases that used the old names; do not run both migration sets.
Merged migration files must remain immutable. Hosted databases that already have `0010` need only the new
commerce migrations and `app.tools.demo ensure` (normal hosted boot runs migrations and seed automatically).
Do not reset the hosted demo to add these features.

Behavior changes that resumed agents must preserve:

- `ensure_demo_account` backfills new commerce data without resetting earlier inventory/history. It adds a
  realistic mandate, monthly budget, purchase/spending history and an approval waiting for the user.
- Server checkouts simulate payments only when `users.is_demo` is true. Ordinary accounts get
  `503 payments_unavailable` until a real provider exists; no simulated order or spend is recorded.
  The demo always uses simulation, even if a real provider is configured later. No payment credentials are
  needed for the current release.
- Hosted `app.seed` creates only the catalog and the single designated demo account. The old `kedar` and
  `saharsh` synthetic histories are local dev/test only. Ordinary Google accounts remain empty.
- Pause/resume publish `agent.updated` for the user ID even without changed intents. Refresh agent state
  when handling these events. API examples captured with legacy `kedar` credentials are illustrative;
  use the designated demo identity for simulated checkout.
- Current client integration stays on `Agora/API/AgoraClient.swift` using Google ID tokens. Read the
  [frontend hosting handoff](frontend-handoff.md) for current deployment status and client configuration.

Local validation: all **193 tests passed** against Postgres 16, Ruff passed, and
`uv run --no-sync python -m app.tools.demo reset` succeeded against a fresh, isolated local database.
GitHub checks must pass on the final PR head before merge; the required matrix covers Postgres 17,
TimescaleDB 17, and the deploy Docker image. No hosted database was reset during PR validation.
