-- =============================================================================
-- 00_generate_test_data.sql
-- LocID Dev: Synthetic test data generator for sandbox testing
--
-- ALTERNATIVE TO: 01_load_test_data.sql (CSV loader)
--   Use this file when you do not want to load real client CSV data.
--   Generates deterministic, fake data using Snowflake GENERATOR().
--
-- Run order:
--   1. db/dev/provider/01_setup.sql      (LOCID_DEV database + STAGING schema)
--   2. db/dev/provider/02_build_dates.sql
--   3. db/dev/provider/03_locid_builds.sql
--   4. db/dev/provider/04_locid_builds_ipv4_exploded.sql
--   5. db/dev/provider/05_stage_setup.sql
--   6. db/dev/provider/06_udfs.sql       (required for LOCID_BASE_ENCRYPT below)
--   7. db/dev/provider_tests/01_load_test_data.sql  (STEP 3 only: CREATE TABLE)
--      OR run the CREATE TABLE statements in this file's STEP 2.
--   8. db/dev/provider_tests/02_customer_input_sample.sql
--      (creates LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT — needed for STEP 7)
--   9. THIS FILE
--
-- GENERATED DATA SCHEMA:
--   IPv4 address space: 10.0.0.0 – 10.9.9.0 (/24 subnets, 100 blocks)
--   Build date:         2025-01-08
--   Customer event ts:  2025-01-10 (falls within the 2025-01-08 build range)
--   All rows produce valid LOCID_TXCLOC_ENCRYPT / LOCID_STABLE_CLOC output
--   when $dev_key matches the key registered with LocID Central.
--
-- IMPORTANT — $dev_key:
--   Set $dev_key to your actual dev license key BEFORE running this file.
--   The same key must be used in APP_CONFIG for the Native App proc calls
--   to succeed. Replace the placeholder below with your actual key.
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- ⚠ Replace with your actual dev license key (same key used in 03_udf_test.sql)
SET dev_key = 'REPLACE_WITH_YOUR_DEV_LICENSE_KEY';


-- ---------------------------------------------------------------------------
-- STEP 1: Pre-compute the test encrypted_locid value
--         Uses sample LocID from 03_udf_test.sql (EncryptionTest.scala).
--         All 100 generated LOCID_BUILDS rows share this encrypted value.
--         LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT must exist (run 06_udfs.sql first).
-- ---------------------------------------------------------------------------
SET test_encrypted_locid = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT('31F24ZE1W1YX58K2R1139', $dev_key)
);
SELECT $test_encrypted_locid AS test_encrypted_locid;
-- Expected: non-null base64-URL string (exact value depends on $dev_key)


-- ---------------------------------------------------------------------------
-- STEP 2: Test-only table definitions
--         Skip this step if 01_load_test_data.sql has already been run
--         (tables already exist due to CREATE TABLE IF NOT EXISTS).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT_2K (
    id          VARCHAR(16777216),
    ip_address  VARCHAR(16777216),
    ts          TIMESTAMP_NTZ(9)
);

CREATE TABLE IF NOT EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT_2K (
    id                        VARCHAR(16777216),
    ip_address                VARCHAR(16777216),
    ts                        TIMESTAMP_NTZ(9),
    tier                      VARCHAR(16777216),
    locid_country             VARCHAR(16777216),
    locid_country_code        VARCHAR(16777216),
    locid_region              VARCHAR(16777216),
    locid_region_code         VARCHAR(16777216),
    locid_city                VARCHAR(16777216),
    locid_city_code           VARCHAR(16777216),
    locid_postal_code         VARCHAR(16777216),
    encrypted_locid           VARCHAR(16777216),
    locid_horizontal_accuracy VARCHAR(16777216),
    run_dt                    DATE
);


-- ---------------------------------------------------------------------------
-- STEP 3: Truncate all target tables (idempotent)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILD_DATES;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED;
TRUNCATE TABLE LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT_2K;


-- ---------------------------------------------------------------------------
-- STEP 4: LOCID_BUILD_DATES (5 rows)
--
-- Each entry defines the date range during which a given weekly build applies.
-- A customer event timestamped 2025-01-10 falls in the 2025-01-08 build range.
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.LOCID_BUILD_DATES (build_dt, start_dt, end_dt)
VALUES
    ('2025-01-01'::DATE, '2025-01-01'::DATE, '2025-01-07'::DATE),
    ('2025-01-08'::DATE, '2025-01-08'::DATE, '2025-01-14'::DATE),
    ('2025-01-15'::DATE, '2025-01-15'::DATE, '2025-01-21'::DATE),
    ('2025-01-22'::DATE, '2025-01-22'::DATE, '2025-01-28'::DATE),
    ('2025-01-29'::DATE, '2025-01-29'::DATE, '2025-02-04'::DATE);


-- ---------------------------------------------------------------------------
-- STEP 5: LOCID_BUILDS (100 rows)
--
-- Generated IPv4 ranges: /24 subnets in 10.0.0.0/8
--   rn 0-9:   10.0.0.0/24  →  10.9.0.0/24
--   rn 10-19: 10.0.1.0/24  →  10.9.1.0/24
--   ...
--   rn 90-99: 10.0.9.0/24  →  10.9.9.0/24
--
-- All rows use build_dt = 2025-01-08 (matches the LOCID_BUILD_DATES entry above).
-- start_ip_int_hex / end_ip_int_hex are NULL — not used for IPv4 range matching.
-- locid_horizontal_accuracy rotates through four representative values (meters).
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.LOCID_BUILDS (
    build_dt, start_ip, end_ip, start_ip_int_hex, end_ip_int_hex,
    tier, locid_country, locid_country_code,
    locid_region, locid_region_code,
    locid_city, locid_city_code, locid_postal_code,
    encrypted_locid, locid_horizontal_accuracy
)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
    FROM TABLE(GENERATOR(rowcount => 100))
)
SELECT
    '2025-01-08'::DATE AS build_dt,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.0'   AS start_ip,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.255' AS end_ip,
    NULL AS start_ip_int_hex,
    NULL AS end_ip_int_hex,
    CASE (rn % 4) WHEN 0 THEN 'T0' WHEN 1 THEN 'T1' WHEN 2 THEN 'T2' ELSE 'T3' END
                                                         AS tier,
    'United States'                                      AS locid_country,
    'US'                                                 AS locid_country_code,
    CASE (rn % 4)
        WHEN 0 THEN 'California'
        WHEN 1 THEN 'New York'
        WHEN 2 THEN 'Texas'
        ELSE        'Florida'
    END                                                  AS locid_region,
    CASE (rn % 4) WHEN 0 THEN 'CA' WHEN 1 THEN 'NY' WHEN 2 THEN 'TX' ELSE 'FL' END
                                                         AS locid_region_code,
    CASE (rn % 4)
        WHEN 0 THEN 'San Francisco'
        WHEN 1 THEN 'New York City'
        WHEN 2 THEN 'Houston'
        ELSE        'Miami'
    END                                                  AS locid_city,
    CASE (rn % 4)
        WHEN 0 THEN 'SAN_FRANCISCO'
        WHEN 1 THEN 'NEW_YORK_CITY'
        WHEN 2 THEN 'HOUSTON'
        ELSE        'MIAMI'
    END                                                  AS locid_city_code,
    CASE (rn % 4)
        WHEN 0 THEN '94102'
        WHEN 1 THEN '10001'
        WHEN 2 THEN '77001'
        ELSE        '33101'
    END                                                  AS locid_postal_code,
    $test_encrypted_locid                                AS encrypted_locid,
    CASE (rn % 4) WHEN 0 THEN 50 WHEN 1 THEN 100 WHEN 2 THEN 200 ELSE 500 END
                                                         AS locid_horizontal_accuracy
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 6: LOCID_BUILDS_IPV4_EXPLODED (100 rows)
--
-- One row per /24 subnet, representing the .1 host address.
-- The equi-join in LOCID_ENCRYPT matches customer ip_address → ex.ip_address,
-- then back to LOCID_BUILDS on (build_dt, start_ip, end_ip).
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED (
    build_dt, ip_address, start_ip, end_ip
)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
    FROM TABLE(GENERATOR(rowcount => 100))
)
SELECT
    '2025-01-08'::DATE AS build_dt,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.1'   AS ip_address,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.0'   AS start_ip,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.255' AS end_ip
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 7: CUSTOMER_TEST_INPUT_2K (100 rows)
--
-- Each row uses the .1 host from a generated /24 subnet so that it matches
-- exactly one LOCID_BUILDS_IPV4_EXPLODED entry (and therefore one LOCID_BUILDS row).
--
-- Timestamps: 2025-01-10 08:00:00 + (rn × 10 minutes)
--   Date 2025-01-10 falls within build_dt 2025-01-08 range (2025-01-08 → 2025-01-14).
--   Timestamps span ~16.5 hours — all on 2025-01-10 for clarity.
--
-- For the Native App Encrypt proc, select timestamp format: 'datetime' (not epoch_ms).
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT_2K (id, ip_address, ts)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
    FROM TABLE(GENERATOR(rowcount => 100))
)
SELECT
    'GEN_' || LPAD(rn::VARCHAR, 4, '0')                                       AS id,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.1'    AS ip_address,
    DATEADD('minute', rn * 10, '2025-01-10 08:00:00'::TIMESTAMP_NTZ)         AS ts
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 8: CONSUMER_TEST.NA_TEST_INPUT (100 rows)
--
-- Mirrors CUSTOMER_TEST_INPUT_2K in the simulated consumer schema.
-- Requires 02_customer_input_sample.sql to have been run first
-- (LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT must exist).
-- Column names differ: row_id, ip_addr, event_ts  (see 02_customer_input_sample.sql)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT;

INSERT INTO LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT (row_id, ip_addr, event_ts)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS rn
    FROM TABLE(GENERATOR(rowcount => 100))
)
SELECT
    'GEN_' || LPAD(rn::VARCHAR, 4, '0')                                       AS row_id,
    '10.' || (rn % 10)::VARCHAR || '.' || (rn / 10 % 10)::VARCHAR || '.1'    AS ip_addr,
    DATEADD('minute', rn * 10, '2025-01-10 08:00:00'::TIMESTAMP_NTZ)         AS event_ts
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 9: Verify row counts
-- ---------------------------------------------------------------------------
SELECT 'LOCID_BUILD_DATES'          AS tbl, COUNT(*) AS rows FROM LOCID_DEV.STAGING.LOCID_BUILD_DATES
UNION ALL
SELECT 'LOCID_BUILDS'               AS tbl, COUNT(*) AS rows FROM LOCID_DEV.STAGING.LOCID_BUILDS
UNION ALL
SELECT 'LOCID_BUILDS_IPV4_EXPLODED' AS tbl, COUNT(*) AS rows FROM LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED
UNION ALL
SELECT 'CUSTOMER_TEST_INPUT_2K'     AS tbl, COUNT(*) AS rows FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT_2K
UNION ALL
SELECT 'NA_TEST_INPUT'              AS tbl, COUNT(*) AS rows FROM LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT
ORDER BY 1;
-- Expected:
--   CUSTOMER_TEST_INPUT_2K       100
--   LOCID_BUILD_DATES              5
--   LOCID_BUILDS                 100
--   LOCID_BUILDS_IPV4_EXPLODED   100
--   NA_TEST_INPUT                100

-- Spot-check: verify 10 generated IPs match between LOCID_BUILDS_IPV4_EXPLODED
--             and CUSTOMER_TEST_INPUT_2K (should return 100 rows)
SELECT COUNT(*) AS matched_ips
FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT_2K c
JOIN LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED e ON e.ip_address = c.ip_address;
-- Expected: 100
