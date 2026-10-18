-- Additive verification evidence; earlier backends can continue reading/writing these tables.
ALTER TABLE item_image_assets ADD COLUMN verification jsonb NOT NULL DEFAULT '{}';
ALTER TABLE item_images ADD COLUMN product_identity jsonb NOT NULL DEFAULT '{}';
ALTER TABLE item_images ADD COLUMN identity_item_name text;

-- Earlier automatic matches did not establish product/variant identity. Reverify them.
-- Preserve explicit choices and demo artwork; neither is relabeled as an exact product match.
UPDATE item_images i SET asset_id=NULL,candidates='{}',status='queued',version=version+1,updated_at=now()
FROM item_image_assets a WHERE i.asset_id=a.id AND a.match_kind='product' AND NOT i.user_selected;
INSERT INTO jobs(kind,payload,max_attempts)
SELECT 'image.resolve',jsonb_build_object('kind',kind,'item_id',item_id,'version',version),2
FROM item_images i WHERE status='queued' AND NOT user_selected
AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.kind='image.resolve' AND j.status IN ('queued','running')
AND j.payload->>'item_id'=i.item_id::text AND j.payload->>'kind'=i.kind
AND j.payload->>'version'=i.version::text);
