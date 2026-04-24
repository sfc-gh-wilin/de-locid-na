-- =============================================================================
-- 01_load_test_data.sql
-- LocID Dev: Load sandbox test data from CSV files
--
-- Run order: after db/dev/provider/01-04 (tables must exist).
-- Run this file before running any Native App tests.
--
-- Loads:
--   LOCID_BUILDS                 10,000 rows  (weekly IP→LocID map, IPv4 + IPv6)
--   LOCID_BUILDS_IPV4_EXPLODED   10,000 rows  (exploded IPv4 equi-join table)
--   LOCID_BUILD_DATES               60 rows   (build calendar, date range lookup)
--   CUSTOMER_TEST_INPUT         100 rows   (sample customer input for testing)
--
-- Source CSVs are in: Coco/db/
-- CUSTOMER_TEST_OUTPUT_2K.csv is reference-only; load not required.
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;


-- ---------------------------------------------------------------------------
-- STEP 1: Internal stage for test CSV files
--         (Separate from LOCID_STAGE which holds the encode-lib JAR)
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE
    DIRECTORY = ( ENABLE = TRUE )
    COMMENT   = 'Internal stage for sandbox test CSV data';


-- ---------------------------------------------------------------------------
-- STEP 2: Upload CSV files to the stage
--         Run these PUT commands in SnowSQL from the repository root.
--         AUTO_COMPRESS=FALSE preserves CSV format.
--
-- PUT file://Coco/db/LOCID_BUILDS.csv
--     @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE
--     AUTO_COMPRESS = FALSE  OVERWRITE = TRUE;
--
-- PUT file://Coco/db/LOCID_BUILDS_IPV4_EXPLODED.csv
--     @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE
--     AUTO_COMPRESS = FALSE  OVERWRITE = TRUE;
--
-- PUT file://Coco/db/LOCID_BUILD_DATES.csv
--     @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE
--     AUTO_COMPRESS = FALSE  OVERWRITE = TRUE;
--
-- PUT file://Coco/db/CUSTOMER_TEST_INPUT.csv
--     @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE
--     AUTO_COMPRESS = FALSE  OVERWRITE = TRUE;
-- ---------------------------------------------------------------------------

-- Verify all four files are present before proceeding
LIST @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE;
-- Expected: 4 rows (LOCID_BUILDS.csv.gz, LOCID_BUILDS_IPV4_EXPLODED.csv.gz,
--                    LOCID_BUILD_DATES.csv.gz, CUSTOMER_TEST_INPUT.csv.gz)
-- Note: SnowSQL auto-compresses to .gz even with AUTO_COMPRESS=FALSE when staging;
--       the stage metadata is transparent to COPY INTO.


-- ---------------------------------------------------------------------------
-- STEP 3: Test-only tables (not part of standard provider schema)
-- ---------------------------------------------------------------------------

-- Customer test input: simulates the customer-provided IP+timestamp table
-- Column types mirror Coco/db/tables.sql exactly.
CREATE TABLE IF NOT EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT (
    id          VARCHAR(16777216),
    ip_address  VARCHAR(16777216),
    ts          TIMESTAMP_NTZ(9)
);

-- Customer test output: expected results for validation (reference, not loaded by procs)
-- Column types mirror Coco/db/tables.sql exactly.
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
-- STEP 4: Truncate existing rows before reload (idempotent)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILD_DATES;
TRUNCATE TABLE LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;


-- ---------------------------------------------------------------------------
-- STEP 5: Load LOCID_BUILDS (10,000 rows)
--
-- CSV column order (header):
--   START_IP, END_IP, TIER, LOCID_COUNTRY, LOCID_COUNTRY_CODE,
--   LOCID_REGION, LOCID_REGION_CODE, LOCID_CITY, LOCID_CITY_CODE,
--   LOCID_POSTAL_CODE, ENCRYPTED_LOCID, LOCID_HORIZONTAL_ACCURACY,
--   BUILD_DT, START_IP_INT_HEX, END_IP_INT_HEX
--
-- Table column order: build_dt, start_ip, end_ip, start_ip_int_hex, end_ip_int_hex,
--   tier, ..., encrypted_locid, locid_horizontal_accuracy
-- Column positions are remapped explicitly below.
-- ---------------------------------------------------------------------------
COPY INTO LOCID_DEV.STAGING.LOCID_BUILDS (
    build_dt, start_ip, end_ip, start_ip_int_hex, end_ip_int_hex,
    tier, locid_country, locid_country_code, locid_region, locid_region_code,
    locid_city, locid_city_code, locid_postal_code, encrypted_locid,
    locid_horizontal_accuracy
)
FROM (
    SELECT
        $13::DATE,   -- build_dt              ← CSV col 13
        $1,          -- start_ip              ← CSV col 1
        $2,          -- end_ip                ← CSV col 2
        $14,         -- start_ip_int_hex      ← CSV col 14
        $15,         -- end_ip_int_hex        ← CSV col 15
        $3,          -- tier                  ← CSV col 3
        $4,          -- locid_country         ← CSV col 4
        $5,          -- locid_country_code    ← CSV col 5
        $6,          -- locid_region          ← CSV col 6
        $7,          -- locid_region_code     ← CSV col 7
        $8,          -- locid_city            ← CSV col 8
        $9,          -- locid_city_code       ← CSV col 9
        $10,         -- locid_postal_code     ← CSV col 10
        $11,         -- encrypted_locid       ← CSV col 11
        $12          -- locid_horizontal_accuracy ← CSV col 12 ('?' → NULL via NULL_IF)
    FROM @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE/LOCID_BUILDS.csv
)
FILE_FORMAT = (
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', '?')
    EMPTY_FIELD_AS_NULL          = TRUE
);


-- ---------------------------------------------------------------------------
-- STEP 6: Load LOCID_BUILDS_IPV4_EXPLODED (10,000 rows)
--
-- CSV column order (header): START_IP, END_IP, IP_ADDRESS, BUILD_DT
-- Table column order:         build_dt, ip_address, start_ip, end_ip
-- ---------------------------------------------------------------------------
COPY INTO LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED (
    build_dt, ip_address, start_ip, end_ip
)
FROM (
    SELECT
        $4::DATE,   -- build_dt    ← CSV col 4
        $3,         -- ip_address  ← CSV col 3
        $1,         -- start_ip    ← CSV col 1
        $2          -- end_ip      ← CSV col 2
    FROM @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE/LOCID_BUILDS_IPV4_EXPLODED.csv
)
FILE_FORMAT = (
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', '?')
    EMPTY_FIELD_AS_NULL          = TRUE
);


-- ---------------------------------------------------------------------------
-- STEP 7: Load LOCID_BUILD_DATES (60 rows)
--
-- CSV column order: BUILD_DT, START_DT, END_DT — matches table order.
-- ---------------------------------------------------------------------------
COPY INTO LOCID_DEV.STAGING.LOCID_BUILD_DATES
FROM @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE/LOCID_BUILD_DATES.csv
FILE_FORMAT = (
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', '?')
    EMPTY_FIELD_AS_NULL          = TRUE
);


-- ---------------------------------------------------------------------------
-- STEP 8: Load CUSTOMER_TEST_INPUT (100 rows)
--
-- CSV column order: ID, IP_ADDRESS, TS — matches table order.
-- TS format: 'YYYY-MM-DD HH24:MI:SS.FF3' (e.g. 2025-08-20 21:16:25.195)
-- ---------------------------------------------------------------------------
COPY INTO LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT
FROM @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE/CUSTOMER_TEST_INPUT.csv
FILE_FORMAT = (
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', '?')
    EMPTY_FIELD_AS_NULL          = TRUE
    TIMESTAMP_FORMAT             = 'YYYY-MM-DD HH24:MI:SS.FF9'
);


-- ---------------------------------------------------------------------------
-- STEP 9: Verify row counts
-- ---------------------------------------------------------------------------
SELECT 'LOCID_BUILDS'               AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILDS
UNION ALL
SELECT 'LOCID_BUILDS_IPV4_EXPLODED' AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED
UNION ALL
SELECT 'LOCID_BUILD_DATES'          AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.LOCID_BUILD_DATES
UNION ALL
SELECT 'CUSTOMER_TEST_INPUT'        AS tbl, COUNT(*) AS row_count FROM LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT
ORDER BY 1;
-- Expected:
--   CUSTOMER_TEST_INPUT       100
--   LOCID_BUILD_DATES             60
--   LOCID_BUILDS              10,000
--   LOCID_BUILDS_IPV4_EXPLODED 10,000

-- Spot-check: verify the build_dt date range loaded correctly
SELECT MIN(build_dt) AS earliest, MAX(build_dt) AS latest, COUNT(DISTINCT build_dt) AS builds
FROM LOCID_DEV.STAGING.LOCID_BUILD_DATES;
