-- "Purchased from" / "Purchased on": which store a scanned product came from, and the day it was bought.
--
-- Merchants come in two scopes. Global merchants (household_id IS NULL) are the shared catalog; only migrations
-- and admins write them. Household merchants are created by users, visible only to that household, and can't
-- leak to or be edited by anyone else. Search returns both.
--
-- Purchase origin is deliberately separate from an item's preferred store: the same product can be bought at
-- several stores, and each confirmed sighting records where that batch came from.

CREATE FUNCTION agora_normalize_name(value text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  -- "Trader Joe's" and "trader joes" normalize to the same key: apostrophes vanish, other punctuation is a space.
  SELECT btrim(regexp_replace(regexp_replace(lower(coalesce(value, '')), '[''’`]', '', 'g'),
                              '[^[:alnum:]]+', ' ', 'g'))
$$;

ALTER TABLE merchants
  ADD COLUMN household_id uuid REFERENCES households ON DELETE CASCADE,
  ADD COLUMN locality text CHECK (length(locality) <= 80),
  ADD COLUMN created_by uuid REFERENCES users ON DELETE SET NULL,
  ADD COLUMN normalized_name text GENERATED ALWAYS AS (agora_normalize_name(name)) STORED,
  ADD COLUMN normalized_locality text GENERATED ALWAYS AS (agora_normalize_name(locality)) STORED,
  ADD CONSTRAINT merchants_name_length CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  ADD CONSTRAINT merchants_name_has_text CHECK (agora_normalize_name(name) <> ''),
  DROP CONSTRAINT merchants_kind_check,
  ADD CONSTRAINT merchants_kind_check CHECK (kind IN ('grocery', 'big_box', 'online', 'local', 'other'));

-- One merchant per (scope, name, locality): "Safeway" and "Safeway, Ballard" can coexist, two "Safeway"s can't.
CREATE UNIQUE INDEX merchants_unique_global ON merchants (normalized_name, normalized_locality)
  WHERE household_id IS NULL;
CREATE UNIQUE INDEX merchants_unique_household ON merchants (household_id, normalized_name, normalized_locality)
  WHERE household_id IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_extension WHERE extname = 'pg_trgm') THEN
    CREATE INDEX merchants_name_trgm ON merchants USING gin (normalized_name gin_trgm_ops);
  END IF;
END $$;

ALTER TABLE merchants ENABLE ROW LEVEL SECURITY;
CREATE POLICY merchants_visible ON merchants FOR SELECT
  USING (household_id IS NULL OR household_id = ANY (app_household_ids()));
-- Users can only add merchants to their own household; the global catalog is never writable from a request.
CREATE POLICY merchants_household_insert ON merchants FOR INSERT
  WITH CHECK (household_id IS NOT NULL AND household_id = ANY (app_household_ids()));
GRANT INSERT ON merchants TO agora_rw;

-- Store and purchase date for the whole upload, plus optional per-detection overrides for mixed hauls.
-- *_override = false: inherit the scan's value. true: use the detection's own value (NULL = "none/unknown").
-- purchased_on is a calendar date (the receipt date), separate from captured_at: you may photograph the
-- pantry days after shopping.
ALTER TABLE scans
  ADD COLUMN purchased_from_merchant_id uuid REFERENCES merchants ON DELETE SET NULL,
  ADD COLUMN purchased_on date;
ALTER TABLE scan_detections
  ADD COLUMN purchased_from_merchant_id uuid REFERENCES merchants ON DELETE SET NULL,
  ADD COLUMN merchant_override boolean NOT NULL DEFAULT false,
  ADD COLUMN purchased_on date,
  ADD COLUMN purchased_on_override boolean NOT NULL DEFAULT false;

ALTER TABLE inventory_items
  ADD COLUMN preferred_merchant_id uuid REFERENCES merchants ON DELETE SET NULL;

-- Purchase/source history: one row per confirmed detection with a known store and/or purchase date. A regular
-- (mutable) table rather than columns on the observations hypertable, because users can correct both later.
CREATE TABLE inventory_purchase_origins (
  scan_detection_id  uuid PRIMARY KEY REFERENCES scan_detections ON DELETE CASCADE,
  household_id       uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  inventory_item_id  uuid NOT NULL REFERENCES inventory_items ON DELETE CASCADE,
  merchant_id        uuid REFERENCES merchants ON DELETE SET NULL,
  purchased_on       date,
  scan_id            uuid NOT NULL REFERENCES scans ON DELETE CASCADE,
  observed_at        timestamptz NOT NULL,
  quantity           numeric NOT NULL CHECK (quantity >= 0),
  recorded_by        uuid REFERENCES users ON DELETE SET NULL,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (merchant_id IS NOT NULL OR purchased_on IS NOT NULL)
);
CREATE INDEX purchase_origins_item ON inventory_purchase_origins (inventory_item_id, observed_at DESC);
CREATE INDEX purchase_origins_merchant ON inventory_purchase_origins (household_id, merchant_id, observed_at DESC);

ALTER TABLE inventory_purchase_origins ENABLE ROW LEVEL SECURITY;
CREATE POLICY inventory_purchase_origins_household ON inventory_purchase_origins
  USING (household_id = ANY (app_household_ids())) WITH CHECK (household_id = ANY (app_household_ids()));
GRANT SELECT, INSERT, UPDATE, DELETE ON inventory_purchase_origins TO agora_rw;
