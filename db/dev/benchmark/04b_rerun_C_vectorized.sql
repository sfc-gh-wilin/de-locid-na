-- =============================================================================
-- db/dev/benchmark/04b_rerun_C_vectorized.sql
-- LocID Dev: Re-register and time Approach C only
--
-- Use this script after the initial 04_run_timing.sql run if Approach C
-- (PROXY_VECTORIZED) was missing or failed. It re-creates the UDF with the
-- corrected import and runs only the Approach C timing query, then appends
-- the result to BENCHMARK_RESULTS.
--
-- Why Approach C was missing initially:
--   The original 03_proxy_vectorized_python.sql was missing the line
--   `from _snowflake import vectorized` — Snowflake does not inject the
--   `vectorized` decorator into the global namespace automatically; it must
--   be imported explicitly from the `_snowflake` module.
--   This has been corrected in 03_proxy_vectorized_python.sql.
--
-- Prerequisites:
--   01_setup.sql has been run (MOCKUP_5M and BENCHMARK_RESULTS tables exist).
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;


-- ---------------------------------------------------------------------------
-- STEP 1: Re-register the fixed PROXY_VECTORIZED UDF
--         (identical to 03_proxy_vectorized_python.sql — included inline so
--          this script is self-contained)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('pandas')
HANDLER = 'encode_batch'
COMMENT = 'Benchmark proxy: Python vectorized batch dispatch. Compute proxy for LOCID_BASE_ENCRYPT (HMAC-SHA256). Key setup amortised once per batch via worker-level cache.'
AS $$
import hashlib
import base64
import pandas as pd
from _snowflake import vectorized   # required: not auto-injected into global namespace

# Worker-level cache: key_str → key_bytes
# Persists across batches in the same worker process.
_key_cache: dict = {}


@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    """
    Vectorized batch handler — called once per batch (1,000–8,192 rows).

    df.iloc[:, 0] = LOC_ID  (pd.Series of str)
    df.iloc[:, 1] = KEY_STR (constant for all rows in a query)
    """
    key_str = df.iloc[0, 1]

    if key_str not in _key_cache:
        key_b64 = key_str.replace('~', '=')
        pad = (4 - len(key_b64) % 4) % 4
        try:
            _key_cache[key_str] = base64.urlsafe_b64decode(key_b64 + '=' * pad)
        except Exception:
            _key_cache[key_str] = key_str.encode()[:32]

    key_bytes = _key_cache[key_str]

    return df.iloc[:, 0].apply(
        lambda loc_id: base64.urlsafe_b64encode(
            hashlib.new('sha256', key_bytes + loc_id.encode()).digest()
        ).rstrip(b'=').decode()
    )
$$;

-- Verify UDF created without error
SELECT LOCID_DEV.BENCHMARK.PROXY_VECTORIZED('31F24ZE1W1YX58K2R1139', 'BENCHMARK_PLACEHOLDER_KEY~') AS smoke_test;
-- Expected: non-null base64url string (~43 chars)


-- ---------------------------------------------------------------------------
-- STEP 2: Time Approach C on 5M rows
-- ---------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = 'locid_bench_C_python_vectorized';

SELECT
    COUNT(*)                                                     AS rows_processed,
    SUM(LENGTH(result_col))                                      AS total_output_len
FROM (
    SELECT LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(loc_id, key_str) AS result_col
    FROM   LOCID_DEV.BENCHMARK.MOCKUP_5M
);

ALTER SESSION UNSET QUERY_TAG;


-- ---------------------------------------------------------------------------
-- STEP 3: Pull result from QUERY_HISTORY and insert into BENCHMARK_RESULTS
--         Wait ~10 s after the query above before running this block.
-- ---------------------------------------------------------------------------
SET warehouse_size = CURRENT_WAREHOUSE();

-- Preview
SELECT
    query_tag,
    total_elapsed_time / 1000.0                                   AS elapsed_s,
    ROUND(5000000.0 / (total_elapsed_time / 1000.0) / 1000, 1)   AS krows_per_s
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -10, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag = 'locid_bench_C_python_vectorized'
  AND execution_status = 'SUCCESS'
ORDER BY start_time DESC
LIMIT 1;

-- Insert
INSERT INTO LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
    (approach, warehouse_size, rows_processed, elapsed_s, krows_per_s, notes)
SELECT
    'C_python_vectorized'                                         AS approach,
    $warehouse_size                                               AS warehouse_size,
    5000000                                                       AS rows_processed,
    total_elapsed_time / 1000.0                                   AS elapsed_s,
    ROUND(5000000.0 / (total_elapsed_time / 1000.0) / 1000, 1)   AS krows_per_s,
    'HMAC-SHA256 proxy; vectorized import fix applied'            AS notes
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('minute', -10, CURRENT_TIMESTAMP()),
    END_TIME_RANGE_END   => DATEADD('minute',   1, CURRENT_TIMESTAMP())
))
WHERE query_tag = 'locid_bench_C_python_vectorized'
  AND execution_status = 'SUCCESS'
QUALIFY ROW_NUMBER() OVER (ORDER BY start_time DESC) = 1;


-- ---------------------------------------------------------------------------
-- STEP 4: Full comparison including all three approaches
-- ---------------------------------------------------------------------------
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
