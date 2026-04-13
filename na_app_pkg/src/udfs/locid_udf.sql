-- =============================================================================
-- src/udfs/locid_udf.sql
-- LocID Native App — Scala UDF Definitions
--
-- This file is uploaded to @APP_SCHEMA.APP_STAGE/src/udfs/ and executed
-- from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/udfs/locid_udf.sql';
--
-- Prerequisites:
--   - encode-lib JAR uploaded to @APP_SCHEMA.APP_STAGE/lib/ (Java 11 build)
--   - ⚠ BLOCKED until DE recompiles JAR with -release 11 (Java 11 target)
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
--   PRODUCTION: replace with Base64.getUrlDecoder.decode(centralSecret) → 16 bytes (AES-128).
--   Confirm correct key size with DE before production deploy.
--
-- JAR: encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar  (Scala 2.12)
-- =============================================================================


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT  (admin helper)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_BASE_ENCRYPT(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
HANDLER = 'Handler.encrypt'
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

  def encrypt(locId: String, keyStr: String): String = {
    val enc = BaseLocIdEncryption(toKey(keyStr))
    Base64.getUrlEncoder.encodeToString(enc.encrypt(locId.getBytes(StandardCharsets.UTF_8)))
  }
}
$$;


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT  (admin helper)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
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
-- 3. LOCID_TXCLOC_ENCRYPT  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share, decrypts to base LocID,
--    then encodes as TX_CLOC using EncScheme0.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_TXCLOC_ENCRYPT(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    SCHEME_KEY       VARCHAR,
    TIMESTAMP_SEC    BIGINT,
    CLIENT_ID        INT
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
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
    val baseEnc = BaseLocIdEncryption(toKey(baseLocidKey))
    val locId   = new String(baseEnc.decrypt(Base64.getUrlDecoder.decode(encryptedLocid)),
                             StandardCharsets.UTF_8)
    val scheme  = new EncScheme0(toKey(schemeKey))
    val txCloc  = TxCloc(locId, timestampSec, clientId, GeoContext(), None)
    scheme.encoder.encode(txCloc) match {
      case Right(result) => result
      case Left(err)     => throw new RuntimeException(s"TX_CLOC encode failed: ${err.getMessage}")
    }
  }
}
$$;


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT  (production)
--    Decodes a TX_CLOC string back to its component fields.
--    Returns VARCHAR (JSON): { "location_id": "...", "timestamp": ..., "enc_client_id": ... }
--    Use PARSE_JSON() in the calling stored procedure to access individual fields.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
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
        val locId = cloc.locationId.replace("\\", "\\\\").replace("\"", "\\\"")
        s"""{"location_id":"$locId","timestamp":${cloc.timestamp},"enc_client_id":${cloc.encClientId}}"""
      case Left(err) =>
        throw new RuntimeException(s"TX_CLOC decode failed: ${err.getMessage}")
    }
  }
}
$$;


-- =============================================================================
-- 5. LOCID_STABLE_CLOC  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share and generates a
--    publisher-specific Stable CLOC UUID.
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
LANGUAGE SCALA
RUNTIME_VERSION = '2.12'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/lib/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar')
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
               clientId: Int, encClientId: Int, tier: String): String = {
    val baseEnc = BaseLocIdEncryption(toKey(baseLocidKey))
    val locId   = new String(baseEnc.decrypt(Base64.getUrlDecoder.decode(encryptedLocid)),
                             StandardCharsets.UTF_8)
    StableCloc(locId).encode(namespaceGuid, clientId, Some(encClientId), Some(tier))
  }
}
$$;


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
