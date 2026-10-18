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

Merge status and final validation are recorded below as integration completes.
