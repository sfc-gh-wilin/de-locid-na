-- =============================================================================
-- 08_cross_compat_test.sql
-- LocID Dev: Cross-compatibility validation test
--   Based on note from David Moser (DE), 2026-04-15
--
-- PURPOSE:
--   Verify that UDF output is cross-compatible with the production LocID API.
--   Two test paths; both must produce the same expected STABLE_CLOC:
--     T1-56c17ed5-69ac-5393-9327-aadc4e255e3f
--
--   Test 1 — Encrypt path:
--     Look up 8.8.8.8 in LOCID_BUILDS → LOCID_TXCLOC_ENCRYPT → LOCID_STABLE_CLOC
--     LOCID_BUILDS sandbox data — Test 1 requires 8.8.8.8 to be present in the sandbox LOCID_BUILDS.
--       This is listed as an open item (David to confirm V6 data).
--       If the IP lookup returns NULL, Test 1 will fail at step 1a.
--
--   Test 2 — Decrypt path:
--     Decode known tx_cloc from DE → LOCID_TXCLOC_DECRYPT → LOCID_STABLE_CLOC
--
-- ⚠ PRODUCTION KEY DERIVATION REQUIRED:
--   Current 06_udfs.sql uses TEST-MODE key derivation (UTF-8 padded, AES-256).
--   Cross-compatibility with the production API REQUIRES production keys.
--   Before running this test:
--     1. Update toKey() in all 06_udfs.sql handlers to use production derivation:
--           Base64.getUrlDecoder.decode(key.replaceAll("~","="))
--     2. Re-run 06_udfs.sql to recreate UDFs with production key derivation.
--     3. Populate $base_locid_key, $scheme_key, $namespace_guid, $client_id below.
--
-- PRODUCTION KEYS — retrieve via:
--   GET https://central.locid.com/api/0/location_id/license/77cb3a02-...
--   → secrets.base_locid     → $base_locid_key  (Base64 URL, ~ as padding char)
--   → secrets.enc_scheme_0   → $scheme_key      (Base64 URL, ~ as padding char)
--   → access[0].namespace_guid → $namespace_guid
--   → access[0].client_id      → $client_id
--
-- CROSS-COMPATIBILITY (manual, outside Snowflake):
--   Encrypt:  curl -H 'x-api-key: ee92f07a-...' \
--                  'https://apie.locid.com/encrypt?ip=8.8.8.8'
--   Decrypt:  curl -H 'x-api-key: ee92f07a-...' \
--                  'https://apid.locid.com/decrypt?tx_cloc=<tx_cloc_from_udf>'
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;


-- ---------------------------------------------------------------------------
-- SETUP: Session variables
-- ---------------------------------------------------------------------------


-- {
--   "api_key": "77cb3a02-...",  <-- **77cb**
--   "api_key_id": 13,
--   "client_id": 1569,
--   "provider_id": 1569,
--   "status": "ACTIVE",
--   "namespace_guid": "d1a6ebc3-c1d1-4a3f-9d91-b7add31bdb71",
--   "allow_encrypt": true,
--   "allow_decrypt": true,
--   "allow_tx": true,
--   "allow_stable": true,
--   "allow_geo_context": true
-- }
SET base_locid_key = '1569-0f...';
SET scheme_key     = '77cb3a02-92...';
SET namespace_guid = 'd1a6ebc3-c1d1-4a3f-9d91-b7add31bdb71';
SET client_id      = 1569;

SET test_ip             = '8.8.8.8';
SET expected_stable     = 'T1-56c17ed5-69ac-5393-9327-aadc4e255e3f';
SET known_tx_cloc = '0PVqVJ8a59_edbqwp--9jMK2dyvbt4IBjJS_Opqlu59_tpYb822LwRBEIiWF3--WplWk3bkkfnOvra3cPSe-3pYqD8AeDoyXrqCRE8U1IegOoOxPn8tIhOt5XWg_mM5VijldrYPNpAM2aQ~~.0';

-- ---------------------------------------------------------------------------
-- PREREQUISITE: Verify JAR is on stage
-- ---------------------------------------------------------------------------
-- Expected: one row for encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
LIST @LOCID_DEV.STAGING.LOCID_STAGE;


-- ===========================================================================
-- TEST 1: Encrypt path — 8.8.8.8 → TX_CLOC → STABLE_CLOC
--
-- Expected: $stable_cloc_1 = T1-56c17ed5-69ac-5393-9327-aadc4e255e3f
-- ===========================================================================

-- 1a. Look up encrypted_locid for 8.8.8.8 from LOCID_BUILDS
--     Uses IPv4 exploded table (equi-join), picks the most recent build.
--     ⚠ If NULL: LOCID_BUILDS does not yet contain data for this IP in sandbox.
SET encrypted_8888 = (
    SELECT lb.encrypted_locid
    FROM   LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED ex
    JOIN   LOCID_DEV.STAGING.LOCID_BUILDS lb
           ON  lb.build_dt = ex.build_dt
           AND lb.start_ip = ex.start_ip
           AND lb.end_ip   = ex.end_ip
    WHERE  ex.ip_address = $test_ip
    ORDER BY lb.build_dt DESC
    LIMIT 1
);
SELECT $encrypted_8888 AS encrypted_locid_for_8888;

-- 1b. Capture current Unix timestamp (seconds)
SET ts_now = (
    SELECT DATE_PART('epoch_second', CURRENT_TIMESTAMP::TIMESTAMP_NTZ)::BIGINT
);

-- 1c. Encrypt → TX_CLOC
--     Publisher-independent: enc_client_id = dec_client_id = $client_id
SET tx_cloc_1 = (
    SELECT LOCID_DEV.STAGING.LOCID_TXCLOC_ENCRYPT(
        $encrypted_8888,  -- encrypted_locid from LOCID_BUILDS
        $base_locid_key,  -- key to decrypt the stored base locid
        $scheme_key,      -- EncScheme0 key
        $ts_now,          -- timestamp_sec
        $client_id        -- encClientId
    )
);
SELECT $tx_cloc_1 AS tx_cloc_from_encrypt;
-- Cross-compat: paste $tx_cloc_1 into the Decrypt curl command to verify via API.

-- 1d. Compute STABLE_CLOC
--     Tier 'T1' is known from the T1- prefix of the expected stable_cloc.
SET stable_cloc_1 = (
    SELECT LOCID_DEV.STAGING.LOCID_STABLE_CLOC(
        $encrypted_8888,  -- encrypted_locid from LOCID_BUILDS
        $base_locid_key,  -- key to decrypt the stored base locid
        $namespace_guid,  -- namespace GUID from LocID Central
        $client_id,       -- dec_client_id (consumer)
        $client_id,       -- enc_client_id (publisher — same for encrypt path)
        'T1'
    )
);
SELECT $stable_cloc_1 AS stable_cloc_from_encrypt;

-- 1e. Assert
SELECT
    $stable_cloc_1  AS stable_cloc,
    $expected_stable AS expected,
    IFF($stable_cloc_1 = $expected_stable, 'PASS', 'FAIL') AS test_1_encrypt_path;


-- ===========================================================================
-- TEST 2: Decrypt path — known tx_cloc from DE → STABLE_CLOC
--
-- tx_cloc: YwQ9ZH5MNvmkwK3cW3unpt-...  (David Moser, 2026-04-15)
-- Expected: $stable_cloc_2 = T1-56c17ed5-69ac-5393-9327-aadc4e255e3f
-- ===========================================================================

-- 2a. Decode known tx_cloc → JSON with location_id, timestamp, enc_client_id
SET decoded_json = (
    SELECT LOCID_DEV.STAGING.LOCID_TXCLOC_DECRYPT($known_tx_cloc, $scheme_key)
);
SELECT
    PARSE_JSON($decoded_json):location_id::VARCHAR AS location_id,
    PARSE_JSON($decoded_json):timestamp::BIGINT    AS timestamp_sec,
    PARSE_JSON($decoded_json):enc_client_id::INT   AS enc_client_id;

-- 2b. Extract enc_client_id from decoded tx_cloc
SET enc_client_id_2 = (
    SELECT PARSE_JSON($decoded_json):enc_client_id::INT
);

-- 2c. Re-encrypt the raw location_id so it can be passed to LOCID_STABLE_CLOC
--     (LOCID_STABLE_CLOC decrypts encrypted_locid → base locid internally;
--      re-encrypting here is a round-trip using the same key — result is consistent)
SET location_id_2 = (
    SELECT PARSE_JSON($decoded_json):location_id::VARCHAR
);
SET encrypted_for_stable = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT($location_id_2, $base_locid_key)
);

-- 2d. Compute STABLE_CLOC from decrypt path
--     dec_client_id = $client_id (our consumer), enc_client_id from decoded tx_cloc
SET stable_cloc_2 = (
    SELECT LOCID_DEV.STAGING.LOCID_STABLE_CLOC(
        $encrypted_for_stable,  -- re-encrypted location_id
        $base_locid_key,
        $namespace_guid,
        $client_id,             -- dec_client_id (consumer = us)
        $enc_client_id_2,       -- enc_client_id (publisher, from decoded tx_cloc)
        'T1'
    )
);
SELECT $stable_cloc_2 AS stable_cloc_from_decrypt;

-- 2e. Assert
SELECT
    $stable_cloc_2   AS stable_cloc,
    $expected_stable  AS expected,
    IFF($stable_cloc_2 = $expected_stable, 'PASS', 'FAIL') AS test_2_decrypt_path;


-- ===========================================================================
-- TEST 3: Summary — both paths in one row
-- ===========================================================================
SELECT
    IFF($stable_cloc_1 = $expected_stable, 'PASS', 'FAIL') AS test_1_encrypt_path,
    IFF($stable_cloc_2 = $expected_stable, 'PASS', 'FAIL') AS test_2_decrypt_path,
    $tx_cloc_1    AS tx_cloc_from_encrypt,
    $stable_cloc_1 AS stable_cloc_1,
    $stable_cloc_2 AS stable_cloc_2;
