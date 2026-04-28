-- =============================================================================
-- db/dev/benchmark/02_proxy_scalar_python.sql
-- LocID Dev: Python scalar proxy UDF for throughput benchmarking
--
-- APPROACH B — Python scalar, per-row dispatch
--
-- Purpose:
--   Measures the per-row Python function call overhead on 5M rows.
--   Acts as the Python-language baseline to compare against:
--     - Approach A: Scala scalar (LOCID_BASE_ENCRYPT, JAR-based)
--     - Approach C: Python vectorized (PROXY_VECTORIZED, batch dispatch)
--
-- Compute proxy:
--   Uses HMAC-SHA256 as a stand-in for the AES-128 ECB operation performed
--   by BaseLocIdEncryption in encode-lib. The key is re-derived on every row,
--   matching the per-row toKey() pattern in the Scala scalar UDFs.
--   Replace the body with locid.base_encrypt() once locid.py is available.
--
-- Run order: after 01_setup.sql
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;


CREATE OR REPLACE FUNCTION LOCID_DEV.BENCHMARK.PROXY_SCALAR(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'encode_scalar'
COMMENT = 'Benchmark proxy: Python scalar per-row dispatch. Compute proxy for LOCID_BASE_ENCRYPT (HMAC-SHA256 in place of AES-128).'
AS $$
import hashlib
import base64


def encode_scalar(loc_id: str, key_str: str) -> str:
    """
    Per-row scalar handler — called once per input row.

    Key derivation mirrors the Scala UDF's toKey():
        key_str.replaceAll("~","=") → Base64URL.decode() → raw key bytes
    Key bytes are re-derived on every invocation (no caching), matching
    the Scala scalar UDF behaviour where a new SecretKeySpec is created
    per row call.

    Compute proxy: HMAC-SHA256(key_bytes, loc_id) in place of AES-128 ECB.
    Output: base64url-encoded digest (no padding), VARCHAR.
    """
    # Key derivation — same pattern as Scala toKey()
    key_b64 = key_str.replace('~', '=')
    # Pad to a valid base64 length
    pad = (4 - len(key_b64) % 4) % 4
    try:
        key_bytes = base64.urlsafe_b64decode(key_b64 + '=' * pad)
    except Exception:
        key_bytes = key_str.encode()[:32]  # fallback for placeholder key

    # Per-row work: HMAC-SHA256 (proxy for AES-128 ECB encrypt)
    digest = hashlib.new('sha256', key_bytes + loc_id.encode()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b'=').decode()
$$;
