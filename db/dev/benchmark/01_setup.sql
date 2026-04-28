-- =============================================================================
-- db/dev/benchmark/01_setup.sql
-- LocID Dev: Benchmark schema + 5M mockup row table
--
-- Creates LOCID_DEV.BENCHMARK schema and a 5-million-row table of synthetic
-- LocID-like strings used to compare UDF throughput across three approaches:
--   A. Existing Scala scalar UDF (LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT)
--   B. Python scalar proxy UDF  (LOCID_DEV.BENCHMARK.PROXY_SCALAR)
--   C. Python vectorized proxy  (LOCID_DEV.BENCHMARK.PROXY_VECTORIZED)
--
-- Run order: after db/dev/provider/01_setup.sql (LOCID_DEV database must exist).
-- Idempotent: CREATE OR REPLACE on all objects.
-- Expected runtime: ~30–60 s on an XS warehouse for the 5M INSERT.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;


-- ---------------------------------------------------------------------------
-- STEP 1: Create benchmark schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS LOCID_DEV.BENCHMARK
    COMMENT = 'UDF throughput benchmark — Scala scalar vs Python vectorized';

USE SCHEMA LOCID_DEV.BENCHMARK;


-- ---------------------------------------------------------------------------
-- STEP 2: 5M mockup row table
--
-- loc_id   — synthetic 21-char uppercase alphanumeric string, unique per row.
--            Derived from MD5 of row number so generation is deterministic.
--            Format resembles real LocID strings (e.g. '31F24ZE1W1YX58K2R1139').
--
-- key_str  — constant placeholder key for all rows.
--            For Approach A (Scala/JAR), replace with actual $base_locid_secret
--            in 04_run_timing.sql — the value here is not used by that query.
--            For Approaches B/C (Python proxy), any non-empty string is valid.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK.MOCKUP_5M (
    row_id   BIGINT        NOT NULL COMMENT 'Sequential row identifier (1–5,000,000)',
    loc_id   VARCHAR(21)   NOT NULL COMMENT 'Synthetic 21-char LocID-like string',
    key_str  VARCHAR       NOT NULL COMMENT 'Constant key placeholder; overridden per approach in 04_run_timing.sql'
)
COMMENT = 'Benchmark input: 5M synthetic rows for UDF throughput testing'
AS
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ8()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 5000000))
)
SELECT
    rn                                                              AS row_id,
    -- 21-char synthetic string: uppercase hex chars from two chained MD5 hashes.
    -- Unique per row; format is close enough to real LocID strings for timing purposes.
    UPPER(SUBSTR(MD5(rn::VARCHAR) || MD5((rn * 7 + 13)::VARCHAR), 1, 21))  AS loc_id,
    -- Placeholder — not used in proxy UDF calls (proxy ignores the key value);
    -- overridden by $base_locid_secret in Approach A timing query.
    'BENCHMARK_PLACEHOLDER_KEY~'                                   AS key_str
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 3: Results table (populated by 04_run_timing.sql)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS (
    approach        VARCHAR  NOT NULL COMMENT 'A_scala_scalar | B_python_scalar | C_python_vectorized',
    warehouse_size  VARCHAR  NOT NULL COMMENT 'Snowflake warehouse size used',
    rows_processed  BIGINT   NOT NULL COMMENT 'Number of rows in the benchmark query',
    elapsed_s       FLOAT    NOT NULL COMMENT 'Wall-clock seconds from QUERY_HISTORY',
    krows_per_s     FLOAT    COMMENT 'Throughput: rows_processed / elapsed_s / 1000',
    notes           VARCHAR  COMMENT 'Optional notes (cold start, cache state, etc.)',
    run_at          TIMESTAMP_NTZ DEFAULT CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
)
COMMENT = 'Benchmark timing results — insert one row per run via 04_run_timing.sql';


-- ---------------------------------------------------------------------------
-- STEP 4: Verify
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS row_count FROM LOCID_DEV.BENCHMARK.MOCKUP_5M;
-- Expected: 5,000,000

-- Spot-check first 5 rows
SELECT * FROM LOCID_DEV.BENCHMARK.MOCKUP_5M LIMIT 5;
-- Expected: row_id 1–5, loc_id = 21-char uppercase hex, key_str = placeholder
