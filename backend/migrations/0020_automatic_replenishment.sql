-- Track automatic lines separately so restocks never remove hand-written or edited lines.
ALTER TABLE shopping_list_items ADD COLUMN auto_replenished boolean NOT NULL DEFAULT false;

-- A checked, removed or archived item stays dismissed until newer stock evidence arrives.
CREATE TABLE replenishment_dismissals (
  household_id uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  inventory_item_id uuid PRIMARY KEY REFERENCES inventory_items ON DELETE CASCADE,
  observed_at timestamptz NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE replenishment_dismissals ENABLE ROW LEVEL SECURITY;
CREATE POLICY replenishment_dismissals_household ON replenishment_dismissals
  USING (household_id = ANY (app_household_ids()))
  WITH CHECK (household_id = ANY (app_household_ids()));
GRANT SELECT, INSERT, UPDATE ON replenishment_dismissals TO agora_rw;

-- Preserve decisions made before automation was introduced.
INSERT INTO replenishment_dismissals (household_id, inventory_item_id, observed_at, decided_at)
SELECT DISTINCT ON (i.id) i.household_id, i.id, o.time, greatest(li.checked_at, l.completed_at)
FROM inventory_items i
JOIN LATERAL (SELECT time FROM inventory_observations WHERE inventory_item_id = i.id
              ORDER BY time DESC LIMIT 1) o ON true
JOIN shopping_list_items li ON li.inventory_item_id = i.id AND li.household_id = i.household_id
JOIN shopping_lists l ON l.id = li.list_id
WHERE (li.checked OR l.status <> 'open') AND greatest(li.checked_at, l.completed_at) >= o.time
ORDER BY i.id, greatest(li.checked_at, l.completed_at) DESC
ON CONFLICT DO NOTHING;

-- Allow a follow-up while a job is running: an observation arriving mid-run must not be lost.
CREATE UNIQUE INDEX jobs_lists_replenish_once ON jobs ((payload->>'household_id'))
  WHERE kind = 'lists.replenish' AND status = 'queued';
