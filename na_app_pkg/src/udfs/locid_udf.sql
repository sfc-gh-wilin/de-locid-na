-- =============================================================================
-- src/udfs/locid_udf.sql
-- LocID Native App — Scala UDF Definitions
--
-- This file is uploaded to @APP_SCHEMA.APP_STAGE/src/udfs/ and executed
-- from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/udfs/locid_udf.sql';
--
-- Prerequisites:
--   - encode-lib JAR uploaded to @APP_SCHEMA.APP_STAGE/lib/ (Scala 2.13 / Java 17)
--
-- UDFs created:
--   1. LOCID_BASE_ENCRYPT    — admin helper: encrypt raw base LocID string
--   2. LOCID_BASE_DECRYPT    — admin helper: decrypt base64 ciphertext
--   3. LOCID_TXCLOC_ENCRYPT  — production: encrypted_locid (from share) → TX_CLOC
--   4. LOCID_TXCLOC_DECRYPT  — production: TX_CLOC → JSON (location_id, timestamp, enc_client_id)
--   5. LOCID_STABLE_CLOC     — production: encrypted_locid (from share) → STABLE_CLOC UUID
--
-- KEY MAP — secrets used across all UDFs
-- (neither the License Key nor the API Key is passed to UDFs directly)
--
--   base_locid_secret  → APP_CONFIG 'base_locid_secret' (fetched from license endpoint secrets)
--                        Base64-URL encoded, ~ as alternate padding.
--                        Key derivation: secret.replaceAll("~","=") → Base64.getUrlDecoder.decode() → AES key
--                        Used by: BaseLocIdEncryption  (UDFs 1, 2, 3, 5, 6)
--                        Parameter name in UDFs: key_str  (UDF 1/2),  base_locid_key  (UDF 3/5/6)
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
--
-- PERFORMANCE NOTE:
--   Each handler class uses a companion object (Cache) to memoize AES keys and
--   encryption objects by key string. The companion object is JVM-class-level
--   (static equivalent) and persists across rows within the same worker JVM
--   instance. Key derivation (Base64 decode + SecretKeySpec construction) and
--   encryption object allocation therefore happen once per unique key per worker,
--   not once per row.
-- =============================================================================


-- =============================================================================
-- 1. LOCID_BASE_ENCRYPT  (admin helper)
--    Encrypts a raw base LocID string using BaseLocIdEncryption.
--    Returns: base64-URL encoded ciphertext.
--
--    Input:  loc_id  — raw base LocID string  e.g. '31F24ZE1W1YX58K2R1139'
--            key_str — base_locid_secret (Base64-URL encoded AES key, from license endpoint secrets)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_ENCRYPT(
    LOC_ID   VARCHAR,
    KEY_STR  VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.encrypt'
AS $$
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  // Cache BaseLocIdEncryption by key string — persists across rows in the same worker JVM
  object Cache {
    private val encs = new java.util.concurrent.ConcurrentHashMap[String, BaseLocIdEncryption]()
    def enc(k: String): BaseLocIdEncryption = encs.computeIfAbsent(k, s => {
      val b = Base64.getUrlDecoder.decode(s.replaceAll("~", "="))
      BaseLocIdEncryption(new SecretKeySpec(b, "AES"))
    })
  }

  class Handler {
    def encrypt(locId: String, keyStr: String): String = {
      val enc = Cache.enc(keyStr)
      Base64.getUrlEncoder.encodeToString(enc.encrypt(locId.getBytes(StandardCharsets.UTF_8)))
    }
  }
$$;


-- =============================================================================
-- 2. LOCID_BASE_DECRYPT  (admin helper)
--    Decrypts a base64-URL encoded ciphertext back to the raw base LocID string.
--
--    Input:  encrypted_loc_id — base64-URL encoded ciphertext (output of LOCID_BASE_ENCRYPT)
--            key_str          — base_locid_secret (same key used to encrypt)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_BASE_DECRYPT(
    ENCRYPTED_LOC_ID  VARCHAR,
    KEY_STR           VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.decrypt'
AS $$
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  // Cache BaseLocIdEncryption by key string — persists across rows in the same worker JVM
  object Cache {
    private val encs = new java.util.concurrent.ConcurrentHashMap[String, BaseLocIdEncryption]()
    def enc(k: String): BaseLocIdEncryption = encs.computeIfAbsent(k, s => {
      val b = Base64.getUrlDecoder.decode(s.replaceAll("~", "="))
      BaseLocIdEncryption(new SecretKeySpec(b, "AES"))
    })
  }

  class Handler {
    def decrypt(encryptedLocId: String, keyStr: String): String = {
      val enc     = Cache.enc(keyStr)
      val decoded = Base64.getUrlDecoder.decode(encryptedLocId)
      new String(enc.decrypt(decoded), StandardCharsets.UTF_8)
    }
  }
$$;


-- =============================================================================
-- 3. LOCID_TXCLOC_ENCRYPT  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share, decrypts to base LocID,
--    then encodes as TX_CLOC using EncScheme0.
--
--    Workflow:
--      1. Decrypt ENCRYPTED_LOCID using BASE_LOCID_KEY → raw base LocID string
--      2. Build TxCloc(locId, timestampSec, clientId, GeoContext())
--      3. Encode via EncScheme0 using SCHEME_KEY → TX_CLOC string
--
--    Input:  encrypted_locid  — base64-URL encrypted locid from LOCID_BUILDS.encrypted_locid
--            base_locid_key   — key used to encrypt the base locid at ingest time
--            scheme_key       — EncScheme0 key (may differ from base_locid_key in production)
--            timestamp_sec    — Unix timestamp in seconds (BIGINT → Long)
--            client_id        — encClientId for TxCloc (INT → Int)
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_ENCRYPT(
    ENCRYPTED_LOCID  VARCHAR,
    BASE_LOCID_KEY   VARCHAR,
    SCHEME_KEY       VARCHAR,
    TIMESTAMP_SEC    BIGINT,
    CLIENT_ID        INT
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.txClocEncrypt'
AS $$
  import io.ol.locationid.TxCloc
  import io.ol.locationid.GeoContext
  import io.ol.locationid.encoding.EncScheme0
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  // Cache BaseLocIdEncryption (by base key) and EncScheme0 (by scheme key) separately —
  // both are constant across all rows in a query and expensive to construct.
  object Cache {
    private def toKey(s: String): SecretKeySpec = {
      val b = Base64.getUrlDecoder.decode(s.replaceAll("~", "="))
      new SecretKeySpec(b, "AES")
    }
    private val baseEncs = new java.util.concurrent.ConcurrentHashMap[String, BaseLocIdEncryption]()
    private val schemes  = new java.util.concurrent.ConcurrentHashMap[String, EncScheme0]()
    def baseEnc(k: String): BaseLocIdEncryption = baseEncs.computeIfAbsent(k, s => BaseLocIdEncryption(toKey(s)))
    def scheme(k: String):  EncScheme0          = schemes.computeIfAbsent(k,  s => new EncScheme0(toKey(s)))
  }

  class Handler {
    def txClocEncrypt(encryptedLocid: String, baseLocidKey: String, schemeKey: String,
                      timestampSec: Long, clientId: Int): String = {
      // 1. Decrypt encrypted_locid → raw base LocID
      val decoded   = Base64.getUrlDecoder.decode(encryptedLocid)
      val baseLocId = new String(Cache.baseEnc(baseLocidKey).decrypt(decoded), StandardCharsets.UTF_8)
      // 2. Build TxCloc and encode via EncScheme0
      val txCloc = TxCloc(baseLocId, timestampSec, clientId, GeoContext())
      Cache.scheme(schemeKey).encoder.encode(txCloc).fold(t => throw t, identity)
    }
  }
$$;


-- =============================================================================
-- 4. LOCID_TXCLOC_DECRYPT  (production)
--    Decodes a TX_CLOC string back to its component fields.
--
--    Returns: VARCHAR — JSON string:
--      { "location_id": "...", "timestamp": 1234567890, "enc_client_id": 1 }
--    Use PARSE_JSON() in SQL to access individual fields.
--
--    Input:  tx_cloc    — TX_CLOC string (output of LOCID_TXCLOC_ENCRYPT)
--            scheme_key — same EncScheme0 key used to encrypt
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.txClocDecrypt'
AS $$
  import io.ol.locationid.encoding.EncScheme0
  import javax.crypto.spec.SecretKeySpec

  // Cache EncScheme0 by key string — constant for all rows in a query
  object Cache {
    private val schemes = new java.util.concurrent.ConcurrentHashMap[String, EncScheme0]()
    def scheme(k: String): EncScheme0 = schemes.computeIfAbsent(k, s => {
      val b = java.util.Base64.getUrlDecoder.decode(s.replaceAll("~", "="))
      new EncScheme0(new SecretKeySpec(b, "AES"))
    })
  }

  class Handler {
    def txClocDecrypt(txCloc: String, schemeKey: String): String = {
      Cache.scheme(schemeKey).encoder.decode(txCloc).fold(
        t => throw t,
        d => s"""{"location_id":"${d.locationId}","timestamp":${d.timestamp},"enc_client_id":${d.encClientId}}"""
      )
    }
  }
$$;


-- =============================================================================
-- 5. LOCID_STABLE_CLOC  (production)
--    Takes encrypted_locid from the LOCID_BUILDS share and generates a
--    publisher-specific Stable CLOC UUID.
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
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_STABLE_CLOC(
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
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.stableCloc'
AS $$
  import io.ol.locationid.StableCloc
  import io.ol.locationid.encoding.encryption.BaseLocIdEncryption
  import java.util.Base64
  import java.nio.charset.StandardCharsets
  import javax.crypto.spec.SecretKeySpec

  // Cache BaseLocIdEncryption by key string — constant for all rows in a query
  object Cache {
    private val encs = new java.util.concurrent.ConcurrentHashMap[String, BaseLocIdEncryption]()
    def enc(k: String): BaseLocIdEncryption = encs.computeIfAbsent(k, s => {
      val b = Base64.getUrlDecoder.decode(s.replaceAll("~", "="))
      BaseLocIdEncryption(new SecretKeySpec(b, "AES"))
    })
  }

  class Handler {
    def stableCloc(encryptedLocid: String, baseLocidKey: String, namespaceGuid: String,
                   clientId: Int, encClientId: Int, tier: String): String = {
      // 1. Decrypt encrypted_locid → raw base LocID
      val decoded   = Base64.getUrlDecoder.decode(encryptedLocid)
      val baseLocId = new String(Cache.enc(baseLocidKey).decrypt(decoded), StandardCharsets.UTF_8)
      // 2. Generate stable CLOC
      StableCloc(baseLocId).encode(namespaceGuid, clientId, encClientId, Some(tier))
    }
  }
$$;


-- =============================================================================
-- 6. LOCID_STABLE_CLOC_FROM_PLAIN  (decrypt path)
--    Generates a STABLE_CLOC from a plaintext base LocID string.
--    Used in the Decrypt stored procedure, where LOCID_TXCLOC_DECRYPT returns
--    the raw location_id directly — no base-encryption round-trip needed.
--
--    For the encrypt path, use LOCID_STABLE_CLOC (takes encrypted_locid).
--
--    STABLE_CLOC semantics (from developer-integration-guide.md):
--      - encClientId: client that created the original TX_CLOC
--      - decClientId: client decrypting it (same as encClientId on the encrypt path)
--      - tier: "T0" (rooftop) or "T1" (low accuracy) — prepended to the UUID
--
--    NOTE: Tier is not embedded in TX_CLOC. The decrypt stored procedure
--    defaults to 'T0'. A future version may allow the caller to supply tier.
--
--    Input:  base_loc_id    — plaintext base LocID from LOCID_TXCLOC_DECRYPT result
--            namespace_guid — customer namespace GUID (from APP_CONFIG)
--            dec_client_id  — decrypting client ID  (license.client_id)
--            enc_client_id  — encrypting client ID  (from TX_CLOC decode)
--            tier           — "T0" or "T1"
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN(
    BASE_LOC_ID    VARCHAR,
    NAMESPACE_GUID VARCHAR,
    DEC_CLIENT_ID  INT,
    ENC_CLIENT_ID  INT,
    TIER           VARCHAR
)
RETURNS VARCHAR
LANGUAGE SCALA
RUNTIME_VERSION = '2.13'
IMPORTS = ('/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar')
HANDLER = 'Handler.stableClocFromPlain'
AS $$
  import io.ol.locationid.StableCloc

  // No key derivation in this UDF — StableCloc is built from the plaintext locId
  // which varies per row, so nothing to cache here.
  class Handler {
    def stableClocFromPlain(baseLocId: String, namespaceGuid: String,
                            decClientId: Int, encClientId: Int, tier: String): String =
      StableCloc(baseLocId).encode(namespaceGuid, decClientId, encClientId, Some(tier))
  }
$$;


-- NOTE: Object-level grants are not supported in versioned schemas.
-- USAGE on APP_CODE schema is granted to APP_ADMIN in setup.sql.
-- These UDFs are called from owner's-rights stored procs (LOCID_ENCRYPT / LOCID_DECRYPT)
-- and do not require direct application role grants.
