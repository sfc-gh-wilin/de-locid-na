-- =============================================================================
-- src/udfs/locid_udf.sql
-- LocID Native App — Java UDF Definitions
--
-- This file is uploaded to @APP_SCHEMA.APP_STAGE/src/udfs/ and executed
-- from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/udfs/locid_udf.sql';
--
-- Prerequisites:
--   - encode-lib JAR uploaded to @APP_SCHEMA.APP_STAGE/lib/ (Java 17 build)
--   - ⚠ BLOCKED until DE provides Java 17 fat JAR with SnowflakeHandler class
--     See Open Items in README.md
--
-- UDFs created:
--   1. LOCID_BASE_ENCRYPT    — admin helper: encrypt raw base LocID string
--   2. LOCID_BASE_DECRYPT    — admin helper: decrypt base64 ciphertext
--   3. LOCID_TXCLOC_ENCRYPT  — production: encrypted_locid (from share) → TX_CLOC
--   4. LOCID_TXCLOC_DECRYPT  — production: TX_CLOC → JSON (location_id, timestamp, enc_client_id)
--   5. LOCID_STABLE_CLOC     — production: encrypted_locid (from share) → STABLE_CLOC UUID
--
-- ⚠ KEY DERIVATION (TEST MODE):
--   UDFs derive AES key from UTF-8 bytes of key string padded to 32 bytes (AES-256).
--   PRODUCTION: replace with Base64.getUrlDecoder().decode(centralSecret) → 16 bytes (AES-128).
--   Confirm correct key size with DE before production deploy.
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


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT  (admin helper)
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String encrypt(String locId, String keyStr)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_BASE_ENCRYPT(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.encrypt';


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT  (admin helper)
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String decrypt(String encryptedLocId, String keyStr)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.decrypt';


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share, decrypts to base LocID,
--    then encodes as TX_CLOC using EncScheme0.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID string
--      2. Build TxCloc(locId, timestampSec, clientId, GeoContext(), None)
--      3. Encode via EncScheme0 using SCHEME_KEY → TX_CLOC string
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String txClocEncrypt(String encryptedLocid, String baseLocidKey,
--                                         String schemeKey, long timestampSec, long clientId)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_TXCLOC_ENCRYPT(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    SCHEME_KEY       VARCHAR,
    TIMESTAMP_SEC    BIGINT,
    CLIENT_ID        INT
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.txClocEncrypt';


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT  (production)
--    Decodes a TX_CLOC string back to its component fields.
--    Returns VARCHAR (JSON): { "location_id": "...", "timestamp": ..., "enc_client_id": ... }
--    Use PARSE_JSON() in the calling stored procedure to access individual fields.
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String txClocDecrypt(String txCloc, String schemeKey)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE JAVA
RUNTIME_VERSION = '17'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.txClocDecrypt';


-- =============================================================================
-- 5. LOCID_STABLE_CLOC  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share and generates a
--    publisher-specific Stable CLOC UUID.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID string
--      2. StableCloc(locId).encode(namespaceGuid, clientId, Some(encClientId), Some(tier))
--         → UUID string e.g. "463cd5b0-89e6-52b2-885e-baff5124f992"
--
--    Expected Java method in SnowflakeHandler (DE to implement):
--      public static String stableCloc(String encryptedLocid, String baseLocidKey,
--                                      String namespaceGuid, long clientId,
--                                      long encClientId, String tier)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_STABLE_CLOC(
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
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'io.ol.locationid.SnowflakeHandler.stableCloc';


-- =============================================================================
-- Grants
-- =============================================================================
GRANT USAGE ON FUNCTION APP_SCHEMA.LOCID_BASE_ENCRYPT(VARCHAR, VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON FUNCTION APP_SCHEMA.LOCID_BASE_DECRYPT(VARCHAR, VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON FUNCTION APP_SCHEMA.LOCID_TXCLOC_ENCRYPT(VARCHAR, VARCHAR, VARCHAR, BIGINT, INT)
    TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON FUNCTION APP_SCHEMA.LOCID_TXCLOC_DECRYPT(VARCHAR, VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON FUNCTION APP_SCHEMA.LOCID_STABLE_CLOC(VARCHAR, VARCHAR, VARCHAR, INT, INT, VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
