-- Household wishlist. Items come from the user (source 'user', start 'active') or from the on-device agent
-- (source 'agent', start 'suggested' and need an explicit accept / reject / snooze). Thumbs feedback is kept
-- separately so the agent can learn from it without changing an item's lifecycle.

CREATE TABLE wishlist_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id        uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  title               text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
  normalized_title    text NOT NULL CHECK (length(normalized_title) BETWEEN 1 AND 120),
  notes               text CHECK (length(notes) <= 1000),
  category            text CHECK (length(category) BETWEEN 1 AND 40),
  quantity            int NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 99),
  target_price_cents  int CHECK (target_price_cents BETWEEN 0 AND 10000000),
  needed_by           date,
  product_id          uuid REFERENCES products ON DELETE SET NULL,
  inventory_item_id   uuid REFERENCES inventory_items ON DELETE SET NULL,
  source              text NOT NULL CHECK (source IN ('user', 'agent')),
  status              text NOT NULL
                      CHECK (status IN ('suggested', 'active', 'snoozed', 'rejected', 'purchased', 'removed')),
  pinned              boolean NOT NULL DEFAULT false,
  priority            smallint CHECK (priority BETWEEN 1 AND 5),
  -- Agent suggestions only: why, how sure, and what it looked at.
  confidence          numeric(4, 3) CHECK (confidence BETWEEN 0 AND 1),
  rationale           text CHECK (length(rationale) BETWEEN 1 AND 500),
  evidence            jsonb NOT NULL DEFAULT '[]',
  snoozed_until       timestamptz,
  reject_reason       text CHECK (reject_reason IN ('not_interested', 'already_have', 'too_expensive', 'wrong_item',
                                                    'other')),
  reject_comment      text CHECK (length(reject_comment) <= 500),
  created_by          uuid REFERENCES users ON DELETE SET NULL,
  decided_by          uuid REFERENCES users ON DELETE SET NULL,
  decided_at          timestamptz,
  accepted_at         timestamptz,
  completed_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, household_id),
  CHECK (source = 'user' OR (rationale IS NOT NULL AND confidence IS NOT NULL)),
  CHECK (source = 'agent' OR status NOT IN ('suggested', 'snoozed', 'rejected')),
  CHECK ((status = 'snoozed') = (snoozed_until IS NOT NULL)),
  CHECK ((status = 'rejected') = (reject_reason IS NOT NULL))
);
CREATE INDEX wishlist_items_household_status ON wishlist_items (household_id, status);
CREATE INDEX wishlist_items_household_title ON wishlist_items (household_id, normalized_title);

-- One thumbs up/down per user per item. The composite key keeps feedback in the item's own household.
CREATE TABLE wishlist_feedback (
  wishlist_item_id  uuid NOT NULL,
  household_id      uuid NOT NULL,
  user_id           uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  rating            text NOT NULL CHECK (rating IN ('up', 'down')),
  reason_code       text CHECK (reason_code IN ('not_interested', 'already_have', 'too_expensive', 'wrong_item',
                                                'other')),
  comment           text CHECK (length(comment) <= 500),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (wishlist_item_id, user_id),
  FOREIGN KEY (wishlist_item_id, household_id) REFERENCES wishlist_items (id, household_id) ON DELETE CASCADE
);
CREATE INDEX wishlist_feedback_household ON wishlist_feedback (household_id);

ALTER TABLE wishlist_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY wishlist_items_household ON wishlist_items
  USING (household_id = ANY (app_household_ids())) WITH CHECK (household_id = ANY (app_household_ids()));

-- Household members can read each other's feedback (it feeds the shared ranking) but only write their own.
ALTER TABLE wishlist_feedback ENABLE ROW LEVEL SECURITY;
CREATE POLICY wishlist_feedback_read ON wishlist_feedback FOR SELECT
  USING (household_id = ANY (app_household_ids()));
CREATE POLICY wishlist_feedback_own ON wishlist_feedback
  USING (household_id = ANY (app_household_ids()) AND user_id = app_user_id())
  WITH CHECK (household_id = ANY (app_household_ids()) AND user_id = app_user_id());

GRANT SELECT, INSERT, UPDATE ON wishlist_items TO agora_rw;  -- no DELETE: removal is a status change
GRANT SELECT, INSERT, UPDATE, DELETE ON wishlist_feedback TO agora_rw;
