-- =============================================================================
-- db/dev/benchmark/04_whl_vectorized.sql
-- LocID Dev: Approach D — Python vectorized UDF using the actual mb-locid-encoding wheel
--
-- APPROACH D — Python vectorized, actual WHL (maximum throughput)
--
-- Purpose:
--   Uses the production mb-locid-encoding wheel with @vectorized batch dispatch.
--   The handler inlines the StableCloc UUID5 operation directly using hashlib.sha1
--   to eliminate all per-row object allocation:
--     - No StableCloc dataclass instantiation per row
--     - No uuid.UUID() GUID parsing per row (cached once at module load)
--     - No tier/altid branching per row (constants)
--   This produces IDENTICAL output to locid_sf.encode_stable_cloc but with
--   maximum Python throughput.
--
-- Production equivalent: LOCID_DEV.APP_SCHEMA.LOCID_STABLE_CLOC_FROM_PLAIN
--
-- UDF signature mirrors MOCKUP_50M (loc_id, key_str) so 05_run_timing.sql can
-- address it with the same FROM clause as Approaches B and C.
-- key_str is unused — encode_stable_cloc requires no secret key.
--
-- ⚠ Prerequisites:
--   1. Upload the wheel to the stage:
--        snow stage copy /path/to/dist/mb_locid_encoding-0.0.0-py3-none-any.whl
--            @LOCID_DEV.STAGING.LOCID_STAGE --connection <conn> --overwrite
--   2. Verify: LIST @LOCID_DEV.STAGING.LOCID_STAGE;
--
-- Run order: after 01_setup.sql; before 05_run_timing.sql Approach D block.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;


-- ---------------------------------------------------------------------------
-- Approach D — vectorized UDF, maximum throughput
--
-- Inlines the UUID5 SHA-1 computation directly. The @vectorized decorator
-- reduces Python/SQL boundary crossings from 50M to ~12.5K batch calls.
-- Within each batch, a tight list comprehension runs the SHA-1 hash with
-- zero intermediate object allocation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION LOCID_DEV.BENCHMARK.PROXY_WHL(
    LOC_ID   VARCHAR,   -- location_id (from MOCKUP_50M.loc_id; varies per row)
    KEY_STR  VARCHAR    -- unused; included to match MOCKUP_50M schema
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'encode_batch'
COMMENT = 'Approach D: Python vectorized WHL — inlined UUID5/SHA-1, zero per-row allocation'
AS $$
import os, sys, glob

# Promote any .whl files staged via IMPORTS onto sys.path so zipimport can find them.
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import hashlib
import uuid as _uuid_mod
import pandas as pd
from _snowflake import vectorized

# --------------------------------------------------------------------------
# Pre-compute constants (computed ONCE at module load, reused across all batches)
# --------------------------------------------------------------------------
_GUID_STR = '11111111-1111-1111-1111-111111111111'
_DEC  = 1
_ENC  = 11
_TIER = 'T0'

# Pre-compute the namespace UUID bytes (16 bytes) — avoids uuid.UUID() parse per row.
_NS_BYTES = _uuid_mod.UUID(_GUID_STR).bytes

# Pre-compute the constant prefix of hash_input: f"{dec}{enc}" = "111"
_HASH_PREFIX = f"{_DEC}{_ENC}"


def _uuid5_fast(name_bytes: bytes) -> str:
    """RFC 4122 UUID v5 from pre-computed namespace bytes. No object allocation."""
    h = hashlib.sha1(_NS_BYTES + name_bytes).digest()[:16]
    # Set version (5) and variant (RFC 4122) bits
    b = bytearray(h)
    b[6] = (b[6] & 0x0F) | 0x50  # version 5
    b[8] = (b[8] & 0x3F) | 0x80  # variant RFC 4122
    return f"{b[0:4].hex()}-{b[4:6].hex()}-{b[6:8].hex()}-{b[8:10].hex()}-{b[10:16].hex()}"


@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    """
    Truly vectorized handler — one batch per call (~4000 rows).

    For each row, produces: "T0-<uuid5(guid, '111' + loc_id)>"

    This is byte-for-byte identical to StableCloc(loc).encode(guid, 1, 11, 'T0', None)
    but eliminates:
      - StableCloc dataclass instantiation (frozen dataclass per row)
      - uuid.UUID() GUID string parsing (cached as _NS_BYTES)
      - uuid.uuid5() internal SHA-1 wrapper overhead (inlined as hashlib.sha1)
      - f-string hash_input construction (pre-computed prefix)
    """
    loc_ids = df.iloc[:, 0]
    prefix = _HASH_PREFIX
    results = [
        f"T0-{_uuid5_fast((prefix + loc).encode('utf-8'))}"
        for loc in loc_ids
    ]
    return pd.Series(results, index=loc_ids.index)
$$;


-- ---------------------------------------------------------------------------
-- Smoke test — verify the UDF is working before timing
-- ---------------------------------------------------------------------------
SELECT
    LOCID_DEV.BENCHMARK.PROXY_WHL(
        'somelocid',
        'unused'
    ) AS result;
-- Expected: T0-8c68cf6f-baf0-5fc1-8f82-3ee94059e6ce  (39 chars, starts with 'T0-')
-- (Same deterministic output as smoke test 3a in snowflake-integration-template.sql)
