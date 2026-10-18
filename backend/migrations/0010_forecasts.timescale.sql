-- TimescaleDB-only step (see 0002). Forecast history is a time series: one row per item per recompute.

SELECT create_hypertable('consumption_forecasts', by_range('computed_at', INTERVAL '30 days'),
                         migrate_data => true, if_not_exists => true);

-- A year of history is plenty for "forecast vs actual"; the database drops older rows by itself.
SELECT add_retention_policy('consumption_forecasts', INTERVAL '365 days', if_not_exists => true);
