-- TimescaleDB-only step (see 0002). Spend is append-only time series; budget and spend views read it by period.
-- No retention policy: spend history is the user's financial record, kept until they delete their account.

SELECT create_hypertable('spend_entries', by_range('time', INTERVAL '30 days'),
                         migrate_data => true, if_not_exists => true);
