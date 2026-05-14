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
--
-- UDFs created (all Python vectorized, @vectorized batch dispatch):
--   1. LOCID_BASE_ENCRYPT    — admin helper: encrypt raw base LocID string
--   2. LOCID_BASE_DECRYPT    — admin helper: decrypt base64 ciphertext
--   3. LOCID_TXCLOC_ENCRYPT  — production: JSON (flat geo fields) → TX_CLOC
--   4. LOCID_TXCLOC_DECRYPT  — production: TX_CLOC → JSON (all encoded fields incl. geo)
--   5. LOCID_STABLE_CLOC     — production: encrypted_locid (from share) → STABLE_CLOC UUID
--   6. LOCID_STABLE_CLOC_FROM_PLAIN — decrypt path: plaintext base LocID → STABLE_CLOC UUID
--
-- KEY MAP — secrets used across all UDFs
-- (neither the License Key nor the API Key is passed to UDFs directly)
--
--   base_locid_secret  → APP_CONFIG 'base_locid_secret' (fetched from license endpoint secrets)
--                        Base64-URL encoded, ~ as alternate padding.
--                        Used by: BaseLocIdEncryption  (UDFs 1, 2, 5)
--                        Parameter name in UDFs: key_str (UDF 1/2), base_locid_key (UDF 5)
--
--   scheme_secret      → APP_CONFIG 'scheme_secret' (fetched from license endpoint secrets)
--                        Same encoding as base_locid_secret.
--                        Used by: EncScheme0  (UDFs 3, 4)
--                        Parameter name in UDFs: scheme_key
--
-- WHL: mb_locid_encoding-0.0.0-py3-none-any.whl  (Python 3.11, pure Python)
--
-- PERFORMANCE NOTE:
--   Each handler uses @vectorized batch dispatch — Snowflake delivers batches of
--   ~4,000 rows per call, reducing Python/SQL boundary crossings by ~1000×.
--   Module-scope caches (scheme key → cipher, base key → cipher) persist across
--   batches within the same worker process.
--
-- sys.path NOTE:
--   The WHL is staged via snow app deploy (same as the JAR was). Python's runtime
--   does not auto-register staged .whl files for zipimport. The sys.path hack at
--   module scope in each handler promotes .whl files onto sys.path once per worker.
--   Cost: ~10–50 μs one-time per worker process — negligible.
-- =============================================================================


-- =============================================================================
-- Common sys.path preamble (included in each UDF handler body)
-- =============================================================================
-- Each handler AS $$ block begins with:
--   import os, sys, glob
--   for _dir in list(sys.path):
--       if _dir and os.path.isdir(_dir):
--           for _whl in glob.glob(os.path.join(_dir, '*.whl')):
--               if _whl not in sys.path:
--                   sys.path.insert(0, _whl)


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT  (admin helper)
--    Encrypts a raw base LocID string using BaseLocIdEncryption (AES-GCM).
--    Returns: URL-safe base64 encoded ciphertext.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_ENCRYPT(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'encrypt_batch'
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
def encrypt_batch(df: pd.DataFrame) -> pd.Series:
    return locid_sf.encrypt_base_loc_id(df.iloc[:, 0], df.iloc[:, 1])
$$;


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT  (admin helper)
--    Decrypts a URL-safe base64 encoded ciphertext back to the raw base LocID.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'decrypt_batch'
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
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    return locid_sf.decrypt_base_loc_id(df.iloc[:, 0], df.iloc[:, 1])
$$;


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT  (production)
--    Encrypts a flat JSON document into a TX_CLOC string.
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
--    scheme_key:   AES key in any base64 variant (16/24/32 bytes raw)
--    returns:      base64-encoded TX CLOC ending in ".0"
--
--    The encrypt proc builds tx_cloc_json via OBJECT_CONSTRUCT (which
--    automatically drops NULL-valued keys), then calls this UDF.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_ENCRYPT(
    TX_CLOC_JSON VARCHAR,
    SCHEME_KEY   VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'encrypt_batch'
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
def encrypt_batch(df: pd.DataFrame) -> pd.Series:
    return locid_sf.encrypt_tx_cloc(df.iloc[:, 0], df.iloc[:, 1])
$$;


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT  (production)
--    Decodes a TX_CLOC string back to its component fields.
--    Returns: VARCHAR — JSON string:
--      { "base_loc_id": "...", "timestamp": 1234567890, "enc_client_id": 1 }
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'decrypt_batch'
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
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    return locid_sf.decrypt_tx_cloc(df.iloc[:, 0], df.iloc[:, 1])
$$;


-- =============================================================================
-- 5. LOCID_STABLE_CLOC  (production — encrypt path)
--    Takes encrypted_locid from LOCID_BUILDS and generates a publisher-specific
--    Stable CLOC UUID.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID
--      2. StableCloc(locId).encode(namespaceGuid, clientId, encClientId, tier)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_STABLE_CLOC(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    NAMESPACE_GUID   VARCHAR,
    CLIENT_ID        INT,
    ENC_CLIENT_ID    INT,
    TIER             VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'stable_cloc_batch'
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
def stable_cloc_batch(df: pd.DataFrame) -> pd.Series:
    # df columns: [encrypted_locid, base_locid_key, namespace_guid, client_id, enc_client_id, tier]
    # stable_cloc_from_encrypted expects: (encrypted, key, guid, dec_client_id, enc_client_id, tier, alt_id)
    n = len(df)
    return locid_sf.stable_cloc_from_encrypted(
        df.iloc[:, 0],                              # encrypted_base_loc_id
        df.iloc[:, 1],                              # base_locid_key
        df.iloc[:, 2],                              # guid
        df.iloc[:, 3],                              # dec_client_id (CLIENT_ID)
        df.iloc[:, 4],                              # enc_client_id
        df.iloc[:, 5],                              # tier
        pd.Series([None] * n, dtype='object'),      # alt_id (NULL — not used in encrypt path)
    )
$$;


-- =============================================================================
-- 6. LOCID_STABLE_CLOC_FROM_PLAIN  (decrypt path)
--    Generates a STABLE_CLOC from a plaintext base LocID string.
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
