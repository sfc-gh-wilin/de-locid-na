-- =============================================================================
-- 06_udfs.sql
-- LocID Dev: Java UDFs wrapping encode-lib JAR
--
-- Run order: after 05_stage_setup.sql AND after the JAR has been PUT to stage.
-- All UDFs are created in LOCID_DEV.STAGING.
--
-- UDFs created:
--   1. LOCID_BASE_ENCRYPT    — test helper: encrypt raw base LocID string
--   2. LOCID_BASE_DECRYPT    — test helper: decrypt base64 encrypted LocID
--   3. LOCID_TXCLOC_ENCRYPT  — production: encrypted_locid (from DB) → TX_CLOC
--   4. LOCID_TXCLOC_DECRYPT  — production: TX_CLOC → JSON (location_id, timestamp, enc_client_id)
--   5. LOCID_STABLE_CLOC     — production: encrypted_locid (from DB) → STABLE_CLOC UUID
--
-- ⚠ KEY DERIVATION (TEST MODE ONLY):
--   These UDFs derive the AES key by taking UTF-8 bytes of the key string and
--   padding to 32 bytes (AES-256). This matches EncryptionTest.scala and
--   EncryptionTestWithTS.scala used for local JAR testing.
--
--   PRODUCTION key derivation (from LocID Central) is:
--     Base64.getUrlDecoder().decode(secret.replace('~','='))  →  16 bytes (AES-128)
--   This discrepancy MUST be resolved with Digital Envoy before production deploy.
--
-- JAR: encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar  (Java 17 build — pending DE)
--
-- ⚠ HANDLER CLASS:
--   All UDFs point to io.ol.locationid.SnowflakeHandler — a public Java class that
--   DE must include in the fat JAR.  Method signatures are documented per UDF below.
--   Confirm exact class name and method names with DE before running this file.
--
-- ⚠ TYPE MAPPING:
--   Snowflake maps SQL INT and BIGINT → Java long for LANGUAGE JAVA UDFs.
--   All integer handler parameters must be declared as long, not int.
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- Full stage reference used inline in each IMPORTS clause:
--   @LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT
--    Encrypts a raw base LocID string using BaseLocIdEncryption.
--    Returns: base64-URL encoded ciphertext (no padding).
--
--    Maps to EncryptionTest.scala behaviour.
--    Input:  loc_id  — raw base LocID string  e.g. '31F24ZE1W1YX58K2R1139'
--            key_str — license key string (dev mode: UTF-8 bytes padded to 32)
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String encrypt(String locId, String keyStr)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(
    LOC_ID    VARCHAR,
    KEY_STR   VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.encrypt';


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT
--    Decrypts a base64-URL encoded ciphertext back to the raw base LocID string.
--
--    Input:  encrypted_loc_id — base64-URL encoded ciphertext (output of LOCID_BASE_ENCRYPT)
--            key_str          — same license key used to encrypt
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String decrypt(String encryptedLocId, String keyStr)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.decrypt';


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT
--    Production UDF: takes an encrypted_locid from LOCID_BUILDS, decrypts it,
--    then encodes it as a TX_CLOC using EncScheme0.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID (stored in DB) using BASE_LOCID_KEY
--         → raw base LocID string
--      2. Build TxCloc(locId, timestampSec, clientId, GeoContext(), None)
--      3. Encode via EncScheme0 using SCHEME_KEY → TX_CLOC string
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            scheme_key       — EncScheme0 key (may differ from base_locid_key in production)
--            timestamp_sec    — Unix timestamp in seconds (BIGINT)
--            client_id        — encClientId for TxCloc (publisher/consumer ID) (INT → long)
--    Returns: TX_CLOC string
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String txClocEncrypt(String encryptedLocid, String baseLocidKey,
--                                         String schemeKey, long timestampSec, long clientId)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_TXCLOC_ENCRYPT(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    SCHEME_KEY       VARCHAR,
    TIMESTAMP_SEC    BIGINT,
    CLIENT_ID        INT
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.txClocEncrypt';


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT
--    Production UDF: decodes a TX_CLOC string back to its component fields.
--
--    Returns: VARCHAR — JSON string with keys:
--      { "location_id": "...", "timestamp": 1234567890, "enc_client_id": 1 }
--    Use PARSE_JSON() in SQL to access individual fields.
--
--    Input:  tx_cloc    — TX_CLOC string (output of LOCID_TXCLOC_ENCRYPT)
--            scheme_key — same EncScheme0 key used to encrypt
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String txClocDecrypt(String txCloc, String schemeKey)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.txClocDecrypt';


-- =============================================================================
-- 5. LOCID_STABLE_CLOC
--    Production UDF: takes an encrypted_locid from LOCID_BUILDS and generates
--    a publisher-specific Stable CLOC UUID.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID string
--      2. StableCloc(locId).encode(namespaceGuid, clientId, Some(encClientId), Some(tier))
--         → UUID string e.g. "463cd5b0-89e6-52b2-885e-baff5124f992"
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            namespace_guid   — customer namespace GUID (hex string, no dashes)
--                               e.g. 'ffffffff111122223333444444444444'
--            client_id        — decrypting client ID (consumer) (INT → long)
--            enc_client_id    — encrypting client ID (publisher) (INT → long)
--            tier             — location tier: 'T0' (rooftop) or 'T1' (low accuracy)
--    Returns: UUID string
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String stableCloc(String encryptedLocid, String baseLocidKey,
--                                      String namespaceGuid, long clientId,
--                                      long encClientId, String tier)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_STABLE_CLOC(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    NAMESPACE_GUID   VARCHAR,
    CLIENT_ID        INT,
    ENC_CLIENT_ID    INT,
    TIER             VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.stableCloc';
