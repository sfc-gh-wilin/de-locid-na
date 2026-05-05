-- =============================================================================
-- db/dev/benchmark/05_run_timing.sql
-- LocID Dev: UDF throughput benchmark — timing queries for all four approaches
--
-- Need replace: 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET'
--
-- Runs four SELECT statements (one per approach) with QUERY_TAG set so that
-- INFORMATION_SCHEMA.QUERY_HISTORY can retrieve the elapsed time for each.
-- After all runs, inserts results into LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
-- and prints a comparison summary.
--
-- Prerequisites:
--   1. 01_setup.sql has been run (MOCKUP_50M + BENCHMARK_RESULTS tables exist)
--   2. 02_proxy_scalar_python.sql has been run (PROXY_SCALAR UDF exists)
--   3. 03_proxy_vectorized_python.sql has been run (PROXY_VECTORIZED UDF exists)
--   4. 04_whl_vectorized.sql has been run (PROXY_WHL UDF exists — requires WHL staged)
--   5. db/dev/provider/06_udfs.sql has been run (LOCID_BASE_ENCRYPT UDF exists)
--   6. $base_locid_secret is set below (required for Approach A only)
--
-- Run on at least an XS warehouse. For more realistic production numbers, run
-- on the same warehouse size used in production encrypt/decrypt jobs.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;

-- ---------------------------------------------------------------------------
-- ⚠ Set $base_locid_secret for Approach A (Scala/JAR).
--   Use the base_locid_secret value from the LocID Central license response
--   (secrets.base_locid_secret — NOT the License Key).
--   Approaches B, C, and D ignore this variable (they use the placeholder key
--   stored in MOCKUP_50M.key_str).
-- ---------------------------------------------------------------------------
SET base_locid_secret = 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET';

-- Record the warehouse size for the results table
SET warehouse_size = CURRENT_WAREHOUSE();

-- ---------------------------------------------------------------------------
-- ⚠ Disable result cache for accurate benchmarking.
--   Without this, Snowflake may return a cached result from a previous run
--   (identical SQL + identical data = same result fingerprint), making all
--   three approaches appear to complete in ~60–70 ms (cache-return overhead)
--   instead of showing true UDF computation times.
-- ---------------------------------------------------------------------------
ALTER SESSION SET USE_CACHED_RESULT = FALSE;


-- =============================================================================
-- APPROACH A — Scala scalar UDF (encode-lib JAR)
--   LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(loc_id, key_str)
--   Key is passed as a SQL literal (overrides the placeholder in key_str column).
--   ⚠ Requires the encode-lib JAR in @LOCID_DEV.STAGING.LOCID_STAGE.
--   ⚠ Requires a valid $base_locid_secret; invalid keys will throw a runtime error.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_A_scala_scalar';

SELECT
    COUNT(*)                                                                AS rows_processed,
    SUM(LENGTH(result_col))                                                 AS total_output_len  -- prevent result caching
FROM (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(loc_id, $base_locid_secret) AS result_col
    FROM   LOCID_DEV.BENCHMARK.MOCKUP_50M
);

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH B — Python scalar UDF (per-row dispatch proxy)
--   LOCID_DEV.BENCHMARK.PROXY_SCALAR(loc_id, key_str)
--   Uses the placeholder key_str from MOCKUP_50M (proxy; key value ignored).
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_B_python_scalar';

SELECT
    COUNT(*)                                                                AS rows_processed,
    SUM(LENGTH(result_col))                                                 AS total_output_len
FROM (
    SELECT LOCID_DEV.BENCHMARK.PROXY_SCALAR(loc_id, key_str)               AS result_col
    FROM   LOCID_DEV.BENCHMARK.MOCKUP_50M
);

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH C — Python vectorized UDF (batch dispatch proxy)
--   LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(loc_id, key_str)
--   Same proxy computation as B but batched via @vectorized.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_C_python_vectorized';

SELECT
    COUNT(*)                                                                AS rows_processed,
    SUM(LENGTH(result_col))                                                 AS total_output_len
FROM (
    SELECT LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(loc_id, key_str)           AS result_col
    FROM   LOCID_DEV.BENCHMARK.MOCKUP_50M
);

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- APPROACH D — Python vectorized UDF (actual mb-locid-encoding wheel)
--   LOCID_DEV.BENCHMARK.PROXY_WHL(loc_id, key_str)
--   Uses locid_sf.encode_stable_cloc from the production WHL.
--   ⚠ Requires 04_whl_vectorized.sql to have been run with <WHEEL_FILE> set.
-- =============================================================================
ALTER SESSION SET QUERY_TAG = 'locid_bench_D_whl_vectorized';

SELECT
    COUNT(*)                                                                AS rows_processed,
    SUM(LENGTH(result_col))                                                 AS total_output_len
FROM (
    SELECT LOCID_DEV.BENCHMARK.PROXY_WHL(loc_id, key_str)                  AS result_col
    FROM   LOCID_DEV.BENCHMARK.MOCKUP_50M
);

ALTER SESSION UNSET QUERY_TAG;


-- =============================================================================
-- RESULTS: Pull elapsed time from QUERY_HISTORY and insert into results table
--
-- Wait a few seconds after the queries above complete before running this block,
-- as INFORMATION_SCHEMA.QUERY_HISTORY has a short propagation delay (~5–10 s).
-- =============================================================================

-- Preview elapsed times
SELECT
    query_tag,
    total_elapsed_time / 1000.0                               AS elapsed_s,
    rows_produced,
    ROUND(100000000.0 / (total_elapsed_time / 1000.0) / 1000, 1) AS krows_per_s
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -30, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag IN (
    'locid_bench_A_scala_scalar',
    'locid_bench_B_python_scalar',
    'locid_bench_C_python_vectorized',
    'locid_bench_D_whl_vectorized'
)
  AND execution_status = 'SUCCESS'
ORDER BY start_time;


-- Insert into persistent results table
-- (Edit 'notes' and 'warehouse_size' as needed before running)
INSERT INTO LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
    (approach, warehouse_size, rows_processed, elapsed_s, krows_per_s, notes)
SELECT
    CASE query_tag
        WHEN 'locid_bench_A_scala_scalar'        THEN 'A_scala_scalar'
        WHEN 'locid_bench_B_python_scalar'        THEN 'B_python_scalar'
        WHEN 'locid_bench_C_python_vectorized'    THEN 'C_python_vectorized'
        WHEN 'locid_bench_D_whl_vectorized'       THEN 'D_whl_vectorized'
    END                                                           AS approach,
    $warehouse_size                                               AS warehouse_size,
    100000000                                                       AS rows_processed,
    total_elapsed_time / 1000.0                                   AS elapsed_s,
    ROUND(100000000.0 / (total_elapsed_time / 1000.0) / 1000, 1)   AS krows_per_s,
    'Initial benchmark run — see README for interpretation'  AS notes
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -30, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag IN (
    'locid_bench_A_scala_scalar',
    'locid_bench_B_python_scalar',
    'locid_bench_C_python_vectorized',
    'locid_bench_D_whl_vectorized'
)
  AND execution_status = 'SUCCESS'
-- Keep only the most recent run per approach if re-run multiple times
QUALIFY ROW_NUMBER() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1;


-- =============================================================================
-- SUMMARY: Compare all four approaches
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

-- Restore session default
ALTER SESSION UNSET USE_CACHED_RESULT;
