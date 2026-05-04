-- =============================================================================
-- db/dev/benchmark/05_whl_vectorized.sql
-- LocID Dev: Approach D — Python vectorized UDF using the actual mb-locid-encoding wheel
--
-- APPROACH D — Python vectorized, actual WHL
--
-- Purpose:
--   Replaces the numpy BLAS proxy (Approach C) with the production
--   mb-locid-encoding wheel (locid.snowflake.encode_stable_cloc) to measure
--   real SHA-1 UUID5 throughput under @vectorized batch dispatch.
--   This is the definitive vectorized Python benchmark against Approach A (Scala).
--
-- Production equivalent: LOCID_DEV.APP_SCHEMA.LOCID_STABLE_CLOC_FROM_PLAIN
--
-- UDF signature mirrors MOCKUP_5M (loc_id, key_str) so 04_run_timing.sql can
-- address it with the same FROM clause as Approaches B and C.
-- key_str is unused — encode_stable_cloc requires no secret key.
--
-- ⚠ Prerequisites:
--   1. Upload the wheel to the stage before running this file:
--        PUT file:///absolute/path/to/dist/<WHEEL_FILE>
--            @LOCID_DEV.STAGING.LOCID_STAGE/wheels/
--            AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
--   2. Verify: LIST @LOCID_DEV.STAGING.LOCID_STAGE/wheels/;
--   3. Replace <WHEEL_FILE> below with the actual filename
--      (e.g. mb_locid_encoding-1.0.0-py3-none-any.whl).
--
-- Run order: after 01_setup.sql; before 04_run_timing.sql Approach D block.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.BENCHMARK;


-- ---------------------------------------------------------------------------
-- Approach D — vectorized UDF backed by the actual mb-locid-encoding wheel
--
-- Handler broadcasts constants for guid / dec_client_id / enc_client_id /
-- tier / alt_id so that locid_sf.encode_stable_cloc receives pd.Series for
-- every argument, matching its production calling convention.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION LOCID_DEV.BENCHMARK.PROXY_WHL(
    LOC_ID   VARCHAR,   -- location_id (from MOCKUP_5M.loc_id; varies per row)
    KEY_STR  VARCHAR    -- unused; included to match MOCKUP_5M schema
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'encode_batch'
COMMENT = 'Approach D: Python vectorized, actual mb-locid-encoding wheel — locid_sf.encode_stable_cloc on MOCKUP_5M'
AS $$
import os, sys, glob

# Promote any .whl files staged via IMPORTS onto sys.path so zipimport can find them.
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

# Constants broadcast to every row in the batch.
# These mirror the smoke-test values in snowflake-integration-template.sql.
_GUID = '11111111-1111-1111-1111-111111111111'
_DEC  = 1
_ENC  = 11
_TIER = 'T0'


@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    """
    Vectorized handler — called once per batch of N rows.

    df.iloc[:, 0] = LOC_ID column  (varies per row — drives unique output per row)
    df.iloc[:, 1] = KEY_STR column (unused for encode_stable_cloc)

    guid / dec_client_id / enc_client_id / tier / alt_id are constant across
    the benchmark dataset; they are broadcast as same-length pd.Series so that
    locid_sf.encode_stable_cloc receives a uniform Series-per-argument interface.
    """
    n = len(df)
    return locid_sf.encode_stable_cloc(
        df.iloc[:, 0],                               # location_id (varies)
        pd.Series([_GUID] * n, dtype='object'),      # guid (constant)
        pd.Series([_DEC]  * n),                      # dec_client_id
        pd.Series([_ENC]  * n),                      # enc_client_id
        pd.Series([_TIER] * n, dtype='object'),      # tier
        pd.Series([None]  * n, dtype='object'),      # alt_id (nullable)
    )
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
