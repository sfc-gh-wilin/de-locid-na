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
--   7. THIS FILE  (self-contained — no other provider_tests file needed first)
--
-- GENERATED DATA SCHEMA:
--   IPv4: 10.0.0.0 – 10.9.9.0 (/24 subnets, 100 blocks)
--   IPv6: 2001:DB8:1:1:: – 2001:DB8:1:10:: (/64 subnets, 10 blocks, RFC 3849 documentation prefix)
--   Build date:         2025-01-08
--   Customer event ts:  2025-01-10 (falls within the 2025-01-08 build range)
--   All rows produce valid LOCID_TXCLOC_ENCRYPT / LOCID_STABLE_CLOC output
--   when $base_locid_secret matches the secret registered with LocID Central.
--
-- IMPORTANT — $base_locid_secret:
--   Set $base_locid_secret to the base_locid_secret value from the LocID Central
--   license endpoint (secrets.base_locid_secret — NOT the License Key itself).
--   Format: Base64-URL encoded AES key string with ~ as alternate padding.
--   The same secret must be stored in APP_CONFIG for the Native App proc calls
--   to succeed. Replace the placeholder below with your actual secret.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- ⚠ Replace with base_locid_secret from the LocID Central license response
--   (secrets.base_locid_secret — NOT the License Key).
--   Format: Base64-URL encoded AES key string with ~ as alternate padding.
SET base_locid_secret = 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET';


-- ---------------------------------------------------------------------------
-- STEP 1: Pre-compute the test encrypted_locid value
--         Uses sample LocID from 03_udf_test.sql (EncryptionTest.scala).
--         All LOCID_BUILDS rows (IPv4 and IPv6) share this encrypted value.
--         LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT must exist (run 06_udfs.sql first).
-- ---------------------------------------------------------------------------
SET test_encrypted_locid = (
    SELECT LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT('31F24ZE1W1YX58K2R1139', $base_locid_secret)
);
SELECT $test_encrypted_locid AS test_encrypted_locid;
-- Expected: non-null base64-URL string (exact value depends on $base_locid_secret)


-- ---------------------------------------------------------------------------
-- STEP 2: Test-only table definitions
--         Skip this step if 01_load_test_data.sql has already been run
--         (tables already exist due to CREATE TABLE IF NOT EXISTS).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT (
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
TRUNCATE TABLE LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;


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
-- STEP 5: LOCID_BUILDS — IPv4 rows (100 rows)
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
-- STEP 5b: LOCID_BUILDS — IPv6 rows (10 rows)
--
-- 10 synthetic /64 subnets using the 2001:DB8::/32 documentation prefix (RFC 3849).
-- start_ip_int_hex / end_ip_int_hex are computed via PARSE_IP so that the
-- range-join matching in the encrypt proc works correctly.
-- Customer test IPs (STEP 7b) use the ::1 host of each subnet to guarantee a match.
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.LOCID_BUILDS (
    build_dt, start_ip, end_ip, start_ip_int_hex, end_ip_int_hex,
    tier, locid_country, locid_country_code,
    locid_region, locid_region_code,
    locid_city, locid_city_code, locid_postal_code,
    encrypted_locid, locid_horizontal_accuracy
)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(rowcount => 10))
)
SELECT
    '2025-01-08'::DATE                                                                AS build_dt,
    '2001:DB8:1:' || rn::VARCHAR || '::'                                              AS start_ip,
    '2001:DB8:1:' || rn::VARCHAR || ':FFFF:FFFF:FFFF:FFFF'                            AS end_ip,
    GET_PATH(PARSE_IP('2001:DB8:1:' || rn::VARCHAR || '::', 'INET'), 'hex_ipv6')
                                                                                      AS start_ip_int_hex,
    GET_PATH(PARSE_IP('2001:DB8:1:' || rn::VARCHAR || ':FFFF:FFFF:FFFF:FFFF', 'INET'), 'hex_ipv6')
                                                                                      AS end_ip_int_hex,
    CASE (rn % 4) WHEN 1 THEN 'T0' WHEN 2 THEN 'T1' WHEN 3 THEN 'T2' ELSE 'T3' END  AS tier,
    'United States'                                                                    AS locid_country,
    'US'                                                                               AS locid_country_code,
    CASE (rn % 4)
        WHEN 1 THEN 'California'
        WHEN 2 THEN 'New York'
        WHEN 3 THEN 'Texas'
        ELSE        'Florida'
    END                                                                                AS locid_region,
    CASE (rn % 4) WHEN 1 THEN 'CA' WHEN 2 THEN 'NY' WHEN 3 THEN 'TX' ELSE 'FL' END   AS locid_region_code,
    CASE (rn % 4)
        WHEN 1 THEN 'San Francisco'
        WHEN 2 THEN 'New York City'
        WHEN 3 THEN 'Houston'
        ELSE        'Miami'
    END                                                                                AS locid_city,
    CASE (rn % 4)
        WHEN 1 THEN 'SAN_FRANCISCO'
        WHEN 2 THEN 'NEW_YORK_CITY'
        WHEN 3 THEN 'HOUSTON'
        ELSE        'MIAMI'
    END                                                                                AS locid_city_code,
    CASE (rn % 4)
        WHEN 1 THEN '94102'
        WHEN 2 THEN '10001'
        WHEN 3 THEN '77001'
        ELSE        '33101'
    END                                                                                AS locid_postal_code,
    $test_encrypted_locid                                                              AS encrypted_locid,
    CASE (rn % 4) WHEN 1 THEN 50 WHEN 2 THEN 100 WHEN 3 THEN 200 ELSE 500 END        AS locid_horizontal_accuracy
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
-- STEP 7: CUSTOMER_TEST_INPUT — IPv4 rows (100 rows)
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
INSERT INTO LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT (id, ip_address, ts)
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
-- STEP 7b: CUSTOMER_TEST_INPUT — IPv6 rows (10 rows)
--
-- One ::1 host per generated /64 subnet, matching the LOCID_BUILDS IPv6 rows
-- inserted in STEP 5b. Timestamps start at 18:00:00 on 2025-01-10 to avoid
-- overlap with IPv4 rows while staying within the same 2025-01-08 build range.
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT (id, ip_address, ts)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(rowcount => 10))
)
SELECT
    'GEN_V6_' || LPAD(rn::VARCHAR, 4, '0')                                    AS id,
    '2001:DB8:1:' || rn::VARCHAR || '::1'                                      AS ip_address,
    DATEADD('minute', rn * 10, '2025-01-10 18:00:00'::TIMESTAMP_NTZ)          AS ts
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 8: CONSUMER_TEST.NA_TEST_INPUT — IPv4 + IPv6 rows (110 rows)
--
-- Simulates the consumer-owned input table.
-- Creates the schema and table inline — no need to run
-- 02_customer_input_sample.sql first.
-- Column names differ from CUSTOMER_TEST_INPUT: row_id, ip_addr, event_ts
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS LOCID_DEV.CONSUMER_TEST
    COMMENT = 'Sandbox consumer simulation — mirrors a customer-owned schema for Native App testing';

CREATE OR REPLACE TABLE LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT (
    row_id      VARCHAR          NOT NULL,
    ip_addr     VARCHAR          NOT NULL,
    event_ts    TIMESTAMP_NTZ(9) NOT NULL
)
COMMENT = 'Sandbox consumer input: 110-row sample (100 IPv4 + 10 IPv6) for Native App Encrypt testing';

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

-- IPv6 consumer input (10 rows) — mirrors CUSTOMER_TEST_INPUT IPv6 rows (STEP 7b)
INSERT INTO LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT (row_id, ip_addr, event_ts)
WITH gen AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(rowcount => 10))
)
SELECT
    'GEN_V6_' || LPAD(rn::VARCHAR, 4, '0')                                    AS row_id,
    '2001:DB8:1:' || rn::VARCHAR || '::1'                                      AS ip_addr,
    DATEADD('minute', rn * 10, '2025-01-10 18:00:00'::TIMESTAMP_NTZ)          AS event_ts
FROM gen;


-- ---------------------------------------------------------------------------
-- STEP 9: Verify row counts
-- ---------------------------------------------------------------------------
SELECT 'LOCID_BUILD_DATES'          AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILD_DATES
UNION ALL
SELECT 'LOCID_BUILDS'               AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILDS
UNION ALL
SELECT 'LOCID_BUILDS_IPV4_EXPLODED' AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED
UNION ALL
SELECT 'CUSTOMER_TEST_INPUT'        AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT
UNION ALL
SELECT 'NA_TEST_INPUT'              AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT
ORDER BY 1;
-- Expected:
--   CUSTOMER_TEST_INPUT          110  (100 IPv4 + 10 IPv6)
--   LOCID_BUILD_DATES              5
--   LOCID_BUILDS                 110  (100 IPv4 + 10 IPv6)
--   LOCID_BUILDS_IPV4_EXPLODED   100  (IPv4 only)
--   NA_TEST_INPUT                110  (100 IPv4 + 10 IPv6)

-- Spot-check IPv4: verify all 100 IPv4 IPs match LOCID_BUILDS_IPV4_EXPLODED
SELECT COUNT(*) AS matched_ipv4
FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT c
JOIN LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED e ON e.ip_address = c.ip_address;
-- Expected: 100

-- Spot-check IPv6: verify all 10 IPv6 IPs fall within a LOCID_BUILDS IPv6 range
SELECT COUNT(*) AS matched_ipv6
FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT c
JOIN LOCID_DEV.STAGING.LOCID_BUILDS lb
  ON lb.start_ip LIKE '%:%'
 AND GET_PATH(PARSE_IP(c.ip_address, 'INET'), 'hex_ipv6')
       BETWEEN lb.start_ip_int_hex AND lb.end_ip_int_hex
WHERE c.ip_address LIKE '%:%';
-- Expected: 10
