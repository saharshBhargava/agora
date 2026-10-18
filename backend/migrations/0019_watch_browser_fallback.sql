-- Optional foreground handoff to the app's shared chat browser. Old workers ignore these columns.
ALTER TABLE watch_runs
  ADD COLUMN browser_state text NOT NULL DEFAULT 'none'
    CHECK (browser_state IN ('none','pending','claimed','completed','unavailable')),
  ADD COLUMN browser_urls jsonb NOT NULL DEFAULT '[]'
    CHECK (jsonb_typeof(browser_urls)='array' AND jsonb_array_length(browser_urls)<=5),
  ADD COLUMN browser_prices jsonb NOT NULL DEFAULT '[]'
    CHECK (jsonb_typeof(browser_prices)='array' AND jsonb_array_length(browser_prices)<=20),
  ADD COLUMN browser_token uuid,
  ADD COLUMN browser_user_id uuid REFERENCES users ON DELETE SET NULL,
  ADD COLUMN browser_expires_at timestamptz;
