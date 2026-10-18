-- Durable six-hour replenishment refresh; no merchant price collection in this release.
CREATE TABLE wishlist_refresh_state (
  household_id uuid PRIMARY KEY REFERENCES households ON DELETE CASCADE,
  last_refreshed_at timestamptz,
  next_refresh_at timestamptz NOT NULL,
  last_error text,
  generated_count integer NOT NULL DEFAULT 0 CHECK (generated_count BETWEEN 0 AND 5)
);
ALTER TABLE wishlist_refresh_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY wishlist_refresh_household ON wishlist_refresh_state
  USING (household_id = ANY (app_household_ids())) WITH CHECK (household_id = ANY (app_household_ids()));
GRANT SELECT, INSERT, UPDATE ON wishlist_refresh_state TO agora_rw;
CREATE UNIQUE INDEX jobs_wishlist_sweep_once ON jobs (kind)
  WHERE kind = 'wishlist.sweep' AND status = 'queued';
CREATE UNIQUE INDEX jobs_wishlist_refresh_once ON jobs ((payload->>'household_id'))
  WHERE kind = 'wishlist.refresh' AND status IN ('queued', 'running');
