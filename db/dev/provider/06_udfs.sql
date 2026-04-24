-- =============================================================================
-- 06_udfs.sql
-- LocID Dev: Scala UDFs wrapping encode-lib JAR
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
-- KEY MAP — secrets used across all UDFs
-- (neither the License Key nor the API Key is passed to UDFs directly)
--
--   base_locid_secret  → APP_CONFIG 'base_locid_secret' (fetched from license endpoint secrets)
--                        Base64-URL encoded, ~ as alternate padding.
--                        Key derivation: secret.replaceAll("~","=") → Base64.getUrlDecoder.decode() → AES key
--                        Used by: BaseLocIdEncryption  (UDFs 1, 2, 3, 5)
--                        Parameter name in UDFs: key_str  (UDF 1/2),  base_locid_key  (UDF 3/5)
--
--   scheme_secret      → APP_CONFIG 'scheme_secret' (fetched from license endpoint secrets)
--                        Same encoding and key derivation as base_locid_secret.
--                        Used by: EncScheme0  (UDFs 3, 4)
--                        Parameter name in UDFs: scheme_key
--
--   API Key            → NOT used in any UDF.
--                        Used only as de-access-token HTTP header for stats reporting.
--
--   License Key        → NOT passed to any UDF.
--                        Used to call LocID Central API to retrieve secrets + access[].
--
-- JAR: encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar  (Scala 2.13 / Java 17)
--
-- TYPE MAPPING:
--   Snowflake maps SQL INT → Scala Int, BIGINT → Scala Long for LANGUAGE SCALA UDFs.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- Full stage reference used inline in each IMPORTS clause:
--   @LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT
--    Encrypts a raw base LocID string using BaseLocIdEncryption.
--    Returns: base64-URL encoded ciphertext.
--
--    Input:  loc_id  — raw base LocID string  e.g. '31F24ZE1W1YX58K2R1139'
--            key_str — base_locid_secret (Base64-URL encoded AES key, from license endpoint secrets)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.encrypt'
AS $$
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  class Handler {
    private def toKey(keyStr: String): SecretKeySpec = {
      val decoded = java.util.Base64.getUrlDecoder.decode(keyStr.replaceAll("~", "="))
      new SecretKeySpec(decoded, "AES")
    }

    def encrypt(locId: String, keyStr: String): String = {
      val enc = BaseLocIdEncryption(toKey(keyStr))
      Base64.getUrlEncoder.encodeToString(enc.encrypt(locId.getBytes(StandardCharsets.UTF_8)))
    }
  }
$$;


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT
--    Decrypts a base64-URL encoded ciphertext back to the raw base LocID string.
--
--    Input:  encrypted_loc_id — base64-URL encoded ciphertext (output of LOCID_BASE_ENCRYPT)
--            key_str          — base_locid_secret (same key used to encrypt)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.decrypt'
AS $$
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  class Handler {
    private def toKey(keyStr: String): SecretKeySpec = {
      val decoded = java.util.Base64.getUrlDecoder.decode(keyStr.replaceAll("~", "="))
      new SecretKeySpec(decoded, "AES")
    }

    def decrypt(encryptedLocId: String, keyStr: String): String = {
      val enc     = BaseLocIdEncryption(toKey(keyStr))
      val decoded = Base64.getUrlDecoder.decode(encryptedLocId)
      new String(enc.decrypt(decoded), StandardCharsets.UTF_8)
    }
  }
$$;


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT
--    Production UDF: takes an encrypted_locid from LOCID_BUILDS, decrypts it,
--    then encodes it as a TX_CLOC using EncScheme0.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID (from DB) using BASE_LOCID_KEY → raw base LocID
--      2. Build TxCloc(locId, timestampSec, clientId, GeoContext())
--      3. Encode via EncScheme0 using SCHEME_KEY → TX_CLOC string
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            scheme_key       — EncScheme0 key (may differ from base_locid_key in production)
--            timestamp_sec    — Unix timestamp in seconds (BIGINT → Long)
--            client_id        — encClientId for TxCloc (INT → Int)
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_TXCLOC_ENCRYPT(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    SCHEME_KEY       VARCHAR,
    TIMESTAMP_SEC    BIGINT,
    CLIENT_ID        INT
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.txClocEncrypt'
AS $$
  import io.ol.locationid.TxCloc
  import io.ol.locationid.GeoContext
  import io.ol.locationid.encoding.EncScheme0
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  class Handler {
    private def toKey(keyStr: String): SecretKeySpec = {
      val decoded = java.util.Base64.getUrlDecoder.decode(keyStr.replaceAll("~", "="))
      new SecretKeySpec(decoded, "AES")
    }

    def txClocEncrypt(encryptedLocid: String, baseLocidKey: String, schemeKey: String,
                      timestampSec: Long, clientId: Int): String = {
      // 1. Decrypt encrypted_locid → raw base LocID
      val baseEnc   = BaseLocIdEncryption(toKey(baseLocidKey))
      val decoded   = Base64.getUrlDecoder.decode(encryptedLocid)
      val baseLocId = new String(baseEnc.decrypt(decoded), StandardCharsets.UTF_8)
      // 2. Build TxCloc and encode via EncScheme0
      val scheme = new EncScheme0(toKey(schemeKey))
      val txCloc = TxCloc(baseLocId, timestampSec, clientId, GeoContext())
      scheme.encoder.encode(txCloc).fold(t => throw t, identity)
    }
  }
$$;


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT
--    Production UDF: decodes a TX_CLOC string back to its component fields.
--
--    Returns: VARCHAR — JSON string:
--      { "location_id": "...", "timestamp": 1234567890, "enc_client_id": 1 }
--    Use PARSE_JSON() in SQL to access individual fields.
--
--    Input:  tx_cloc    — TX_CLOC string (output of LOCID_TXCLOC_ENCRYPT)
--            scheme_key — same EncScheme0 key used to encrypt
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.txClocDecrypt'
AS $$
  import io.ol.locationid.encoding.EncScheme0
  import javax.crypto.spec.SecretKeySpec

  class Handler {
    private def toKey(keyStr: String): SecretKeySpec = {
      val decoded = java.util.Base64.getUrlDecoder.decode(keyStr.replaceAll("~", "="))
      new SecretKeySpec(decoded, "AES")
    }

    def txClocDecrypt(txCloc: String, schemeKey: String): String = {
      val scheme = new EncScheme0(toKey(schemeKey))
      scheme.encoder.decode(txCloc).fold(
        t => throw t,
        d => s"""{"location_id":"${d.locationId}","timestamp":${d.timestamp},"enc_client_id":${d.encClientId}}"""
      )
    }
  }
$$;


-- =============================================================================
-- 5. LOCID_STABLE_CLOC
--    Production UDF: takes an encrypted_locid from LOCID_BUILDS and generates
--    a publisher-specific Stable CLOC UUID.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID string
--      2. StableCloc(locId).encode(namespaceGuid, clientId, encClientId, Some(tier))
--         → e.g. "T0-463cd5b0-89e6-52b2-885e-baff5124f992"
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            namespace_guid   — customer namespace GUID (with or without dashes)
--            client_id        — decrypting client ID (consumer) (INT → Int)
--            enc_client_id    — encrypting client ID (publisher) (INT → Int)
--            tier             — location tier: 'T0' (rooftop) or 'T1' (low accuracy)
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
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.stableCloc'
AS $$
  import io.ol.locationid.StableCloc
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  class Handler {
    private def toKey(keyStr: String): SecretKeySpec = {
      val decoded = java.util.Base64.getUrlDecoder.decode(keyStr.replaceAll("~", "="))
      new SecretKeySpec(decoded, "AES")
    }

    def stableCloc(encryptedLocid: String, baseLocidKey: String, namespaceGuid: String,
                   clientId: Int, encClientId: Int, tier: String): String = {
      // 1. Decrypt encrypted_locid → raw base LocID
      val baseEnc   = BaseLocIdEncryption(toKey(baseLocidKey))
      val decoded   = Base64.getUrlDecoder.decode(encryptedLocid)
      val baseLocId = new String(baseEnc.decrypt(decoded), StandardCharsets.UTF_8)
      // 2. Generate stable CLOC
      StableCloc(baseLocId).encode(namespaceGuid, clientId, encClientId, Some(tier))
    }
  }
$$;
