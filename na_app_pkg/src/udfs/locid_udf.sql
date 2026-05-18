-- =============================================================================
-- src/udfs/locid_udf.sql
-- LocID Native App — Python Vectorized UDF Definitions
--
-- This file is uploaded to @APP_SCHEMA.APP_STAGE/src/udfs/ and executed
-- from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/udfs/locid_udf.sql';
--
-- Prerequisites:
--   - mb_locid_encoding WHL uploaded to @APP_SCHEMA.APP_STAGE/lib/
--     (staged via snow app deploy from src/lib/)
--   - LOCID_CENTRAL_EAI declared in setup.sql with the four secrets in
--     ALLOWED_AUTHENTICATION_SECRETS (no setup.sql change needed)
--
-- UDFs created (all Python vectorized, @vectorized batch dispatch):
--   1. LOCID_BASE_ENCRYPT    — admin helper: encrypt raw base LocID string
--   2. LOCID_BASE_DECRYPT    — production: decrypt base64 ciphertext (used inline by encrypt proc)
--   3. LOCID_TXCLOC_ENCRYPT  — production: JSON (flat geo fields) → TX_CLOC
--   4. LOCID_TXCLOC_DECRYPT  — production: TX_CLOC → JSON (all encoded fields incl. geo)
--   5. LOCID_STABLE_CLOC     — production: encrypted_locid (from share) → STABLE_CLOC UUID
--   6. LOCID_STABLE_CLOC_FROM_PLAIN — decrypt path: plaintext base LocID → STABLE_CLOC UUID
--
-- =============================================================================
-- SECRET-BACKED v2 (May 2026)
--
-- Crypto keys are no longer passed as VARCHAR arguments. Each UDF that needs an
-- AES key declares EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI) and
-- SECRETS = ('alias' = APP_SCHEMA.LOCID_*_SECRET), and reads the key inside the
-- handler via _snowflake.get_generic_secret_string('alias').
--
-- KEY MAP — secrets used across all UDFs (none passed as parameters)
--
--   APP_SCHEMA.LOCID_BASE_SECRET    → BaseLocIdEncryption AES key
--                                     Used by: LOCID_BASE_ENCRYPT,
--                                              LOCID_BASE_DECRYPT,
--                                              LOCID_STABLE_CLOC
--
--   APP_SCHEMA.LOCID_SCHEME_SECRET  → EncScheme0 AES key
--                                     Used by: LOCID_TXCLOC_ENCRYPT,
--                                              LOCID_TXCLOC_DECRYPT
--
-- Both secrets are populated by LOCID_FETCH_LICENSE from LocID Central. They are
-- already listed in LOCID_CENTRAL_EAI.ALLOWED_AUTHENTICATION_SECRETS (setup.sql).
-- =============================================================================
-- WHL: mb_locid_encoding-0.0.0-py3-none-any.whl  (Python 3.11, pure Python)
--
-- PERFORMANCE NOTE:
--   Each handler uses @vectorized batch dispatch — Snowflake delivers batches of
--   ~4,000 rows per call, reducing Python/SQL boundary crossings by ~1000×.
--   Module-scope caches (scheme key → cipher, base key → cipher) persist across
--   batches within the same worker process. The AES key itself is fetched from
--   the Snowflake SECRET once per worker process and cached as a length-1 Series
--   so that locid.snowflake's existing cipher-cache contract is satisfied without
--   a wheel rebuild.
--
-- KEY ROTATION CAVEAT:
--   Module-scope key caches survive across batches within a worker process.
--   When LOCID_FETCH_LICENSE rotates LOCID_*_SECRET, in-flight worker processes
--   continue to use the cached key until the worker recycles (warehouse suspend,
--   idle timeout, scale event). For ordinary daily-or-less-frequent rotations
--   this is acceptable; if shorter rotation is required, drop the module-scope
--   cache and read the secret per-batch.
--
-- sys.path NOTE:
--   The WHL is staged via snow app deploy (same as the JAR was). Python's runtime
--   does not auto-register staged .whl files for zipimport. The sys.path hack at
--   module scope in each handler promotes .whl files onto sys.path once per worker.
--   Cost: ~10–50 μs one-time per worker process — negligible.
-- =============================================================================


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT  (admin helper)
--    Encrypts a raw base LocID string using BaseLocIdEncryption (AES-GCM) under
--    the app's stored base secret.
--    Returns: URL-safe base64 encoded ciphertext.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_ENCRYPT(
    LOC_ID  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS  = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
SECRETS = ('base_key' = APP_SCHEMA.LOCID_BASE_SECRET)
HANDLER = 'encrypt_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import _snowflake
import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

# Cached as a length-1 Series — locid_sf.encrypt_base_loc_id reads
# .iloc[0] of the key Series for its cipher-cache key.
_KEY_SERIES = None

@vectorized(input=pd.DataFrame)
def encrypt_batch(df: pd.DataFrame) -> pd.Series:
    global _KEY_SERIES
    if _KEY_SERIES is None:
        _KEY_SERIES = pd.Series([_snowflake.get_generic_secret_string('base_key')])
    return locid_sf.encrypt_base_loc_id(df.iloc[:, 0], _KEY_SERIES)
$$;


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT  (production)
--    Decrypts a URL-safe base64 encoded ciphertext back to the raw base LocID.
--    Called inline by LOCID_ENCRYPT proc inside OBJECT_CONSTRUCT to feed
--    LOCID_TXCLOC_ENCRYPT.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS  = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
SECRETS = ('base_key' = APP_SCHEMA.LOCID_BASE_SECRET)
HANDLER = 'decrypt_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import _snowflake
import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

_KEY_SERIES = None

@vectorized(input=pd.DataFrame)
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    global _KEY_SERIES
    if _KEY_SERIES is None:
        _KEY_SERIES = pd.Series([_snowflake.get_generic_secret_string('base_key')])
    return locid_sf.decrypt_base_loc_id(df.iloc[:, 0], _KEY_SERIES)
$$;


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT  (production)
--    Encrypts a flat JSON document into a TX_CLOC string under scheme_secret.
--
--    Input JSON (tx_cloc_json) — flat object with:
--      REQUIRED: base_loc_id (string), timestamp (int epoch sec),
--                enc_client_id (int), tier (string "T0"|"T1")
--      OPTIONAL: country, region, city, postal_code,
--                country_code, region_code, city_code  (NetAcuity numeric
--                  codes — must be VARCHAR, not NUMBER),
--                horizontal_accuracy, alt_id, homebiz_type
--      Omitted optional fields are absent from JSON (NULL ↔ absent).
--      alt_id present silently overrides tier to "T0".
--
--    returns:      base64-encoded TX CLOC ending in ".0"
--
--    The encrypt proc builds tx_cloc_json via OBJECT_CONSTRUCT (which
--    automatically drops NULL-valued keys), then calls this UDF.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_ENCRYPT(
    TX_CLOC_JSON VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS  = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
SECRETS = ('scheme_key' = APP_SCHEMA.LOCID_SCHEME_SECRET)
HANDLER = 'encrypt_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import _snowflake
import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

_KEY_SERIES = None

@vectorized(input=pd.DataFrame)
def encrypt_batch(df: pd.DataFrame) -> pd.Series:
    global _KEY_SERIES
    if _KEY_SERIES is None:
        _KEY_SERIES = pd.Series([_snowflake.get_generic_secret_string('scheme_key')])
    return locid_sf.encrypt_tx_cloc(df.iloc[:, 0], _KEY_SERIES)
$$;


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT  (production)
--    Decodes a TX_CLOC string back to its component fields under scheme_secret.
--    Returns: VARCHAR — JSON string:
--      { "base_loc_id": "...", "timestamp": 1234567890, "enc_client_id": 1, ... }
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_DECRYPT(
    TX_CLOC  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS  = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
SECRETS = ('scheme_key' = APP_SCHEMA.LOCID_SCHEME_SECRET)
HANDLER = 'decrypt_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import _snowflake
import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

_KEY_SERIES = None

@vectorized(input=pd.DataFrame)
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    global _KEY_SERIES
    if _KEY_SERIES is None:
        _KEY_SERIES = pd.Series([_snowflake.get_generic_secret_string('scheme_key')])
    return locid_sf.decrypt_tx_cloc(df.iloc[:, 0], _KEY_SERIES)
$$;


-- =============================================================================
-- 5. LOCID_STABLE_CLOC  (production — encrypt path)
--    Takes encrypted_locid from LOCID_BUILDS and generates a publisher-specific
--    Stable CLOC UUID under base_secret.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using stored base_secret → raw base LocID
--      2. StableCloc(locId).encode(namespaceGuid, clientId, encClientId, tier)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_STABLE_CLOC(
    ENCRYPTED_LOCID  VARCHAR,
    NAMESPACE_GUID   VARCHAR,
    CLIENT_ID        INT,
    ENC_CLIENT_ID    INT,
    TIER             VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS  = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
SECRETS = ('base_key' = APP_SCHEMA.LOCID_BASE_SECRET)
HANDLER = 'stable_cloc_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import _snowflake
import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

_KEY_SERIES = None

@vectorized(input=pd.DataFrame)
def stable_cloc_batch(df: pd.DataFrame) -> pd.Series:
    # df columns: [encrypted_locid, namespace_guid, client_id, enc_client_id, tier]
    # stable_cloc_from_encrypted expects: (encrypted, key, guid, dec_client_id, enc_client_id, tier, alt_id)
    global _KEY_SERIES
    if _KEY_SERIES is None:
        _KEY_SERIES = pd.Series([_snowflake.get_generic_secret_string('base_key')])
    n = len(df)
    return locid_sf.stable_cloc_from_encrypted(
        df.iloc[:, 0],                              # encrypted_base_loc_id
        _KEY_SERIES,                                # base_locid_key (from secret)
        df.iloc[:, 1],                              # guid
        df.iloc[:, 2],                              # dec_client_id (CLIENT_ID)
        df.iloc[:, 3],                              # enc_client_id
        df.iloc[:, 4],                              # tier
        pd.Series([None] * n, dtype='object'),      # alt_id (NULL — not used in encrypt path)
    )
$$;


-- =============================================================================
-- 6. LOCID_STABLE_CLOC_FROM_PLAIN  (decrypt path) — unchanged
--    Generates a STABLE_CLOC from a plaintext base LocID string. Pure SHA-1 /
--    UUID5; no AES key required, so no EXTERNAL_ACCESS_INTEGRATIONS / SECRETS.
--    Used in the Decrypt stored procedure where LOCID_TXCLOC_DECRYPT returns
--    the raw location_id directly — no base-encryption round-trip needed.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN(
    BASE_LOC_ID    VARCHAR,
    NAMESPACE_GUID VARCHAR,
    DEC_CLIENT_ID  INT,
    ENC_CLIENT_ID  INT,
    TIER           VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'encode_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

@vectorized(input=pd.DataFrame)
def encode_batch(df: pd.DataFrame) -> pd.Series:
    # df columns: [base_loc_id, namespace_guid, dec_client_id, enc_client_id, tier]
    n = len(df)
    return locid_sf.encode_stable_cloc(
        df.iloc[:, 0],                              # location_id
        df.iloc[:, 1],                              # guid
        df.iloc[:, 2],                              # dec_client_id
        df.iloc[:, 3],                              # enc_client_id
        df.iloc[:, 4],                              # tier
        pd.Series([None] * n, dtype='object'),      # alt_id (NULL — not used in v1)
    )
$$;


-- NOTE: Object-level grants are not supported in versioned schemas.
-- USAGE on APP_CODE schema is granted to APP_ADMIN in setup.sql.
-- These UDFs are called from owner's-rights stored procs (LOCID_ENCRYPT / LOCID_DECRYPT)
-- and do not require direct application role grants.
