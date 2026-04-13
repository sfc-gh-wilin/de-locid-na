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
-- ⚠ KEY DERIVATION (TEST MODE ONLY):
--   These UDFs derive the AES key by taking UTF-8 bytes of the key string and
--   padding to 32 bytes (AES-256). This matches EncryptionTest.scala and
--   EncryptionTestWithTS.scala used for local JAR testing.
--
--   PRODUCTION key derivation (from LocID Central) is:
--     Base64.getUrlDecoder.decode(secret.replace('~','='))  →  16 bytes (AES-128)
--   This discrepancy MUST be resolved with Digital Envoy before production deploy.
--
-- JAR: encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar  (Scala 2.12)
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- Define stage path as a local constant for readability in comments.
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
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT(
    LOC_ID    VARCHAR,
    KEY_STR   VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.encrypt'
AS $$
import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
import java.util.Base64
import java.nio.charset.StandardCharsets
import javax.crypto.spec.SecretKeySpec

class Handler {
  // TEST-MODE key derivation: UTF-8 bytes of key string padded to 32 bytes (AES-256)
  // PRODUCTION: replace with Base64.getUrlDecoder.decode(centralSecret) → 16 bytes (AES-128)
  private def toKey(keyStr: String): SecretKeySpec = {
    val raw = keyStr.getBytes(StandardCharsets.UTF_8)
    new SecretKeySpec(java.util.Arrays.copyOf(raw, 32), "AES")
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
--            key_str          — same license key used to encrypt
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.decrypt'
AS $$
import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
import java.util.Base64
import java.nio.charset.StandardCharsets
import javax.crypto.spec.SecretKeySpec

class Handler {
  private def toKey(keyStr: String): SecretKeySpec = {
    val raw = keyStr.getBytes(StandardCharsets.UTF_8)
    new SecretKeySpec(java.util.Arrays.copyOf(raw, 32), "AES")
  }

  def decrypt(encryptedLocId: String, keyStr: String): String = {
    val enc = BaseLocIdEncryption(toKey(keyStr))
    new String(enc.decrypt(Base64.getUrlDecoder.decode(encryptedLocId)), StandardCharsets.UTF_8)
  }
}
$$;


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
--            client_id        — encClientId for TxCloc (publisher/consumer ID)
--    Returns: TX_CLOC string
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
RUNTIME_VERSION = '2.12'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.encode'
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
    val raw = keyStr.getBytes(StandardCharsets.UTF_8)
    new SecretKeySpec(java.util.Arrays.copyOf(raw, 32), "AES")
  }

  def encode(encryptedLocid: String, baseLocidKey: String, schemeKey: String,
             timestampSec: Long, clientId: Int): String = {
    // Step 1: Decrypt the base LocID stored in LOCID_BUILDS
    val baseEnc = BaseLocIdEncryption(toKey(baseLocidKey))
    val locId   = new String(baseEnc.decrypt(Base64.getUrlDecoder.decode(encryptedLocid)),
                             StandardCharsets.UTF_8)
    // Step 2: Encode as TX_CLOC (5-param constructor confirmed from EncryptionTestWithTS.scala)
    val scheme = new EncScheme0(toKey(schemeKey))
    val txCloc = TxCloc(locId, timestampSec, clientId, GeoContext(), None)
    scheme.encoder.encode(txCloc) match {
      case Right(result) => result
      case Left(err)     => throw new RuntimeException(s"TX_CLOC encode failed: ${err.getMessage}")
    }
  }
}
$$;


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
-- =============================================================================
CREATE OR REPLACE FUNCTION LOCID_DEV.STAGING.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.decode'
AS $$
import io.ol.locationid.encoding.EncScheme0
import java.nio.charset.StandardCharsets
import javax.crypto.spec.SecretKeySpec

class Handler {
  private def toKey(keyStr: String): SecretKeySpec = {
    val raw = keyStr.getBytes(StandardCharsets.UTF_8)
    new SecretKeySpec(java.util.Arrays.copyOf(raw, 32), "AES")
  }

  def decode(txCloc: String, schemeKey: String): String = {
    val scheme = new EncScheme0(toKey(schemeKey))
    scheme.encoder.decode(txCloc) match {
      case Right(cloc) =>
        // Escape locationId to guard against quotes in the value
        val locId = cloc.locationId.replace("\\", "\\\\").replace("\"", "\\\"")
        s"""{"location_id":"$locId","timestamp":${cloc.timestamp},"enc_client_id":${cloc.encClientId}}"""
      case Left(err) =>
        throw new RuntimeException(s"TX_CLOC decode failed: ${err.getMessage}")
    }
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
--      2. StableCloc(locId).encode(namespaceGuid, clientId, Some(encClientId), Some(tier))
--         → UUID string e.g. "463cd5b0-89e6-52b2-885e-baff5124f992"
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            namespace_guid   — customer namespace GUID (hex string, no dashes)
--                               e.g. 'ffffffff111122223333444444444444'
--            client_id        — decrypting client ID (consumer)
--            enc_client_id    — encrypting client ID (publisher); use same as client_id
--                               for publisher-independent CLOC behaviour
--            tier             — location tier: 'T0' (rooftop) or 'T1' (low accuracy)
--    Returns: UUID string
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
RUNTIME_VERSION = '2.12'
IMPORTS = ('@LOCID_DEV.STAGING.LOCID_STAGE/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.generate'
AS $$
import io.ol.locationid.StableCloc
import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
import java.util.Base64
import java.nio.charset.StandardCharsets
import javax.crypto.spec.SecretKeySpec

class Handler {
  private def toKey(keyStr: String): SecretKeySpec = {
    val raw = keyStr.getBytes(StandardCharsets.UTF_8)
    new SecretKeySpec(java.util.Arrays.copyOf(raw, 32), "AES")
  }

  def generate(encryptedLocid: String, baseLocidKey: String, namespaceGuid: String,
               clientId: Long, encClientId: Long, tier: String): String = {
    // Step 1: Decrypt the base LocID stored in LOCID_BUILDS
    val baseEnc = BaseLocIdEncryption(toKey(baseLocidKey))
    val locId   = new String(baseEnc.decrypt(Base64.getUrlDecoder.decode(encryptedLocid)),
                             StandardCharsets.UTF_8)
    // Step 2: Generate publisher-specific stable CLOC
    StableCloc(locId).encode(namespaceGuid, clientId, encClientId, Some(tier))
  }
}
$$;
