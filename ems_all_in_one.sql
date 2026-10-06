-- =====================================================================
-- EMS Level 1 - COMPLETE DATABASE in one file (for pgAdmin, DBeaver or any SQL tool).
-- Run it ONCE on an EMPTY database that has the TimescaleDB extension available:
--   1. create a database (for example "ems"), 2. open this file in the Query Tool of that database, 3. run it (F5).
-- PLANT TIME ZONE: this file uses 'Asia/Kolkata' in 3 places. Replace it (Find & Replace) if your plant is elsewhere.
-- Afterwards run ems_check.sql: every line must say OK.
-- =====================================================================

-- =====================================================================
-- EMS Level 1 - database schema v1 (Step 1 + Step 2)
-- Requires PostgreSQL with TimescaleDB 2.18 or newer.
-- Run as a superuser (or the DB owner) on an empty database, e.g. "ems".
--   psql -U postgres -d ems -f ems_schema_v1.sql
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ---------------------------------------------------------------------
-- STEP 1: master data
-- ---------------------------------------------------------------------
CREATE TABLE areas (
  id         serial PRIMARY KEY,
  parent_id  int REFERENCES areas(id),          -- NULL = top-level (the tabs in the UI)
  name       text NOT NULL,
  sort_order int  NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX areas_unique_name ON areas (coalesce(parent_id, 0), name);

CREATE TABLE meters (
  id                serial PRIMARY KEY,
  code              text UNIQUE NOT NULL,        -- short tag, e.g. 'MX-101'
  name              text NOT NULL,               -- e.g. 'Mixer M-101'
  area_id           int  NOT NULL REFERENCES areas(id),
  plc_index         smallint UNIQUE NOT NULL CHECK (plc_index BETWEEN 0 AND 79),  -- slot in the PLC array
  has_batch         boolean NOT NULL DEFAULT false,
  multiplier        numeric NOT NULL DEFAULT 1,  -- CT/PT scaling if the PLC does not apply it
  run_source        text NOT NULL DEFAULT 'kw' CHECK (run_source IN ('plc','kw')),
  idle_threshold_kw real NOT NULL DEFAULT 1,     -- used only when run_source = 'kw'
  is_active         boolean NOT NULL DEFAULT true,
  sort_order        int NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX meters_area_idx ON meters (area_id, sort_order);

-- ---------------------------------------------------------------------
-- STEP 2a: latest values (one row per meter, upserted on every PLC poll)
-- state: 0 = down, 1 = idle, 2 = running
-- The API treats a row with ts older than ~30 s as DOWN, even if state says otherwise.
-- ---------------------------------------------------------------------
CREATE TABLE meter_latest (
  meter_id      int PRIMARY KEY REFERENCES meters(id),
  ts            timestamptz NOT NULL,
  state         smallint NOT NULL DEFAULT 0 CHECK (state IN (0,1,2)),
  v_l1 real, v_l2 real, v_l3 real,
  i_l1 real, i_l2 real, i_l3 real,
  kw real, kvar real, kva real, pf real, freq real,
  kwh_import    double precision,
  kwh_export    double precision,
  batch_running boolean NOT NULL DEFAULT false,
  batch_no      text,
  recipe_id     int
);

-- ---------------------------------------------------------------------
-- STEP 2b: raw readings (one row per meter per logging interval)
-- quality bit flags: 1 = counter reset, 2 = gap/estimated, 4 = invalid data
-- kwh_*_delta = consumption since the previous logged sample (0 on reset)
-- ---------------------------------------------------------------------
CREATE TABLE readings (
  ts               timestamptz NOT NULL,
  meter_id         int NOT NULL REFERENCES meters(id),
  state            smallint NOT NULL CHECK (state IN (0,1,2)),
  v_l1 real, v_l2 real, v_l3 real,
  i_l1 real, i_l2 real, i_l3 real,
  kw real, kvar real, kva real, pf real, freq real,
  kwh_import       double precision,
  kwh_export       double precision,
  kwh_import_delta double precision,
  kwh_export_delta double precision,
  quality          smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (meter_id, ts)
);

-- ---------------------------------------------------------------------
-- STEP 2c: make it a time-series table (TimescaleDB hypertable)
-- ---------------------------------------------------------------------
SELECT create_hypertable('readings', 'ts', chunk_time_interval => INTERVAL '7 days');

-- Columnar compression (called "columnstore" in TimescaleDB 2.18+)
ALTER TABLE readings SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'meter_id',
  timescaledb.orderby   = 'ts DESC'
);
CALL add_columnstore_policy('readings', INTERVAL '7 days');     -- compress chunks older than 7 days (a procedure, so CALL)

-- Keep raw data for 2 years (aggregates in Step 3 will be kept longer). Adjust as needed.
SELECT add_retention_policy('readings', INTERVAL '2 years');

-- ---------------------------------------------------------------------
-- OPTIONAL TEST DATA (delete this block for production)
-- ---------------------------------------------------------------------
-- INSERT INTO areas (name, sort_order) VALUES ('Blending', 1), ('Extrusion', 2);
-- INSERT INTO meters (code, name, area_id, plc_index, has_batch, run_source)
--   VALUES ('MX-101', 'Mixer M-101', 1, 0, true, 'plc'), ('EX-204', 'Extruder E-204', 2, 1, true, 'plc');
-- INSERT INTO readings (ts, meter_id, state, kw, kwh_import, kwh_import_delta)
--   VALUES (now(), 1, 2, 212.4, 3120.5, 3.5);

-- ---------------------------------------------------------------------
-- VERIFY (run these after the script)
-- ---------------------------------------------------------------------
-- SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
-- SELECT hypertable_name, num_chunks FROM timescaledb_information.hypertables;
-- SELECT job_id, proc_name, hypertable_name, schedule_interval FROM timescaledb_information.jobs;


-- =====================================================================
-- EMS Level 1 - database schema v2 (Step 3: aggregates for charts and reports)
-- Run AFTER ems_schema_v1.sql, on the same database.
--   psql -U postgres -d ems -f ems_schema_v2_aggregates.sql
-- PLANT TIME ZONE: this file uses 'Asia/Kolkata' in 3 places (search for it). If your plant is in another time zone,
-- replace it BEFORE running (names like Europe/Berlin, America/New_York, Asia/Dubai).
-- Works in psql, pgAdmin, DBeaver and other tools (no psql-only commands).
-- Do NOT wrap this script in BEGIN/COMMIT: continuous aggregates cannot be created in a transaction.
-- =====================================================================

-- The plant time zone decides where a "day" starts and ends in daily/monthly reports (used in 3 places below).

-- ---------------------------------------------------------------------
-- Settings the API/UI can read, and the plant-total flag on meters
-- ---------------------------------------------------------------------
CREATE TABLE app_settings (
  key   text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO app_settings (key, value) VALUES ('plant_timezone', 'Asia/Kolkata');

-- Plant total = sum of meters flagged is_main (incomer / main meters).
-- Do not flag sub-meters, or the plant total counts the same energy twice.
ALTER TABLE meters ADD COLUMN is_main boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------
-- 15-minute aggregate: demand and short-term trends.
-- Hourly values are built from these at query time (4 rows per hour).
-- Minutes running/idle/down = *_samples x logging interval (1 minute by default).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW readings_15min
WITH (timescaledb.continuous) AS
SELECT time_bucket('15 minutes', ts) AS bucket,
       meter_id,
       sum(kwh_import_delta) AS kwh_import,
       sum(kwh_export_delta) AS kwh_export,
       avg(kw) AS kw_avg, min(kw) AS kw_min, max(kw) AS kw_max,
       avg(kvar) AS kvar_avg, avg(kva) AS kva_avg, avg(pf) AS pf_avg, avg(freq) AS freq_avg,
       avg(v_l1) AS v_l1_avg, avg(v_l2) AS v_l2_avg, avg(v_l3) AS v_l3_avg,
       avg(i_l1) AS i_l1_avg, avg(i_l2) AS i_l2_avg, avg(i_l3) AS i_l3_avg,
       max(greatest(i_l1, i_l2, i_l3)) AS i_max,
       count(*) AS samples,
       count(*) FILTER (WHERE state = 2) AS running_samples,
       count(*) FILTER (WHERE state = 1) AS idle_samples,
       count(*) FILTER (WHERE state = 0) AS down_samples
FROM readings
GROUP BY bucket, meter_id
WITH NO DATA;

-- ---------------------------------------------------------------------
-- Daily aggregate in the plant time zone. Weekly and monthly reports are summed from this table.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW readings_daily
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', ts, 'Asia/Kolkata') AS day,
       meter_id,
       sum(kwh_import_delta) AS kwh_import,
       sum(kwh_export_delta) AS kwh_export,
       avg(kw) AS kw_avg, min(kw) AS kw_min, max(kw) AS kw_max,
       avg(kvar) AS kvar_avg, avg(kva) AS kva_avg, avg(pf) AS pf_avg, avg(freq) AS freq_avg,
       avg(v_l1) AS v_l1_avg, avg(v_l2) AS v_l2_avg, avg(v_l3) AS v_l3_avg,
       avg(i_l1) AS i_l1_avg, avg(i_l2) AS i_l2_avg, avg(i_l3) AS i_l3_avg,
       max(greatest(i_l1, i_l2, i_l3)) AS i_max,
       count(*) AS samples,
       count(*) FILTER (WHERE state = 2) AS running_samples,
       count(*) FILTER (WHERE state = 1) AS idle_samples,
       count(*) FILTER (WHERE state = 0) AS down_samples
FROM readings
GROUP BY day, meter_id
WITH NO DATA;

-- Real-time mode: queries also include the newest rows that are not materialized yet,
-- so "energy today" on the dashboard is always current.
ALTER MATERIALIZED VIEW readings_15min SET (timescaledb.materialized_only = false);
ALTER MATERIALIZED VIEW readings_daily SET (timescaledb.materialized_only = false);

-- ---------------------------------------------------------------------
-- Refresh policies (background jobs) and retention
-- ---------------------------------------------------------------------
SELECT add_continuous_aggregate_policy('readings_15min',
  start_offset => INTERVAL '3 days', end_offset => INTERVAL '15 minutes', schedule_interval => INTERVAL '5 minutes');
SELECT add_continuous_aggregate_policy('readings_daily',
  start_offset => INTERVAL '7 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '15 minutes');

-- Raw readings are dropped after 2 years (Step 2). Aggregates are kept longer:
SELECT add_retention_policy('readings_15min', INTERVAL '5 years');
-- readings_daily has no retention policy: monthly/yearly history is kept forever (about 29,000 rows per year).

-- ---------------------------------------------------------------------
-- Plant-level views (sum of the meters flagged is_main)
-- kw_demand = average kW over the 15 minutes, summed over the main meters
-- ---------------------------------------------------------------------
CREATE VIEW plant_15min AS
SELECT r.bucket,
       sum(r.kw_avg)     AS kw_demand,
       sum(r.kwh_import) AS kwh_import,
       sum(r.kwh_export) AS kwh_export,
       count(*)          AS main_meters
FROM readings_15min r
JOIN meters m ON m.id = r.meter_id AND m.is_main
GROUP BY r.bucket;

CREATE VIEW plant_daily AS
SELECT time_bucket('1 day', bucket, 'Asia/Kolkata')                 AS day,
       sum(kwh_import)                                           AS kwh_import,
       sum(kwh_export)                                           AS kwh_export,
       max(kw_demand)                                            AS peak_demand_kw,
       (array_agg(bucket ORDER BY kw_demand DESC))[1]            AS peak_at
FROM plant_15min
GROUP BY 1;

-- ---------------------------------------------------------------------
-- Manual refresh after loading old data or fixing readings older than the policy window:
--   CALL refresh_continuous_aggregate('readings_15min', '2026-01-01', '2026-02-01');
--   CALL refresh_continuous_aggregate('readings_daily',  '2026-01-01', '2026-02-01');
--
-- EXAMPLE QUERIES FOR THE API (all time stamps are timestamptz; the plant time zone is in app_settings)
--   Energy per meter per month:      SELECT time_bucket('1 month', day, 'Asia/Kolkata') AS month, meter_id, sum(kwh_import)
--                                    FROM readings_daily GROUP BY 1, 2 ORDER BY 1, 2;
--   Energy per area, last 7 days:    SELECT d.day, a.name, sum(d.kwh_import) FROM readings_daily d
--                                    JOIN meters m ON m.id = d.meter_id JOIN areas a ON a.id = m.area_id
--                                    WHERE NOT m.is_main AND d.day >= now() - interval '7 days' GROUP BY 1, 2;
--   Hourly values for a meter:       SELECT time_bucket('1 hour', bucket) AS hour, sum(kwh_import), avg(kw_avg)
--                                    FROM readings_15min WHERE meter_id = 1 AND bucket >= now() - interval '2 days' GROUP BY 1;
--   Running hours per day:           SELECT day, meter_id, running_samples / 60.0 AS running_hours FROM readings_daily;
-- ---------------------------------------------------------------------


-- =====================================================================
-- EMS Level 1 - Step 4: batches
-- Run after ems_schema_v2_aggregates.sql.
-- The collector calls batch_start() / batch_end() when it sees a batch start/stop from the PLC.
-- Energy per batch comes from the meter counters at start and end (exact); if a counter was reset
-- during the batch, the logged 1-minute deltas are used instead (approximate).
-- =====================================================================

-- Recipe names (the PLC only sends a number). Unknown numbers are added automatically as 'Recipe <n>'; rename them in the UI.
CREATE TABLE recipes (
  id   int PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE batches (
  id               bigserial PRIMARY KEY,
  meter_id         int  NOT NULL REFERENCES meters(id),
  batch_no         text NOT NULL,
  recipe_id        int,
  target_qty       real,
  actual_qty       real,
  start_ts         timestamptz NOT NULL,
  end_ts           timestamptz,                         -- NULL while running
  status           text NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed')),
  recovered        boolean NOT NULL DEFAULT false,      -- start or end was reconstructed after a restart (times/energy approximate)
  kwh_import_start double precision, kwh_import_end double precision,
  kwh_export_start double precision, kwh_export_end double precision,
  kwh_import       double precision,                    -- energy used by the batch (filled when it ends)
  kwh_export       double precision,
  peak_kw          real,
  avg_kw           real,
  CHECK ((status = 'running') = (end_ts IS NULL)),
  CHECK (end_ts IS NULL OR end_ts >= start_ts)
);
CREATE INDEX batches_meter_start ON batches (meter_id, start_ts DESC);
CREATE INDEX batches_batch_no    ON batches (batch_no);
CREATE INDEX batches_recipe      ON batches (recipe_id, start_ts DESC);
CREATE UNIQUE INDEX batches_one_open_per_meter ON batches (meter_id) WHERE end_ts IS NULL;

-- End the open batch of a meter. Returns the batch id, or NULL if nothing was open (safe to call twice).
CREATE FUNCTION batch_end(p_meter int, p_ts timestamptz, p_actual_qty real,
                          p_kwh_import double precision, p_kwh_export double precision,
                          p_recovered boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE b batches%ROWTYPE; ki double precision; ke double precision;
        pk real; av real; sdi double precision; sde double precision; t_end timestamptz;
BEGIN
  SELECT * INTO b FROM batches WHERE meter_id = p_meter AND end_ts IS NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  t_end := greatest(p_ts, b.start_ts);
  SELECT max(kw), avg(kw), sum(kwh_import_delta), sum(kwh_export_delta) INTO pk, av, sdi, sde
    FROM readings WHERE meter_id = p_meter AND ts > b.start_ts AND ts <= t_end;
  ki := p_kwh_import - b.kwh_import_start;
  IF ki IS NULL OR ki < 0 THEN ki := sdi; END IF;          -- counter missing or reset: use logged deltas
  ke := p_kwh_export - b.kwh_export_start;
  IF ke IS NULL OR ke < 0 THEN ke := sde; END IF;
  UPDATE batches SET end_ts = t_end, status = 'completed',
         actual_qty = coalesce(p_actual_qty, actual_qty),
         kwh_import_end = p_kwh_import, kwh_export_end = p_kwh_export,
         kwh_import = ki, kwh_export = ke, peak_kw = pk, avg_kw = av,
         recovered = recovered OR p_recovered
   WHERE id = b.id;
  RETURN b.id;
END $$;

-- Start a batch. If the same batch number is already open it does nothing; if another batch is open it is closed first.
CREATE FUNCTION batch_start(p_meter int, p_batch_no text, p_recipe int, p_target real, p_ts timestamptz,
                            p_kwh_import double precision, p_kwh_export double precision,
                            p_recovered boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE o batches%ROWTYPE; new_id bigint; no text := coalesce(nullif(trim(p_batch_no), ''), '(no number)');
BEGIN
  SELECT * INTO o FROM batches WHERE meter_id = p_meter AND end_ts IS NULL;
  IF FOUND THEN
    IF o.batch_no = no THEN RETURN o.id; END IF;
    PERFORM batch_end(p_meter, p_ts, NULL, p_kwh_import, p_kwh_export, true);
  END IF;
  IF p_recipe IS NOT NULL AND p_recipe <> 0 THEN
    INSERT INTO recipes (id, name) VALUES (p_recipe, 'Recipe ' || p_recipe) ON CONFLICT DO NOTHING;
  END IF;
  INSERT INTO batches (meter_id, batch_no, recipe_id, target_qty, start_ts, kwh_import_start, kwh_export_start, recovered)
  VALUES (p_meter, no, nullif(p_recipe, 0), p_target, p_ts, p_kwh_import, p_kwh_export, p_recovered)
  RETURNING id INTO new_id;
  RETURN new_id;
END $$;

-- One row per batch, with live numbers for running batches. This is what the Batches screen and the meter cards read.
CREATE VIEW v_batches AS
SELECT b.id, b.meter_id, m.name AS meter_name, a.name AS area_name,
       b.batch_no, b.recipe_id, coalesce(r.name, CASE WHEN b.recipe_id IS NOT NULL THEN 'Recipe ' || b.recipe_id END) AS recipe_name,
       b.target_qty, b.actual_qty, b.start_ts, b.end_ts, b.status, b.recovered,
       coalesce(b.end_ts, now()) - b.start_ts AS duration,
       CASE WHEN b.status = 'running' THEN greatest(l.kwh_import - b.kwh_import_start, 0) ELSE b.kwh_import END AS kwh_import,
       CASE WHEN b.status = 'running' THEN x.pk ELSE b.peak_kw END AS peak_kw,
       CASE WHEN b.status = 'running' THEN x.av ELSE b.avg_kw END AS avg_kw,
       CASE WHEN b.status = 'running' THEN l.kw END AS current_kw,
       CASE WHEN coalesce(b.actual_qty, 0) > 0 THEN
         (CASE WHEN b.status = 'running' THEN l.kwh_import - b.kwh_import_start ELSE b.kwh_import END) / b.actual_qty END AS kwh_per_unit
FROM batches b
JOIN meters m ON m.id = b.meter_id
JOIN areas a ON a.id = m.area_id
LEFT JOIN recipes r ON r.id = b.recipe_id
LEFT JOIN meter_latest l ON l.meter_id = b.meter_id AND b.status = 'running'
LEFT JOIN LATERAL (SELECT max(kw) AS pk, avg(kw) AS av FROM readings
                   WHERE meter_id = b.meter_id AND ts > b.start_ts AND b.status = 'running') x ON true;

-- Power curve of a batch (minute 0 = start): used for the batch detail chart and for comparing batches.
CREATE FUNCTION batch_curve(p_batch bigint) RETURNS TABLE (minute int, kw real)
LANGUAGE sql STABLE AS $$
  SELECT floor(extract(epoch FROM r.ts - b.start_ts) / 60)::int, r.kw
  FROM batches b JOIN readings r ON r.meter_id = b.meter_id AND r.ts > b.start_ts AND r.ts <= coalesce(b.end_ts, now())
  WHERE b.id = p_batch ORDER BY r.ts $$;

-- The previous completed batch of the same recipe on the same meter.
CREATE FUNCTION batch_previous(p_batch bigint) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT p.id FROM batches b
  JOIN batches p ON p.meter_id = b.meter_id AND p.recipe_id IS NOT DISTINCT FROM b.recipe_id
                AND p.status = 'completed' AND p.start_ts < b.start_ts
  WHERE b.id = p_batch ORDER BY p.start_ts DESC LIMIT 1 $$;

-- "At minute N this batch has used x% more/less energy than the previous batch at the same point."
CREATE FUNCTION batch_vs_previous(p_batch bigint)
RETURNS TABLE (previous_id bigint, elapsed_min int, kwh_this numeric, kwh_prev numeric, pct_diff numeric)
LANGUAGE sql STABLE AS $$
  WITH c AS (SELECT * FROM batches WHERE id = p_batch),
       p AS (SELECT * FROM batches WHERE id = batch_previous(p_batch)),
       e AS (SELECT floor(extract(epoch FROM coalesce(c.end_ts, now()) - c.start_ts) / 60)::int AS mins FROM c),
       s AS (
         SELECT p.id AS pid, e.mins,
           (SELECT sum(r.kwh_import_delta)::numeric FROM readings r
             WHERE r.meter_id = c.meter_id AND r.ts > c.start_ts AND r.ts <= c.start_ts + e.mins * interval '1 minute') AS a,
           (SELECT sum(r.kwh_import_delta)::numeric FROM readings r
             WHERE r.meter_id = p.meter_id AND r.ts > p.start_ts AND r.ts <= p.start_ts + e.mins * interval '1 minute') AS b
         FROM c, p, e)
  SELECT pid, mins, round(a, 2), round(b, 2), round((a - b) / nullif(b, 0) * 100, 1) FROM s $$;


-- =====================================================================
-- EMS Level 1 - Step 5: dynamic report builder
-- Run after ems_schema_v3_batches.sql.
-- The UI shows the fields/dimensions from the two registry tables. A report is a JSON definition;
-- run_report() validates it against the registry and builds the SQL itself, so the API never
-- accepts raw SQL and a user can only reach fields listed here.
--
-- Definition example:
--   { "groupBy": ["month","area"],
--     "range":   { "from": "2026-01-01", "to": "2026-06-30" },       -- dates in the plant time zone, both inclusive
--     "fields":  [ {"code":"energy_kwh","agg":"sum"}, {"code":"kw_peak"} ],
--     "scope":   "meters",              -- "meters" (default, excludes main meters), "plant" (main meters only), "all"
--     "meters":  [1,2,3] }              -- optional filters: "meters": [ids], "areas": [ids]
-- Usage:  SELECT * FROM run_report('{...}'::jsonb);   -- one JSON object per row
-- =====================================================================

CREATE TABLE report_dimensions (
  code        text PRIMARY KEY,
  label       text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('time','entity')),
  expr_daily  text,              -- SQL on readings_daily t (NULL = not available at day resolution)
  expr_15min  text,              -- SQL on readings_15min t
  fmt         text,              -- to_char format for time dimensions (plant local time)
  sort_order  int NOT NULL DEFAULT 0
);
INSERT INTO report_dimensions (code, label, kind, expr_daily, expr_15min, fmt, sort_order) VALUES
 ('hour',  'Hour',  'time',   NULL,                                   $$time_bucket('1 hour', t.bucket, {tz})$$, 'YYYY-MM-DD HH24:MI', 1),
 ('day',   'Day',   'time',   't.day',                                $$time_bucket('1 day', t.bucket, {tz})$$,  'YYYY-MM-DD', 2),
 ('week',  'Week',  'time',   $$date_trunc('week', t.day, {tz})$$,    $$date_trunc('week', t.bucket, {tz})$$,    'YYYY-MM-DD', 3),
 ('month', 'Month', 'time',   $$date_trunc('month', t.day, {tz})$$,   $$date_trunc('month', t.bucket, {tz})$$,   'YYYY-MM', 4),
 ('meter', 'Meter', 'entity', 'm.name',                               'm.name',                                  NULL, 5),
 ('area',  'Area',  'entity', 'a.name',                               'a.name',                                  NULL, 6);

CREATE TABLE report_fields (
  code         text PRIMARY KEY,
  label        text NOT NULL,
  unit         text,
  column_name  text NOT NULL,     -- column in readings_daily / readings_15min
  default_agg  text NOT NULL,
  allowed_aggs text[] NOT NULL,   -- subset of sum, avg, min, max
  scale        numeric NOT NULL DEFAULT 1,
  sort_order   int NOT NULL DEFAULT 0,
  CHECK (default_agg = ANY (allowed_aggs)),
  CHECK (allowed_aggs <@ ARRAY['sum','avg','min','max'])
);
-- Averages of averages are equal-weight averages of the periods (fine for 1-minute logging with few gaps).
-- running/idle/down hours assume 1-minute logging (samples / 60).
INSERT INTO report_fields (code, label, unit, column_name, default_agg, allowed_aggs, scale, sort_order) VALUES
 ('energy_kwh',        'Energy consumed',  'kWh',  'kwh_import',      'sum', ARRAY['sum'], 1, 1),
 ('energy_export_kwh', 'Energy exported',  'kWh',  'kwh_export',      'sum', ARRAY['sum'], 1, 2),
 ('kw_avg',            'Average power',    'kW',   'kw_avg',          'avg', ARRAY['avg','min','max'], 1, 3),
 ('kw_peak',           'Peak power',       'kW',   'kw_max',          'max', ARRAY['max','avg'], 1, 4),
 ('kw_min',            'Minimum power',    'kW',   'kw_min',          'min', ARRAY['min','avg'], 1, 5),
 ('kvar_avg',          'Reactive power',   'kVAR', 'kvar_avg',        'avg', ARRAY['avg','max'], 1, 6),
 ('kva_avg',           'Apparent power',   'kVA',  'kva_avg',         'avg', ARRAY['avg','max'], 1, 7),
 ('pf_avg',            'Power factor',     '',     'pf_avg',          'avg', ARRAY['avg','min'], 1, 8),
 ('freq_avg',          'Frequency',        'Hz',   'freq_avg',        'avg', ARRAY['avg','min','max'], 1, 9),
 ('v_l1_avg',          'Voltage L1',       'V',    'v_l1_avg',        'avg', ARRAY['avg','min','max'], 1, 10),
 ('v_l2_avg',          'Voltage L2',       'V',    'v_l2_avg',        'avg', ARRAY['avg','min','max'], 1, 11),
 ('v_l3_avg',          'Voltage L3',       'V',    'v_l3_avg',        'avg', ARRAY['avg','min','max'], 1, 12),
 ('current_max',       'Maximum current',  'A',    'i_max',           'max', ARRAY['max','avg'], 1, 13),
 ('running_hours',     'Running time',     'h',    'running_samples', 'sum', ARRAY['sum'], 1.0/60, 14),
 ('idle_hours',        'Idle time',        'h',    'idle_samples',    'sum', ARRAY['sum'], 1.0/60, 15),
 ('down_hours',        'Down time',        'h',    'down_samples',    'sum', ARRAY['sum'], 1.0/60, 16);

CREATE TABLE report_templates (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  owner_id    int,                          -- becomes a foreign key to users in Step 6
  is_shared   boolean NOT NULL DEFAULT false,
  definition  jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object' AND definition ? 'fields'),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX report_templates_owner ON report_templates (owner_id);

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;
CREATE TRIGGER report_templates_updated BEFORE UPDATE ON report_templates FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION run_report(def jsonb) RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  tz     text  := (SELECT value FROM app_settings WHERE key = 'plant_timezone');
  gb     jsonb := CASE WHEN jsonb_typeof(def->'groupBy') = 'string' THEN jsonb_build_array(def->'groupBy')
                       ELSE coalesce(def->'groupBy', '[]'::jsonb) END;
  from_d date  := (def #>> '{range,from}')::date;
  to_d   date  := (def #>> '{range,to}')::date;
  scope  text  := coalesce(def->>'scope', 'meters');
  use15  boolean; src text; tcol text; lo timestamptz; hi timestamptz;
  sel text[] := '{}'; ord text[] := '{}'; w text[] := '{}'; n int := 0;
  d report_dimensions; f report_fields; fld jsonb; dcode text; agg text; e text;
BEGIN
  IF tz IS NULL THEN RAISE EXCEPTION 'plant_timezone is missing in app_settings'; END IF;
  IF from_d IS NULL OR to_d IS NULL OR to_d < from_d THEN
    RAISE EXCEPTION 'range.from and range.to (dates, to >= from) are required'; END IF;
  IF jsonb_typeof(def->'fields') IS DISTINCT FROM 'array' OR jsonb_array_length(def->'fields') = 0 THEN
    RAISE EXCEPTION 'at least one field is required'; END IF;
  IF jsonb_array_length(gb) > 2 THEN RAISE EXCEPTION 'at most two groupBy dimensions'; END IF;
  IF scope NOT IN ('meters','plant','all') THEN RAISE EXCEPTION 'scope must be meters, plant or all'; END IF;

  use15 := EXISTS (SELECT 1 FROM report_dimensions WHERE code IN (SELECT jsonb_array_elements_text(gb)) AND expr_daily IS NULL);
  IF use15 AND to_d - from_d > 62 THEN RAISE EXCEPTION 'hourly reports are limited to 62 days'; END IF;
  src  := CASE WHEN use15 THEN 'readings_15min' ELSE 'readings_daily' END;
  tcol := CASE WHEN use15 THEN 'bucket' ELSE 'day' END;
  lo := from_d::timestamp AT TIME ZONE tz;
  hi := (to_d + 1)::timestamp AT TIME ZONE tz;

  FOR dcode IN SELECT jsonb_array_elements_text(gb) LOOP
    SELECT * INTO d FROM report_dimensions WHERE code = dcode;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown groupBy dimension: %', dcode; END IF;
    e := replace(CASE WHEN use15 THEN d.expr_15min ELSE d.expr_daily END, '{tz}', quote_literal(tz));
    IF d.kind = 'time' THEN e := format('to_char((%s) AT TIME ZONE %L, %L)', e, tz, d.fmt); END IF;
    n := n + 1; sel := sel || format('%s AS %I', e, d.code); ord := ord || n::text;
  END LOOP;

  FOR fld IN SELECT jsonb_array_elements(def->'fields') LOOP
    SELECT * INTO f FROM report_fields WHERE code = fld->>'code';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown field: %', fld->>'code'; END IF;
    agg := lower(coalesce(fld->>'agg', f.default_agg));
    IF NOT agg = ANY (f.allowed_aggs) THEN RAISE EXCEPTION 'aggregate % not allowed for field %', agg, f.code; END IF;
    sel := sel || format('round((%s(t.%I) * %s::numeric)::numeric, 3) AS %I', agg, f.column_name, f.scale, f.code || '_' || agg);
  END LOOP;

  w := w || format('t.%I >= %L AND t.%I < %L', tcol, lo, tcol, hi);
  w := w || CASE scope WHEN 'meters' THEN 'NOT m.is_main' WHEN 'plant' THEN 'm.is_main' ELSE 'true' END;
  IF jsonb_typeof(def->'meters') = 'array' THEN
    w := w || format('t.meter_id = ANY (%L::int[])', ARRAY(SELECT jsonb_array_elements_text(def->'meters'))::int[]); END IF;
  IF jsonb_typeof(def->'areas') = 'array' THEN
    w := w || format('m.area_id = ANY (%L::int[])', ARRAY(SELECT jsonb_array_elements_text(def->'areas'))::int[]); END IF;

  RETURN QUERY EXECUTE format(
    'SELECT to_jsonb(q) FROM (SELECT %s FROM %I t JOIN meters m ON m.id = t.meter_id JOIN areas a ON a.id = m.area_id WHERE %s %s LIMIT 10000) q',
    array_to_string(sel, ', '), src, array_to_string(w, ' AND '),
    CASE WHEN n > 0 THEN 'GROUP BY ' || array_to_string(ord, ', ') || ' ORDER BY ' || array_to_string(ord, ', ') ELSE '' END);
END $fn$;


-- =====================================================================
-- EMS Level 1 - Step 6: users, roles, sessions, audit log
-- Run after ems_schema_v4_report_builder.sql.
--
-- Roles (enforced by the API):
--   viewer   : dashboards, meters, batches, run and export reports, own report templates
--   engineer : viewer + share report templates, edit recipe names, acknowledge alarms
--   admin    : engineer + users, meters, areas, tariffs, alarm rules, settings
-- Passwords: the API stores only a hash (bcrypt or argon2) in users.password_hash. Never store a password.
-- Audit: before changing a config table, the API runs   SET LOCAL ems.user_id = '<user id>';   inside the same
-- transaction, and the triggers below record who changed what (old and new values).
-- =====================================================================

CREATE TABLE users (
  id                   serial PRIMARY KEY,
  username             text NOT NULL,
  display_name         text,
  email                text,
  password_hash        text NOT NULL,
  role                 text NOT NULL DEFAULT 'viewer' CHECK (role IN ('admin','engineer','viewer')),
  is_active            boolean NOT NULL DEFAULT true,
  must_change_password boolean NOT NULL DEFAULT false,
  failed_logins        int NOT NULL DEFAULT 0,
  locked_until         timestamptz,
  last_login_at        timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_username_ci ON users (lower(username));

-- Refresh-token sessions (store only a hash of the token)
CREATE TABLE user_sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash text NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz,
  ip                 inet,
  user_agent         text
);
CREATE INDEX user_sessions_user ON user_sessions (user_id, expires_at);

ALTER TABLE report_templates
  ADD CONSTRAINT report_templates_owner_fk FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
  id        bigserial PRIMARY KEY,
  ts        timestamptz NOT NULL DEFAULT now(),
  user_id   int,                    -- from ems.user_id (NULL = changed directly in the database)
  action    text NOT NULL,          -- INSERT / UPDATE / DELETE
  entity    text NOT NULL,          -- table name
  entity_id text,
  details   jsonb                   -- INSERT/DELETE: the row; UPDATE: {column: {old, new}}
);
CREATE INDEX audit_log_ts     ON audit_log (ts DESC);
CREATE INDEX audit_log_entity ON audit_log (entity, entity_id, ts DESC);
CREATE INDEX audit_log_user   ON audit_log (user_id, ts DESC);

CREATE FUNCTION audit_row_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
        n jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
        d jsonb; pw_changed boolean := false;
BEGIN
  IF TG_TABLE_NAME = 'users' THEN                       -- never copy password hashes into the log
    IF TG_OP = 'UPDATE' THEN pw_changed := (o->>'password_hash') IS DISTINCT FROM (n->>'password_hash'); END IF;
    o := o - 'password_hash' - 'failed_logins' - 'locked_until' - 'last_login_at';
    n := n - 'password_hash' - 'failed_logins' - 'locked_until' - 'last_login_at';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    SELECT jsonb_object_agg(k, jsonb_build_object('old', o->k, 'new', n->k)) INTO d
      FROM jsonb_object_keys(n) AS k WHERE o->k IS DISTINCT FROM n->k AND k <> 'updated_at';
    IF pw_changed THEN d := coalesce(d, '{}'::jsonb) || '{"password":"changed"}'; END IF;
    IF d IS NULL THEN RETURN NEW; END IF;                -- nothing worth logging
  ELSIF TG_OP = 'INSERT' THEN d := n;
  ELSE d := o; END IF;
  INSERT INTO audit_log (user_id, action, entity, entity_id, details)
  VALUES (nullif(current_setting('ems.user_id', true), '')::int, TG_OP, TG_TABLE_NAME,
          coalesce(n->>'id', n->>'key', o->>'id', o->>'key'), d);
  RETURN coalesce(NEW, OLD);
END $$;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['areas','meters','recipes','report_templates','users','app_settings','report_fields'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION audit_row_change()', 'audit_' || t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- First administrator (run once, then log in and change the password). Needs the pgcrypto extension:
--   CREATE EXTENSION IF NOT EXISTS pgcrypto;
--   INSERT INTO users (username, display_name, password_hash, role, must_change_password)
--   VALUES ('admin', 'Administrator', crypt('ChangeMe-123', gen_salt('bf', 12)), 'admin', true);
-- (bcrypt hashes made here can be verified by the Node bcrypt/bcryptjs libraries.)
-- ---------------------------------------------------------------------


-- =====================================================================
-- EMS Level 1 - Step 7 (optional): alarms and tariffs / cost
-- Run after ems_schema_v5_users_audit.sql.
-- Alarm rules are stored here; the collector/API evaluates them and calls alarm_raise() / alarm_clear().
-- =====================================================================

-- ---------------------------------------------------------------------
-- Alarms
-- ---------------------------------------------------------------------
CREATE TABLE alarm_rules (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  scope       text NOT NULL DEFAULT 'meter' CHECK (scope IN ('meter','area','all')),
  meter_id    int REFERENCES meters(id),
  area_id     int REFERENCES areas(id),
  metric      text NOT NULL CHECK (metric IN ('kw','kvar','kva','pf','freq','v_l1','v_l2','v_l3','i_l1','i_l2','i_l3','state')),
  operator    text NOT NULL CHECK (operator IN ('>','>=','<','<=','=')),
  threshold   double precision NOT NULL,            -- for metric 'state': 0 = down, 1 = idle, 2 = running
  for_seconds int NOT NULL DEFAULT 0,               -- condition must hold this long before the alarm is raised
  severity    text NOT NULL DEFAULT 'warning' CHECK (severity IN ('info','warning','critical')),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK ((scope = 'meter' AND meter_id IS NOT NULL) OR (scope = 'area' AND area_id IS NOT NULL) OR scope = 'all')
);

CREATE TABLE alarm_events (
  id              bigserial PRIMARY KEY,
  rule_id         int NOT NULL REFERENCES alarm_rules(id) ON DELETE CASCADE,
  meter_id        int NOT NULL REFERENCES meters(id),
  started_at      timestamptz NOT NULL,
  cleared_at      timestamptz,
  value           double precision,                 -- value that triggered it
  message         text,
  acknowledged_by int REFERENCES users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz
);
CREATE UNIQUE INDEX alarm_one_open ON alarm_events (rule_id, meter_id) WHERE cleared_at IS NULL;
CREATE INDEX alarm_events_started ON alarm_events (started_at DESC);
CREATE INDEX alarm_events_meter   ON alarm_events (meter_id, started_at DESC);

-- Raise an alarm (does nothing if the same rule/meter alarm is already open). Returns the event id.
CREATE FUNCTION alarm_raise(p_rule int, p_meter int, p_ts timestamptz, p_value double precision, p_message text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE eid bigint;
BEGIN
  INSERT INTO alarm_events (rule_id, meter_id, started_at, value, message) VALUES (p_rule, p_meter, p_ts, p_value, p_message)
  ON CONFLICT (rule_id, meter_id) WHERE cleared_at IS NULL DO NOTHING RETURNING id INTO eid;
  RETURN eid;                                       -- NULL if it was already open
END $$;

CREATE FUNCTION alarm_clear(p_rule int, p_meter int, p_ts timestamptz) RETURNS bigint LANGUAGE sql AS $$
  UPDATE alarm_events SET cleared_at = p_ts WHERE rule_id = p_rule AND meter_id = p_meter AND cleared_at IS NULL RETURNING id $$;

CREATE FUNCTION alarm_ack(p_event bigint, p_user int) RETURNS boolean LANGUAGE sql AS $$
  WITH u AS (UPDATE alarm_events SET acknowledged_by = p_user, acknowledged_at = now()
             WHERE id = p_event AND acknowledged_at IS NULL RETURNING 1) SELECT EXISTS (SELECT 1 FROM u) $$;

CREATE VIEW v_alarms AS
SELECT e.id, e.started_at, e.cleared_at, (e.cleared_at IS NULL) AS active, r.name AS rule_name, r.severity,
       e.meter_id, m.name AS meter_name, a.name AS area_name, e.value, e.message,
       e.acknowledged_at, u.username AS acknowledged_by
FROM alarm_events e
JOIN alarm_rules r ON r.id = e.rule_id
JOIN meters m ON m.id = e.meter_id
JOIN areas a ON a.id = m.area_id
LEFT JOIN users u ON u.id = e.acknowledged_by;

-- ---------------------------------------------------------------------
-- Tariffs (flat rate, or time-of-use periods in plant local time) and energy cost
-- ---------------------------------------------------------------------
CREATE TABLE tariffs (
  id                   serial PRIMARY KEY,
  name                 text NOT NULL,
  valid_from           date NOT NULL,
  valid_to             date,                                  -- NULL = open ended
  currency             text,
  default_rate_per_kwh numeric NOT NULL,                      -- used when no time-of-use period matches
  demand_rate_per_kw   numeric NOT NULL DEFAULT 0,            -- stored for later; not used by energy_cost()
  fixed_monthly_charge numeric NOT NULL DEFAULT 0,            -- stored for later; not used by energy_cost()
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE tariff_periods (
  id           serial PRIMARY KEY,
  tariff_id    int NOT NULL REFERENCES tariffs(id) ON DELETE CASCADE,
  name         text NOT NULL,                                 -- e.g. 'Peak'
  start_time   time NOT NULL,                                 -- local time; start >= end means it crosses midnight
  end_time     time NOT NULL,
  days         int[] NOT NULL DEFAULT ARRAY[1,2,3,4,5,6,7],   -- ISO weekdays, 1 = Monday
  rate_per_kwh numeric NOT NULL
);
CREATE INDEX tariff_periods_tariff ON tariff_periods (tariff_id);

-- Cost per local day and meter, from the 15-minute aggregate. With p_meters = NULL it uses all meters except main meters.
-- Where several periods overlap, the highest rate wins. The tariff valid on each local date is used.
CREATE FUNCTION energy_cost(p_from date, p_to date, p_meters int[] DEFAULT NULL)
RETURNS TABLE (day date, meter_id int, kwh numeric, cost numeric, currency text)
LANGUAGE sql STABLE AS $$
  WITH z AS (SELECT value AS tz FROM app_settings WHERE key = 'plant_timezone'),
  b AS (
    SELECT r.meter_id, r.kwh_import, (r.bucket AT TIME ZONE z.tz) AS lt
    FROM readings_15min r CROSS JOIN z JOIN meters m ON m.id = r.meter_id
    WHERE r.bucket >= (p_from::timestamp AT TIME ZONE z.tz) AND r.bucket < ((p_to + 1)::timestamp AT TIME ZONE z.tz)
      AND CASE WHEN p_meters IS NULL THEN NOT m.is_main ELSE m.id = ANY (p_meters) END)
  SELECT b.lt::date, b.meter_id, sum(b.kwh_import)::numeric,
         sum(b.kwh_import * coalesce(p.rate_per_kwh, t.default_rate_per_kwh))::numeric, max(t.currency)
  FROM b
  LEFT JOIN LATERAL (SELECT * FROM tariffs t WHERE t.valid_from <= b.lt::date AND (t.valid_to IS NULL OR t.valid_to >= b.lt::date)
                     ORDER BY t.valid_from DESC LIMIT 1) t ON true
  LEFT JOIN LATERAL (SELECT tp.rate_per_kwh FROM tariff_periods tp
                     WHERE tp.tariff_id = t.id AND extract(isodow FROM b.lt)::int = ANY (tp.days)
                       AND ((tp.start_time < tp.end_time AND b.lt::time >= tp.start_time AND b.lt::time < tp.end_time)
                         OR (tp.start_time >= tp.end_time AND (b.lt::time >= tp.start_time OR b.lt::time < tp.end_time)))
                     ORDER BY tp.rate_per_kwh DESC LIMIT 1) p ON true
  GROUP BY 1, 2 ORDER BY 1, 2 $$;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['alarm_rules','tariffs','tariff_periods'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION audit_row_change()', 'audit_' || t, t);
  END LOOP;
END $$;
