-- Optional media store inside Postgres (AGORA_STORAGE_BACKEND=db), so a deploy needs no object-storage account.
-- Frames are small (re-encoded JPEGs, ~100-300 KB) and are deleted right after review by default, so this stays
-- tiny. Only the API's own connection touches it: the per-request role has no grant at all, and every read goes
-- through the scan routes' authorization first.
CREATE TABLE media_objects (
  key           text PRIMARY KEY,
  content_type  text NOT NULL,
  data          bytea NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON media_objects FROM PUBLIC;
