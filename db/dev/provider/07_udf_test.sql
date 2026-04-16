-- =============================================================================
-- 07_udf_test.sql
-- LocID Dev: Round-trip validation tests for encode-lib UDFs
--
-- Run order: after 06_udfs.sql (all UDFs must exist).
-- Run step by step — each SET feeds into subsequent tests.
--
-- Test coverage:
--   Test 1  LOCID_BASE_ENCRYPT / LOCID_BASE_DECRYPT   round-trip
--   Test 2  LOCID_TXCLOC_ENCRYPT                       produces TX_CLOC
--   Test 3  LOCID_TXCLOC_DECRYPT                       round-trip assertion
--   Test 4  LOCID_STABLE_CLOC                           produces UUID
--   Test 5  Summary                                     all tests in one row
--
-- Sample values are taken from the developer integration guide and local
-- test files (EncryptionTest.scala, EncryptionTestWithTS.scala).
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;


-- ---------------------------------------------------------------------------
-- SETUP: Session variables
-- ---------------------------------------------------------------------------

-- ⚠ Replace with your actual dev license key before running.
--   Format example: '1569-XXXX-XXXX-XXXX-XXXX-XXXX'
SET dev_key = 'REPLACE_WITH_YOUR_DEV_LICENSE_KEY';

-- Sample LocIDs from test files and integration guide
SET locid_1 = '31F24ZE1W1YX58K2R1139';         -- EncryptionTest.scala
SET locid_2 = '4SV5XGYRWPT8AS6M04A8SMGVBZ';    -- EncryptionTestWithTS.scala / integration guide

-- Namespace GUID from integration guide examples
SET namespace_guid = 'ffffffff111122223333444444444444';


-- ---------------------------------------------------------------------------
-- PREREQUISITE: Verify JAR is on stage
-- ---------------------------------------------------------------------------
-- Expected: one row for encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
-- If this returns zero rows, run the PUT command in 05_stage_setup.sql first.
LIST @LOCID_DEV.STAGING.LOCID_STAGE;


-- ===========================================================================
-- TEST 1: LOCID_BASE_ENCRYPT / LOCID_BASE_DECRYPT — round-trip
--
-- Mirrors EncryptionTest.scala behaviour.
-- Expected:
--   encrypted_locid_1  →  non-null base64-URL string
--   decrypted_locid_1  →  '31F24ZE1W1YX58K2R1139'  (= $locid_1)
--   test_result        →  'PASS'
-- ===========================================================================

-- 1a. Encrypt
SET encrypted_locid_1 = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT($locid_1, $dev_key)
);
SELECT $encrypted_locid_1 AS encrypted_locid_1;
-- Input: 31F24ZE1W1YX58K2R1139
-- Output: VvOPJrPpJm6CwNEXCg_91DmS9ue7TUdPJQ0sbyFvfmlVTMPJliA63ZSnFlWZqhTWrQ==

-- 1b. Decrypt
SET decrypted_locid_1 = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_DECRYPT($encrypted_locid_1, $dev_key)
);
SELECT $decrypted_locid_1 AS decrypted_locid_1;
-- Input: VvOPJrPpJm6CwNEXCg_91DmS9ue7TUdPJQ0sbyFvfmlVTMPJliA63ZSnFlWZqhTWrQ==
-- Output: 31F24ZE1W1YX58K2R1139

-- 1c. Assert
SELECT
    $locid_1             AS original_locid,
    $decrypted_locid_1   AS decrypted_locid,
    IFF($decrypted_locid_1 = $locid_1, 'PASS', 'FAIL') AS test_base_encrypt_decrypt;
-- PASS

-- ===========================================================================
-- TEST 2: LOCID_TXCLOC_ENCRYPT — produces TX_CLOC
--
-- Mirrors EncryptionTestWithTS.scala behaviour.
-- We first simulate what is stored in LOCID_BUILDS by encrypting locid_2,
-- then pass that encrypted value to LOCID_TXCLOC_ENCRYPT.
--
-- Expected:
--   encrypted_locid_2  →  non-null base64-URL string (simulates DB value)
--   tx_cloc            →  non-null TX_CLOC string (e.g. "b1y1t1X...")
-- ===========================================================================

-- 2a. Simulate LOCID_BUILDS.encrypted_locid for locid_2
SET encrypted_locid_2 = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT($locid_2, $dev_key)
);
SELECT $encrypted_locid_2 AS encrypted_locid_2;
-- Input: 4SV5XGYRWPT8AS6M04A8SMGVBZ
-- Output: 1YOzH76UctsEdsxwOM7l2BgThtqumS69TBfyhPFcW2lc4fACeLHzZ2r2GucaJhHVYbkfD9CP

-- 2b. Capture current Unix timestamp (seconds)
SET ts_now = (
    SELECT DATE_PART('epoch_second', CURRENT_TIMESTAMP::TIMESTAMP_NTZ)::BIGINT
);
SELECT $ts_now AS timestamp_sec;
-- 1776320434

-- 2c. Encrypt → TX_CLOC
--     Using same key for base_locid_key and scheme_key (valid for dev testing)
--     client_id = 1 (matches integration guide examples)
SET tx_cloc = (
    SELECT LOCID_DEV.STAGING.LOCID_TXCLOC_ENCRYPT(
        $encrypted_locid_2,  -- encrypted_locid from DB
        $dev_key,            -- base_locid_key
        $dev_key,            -- scheme_key
        $ts_now,             -- timestamp_sec
        1                    -- client_id
    )
);
SELECT $tx_cloc AS tx_cloc;
-- YjRFjkdgbrRlZB0F3D5078a8dfjeVFCLa-a0ACVcW4hJn3GusjsfLmgISrfYNo2a2x0438-3GidvO4wh7t7UoOZ7srQ~.0

-- ✓ RESOLVED (2026-04-15): Switched to LANGUAGE SCALA RUNTIME_VERSION = '2.13' with inline
--   handlers. SnowflakeHandler wrapper from DE is no longer required.

-- ===========================================================================
-- TEST 3: LOCID_TXCLOC_DECRYPT — round-trip assertion
--
-- Expected:
--   decoded_json   →  JSON string with location_id, timestamp, enc_client_id
--   location_id    →  '4SV5XGYRWPT8AS6M04A8SMGVBZ'  (= $locid_2)
--   enc_client_id  →  1
--   test_result    →  'PASS'
-- ===========================================================================

-- 3a. Decrypt TX_CLOC
SET decoded_json = (
    SELECT LOCID_DEV.STAGING.LOCID_TXCLOC_DECRYPT($tx_cloc, $dev_key)
);
SELECT $decoded_json AS decoded_json;
-- {"location_id":"4SV5XGYRWPT8AS6M04A8SMGVBZ","timestamp":1776320434,"enc_client_id":1}

-- 3b. Parse JSON and assert
SELECT
    PARSE_JSON($decoded_json):location_id::VARCHAR   AS location_id,
    PARSE_JSON($decoded_json):timestamp::BIGINT      AS timestamp_sec,
    PARSE_JSON($decoded_json):enc_client_id::INT     AS enc_client_id,
    $locid_2                                         AS expected_location_id,
    IFF(
        PARSE_JSON($decoded_json):location_id::VARCHAR = $locid_2,
        'PASS', 'FAIL'
    ) AS test_txcloc_roundtrip;
-- PASS

-- ===========================================================================
-- TEST 4: LOCID_STABLE_CLOC — produces UUID
--
-- Uses same encrypted_locid_2 from Test 2.
-- Expected:
--   stable_cloc  →  UUID string e.g. '463cd5b0-89e6-52b2-885e-baff5124f992'
--                   (exact value depends on key; will differ from guide examples
--                    which used a different key version)
-- ===========================================================================

SET stable_cloc = (
    SELECT LOCID_DEV.STAGING.LOCID_STABLE_CLOC(
        $encrypted_locid_2,  -- encrypted_locid from DB
        $dev_key,            -- base_locid_key
        $namespace_guid,     -- namespace GUID (hex, no dashes)
        1,                   -- client_id (consumer)
        1,                   -- enc_client_id (publisher)
        'T0'                 -- tier: 'T0' = rooftop, 'T1' = low accuracy
    )
);
SELECT $stable_cloc AS stable_cloc;
-- T0-81751ea7-fe52-5663-b339-18f2ace84623

-- ===========================================================================
-- TEST 5: Summary — all tests in one row
--
-- All columns should show 'PASS'.
-- ===========================================================================
SELECT
    -- Test 1: BASE_ENCRYPT / BASE_DECRYPT round-trip
    IFF(
        $decrypted_locid_1 = $locid_1,
        'PASS', 'FAIL'
    ) AS test_1_base_encrypt_decrypt,

    -- Test 2+3: TX_CLOC encode / decode round-trip
    IFF(
        PARSE_JSON($decoded_json):location_id::VARCHAR = $locid_2,
        'PASS', 'FAIL'
    ) AS test_2_3_txcloc_roundtrip,

    -- Test 4: STABLE_CLOC is non-null and non-empty
    IFF(
        $stable_cloc IS NOT NULL AND LENGTH($stable_cloc) > 0,
        'PASS', 'FAIL'
    ) AS test_4_stable_cloc,

    -- Informational: captured values
    $tx_cloc     AS tx_cloc,
    $stable_cloc AS stable_cloc;
-- tx_cloc: YjRFjkdgbrRlZB0F3D5078a8dfjeVFCLa-a0ACVcW4hJn3GusjsfLmgISrfYNo2a2x0438-3GidvO4wh7t7UoOZ7srQ~.0
-- stable_cloc: T0-81751ea7-fe52-5663-b339-18f2ace84623
