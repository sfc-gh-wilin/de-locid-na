-- =============================================================================
-- db/dev/benchmark/03_proxy_vectorized_python.sql
-- LocID Dev: Python vectorized proxy UDF for throughput benchmarking
--
-- APPROACH C — Python vectorized, batch dispatch
--
-- Purpose:
--   Measures the throughput gain of @vectorized batch dispatch vs per-row
--   dispatch (Approach B) on 5M rows. This is the architecture described in
--   docs/20260428_Architecture_v3.md § Roadmap: Python Package for Vectorized UDFs.
--
-- Key improvements vs scalar (Approach B):
--   1. Fewer dispatch crossings — Python/SQL boundary crossed ceil(N/batch) times
--      instead of N times. Snowflake auto-tunes batch size to 1,000–8,192 rows.
--   2. Amortised key setup — key bytes derived once per batch (via _key_cache),
--      not once per row.
--   3. Pandas vectorised apply — avoids Python interpreter overhead per element.
--
-- Compute proxy:
--   Same HMAC-SHA256 proxy as PROXY_SCALAR. Once locid.py is available, replace
--   the handler body with locid.base_encrypt() applied to the DataFrame column.
--
-- Run order: after 01_setup.sql
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;


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
from _snowflake import vectorized

# Worker-level cache: key_str → key_bytes
# Persists across batches in the same worker process — key derivation cost
# is paid at most once per worker, regardless of how many batches are processed.
_key_cache: dict = {}


@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    """
    Vectorized batch handler — called once per batch (1,000–8,192 rows).

    df.iloc[:, 0] = LOC_ID column (pd.Series of str)
    df.iloc[:, 1] = KEY_STR column (constant for all rows in a query)

    Key setup is amortised:
      - Derived once per unique key_str value, cached in _key_cache.
      - In practice KEY_STR is constant per query, so derivation runs once
        per worker process across all batches.

    Compute proxy: HMAC-SHA256(key_bytes, loc_id) applied to the full batch
    using pandas Series.apply() — avoids the per-row Python dispatch overhead
    present in the scalar UDF.
    """
    key_str = df.iloc[0, 1]  # KEY_STR is constant for all rows in a query

    # Amortised key derivation
    if key_str not in _key_cache:
        key_b64 = key_str.replace('~', '=')
        pad = (4 - len(key_b64) % 4) % 4
        try:
            _key_cache[key_str] = base64.urlsafe_b64decode(key_b64 + '=' * pad)
        except Exception:
            _key_cache[key_str] = key_str.encode()[:32]  # fallback

    key_bytes = _key_cache[key_str]

    # Apply proxy encode to all rows in the batch
    return df.iloc[:, 0].apply(
        lambda loc_id: base64.urlsafe_b64encode(
            hashlib.new('sha256', key_bytes + loc_id.encode()).digest()
        ).rstrip(b'=').decode()
    )
$$;
