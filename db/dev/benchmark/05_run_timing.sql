-- =============================================================================
-- db/dev/benchmark/05_run_timing.sql
-- LocID Dev: UDF throughput benchmark — timing queries for all four approaches
--
-- Need replace: 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET'
--
-- Uses CREATE OR REPLACE TABLE to FORCE full materialization of every UDF call.
-- This prevents Snowflake's optimizer from short-circuiting the UDF execution
-- (which can happen with SELECT COUNT(*)/SUM() patterns).
--
-- After each CTAS, we pull the elapsed time from QUERY_HISTORY using the
-- query_tag and verify rows_produced matches the expected row count.
--
-- Prerequisites:
--   1. 01_setup.sql has been run (MOCKUP_50M + BENCHMARK_RESULTS tables exist)
--   2. 02_proxy_scalar_python.sql has been run (PROXY_SCALAR UDF exists)
--   3. 03_proxy_vectorized_python.sql has been run (PROXY_VECTORIZED UDF exists)
--   4. 04_whl_vectorized.sql has been run (PROXY_WHL UDF exists — requires WHL staged)
--   5. db/dev/provider/06_udfs.sql has been run (LOCID_BASE_ENCRYPT UDF exists)
--   6. $base_locid_secret is set below (required for Approach A only)
--
-- Run on at least a MEDIUM warehouse for 50M rows.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;

-- ---------------------------------------------------------------------------
-- ⚠ Set $base_locid_secret for Approach A (Scala/JAR).
-- ---------------------------------------------------------------------------
SET base_locid_secret = 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET';

-- Record the warehouse size for the results table
SET warehouse_size = CURRENT_WAREHOUSE();

-- ---------------------------------------------------------------------------
-- ⚠ Disable result cache for accurate benchmarking.
-- ---------------------------------------------------------------------------
ALTER SESSION SET USE_CACHED_RESULT = FALSE;


-- =============================================================================
-- APPROACH A — Scala scalar UDF (encode-lib JAR)
--   Forces materialization via CTAS — Snowflake MUST call the UDF on every row.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_A_scala_scalar';

CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK._BENCH_A AS
SELECT
    loc_id,
    LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(loc_id, $base_locid_secret) AS result_col
FROM LOCID_DEV.BENCHMARK.MOCKUP_50M;

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH B — Python scalar UDF (per-row dispatch proxy)
--   Forces materialization via CTAS.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_B_python_scalar';

CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK._BENCH_B AS
SELECT
    loc_id,
    LOCID_DEV.BENCHMARK.PROXY_SCALAR(loc_id, key_str) AS result_col
FROM LOCID_DEV.BENCHMARK.MOCKUP_50M;

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH C — Python vectorized UDF (batch dispatch proxy)
--   Forces materialization via CTAS.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_C_python_vectorized';

CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK._BENCH_C AS
SELECT
    loc_id,
    LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(loc_id, key_str) AS result_col
FROM LOCID_DEV.BENCHMARK.MOCKUP_50M;

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH D — Python vectorized UDF (actual mb-locid-encoding wheel)
--   Forces materialization via CTAS.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_D_whl_vectorized';

CREATE OR REPLACE TABLE LOCID_DEV.BENCHMARK._BENCH_D AS
SELECT
    loc_id,
    LOCID_DEV.BENCHMARK.PROXY_WHL(loc_id, key_str) AS result_col
FROM LOCID_DEV.BENCHMARK.MOCKUP_50M;

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- RESULTS: Pull elapsed time from QUERY_HISTORY
--
-- ⚠ Wait 10–15 seconds after the CTAS queries complete before running this
--    block — INFORMATION_SCHEMA.QUERY_HISTORY has a short propagation delay.
-- =============================================================================

-- Preview: verify rows_produced = 50,000,000 for each approach
SELECT
    query_tag,
    total_elapsed_time / 1000.0                                    AS elapsed_s,
    rows_produced,
    ROUND(rows_produced / (total_elapsed_time / 1000.0) / 1000, 1) AS krows_per_s,
    query_text
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -60, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag IN (
    'locid_bench_A_scala_scalar',
    'locid_bench_B_python_scalar',
    'locid_bench_C_python_vectorized',
    'locid_bench_D_whl_vectorized'
)
  AND execution_status = 'SUCCESS'
  AND query_type = 'CREATE_TABLE_AS_SELECT'
ORDER BY start_time;


-- Insert into persistent results table
INSERT INTO LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
    (approach, warehouse_size, rows_processed, elapsed_s, krows_per_s, notes)
SELECT
    CASE query_tag
        WHEN 'locid_bench_A_scala_scalar'        THEN 'A_scala_scalar'
        WHEN 'locid_bench_B_python_scalar'        THEN 'B_python_scalar'
        WHEN 'locid_bench_C_python_vectorized'    THEN 'C_python_vectorized'
        WHEN 'locid_bench_D_whl_vectorized'       THEN 'D_whl_vectorized'
    END                                                              AS approach,
    $warehouse_size                                                  AS warehouse_size,
    rows_produced                                                    AS rows_processed,
    total_elapsed_time / 1000.0                                      AS elapsed_s,
    ROUND(rows_produced / (total_elapsed_time / 1000.0) / 1000, 1)   AS krows_per_s,
    'CTAS forced materialization — ' || $warehouse_size              AS notes
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -60, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag IN (
    'locid_bench_A_scala_scalar',
    'locid_bench_B_python_scalar',
    'locid_bench_C_python_vectorized',
    'locid_bench_D_whl_vectorized'
)
  AND execution_status = 'SUCCESS'
  AND query_type = 'CREATE_TABLE_AS_SELECT'
QUALIFY ROW_NUMBER() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1;


-- =============================================================================
-- SUMMARY
-- =============================================================================
SELECT
    approach,
    warehouse_size,
    rows_processed,
    elapsed_s,
    krows_per_s,
    ROUND(
        MAX(elapsed_s) OVER () / NULLIF(elapsed_s, 0),
        2
    )                                                             AS speedup_vs_slowest,
    run_at
FROM LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
ORDER BY approach, run_at DESC;


-- =============================================================================
-- CLEANUP: Drop temporary benchmark tables (run after reviewing results)
-- =============================================================================
-- DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK._BENCH_A;
-- DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK._BENCH_B;
-- DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK._BENCH_C;
-- DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK._BENCH_D;

-- Restore session default
ALTER SESSION UNSET USE_CACHED_RESULT;
