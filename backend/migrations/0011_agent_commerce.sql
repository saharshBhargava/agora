-- Agent commerce trust layer: what the user lets the agent spend (mandates), what the agent asks to do
-- (intents, each with a deterministic policy decision), and the money side (budgets, orders, spend).
--
-- The model proposes; app/core/policy.py disposes. Every intent stores the decision and the user-facing reasons
-- behind it, so the app can always show why something was allowed, escalated or refused.
-- Card data never reaches this schema: orders keep a provider token reference plus brand/last4 only.

ALTER TABLE user_settings ADD COLUMN agent_paused_at timestamptz;  -- kill switch: set by POST /v1/agent/pause

-- User-granted spending authority, modelled on Visa Intelligent Commerce agent credentials: who (one user's
-- agent in one household), where (merchants / categories; NULL = any), how much (per purchase and per period),
-- when to still ask (require_confirm_above), and until when (expires_at is mandatory).
CREATE TABLE agent_mandates (
  id                           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                      uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  household_id                 uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  label                        text NOT NULL CHECK (length(label) BETWEEN 1 AND 60),
  merchant_ids                 uuid[] CHECK (cardinality(merchant_ids) BETWEEN 1 AND 20),
  categories                   text[] CHECK (cardinality(categories) BETWEEN 1 AND 20),
  currency                     char(3) NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
  max_per_txn_cents            bigint NOT NULL CHECK (max_per_txn_cents BETWEEN 1 AND 10000000),
  max_per_period_cents         bigint CHECK (max_per_period_cents BETWEEN 1 AND 100000000),
  period                       text NOT NULL DEFAULT 'month' CHECK (period IN ('day', 'week', 'month')),
  require_confirm_above_cents  bigint CHECK (require_confirm_above_cents >= 0),
  expires_at                   timestamptz NOT NULL,
  status                       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  revoked_at                   timestamptz,
  revoked_reason               text CHECK (revoked_reason IN ('user', 'kill_switch')),
  created_at                   timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
  CHECK (max_per_period_cents IS NULL OR max_per_period_cents >= max_per_txn_cents)
);
CREATE INDEX agent_mandates_user ON agent_mandates (user_id, household_id) WHERE status = 'active';

-- Something the agent wants to do. decision is the policy engine's verdict at proposal time; status tracks
-- execution: proposed -> approved/rejected/cancelled -> executing -> succeeded/failed/outcome_unknown.
-- outcome_unknown is never retried automatically.
CREATE TABLE agent_intents (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  household_id        uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  kind                text NOT NULL CHECK (kind IN ('purchase', 'add_to_cart', 'list_add', 'calendar_event')),
  execution           text NOT NULL DEFAULT 'device' CHECK (execution IN ('device', 'agora')),
  title               text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
  item_key            text NOT NULL,  -- product id or normalized title: duplicate detection
  payload             jsonb NOT NULL DEFAULT '{}',
  amount_cents        bigint CHECK (amount_cents BETWEEN 1 AND 10000000),
  final_amount_cents  bigint CHECK (final_amount_cents BETWEEN 0 AND 100000000),
  currency            char(3) NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
  merchant_id         uuid REFERENCES merchants ON DELETE SET NULL,
  merchant_name       text CHECK (length(merchant_name) BETWEEN 1 AND 80),
  category            text CHECK (length(category) BETWEEN 1 AND 40),
  rationale           text NOT NULL CHECK (length(rationale) BETWEEN 1 AND 500),
  evidence            jsonb NOT NULL DEFAULT '[]',
  decision            text NOT NULL CHECK (decision IN ('allow', 'needs_approval', 'deny')),
  decision_reasons    text[] NOT NULL CHECK (cardinality(decision_reasons) >= 1),
  reason_codes        text[] NOT NULL,
  mandate_id          uuid REFERENCES agent_mandates ON DELETE SET NULL,
  status              text NOT NULL CHECK (status IN ('proposed', 'approved', 'rejected', 'cancelled', 'executing',
                                                      'succeeded', 'failed', 'outcome_unknown')),
  decided_by          text CHECK (decided_by IN ('policy', 'user', 'kill_switch')),
  decided_at          timestamptz,
  reject_reason       text CHECK (reject_reason IN ('too_expensive', 'not_needed', 'wrong_item', 'wrong_merchant',
                                                    'other')),
  error_code          text CHECK (error_code ~ '^[a-z0-9_]{1,40}$'),
  idempotency_key     text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  completed_at        timestamptz,
  UNIQUE (user_id, idempotency_key),
  CHECK (kind <> 'purchase' OR amount_cents IS NOT NULL),
  CHECK (execution = 'device' OR kind = 'purchase'),
  CHECK (decision <> 'deny' OR status = 'rejected'),
  CHECK (mandate_id IS NULL OR decision = 'allow')
);
CREATE INDEX agent_intents_household_time ON agent_intents (household_id, created_at DESC);
CREATE INDEX agent_intents_pending ON agent_intents (user_id) WHERE status IN ('proposed', 'approved');

CREATE TABLE budgets (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  period        text NOT NULL CHECK (period IN ('week', 'month')),
  category      text CHECK (length(category) BETWEEN 1 AND 40),  -- NULL = everything
  limit_cents   bigint NOT NULL CHECK (limit_cents BETWEEN 1 AND 100000000),
  currency      char(3) NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
  starts_on     date NOT NULL DEFAULT current_date,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_by    uuid REFERENCES users ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX budgets_one_active ON budgets (household_id, period, coalesce(category, ''))
  WHERE status = 'active';

-- Orders from agent checkouts (and later receipts / manual entry). agent_intent_id is unique, so one intent can
-- produce at most one order however many times anything is retried.
CREATE TABLE orders (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id         uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  user_id              uuid REFERENCES users ON DELETE SET NULL,
  merchant_id          uuid REFERENCES merchants ON DELETE SET NULL,
  merchant_name        text CHECK (length(merchant_name) BETWEEN 1 AND 80),
  title                text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
  category             text CHECK (length(category) BETWEEN 1 AND 40),
  channel              text NOT NULL CHECK (channel IN ('online', 'in_store', 'agent')),
  status               text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'refunded')),
  total_cents          bigint NOT NULL CHECK (total_cents BETWEEN 0 AND 100000000),
  currency             char(3) NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
  payment_provider     text NOT NULL CHECK (payment_provider IN ('simulated', 'stripe_test', 'visa_sandbox',
                                                                 'merchant_site')),
  payment_ref          text CHECK (length(payment_ref) BETWEEN 1 AND 200),  -- provider charge / token ref only
  payment_brand        text CHECK (payment_brand IN ('visa', 'mastercard', 'amex', 'discover', 'other')),
  payment_last4        char(4) CHECK (payment_last4 ~ '^[0-9]{4}$'),
  agent_intent_id      uuid UNIQUE REFERENCES agent_intents ON DELETE SET NULL,
  placed_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_household_time ON orders (household_id, placed_at DESC);

-- Time series: one row per order (per category, once orders have line items). Converted to a hypertable by
-- 0012 when TimescaleDB is available. Corrections and refunds are new (negative) rows, never updates.
CREATE TABLE spend_entries (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  time          timestamptz NOT NULL,
  household_id  uuid NOT NULL REFERENCES households ON DELETE CASCADE,
  user_id       uuid REFERENCES users ON DELETE SET NULL,
  amount_cents  bigint NOT NULL CHECK (amount_cents <> 0 AND abs(amount_cents) <= 100000000),
  currency      char(3) NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
  category      text CHECK (length(category) BETWEEN 1 AND 40),
  merchant_id   uuid REFERENCES merchants ON DELETE SET NULL,
  order_id      uuid REFERENCES orders ON DELETE SET NULL,
  PRIMARY KEY (id, time)
);
CREATE INDEX spend_entries_household_time ON spend_entries (household_id, time DESC);

-- ---------------------------------------------------------------- row-level security
-- Mandates are one person's authority, so only that person sees or changes them. Intents are visible to the
-- whole household (everyone can see what an agent is doing with shared money) but only their owner acts on
-- them. Budgets, orders and spend are household data.

ALTER TABLE agent_mandates ENABLE ROW LEVEL SECURITY;
CREATE POLICY agent_mandates_own ON agent_mandates
  USING (user_id = app_user_id() AND household_id = ANY (app_household_ids()))
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids()));

ALTER TABLE agent_intents ENABLE ROW LEVEL SECURITY;
CREATE POLICY agent_intents_read ON agent_intents FOR SELECT USING (household_id = ANY (app_household_ids()));
CREATE POLICY agent_intents_insert ON agent_intents FOR INSERT
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids()));
CREATE POLICY agent_intents_update ON agent_intents FOR UPDATE
  USING (user_id = app_user_id() AND household_id = ANY (app_household_ids()))
  WITH CHECK (user_id = app_user_id() AND household_id = ANY (app_household_ids()));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['budgets', 'orders', 'spend_entries'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON %I USING (household_id = ANY (app_household_ids())) '
                   'WITH CHECK (household_id = ANY (app_household_ids()))', t || '_household', t);
  END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE ON agent_mandates, agent_intents, budgets TO agora_rw;  -- revoking is an UPDATE
GRANT SELECT, INSERT ON orders, spend_entries TO agora_rw;  -- money history is append-only from requests
