-- Base schema: plain Postgres. Everything here works with or without TimescaleDB.
-- Rules that keep later hypertable conversion safe:
--   * time-series tables have the time column in every unique index / PK
--   * no foreign key points INTO a time-series table
--   * time-series rows are insert-mostly; corrections are new rows

-- Fuzzy name matching uses pg_trgm (available on Tiger Cloud, RDS, Supabase...). Where it's missing, an
-- equivalent SQL similarity() is installed instead, so matching still works, just without index support.
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_trgm unavailable; installing SQL similarity() fallback';
  CREATE FUNCTION trigrams(s text) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $f$
    SELECT DISTINCT substr(p, i, 3)
    FROM (SELECT '  ' || w || ' ' AS p FROM regexp_split_to_table(lower(s), '[^[:alnum:]]+') AS w WHERE w <> '') x,
         generate_series(1, length(p) - 2) AS i
  $f$;
  CREATE FUNCTION similarity(a text, b text) RETURNS real LANGUAGE sql IMMUTABLE AS $f$
    WITH ta AS (SELECT trigrams(a) AS t), tb AS (SELECT trigrams(b) AS t)
    SELECT coalesce((SELECT count(*) FROM ta JOIN tb USING (t))::real
                    / nullif((SELECT count(*) FROM (SELECT t FROM ta UNION SELECT t FROM tb) u), 0), 0)
  $f$;
END $$;

-- The API runs every request as this role (SET LOCAL ROLE), so row-level security applies even when the
-- connection itself belongs to a superuser or table owner.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'agora_rw') THEN
    CREATE ROLE agora_rw NOLOGIN;
  END IF;
END $$;
GRANT agora_rw TO CURRENT_USER;

-- ---------------------------------------------------------------- identity

CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_subject  text NOT NULL UNIQUE,
  handle        text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9_]{3,32}$'),
  display_name  text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

CREATE TABLE user_settings (
  user_id          uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
  timezone         text NOT NULL DEFAULT 'America/Los_Angeles',
  autonomy_level   text NOT NULL DEFAULT 'inform'
                   CHECK (autonomy_level IN ('inform', 'prepare', 'buy_with_approval', 'buy_within_mandate')),
  household_size   int NOT NULL DEFAULT 1 CHECK (household_size BETWEEN 1 AND 20),
  home_geohash5    text CHECK (home_geohash5 ~ '^[0-9b-hjkmnp-z]{5}$'),
  media_retention  text NOT NULL DEFAULT 'delete_after_review'
                   CHECK (media_retention IN ('delete_after_review', '24h', '7d')),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE households (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  created_by  uuid REFERENCES users ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE household_members (
  household_id  uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  role          text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  joined_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (household_id, user_id)
);
CREATE INDEX household_members_user ON household_members (user_id);

CREATE TABLE consents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  scope           text NOT NULL CHECK (scope IN ('vision', 'calendar', 'payments', 'social', 'location')),
  policy_version  text NOT NULL,
  granted_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz
);
CREATE INDEX consents_user_scope ON consents (user_id, scope) WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------- global catalog (no personal data)

CREATE TABLE merchants (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('grocery', 'big_box', 'online', 'local')),
  is_small_business  boolean NOT NULL DEFAULT false,
  website            text,
  lat                double precision,
  lng                double precision,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  brand        text,
  category     text NOT NULL,
  subcategory  text,
  unit         text NOT NULL DEFAULT 'unit',
  size_value   numeric,
  size_unit    text,
  gtin         text UNIQUE,
  nutrition    jsonb,
  image_url    text,
  source       text NOT NULL DEFAULT 'seed' CHECK (source IN ('seed', 'open_food_facts', 'user', 'model')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- inventory

CREATE TABLE storage_locations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  name          text NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  kind          text NOT NULL CHECK (kind IN ('fridge', 'freezer', 'pantry', 'bathroom', 'other')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (household_id, name)
);

CREATE TABLE inventory_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id   uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  product_id     uuid REFERENCES products ON DELETE SET NULL,
  display_name   text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 120),
  category       text,
  location_id    uuid REFERENCES storage_locations ON DELETE SET NULL,
  unit           text NOT NULL DEFAULT 'unit',
  par_level      numeric CHECK (par_level >= 0),
  tracking       text NOT NULL DEFAULT 'scan' CHECK (tracking IN ('scan', 'purchase', 'manual')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_by     uuid REFERENCES users ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX inventory_items_household ON inventory_items (household_id, status);

CREATE TABLE scans (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id      uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  user_id           uuid REFERENCES users ON DELETE SET NULL,
  location_id       uuid REFERENCES storage_locations ON DELETE SET NULL,
  captured_at       timestamptz NOT NULL,
  media_kind        text NOT NULL CHECK (media_kind IN ('photos', 'video')),
  frame_keys        text[] NOT NULL DEFAULT '{}',
  frame_hashes      text[] NOT NULL DEFAULT '{}',
  raw_video_key     text,
  media_deleted_at  timestamptz,
  status            text NOT NULL DEFAULT 'uploaded'
                    CHECK (status IN ('uploaded', 'processing', 'needs_review', 'confirmed', 'failed')),
  provider          text,
  model             text,
  latency_ms        int,
  error_code        text,
  error_detail      text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  processed_at      timestamptz,
  confirmed_at      timestamptz
);
CREATE INDEX scans_household_time ON scans (household_id, captured_at DESC);

CREATE TABLE scan_detections (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scan_id            uuid NOT NULL REFERENCES scans ON DELETE CASCADE,
  household_id       uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  label              text NOT NULL,
  brand              text,
  category           text,
  product_id         uuid REFERENCES products ON DELETE SET NULL,
  inventory_item_id  uuid REFERENCES inventory_items ON DELETE SET NULL,
  match_score        real,
  confidence         real NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  count              int NOT NULL CHECK (count BETWEEN 0 AND 100),
  fill_fraction      real CHECK (fill_fraction BETWEEN 0 AND 1),
  quantity           numeric NOT NULL CHECK (quantity >= 0),
  bbox               jsonb,
  frame_index        int,
  review             text NOT NULL DEFAULT 'proposed'
                     CHECK (review IN ('proposed', 'accepted', 'corrected', 'rejected')),
  auto_accepted      boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scan_detections_scan ON scan_detections (scan_id);

-- Time series. Converted to a hypertable by 0002 when TimescaleDB is available.
CREATE TABLE inventory_observations (
  time               timestamptz NOT NULL,
  household_id       uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  inventory_item_id  uuid NOT NULL REFERENCES inventory_items ON DELETE CASCADE,
  quantity           numeric NOT NULL CHECK (quantity >= 0 AND quantity <= 10000),
  source             text NOT NULL CHECK (source IN ('scan', 'manual', 'purchase', 'receipt', 'inferred_restock')),
  scan_id            uuid REFERENCES scans ON DELETE SET NULL,
  confidence         real CHECK (confidence BETWEEN 0 AND 1),
  recorded_by        uuid REFERENCES users ON DELETE SET NULL,
  PRIMARY KEY (inventory_item_id, time, source)
);
CREATE INDEX inventory_observations_household_time ON inventory_observations (household_id, time DESC);

-- Vision results cached per household and frame hash: re-running the same frames never re-bills a provider,
-- and recorded demo scans replay instantly when venue wifi fails.
CREATE TABLE vision_cache (
  household_id    uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  frame_sha256    text NOT NULL,
  provider        text NOT NULL,
  model           text NOT NULL,
  prompt_version  text NOT NULL,
  result          jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (household_id, frame_sha256, provider, model, prompt_version)
);

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_extension WHERE extname = 'pg_trgm') THEN
    CREATE INDEX products_search_trgm ON products USING gin ((coalesce(brand, '') || ' ' || name) gin_trgm_ops);
    CREATE INDEX inventory_items_name_trgm ON inventory_items USING gin (display_name gin_trgm_ops);
  END IF;
END $$;

-- ---------------------------------------------------------------- infrastructure

CREATE TABLE jobs (
  id            bigserial PRIMARY KEY,
  kind          text NOT NULL,
  payload       jsonb NOT NULL DEFAULT '{}',
  run_at        timestamptz NOT NULL DEFAULT now(),
  status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
  attempts      int NOT NULL DEFAULT 0,
  max_attempts  int NOT NULL DEFAULT 5,
  locked_until  timestamptz,
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz
);
CREATE INDEX jobs_ready ON jobs (run_at) WHERE status IN ('queued', 'running');

CREATE TABLE idempotency_keys (
  user_id       uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  key           text NOT NULL CHECK (length(key) BETWEEN 8 AND 128),
  request_hash  text NOT NULL,
  status_code   int NOT NULL,
  response      jsonb NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);

-- Append-only, hash-chained audit trail. Each row's hash covers the previous row's hash, so editing or
-- deleting any row breaks verification for everything after it.
CREATE TABLE audit_log (
  id            bigserial PRIMARY KEY,
  time          timestamptz NOT NULL DEFAULT now(),
  actor_type    text NOT NULL CHECK (actor_type IN ('user', 'agent', 'system')),
  actor_id      uuid,
  household_id  uuid,
  action        text NOT NULL,
  target_type   text,
  target_id     text,
  meta          jsonb NOT NULL DEFAULT '{}',
  prev_hash     text NOT NULL,
  hash          text NOT NULL
);
CREATE INDEX audit_log_household ON audit_log (household_id, id DESC);
CREATE INDEX audit_log_actor ON audit_log (actor_id, id DESC);

CREATE FUNCTION audit_row_hash(prev text, r audit_log) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(concat_ws('|',
    prev, r.id::text, (extract(epoch FROM r.time) * 1000000)::bigint::text, r.actor_type,
    coalesce(r.actor_id::text, ''), coalesce(r.household_id::text, ''), r.action,
    coalesce(r.target_type, ''), coalesce(r.target_id, ''), r.meta::text), 'UTF8')), 'hex')
$$;

CREATE FUNCTION audit_chain() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  last text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('audit_log_chain'));
  SELECT hash INTO last FROM audit_log ORDER BY id DESC LIMIT 1;
  NEW.id := nextval(pg_get_serial_sequence('audit_log', 'id'));
  NEW.time := clock_timestamp();
  NEW.prev_hash := coalesce(last, repeat('0', 64));
  NEW.hash := audit_row_hash(NEW.prev_hash, NEW);
  RETURN NEW;
END $$;

CREATE TRIGGER audit_chain BEFORE INSERT ON audit_log FOR EACH ROW EXECUTE FUNCTION audit_chain();

-- ---------------------------------------------------------------- row-level security

CREATE FUNCTION app_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

-- SECURITY DEFINER so policies can read memberships without recursing into household_members' own policy.
CREATE FUNCTION app_household_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(array_agg(household_id), '{}') FROM household_members WHERE user_id = app_user_id()
$$;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_visible ON users FOR SELECT
  USING (id = app_user_id() OR id IN (SELECT user_id FROM household_members WHERE household_id = ANY (app_household_ids())));
CREATE POLICY users_self_update ON users FOR UPDATE USING (id = app_user_id()) WITH CHECK (id = app_user_id());

ALTER TABLE user_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_settings_self ON user_settings USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

ALTER TABLE consents ENABLE ROW LEVEL SECURITY;
CREATE POLICY consents_self ON consents USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY idempotency_self ON idempotency_keys USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

ALTER TABLE households ENABLE ROW LEVEL SECURITY;
CREATE POLICY households_member ON households FOR SELECT USING (id = ANY (app_household_ids()));

ALTER TABLE household_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY members_member ON household_members FOR SELECT USING (household_id = ANY (app_household_ids()));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['storage_locations', 'inventory_items', 'inventory_observations', 'scans',
                           'scan_detections', 'vision_cache'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON %I USING (household_id = ANY (app_household_ids())) '
                   'WITH CHECK (household_id = ANY (app_household_ids()))', t || '_household', t);
  END LOOP;
END $$;

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_read ON audit_log FOR SELECT
  USING (household_id = ANY (app_household_ids()) OR actor_id = app_user_id());
CREATE POLICY audit_append ON audit_log FOR INSERT
  WITH CHECK (household_id IS NULL OR household_id = ANY (app_household_ids()));

-- ---------------------------------------------------------------- grants for the request role

GRANT USAGE ON SCHEMA public TO agora_rw;
GRANT SELECT ON products, merchants TO agora_rw;
GRANT SELECT, UPDATE ON users TO agora_rw;
GRANT SELECT ON households, household_members TO agora_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON user_settings, consents, idempotency_keys, storage_locations,
  inventory_items, inventory_observations, scans, scan_detections, vision_cache TO agora_rw;
GRANT SELECT, INSERT ON audit_log TO agora_rw;  -- no UPDATE/DELETE: the trail is append-only
GRANT INSERT ON jobs TO agora_rw;               -- requests may enqueue work but never read the queue
GRANT USAGE ON SEQUENCE jobs_id_seq, audit_log_id_seq TO agora_rw;
