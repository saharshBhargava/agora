-- The one designated demo account (see app/demo_account.py). Server-side only: never returned by the API.
-- Anything mocked for demos (e.g. simulated payments) must check this flag, so real accounts never get mock
-- behaviour and the demo account never reaches real external effects.
ALTER TABLE users ADD COLUMN is_demo boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX users_single_demo ON users (is_demo) WHERE is_demo;

-- Requests run as agora_rw, which may update its own users row (display name etc.) but must never be able to
-- flip this flag. Column-level grants: keep UPDATE on everything except is_demo.
REVOKE UPDATE ON users FROM agora_rw;
GRANT UPDATE (handle, display_name, deleted_at) ON users TO agora_rw;
