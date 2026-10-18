-- A reservation records user approval before the phone attempts a Calendar write.
ALTER TABLE idempotency_keys ADD COLUMN operation text;
-- Older private Calendar results can be classified without guessing from event content.
UPDATE idempotency_keys k SET operation = 'calendar.event'
FROM calendar_events e WHERE e.user_id = k.user_id AND e.id::text = k.response->>'id'
  AND k.status_code = 201 AND k.response->>'created' = 'true';

CREATE TABLE replenishment_trips (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  list_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  list_name text NOT NULL,
  list_updated_at timestamptz NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL CHECK (ends_at > starts_at AND ends_at - starts_at <= interval '4 hours'),
  -- Keep exact wire timestamps: Calendar retry fingerprints include their offsets and precision.
  start_text text NOT NULL,
  end_text text NOT NULL,
  timezone text NOT NULL,
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  description text NOT NULL DEFAULT '',
  location text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'scheduled', 'outcome_unknown', 'failed')),
  event_id text,
  event_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (list_id, household_id) REFERENCES shopping_lists (id, household_id) ON DELETE CASCADE,
  CHECK (status <> 'scheduled' OR (event_id IS NOT NULL AND length(btrim(event_id)) > 0))
);
CREATE INDEX replenishment_trips_household ON replenishment_trips (household_id, created_at DESC);
CREATE INDEX replenishment_trips_list ON replenishment_trips (list_id, status);
CREATE INDEX replenishment_trips_user_window ON replenishment_trips (user_id, starts_at, ends_at);
ALTER TABLE replenishment_trips ENABLE ROW LEVEL SECURITY;
CREATE POLICY replenishment_trips_read ON replenishment_trips FOR SELECT
  USING (household_id = ANY (app_household_ids()));
CREATE POLICY replenishment_trips_insert ON replenishment_trips FOR INSERT
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids())
    AND EXISTS (SELECT 1 FROM shopping_lists l WHERE l.id = list_id AND l.household_id = replenishment_trips.household_id));
CREATE POLICY replenishment_trips_update ON replenishment_trips FOR UPDATE
  USING (user_id = app_user_id() AND household_id = ANY (app_household_ids()))
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids())
    AND EXISTS (SELECT 1 FROM shopping_lists l WHERE l.id = list_id AND l.household_id = replenishment_trips.household_id));
GRANT SELECT, INSERT, UPDATE ON replenishment_trips TO agora_rw;
