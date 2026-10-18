-- Public product thumbnails are shared; user-selected photos remain household private.
CREATE TABLE item_image_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid REFERENCES households ON DELETE CASCADE,
  identity_key text,
  data bytea NOT NULL CHECK (octet_length(data) <= 500000),
  source_url text,
  original_url text,
  attribution text,
  match_kind text NOT NULL CHECK (match_kind IN ('product','representative','photo')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX item_image_cache ON item_image_assets(identity_key) WHERE household_id IS NULL;
ALTER TABLE item_image_assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY image_asset_read ON item_image_assets FOR SELECT
  USING (household_id IS NULL OR household_id = ANY(app_household_ids()));
CREATE POLICY image_asset_write ON item_image_assets FOR INSERT
  WITH CHECK (household_id = ANY(app_household_ids()));
GRANT SELECT, INSERT ON item_image_assets TO agora_rw;

CREATE TABLE item_images (
  kind text NOT NULL CHECK (kind IN ('inventory','wishlist','list')),
  item_id uuid NOT NULL,
  inventory_id uuid REFERENCES inventory_items ON DELETE CASCADE,
  wishlist_id uuid REFERENCES wishlist_items ON DELETE CASCADE,
  list_item_id uuid REFERENCES shopping_list_items ON DELETE CASCADE,
  household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  version integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','ready','fallback')),
  asset_id uuid REFERENCES item_image_assets ON DELETE SET NULL,
  candidates uuid[] NOT NULL DEFAULT '{}',
  user_selected boolean NOT NULL DEFAULT false,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(kind,item_id)
);
ALTER TABLE item_images ENABLE ROW LEVEL SECURITY;
CREATE POLICY item_image_scope ON item_images
  USING (household_id = ANY(app_household_ids())) WITH CHECK (household_id = ANY(app_household_ids()));
GRANT SELECT, INSERT, UPDATE, DELETE ON item_images TO agora_rw;

CREATE FUNCTION queue_item_image() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v integer;
BEGIN
  -- Cascading inventory unlinking during household deletion must not recreate image rows.
  IF NOT EXISTS(SELECT 1 FROM households WHERE id=NEW.household_id) THEN RETURN NEW; END IF;
  INSERT INTO item_images(kind,item_id,household_id,inventory_id,wishlist_id,list_item_id)
  VALUES (TG_ARGV[0],NEW.id,NEW.household_id,
          CASE WHEN TG_ARGV[0]='inventory' THEN NEW.id END,
          CASE WHEN TG_ARGV[0]='wishlist' THEN NEW.id END,
          CASE WHEN TG_ARGV[0]='list' THEN NEW.id END)
  ON CONFLICT(kind,item_id) DO UPDATE SET
    version = item_images.version + 1,
    status = CASE WHEN item_images.user_selected THEN item_images.status ELSE 'queued' END,
    asset_id = CASE WHEN item_images.user_selected THEN item_images.asset_id ELSE NULL END,
    candidates = '{}', last_error = NULL, updated_at = now()
  RETURNING version INTO v;
  INSERT INTO jobs(kind,payload,max_attempts) VALUES ('image.resolve',
    jsonb_build_object('kind',TG_ARGV[0],'item_id',NEW.id,'version',v), 2);
  RETURN NEW;
END $$;
CREATE TRIGGER inventory_image AFTER INSERT OR UPDATE OF display_name,category,product_id
  ON inventory_items FOR EACH ROW EXECUTE FUNCTION queue_item_image('inventory');
CREATE TRIGGER wishlist_image AFTER INSERT OR UPDATE OF title,category,product_id,inventory_item_id
  ON wishlist_items FOR EACH ROW EXECUTE FUNCTION queue_item_image('wishlist');
CREATE TRIGGER list_image AFTER INSERT OR UPDATE OF title,product_id,inventory_item_id
  ON shopping_list_items FOR EACH ROW EXECUTE FUNCTION queue_item_image('list');

INSERT INTO item_images(kind,item_id,household_id,inventory_id,wishlist_id,list_item_id)
  SELECT 'inventory',id,household_id,id,NULL::uuid,NULL::uuid FROM inventory_items
  UNION ALL SELECT 'wishlist',id,household_id,NULL,id,NULL FROM wishlist_items
  UNION ALL SELECT 'list',id,household_id,NULL,NULL,id FROM shopping_list_items;
INSERT INTO jobs(kind,payload,max_attempts)
  SELECT 'image.resolve',jsonb_build_object('kind',kind,'item_id',item_id,'version',version),2 FROM item_images;

-- Shared positive/negative cache and a short lease deduplicate simultaneous households' research.
CREATE TABLE item_image_lookups (
  identity_key text PRIMARY KEY,
  lease_until timestamptz NOT NULL,
  retry_after timestamptz NOT NULL,
  finished boolean NOT NULL DEFAULT false
);

CREATE FUNCTION invalidate_watch_image() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR (NEW.criteria->>'product_url') IS DISTINCT FROM (OLD.criteria->>'product_url') THEN
    UPDATE wishlist_items SET title=title WHERE id=NEW.wishlist_item_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER watch_image_source AFTER INSERT OR UPDATE OF criteria ON price_watches
  FOR EACH ROW EXECUTE FUNCTION invalidate_watch_image();
