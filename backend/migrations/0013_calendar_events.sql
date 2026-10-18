-- Account-owned calendar used by the designated sample account. No Google tokens or outbound calls.
CREATE TABLE calendar_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  description text NOT NULL DEFAULT '',
  location text NOT NULL DEFAULT '',
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
  timezone text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX calendar_events_window ON calendar_events (user_id, starts_at);
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY calendar_events_own ON calendar_events
  USING (user_id = app_user_id() AND household_id = ANY (app_household_ids()))
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids()));
GRANT SELECT, INSERT ON calendar_events TO agora_rw;
