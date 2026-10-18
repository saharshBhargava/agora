-- Run-out forecasts and shopping lists.
--
-- consumption_forecasts keeps every forecast we compute (after each confirmed scan and nightly), not just the
-- latest, so the app can show "forecast vs actual". It is a time series: insert-only, the time column is in the
-- primary key, and nothing references it. 0007_forecasts.timescale.sql turns it into a hypertable.
--
-- Shopping lists are ordinary mutable household data. Items added by the system or the agent always carry an
-- explanation, so the user can see why something is on the list.

CREATE TABLE consumption_forecasts (
  computed_at        timestamptz NOT NULL,
  household_id       uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  inventory_item_id  uuid NOT NULL REFERENCES inventory_items ON DELETE CASCADE,
  -- 'theil_sen': from this item's own history. 'blended': history mixed with the category prior (cold start).
  -- 'prior': no usable history yet, prior only. 'insufficient': nothing to go on, no rate.
  method             text NOT NULL CHECK (method IN ('theil_sen', 'blended', 'prior', 'insufficient')),
  rate_per_day       double precision CHECK (rate_per_day >= 0),
  rate_lo            double precision CHECK (rate_lo >= 0),
  rate_hi            double precision CHECK (rate_hi >= 0),
  qty_now            double precision CHECK (qty_now >= 0),
  -- Last reading the forecast is anchored to. Run-out = last_observed_at + last_quantity / rate.
  last_observed_at   timestamptz,
  last_quantity      double precision CHECK (last_quantity >= 0),
  runout_at          timestamptz,
  runout_lo          timestamptz,
  runout_hi          timestamptz,
  n_obs              int NOT NULL DEFAULT 0 CHECK (n_obs >= 0),
  n_segments         int NOT NULL DEFAULT 0 CHECK (n_segments >= 0),
  span_days          double precision NOT NULL DEFAULT 0 CHECK (span_days >= 0),
  restock_qty        double precision CHECK (restock_qty > 0),  -- typical amount bought, from past restocks
  household_size     int CHECK (household_size BETWEEN 1 AND 20),
  PRIMARY KEY (inventory_item_id, computed_at),
  CHECK (rate_lo <= rate_per_day AND rate_per_day <= rate_hi),
  CHECK (method = 'insufficient' OR rate_per_day IS NOT NULL)
);
CREATE INDEX consumption_forecasts_household_time ON consumption_forecasts (household_id, computed_at DESC);

CREATE TABLE shopping_lists (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  merchant_id   uuid REFERENCES merchants ON DELETE SET NULL,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'archived')),
  source        text NOT NULL CHECK (source IN ('user', 'generated')),
  created_by    uuid REFERENCES users ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  completed_at  timestamptz,
  UNIQUE (id, household_id),
  CHECK ((status = 'open') = (completed_at IS NULL))
);
CREATE INDEX shopping_lists_household_status ON shopping_lists (household_id, status, created_at DESC);

CREATE TABLE shopping_list_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id            uuid NOT NULL,
  household_id       uuid NOT NULL,
  title              text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  inventory_item_id  uuid REFERENCES inventory_items ON DELETE SET NULL,
  product_id         uuid REFERENCES products ON DELETE SET NULL,
  quantity           numeric NOT NULL DEFAULT 1 CHECK (quantity > 0 AND quantity <= 1000),
  unit               text CHECK (length(unit) BETWEEN 1 AND 20),
  note               text CHECK (length(note) <= 500),
  reason             text NOT NULL CHECK (reason IN ('runout', 'manual', 'agent', 'price_drop')),
  added_by           text NOT NULL CHECK (added_by IN ('user', 'agent', 'system')),
  explanation        text CHECK (length(explanation) BETWEEN 1 AND 500),
  -- Where we think it'll be bought and why: the item's preferred store, or wherever it was last bought.
  merchant_id        uuid REFERENCES merchants ON DELETE SET NULL,
  merchant_basis     text CHECK (merchant_basis IN ('preferred', 'last_purchase', 'list')),
  needed_by          timestamptz,  -- forecast run-out when the item was added; trips plan around it
  checked            boolean NOT NULL DEFAULT false,
  checked_at         timestamptz,
  checked_by         uuid REFERENCES users ON DELETE SET NULL,
  created_by         uuid REFERENCES users ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  -- The composite key keeps every item in its list's own household.
  FOREIGN KEY (list_id, household_id) REFERENCES shopping_lists (id, household_id) ON DELETE CASCADE,
  CHECK (added_by = 'user' OR explanation IS NOT NULL),
  CHECK (reason = 'manual' OR explanation IS NOT NULL),
  CHECK (checked = (checked_at IS NOT NULL))
);
CREATE INDEX shopping_list_items_list ON shopping_list_items (list_id, checked, created_at);
-- One unchecked line per inventory item per list, so regenerating never duplicates.
CREATE UNIQUE INDEX shopping_list_items_open_item ON shopping_list_items (list_id, inventory_item_id)
  WHERE inventory_item_id IS NOT NULL AND NOT checked;
CREATE INDEX shopping_list_items_household_item ON shopping_list_items (household_id, inventory_item_id)
  WHERE NOT checked;

-- The nightly forecast refresh reschedules itself. This keeps at most one future run queued, however many
-- workers start up at once.
CREATE UNIQUE INDEX jobs_forecast_nightly_once ON jobs (kind) WHERE kind = 'forecast.nightly' AND status = 'queued';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['consumption_forecasts', 'shopping_lists', 'shopping_list_items'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON %I USING (household_id = ANY (app_household_ids())) '
                   'WITH CHECK (household_id = ANY (app_household_ids()))', t || '_household', t);
  END LOOP;
END $$;

GRANT SELECT, INSERT ON consumption_forecasts TO agora_rw;  -- insert-only: history is never rewritten
GRANT SELECT, INSERT, UPDATE ON shopping_lists TO agora_rw;  -- no DELETE: lists are archived, not dropped
GRANT SELECT, INSERT, UPDATE, DELETE ON shopping_list_items TO agora_rw;
