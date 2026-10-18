-- Confirmed retailer-price criteria, durable checks and account-private alert delivery.
CREATE TABLE price_watches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  wishlist_item_id uuid NOT NULL,
  created_by uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','completed','expired')),
  criteria jsonb NOT NULL CHECK (jsonb_typeof(criteria) = 'object'),
  criteria_version integer NOT NULL DEFAULT 1 CHECK (criteria_version > 0),
  confirmed_at timestamptz,
  last_checked_at timestamptz,
  last_successful_at timestamptz,
  next_check_at timestamptz NOT NULL DEFAULT now(),
  last_error text,
  last_result text NOT NULL DEFAULT 'pending' CHECK (last_result IN ('pending','matched','no_match','failed','skipped')),
  last_manual_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (wishlist_item_id), UNIQUE (id, household_id),
  FOREIGN KEY (wishlist_item_id, household_id) REFERENCES wishlist_items(id, household_id) ON DELETE CASCADE
);
CREATE INDEX price_watches_due ON price_watches(next_check_at) WHERE status = 'active';
CREATE TABLE watch_subscriptions (
  watch_id uuid NOT NULL,
  household_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  push_enabled boolean NOT NULL DEFAULT false,
  quiet_start_hour integer CHECK (quiet_start_hour BETWEEN 0 AND 23),
  quiet_end_hour integer CHECK (quiet_end_hour BETWEEN 0 AND 23),
  timezone text NOT NULL DEFAULT 'UTC',
  daily_cap integer NOT NULL DEFAULT 3 CHECK (daily_cap BETWEEN 1 AND 20),
  cooldown_hours integer NOT NULL DEFAULT 24 CHECK (cooldown_hours BETWEEN 1 AND 168),
  last_notified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(watch_id, user_id),
  CHECK ((quiet_start_hour IS NULL) = (quiet_end_hour IS NULL)),
  FOREIGN KEY(watch_id, household_id) REFERENCES price_watches(id, household_id) ON DELETE CASCADE
);
CREATE TABLE watch_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL,
  watch_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  criteria_version integer NOT NULL,
  status text NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','succeeded','failed','skipped')),
  trigger text NOT NULL CHECK(trigger IN ('manual','scheduled','confirmed')),
  created_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, finished_at timestamptz,
  execution_id uuid,
  offer_count integer NOT NULL DEFAULT 0, match_count integer NOT NULL DEFAULT 0, error_code text,
  interaction_urls jsonb NOT NULL DEFAULT '[]'
    CHECK (jsonb_typeof(interaction_urls)='array' AND jsonb_array_length(interaction_urls)<=5),
  FOREIGN KEY(watch_id, household_id) REFERENCES price_watches(id, household_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX watch_runs_one_pending ON watch_runs(watch_id) WHERE status IN ('queued','running');
CREATE TABLE watch_listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL,
  watch_id uuid NOT NULL, url text NOT NULL, merchant text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(watch_id,url), UNIQUE(id,household_id),
  FOREIGN KEY(watch_id,household_id) REFERENCES price_watches(id,household_id) ON DELETE CASCADE
);
CREATE TABLE watch_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL,
  watch_id uuid NOT NULL, listing_id uuid NOT NULL, run_id uuid NOT NULL REFERENCES watch_runs ON DELETE CASCADE,
  criteria_version integer NOT NULL, offer jsonb NOT NULL, observed_at timestamptz NOT NULL,
  eligible boolean NOT NULL, reason text NOT NULL,
  FOREIGN KEY(watch_id,household_id) REFERENCES price_watches(id,household_id) ON DELETE CASCADE,
  FOREIGN KEY(listing_id,household_id) REFERENCES watch_listings(id,household_id) ON DELETE CASCADE
);
CREATE TABLE watch_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL,
  watch_id uuid NOT NULL, observation_id uuid NOT NULL REFERENCES watch_observations ON DELETE CASCADE,
  criteria_version integer NOT NULL, fingerprint text NOT NULL,
  title text NOT NULL, url text NOT NULL, merchant text NOT NULL,
  unit_price_cents integer NOT NULL, total_price_cents integer, currency text NOT NULL,
  quantity integer NOT NULL, shipping_cents integer, tax_cents integer,
  fulfillment text NOT NULL, location text NOT NULL, condition text NOT NULL,
  observed_at timestamptz NOT NULL, matched_at timestamptz NOT NULL DEFAULT now(),
  evidence jsonb NOT NULL DEFAULT '[]', reason text NOT NULL,
  UNIQUE(watch_id,criteria_version,fingerprint), UNIQUE(id,household_id),
  FOREIGN KEY(watch_id,household_id) REFERENCES price_watches(id,household_id) ON DELETE CASCADE
);
CREATE TABLE notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, watch_id uuid NOT NULL,
  match_id uuid NOT NULL, title text NOT NULL, body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), read_at timestamptz,
  UNIQUE(user_id,match_id), UNIQUE(id,household_id),
  FOREIGN KEY(watch_id,household_id) REFERENCES price_watches(id,household_id) ON DELETE CASCADE,
  FOREIGN KEY(match_id,household_id) REFERENCES watch_matches(id,household_id) ON DELETE CASCADE
);
CREATE TABLE notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), household_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  notification_id uuid NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','sent','suppressed','failed')),
  run_at timestamptz NOT NULL DEFAULT now(), attempts integer NOT NULL DEFAULT 0,
  last_error text, delivered_at timestamptz, locked_until timestamptz,
  FOREIGN KEY(notification_id,household_id) REFERENCES notifications(id,household_id) ON DELETE CASCADE
);
CREATE TABLE push_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  token text NOT NULL CHECK(length(token) BETWEEN 32 AND 512),
  environment text NOT NULL CHECK(environment IN ('sandbox','production')),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(token,environment)
);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['price_watches','watch_runs','watch_listings','watch_observations','watch_matches'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY household_scope ON %I USING(household_id = ANY(app_household_ids())) WITH CHECK(household_id = ANY(app_household_ids()))',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE ON %I TO agora_rw',t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['watch_subscriptions','notifications','notification_outbox'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY own_scope ON %I USING(user_id = app_user_id() AND household_id = ANY(app_household_ids())) WITH CHECK(user_id = app_user_id() AND household_id = ANY(app_household_ids()))',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON %I TO agora_rw',t);
  END LOOP;
END $$;
ALTER TABLE push_devices ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_scope ON push_devices USING(user_id = app_user_id()) WITH CHECK(user_id = app_user_id());
GRANT SELECT,INSERT,UPDATE,DELETE ON push_devices TO agora_rw;
CREATE UNIQUE INDEX jobs_watch_sweep_once ON jobs(kind) WHERE kind = 'watch.sweep' AND status = 'queued';
CREATE UNIQUE INDEX jobs_watch_check_once ON jobs((payload->>'run_id')) WHERE kind = 'watch.check' AND status IN ('queued','running');
-- A changed parent is never allowed to silently reuse a confirmation of different purchase criteria.
CREATE FUNCTION invalidate_price_watch() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE changed_watch record;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.quantity IS DISTINCT FROM OLD.quantity OR NEW.target_price_cents IS DISTINCT FROM OLD.target_price_cents
     OR NEW.product_id IS DISTINCT FROM OLD.product_id OR NEW.needed_by IS DISTINCT FROM OLD.needed_by THEN
    FOR changed_watch IN UPDATE price_watches SET
      status = CASE WHEN NEW.status IN ('purchased','removed') THEN 'completed' ELSE 'paused' END,
      criteria_version = criteria_version + 1, confirmed_at = NULL, updated_at = now(),
      last_result = 'skipped', last_error = 'wishlist_changed'
      WHERE wishlist_item_id = NEW.id RETURNING id, household_id LOOP
      INSERT INTO audit_log(actor_type,actor_id,household_id,action,target_type,target_id,meta,prev_hash,hash)
        VALUES('user',app_user_id(),changed_watch.household_id,'watch.invalidated','watch',
               changed_watch.id::text,'{}','','');
      PERFORM pg_notify('agora_events',json_build_object('household_id',changed_watch.household_id,
                        'type','watch.updated','id',changed_watch.id)::text);
    END LOOP;
    UPDATE watch_runs SET status = 'skipped', finished_at = now(), error_code = 'wishlist_changed'
      WHERE watch_id IN (SELECT id FROM price_watches WHERE wishlist_item_id = NEW.id)
        AND status IN ('queued','running');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER invalidate_price_watch AFTER UPDATE ON wishlist_items
  FOR EACH ROW EXECUTE FUNCTION invalidate_price_watch();
-- A device can be re-registered after an account switch without leaking its prior owner.
CREATE FUNCTION register_push_device(device_token text, device_environment text)
RETURNS TABLE(id uuid, environment text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE account_id uuid := app_user_id();
BEGIN
  IF account_id IS NULL OR NOT EXISTS(SELECT 1 FROM users WHERE users.id=account_id) THEN
    RAISE EXCEPTION 'authentication required';
  END IF;
  IF length(device_token) NOT BETWEEN 32 AND 512 OR device_environment NOT IN ('sandbox','production') THEN
    RAISE EXCEPTION 'invalid device';
  END IF;
  RETURN QUERY INSERT INTO push_devices AS p(user_id,token,environment)
    VALUES(account_id,device_token,device_environment)
    ON CONFLICT ON CONSTRAINT push_devices_token_environment_key
    DO UPDATE SET user_id=account_id,updated_at=now()
    RETURNING p.id,p.environment;
END $$;
REVOKE ALL ON FUNCTION register_push_device(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_push_device(text,text) TO agora_rw;
