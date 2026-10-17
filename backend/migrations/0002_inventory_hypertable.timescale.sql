-- TimescaleDB-only step. The runner applies *.timescale.sql files only when the extension can be enabled,
-- and nothing else may depend on them, so the schema stays valid on plain Postgres.

SELECT create_hypertable('inventory_observations', by_range('time', INTERVAL '7 days'),
                         migrate_data => true, if_not_exists => true);

-- Raw observations are personal data. Keep a year, then let the database drop them on its own.
SELECT add_retention_policy('inventory_observations', INTERVAL '365 days', if_not_exists => true);
