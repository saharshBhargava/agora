-- OAuth state and app sessions are accessed only by the authentication service (system role).
CREATE TABLE google_oauth_states (
  state_hash text PRIMARY KEY,
  challenge text NOT NULL,
  user_id uuid REFERENCES users ON DELETE CASCADE,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);
CREATE TABLE app_sessions (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '30 days'
);
CREATE INDEX app_sessions_user ON app_sessions(user_id);
CREATE TABLE google_calendar_connections (
  user_id uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
  refresh_token_enc text NOT NULL,
  email text NOT NULL,
  scopes text[] NOT NULL,
  status text NOT NULL DEFAULT 'connected' CHECK (status IN ('connected', 'reconnect_required')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE google_calendar_connections ENABLE ROW LEVEL SECURITY;
CREATE POLICY google_calendar_self ON google_calendar_connections
  USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON google_calendar_connections TO agora_rw;
-- Explicit revocation: the base migration grants privileges on existing tables only.
REVOKE ALL ON google_oauth_states, app_sessions FROM agora_rw;
