-- =====================================================================
-- EMS - database check. Run it on the EMS database (works in any SQL tool). Every line should say OK.
-- Lines saying MISSING show which part of the installation did not run: install again, or send me this result.
-- =====================================================================
SELECT * FROM (
SELECT kind, name, CASE WHEN ok THEN 'OK' ELSE 'MISSING' END AS status
FROM (
  SELECT e.kind, e.name,
         CASE WHEN e.kind = 'function' THEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = e.name)
              ELSE to_regclass('public.' || e.name) IS NOT NULL END AS ok
  FROM (VALUES
    ('table','areas'),('table','meters'),('table','meter_latest'),('table','readings'),('table','app_settings'),
    ('continuous aggregate','readings_15min'),('continuous aggregate','readings_daily'),('view','plant_15min'),('view','plant_daily'),
    ('table','recipes'),('table','batches'),('view','v_batches'),('function','batch_start'),('function','batch_end'),
    ('table','report_fields'),('table','report_dimensions'),('table','report_templates'),('function','run_report'),
    ('table','users'),('table','user_sessions'),('table','audit_log'),('function','audit_row_change'),
    ('table','alarm_rules'),('table','alarm_events'),('view','v_alarms'),('function','alarm_raise'),
    ('table','tariffs'),('table','tariff_periods'),('function','energy_cost')
  ) AS e(kind, name)
) x
UNION ALL SELECT 'info', 'TimescaleDB version', coalesce((SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'), 'NOT INSTALLED - install the TimescaleDB extension first')
UNION ALL SELECT 'info', 'PostgreSQL version', current_setting('server_version')
) r
ORDER BY (status = 'OK'), kind, name;
