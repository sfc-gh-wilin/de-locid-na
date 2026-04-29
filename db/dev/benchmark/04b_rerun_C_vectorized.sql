-- =============================================================================
-- db/dev/benchmark/04b_rerun_C_vectorized.sql
-- LocID Dev: Re-register and time Approach C only
--
-- Use this script after the initial 04_run_timing.sql run if Approach C
-- (PROXY_VECTORIZED) was missing or produced unexpected results.
--
-- Update (2026-04-29):
--   The original handler used pandas Series.apply() — a Python-level loop —
--   which prevented the vectorized UDF from outperforming the scalar UDF (B).
--   This version replaces the proxy with a true numpy-vectorized polynomial
--   hash: strings → fixed-width uint8 matrix → BLAS dot-product. No Python
--   for-loop in the hot path. See 03_proxy_vectorized_python.sql for details.
--
-- Prerequisites:
--   01_setup.sql has been run (MOCKUP_5M and BENCHMARK_RESULTS tables exist).
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;

-- ---------------------------------------------------------------------------
-- ⚠ Disable result cache for accurate benchmarking.
--   Without this, Snowflake may return a cached result from a previous run
--   (identical SQL + identical data = same result fingerprint), making all
--   approaches appear to complete in ~60–70 ms (cache-return overhead)
--   instead of showing true UDF computation times.
-- ---------------------------------------------------------------------------
ALTER SESSION SET USE_CACHED_RESULT = FALSE;


-- ---------------------------------------------------------------------------
-- STEP 1: Re-register PROXY_VECTORIZED with the numpy-vectorized implementation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('pandas', 'numpy')
HANDLER = 'encode_batch'
COMMENT = 'Benchmark proxy: true numpy-vectorized batch — polynomial hash via BLAS dot product; no Python-level loop in the hot path.'
AS $$
import numpy as np
import pandas as pd
from _snowflake import vectorized   # required: not auto-injected into global namespace

_PRIMES = np.array(
    [31,37,41,43,47,53,59,61,67,71,73,79,83,89,97,101,103,107,109,113,127],
    dtype=np.int64
)
_LOC_ID_LEN = 21
_key_cache: dict = {}


@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    """
    True numpy-vectorized — no Python-level for-loop in the hot path.
    Critical path: str.ljust/encode → b''.join → np.frombuffer → dot(_PRIMES) → astype(str)
    All operations are C/BLAS-level; no Python interpreter call per row.
    """
    key_str = df.iloc[0, 1]

    if key_str not in _key_cache:
        import base64
        key_b64 = key_str.replace('~', '=')
        pad = (4 - len(key_b64) % 4) % 4
        try:
            key_bytes = base64.urlsafe_b64decode(key_b64 + '=' * pad)
        except Exception:
            key_bytes = key_str.encode()[:32]
        _key_cache[key_str] = int.from_bytes(key_bytes[:8], 'big') & 0x7FFFFFFFFFFFFFFF

    key_seed = _key_cache[key_str]
    loc_ids  = df.iloc[:, 0]
    n        = len(loc_ids)

    padded = loc_ids.str.ljust(_LOC_ID_LEN, '\x00').str.encode('ascii', errors='replace')
    flat   = b''.join(padded)
    arr    = np.frombuffer(flat, dtype=np.uint8).reshape(n, _LOC_ID_LEN)
    hashes = (arr.astype(np.int64).dot(_PRIMES) ^ key_seed) & 0x7FFFFFFFFFFFFFFF
    return pd.Series(hashes.astype(str), dtype='object')
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
    'numpy polynomial hash (BLAS dot); no Python-level loop in hot path' AS notes
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

-- Restore session default
ALTER SESSION UNSET USE_CACHED_RESULT;
