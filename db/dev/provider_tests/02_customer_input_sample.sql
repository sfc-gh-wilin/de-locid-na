-- =============================================================================
-- 02_customer_input_sample.sql
-- LocID Dev: Consumer-side test table for Native App sandbox testing
--
-- Run order: after 01_load_test_data.sql (CUSTOMER_TEST_INPUT must be loaded).
--
-- PURPOSE:
--   Creates a schema and input table that simulates the consumer's own data
--   environment. In production the consumer provides their own table; in sandbox
--   we mirror CUSTOMER_TEST_INPUT here so that the Native App can be tested
--   end-to-end with a realistic consumer boundary.
--
-- Schema: LOCID.CONSUMER_TEST
--   Simulates a separate consumer database/schema.
--   The Native App is granted SELECT on NA_TEST_INPUT and
--   INSERT/SELECT on NA_TEST_OUTPUT (the app creates the output table itself).
-- =============================================================================

-- =============================================================================
-- CONFIGURATION — set these values before running Step 5
-- =============================================================================
SET app_name     = 'LOCID_APP';  -- installed application name
SET my_warehouse = 'DEV_WH';         -- warehouse for the app
-- =============================================================================

USE DATABASE LOCID;


-- ---------------------------------------------------------------------------
-- STEP 1: Consumer test schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS LOCID.CONSUMER_TEST
    COMMENT = 'Sandbox consumer simulation — mirrors a customer-owned schema for Native App testing';


-- ---------------------------------------------------------------------------
-- STEP 2: Input table
--         Column names are intentionally non-standard to test the column
--         mapping UI in the Setup Wizard / Run Encrypt screens.
--
--         float_id  — synthetic FLOAT IDs for "ID to VARCHAR" regression
--                     testing. Simulates consumer IDs that arrive as DOUBLE
--                     from upstream systems (e.g. migrated from Oracle NUMBER,
--                     deserialized from JSON as float64). The first 100 rows
--                     use 13-digit integers (5000000000001–5000000000100)
--                     which are exactly representable in FLOAT64. The last 10
--                     rows use values straddling 2^53 = 9007199254740992,
--                     where FLOAT64 loses integer precision — some of those
--                     values cannot be represented exactly and may display
--                     artifacts via TO_VARCHAR without the ROUND() fix.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LOCID.CONSUMER_TEST.NA_TEST_INPUT (
    row_id      VARCHAR          NOT NULL,   -- unique row identifier (string)
    float_id    FLOAT            NOT NULL,   -- float ID for 'ID to VARCHAR' testing
    ip_addr     VARCHAR          NOT NULL,   -- IPv4 or IPv6 address
    event_ts    TIMESTAMP_NTZ(9) NOT NULL    -- event timestamp (Unix epoch or datetime)
)
COMMENT = 'Sandbox consumer input: 110-row sample for Native App Encrypt testing (incl. float_id for ID-to-VARCHAR regression)';


-- ---------------------------------------------------------------------------
-- STEP 3: Populate from test data loaded in 01_load_test_data.sql
--         Maps CUSTOMER_TEST_INPUT columns → NA_TEST_INPUT columns.
--
--         float_id generation:
--           Rows 1–100 (IPv4): 5000000000001–5000000000100
--             13-digit integers, exactly representable in FLOAT64.
--             Tests that "ID to VARCHAR" produces clean integer strings.
--           Rows 101–110 (IPv6): even offsets above 2^53 = 9007199254740992
--             Values: 9007199254740994, 9007199254740996, ..., 9007199254741012
--             Even numbers in [2^53, 2^54) are exactly representable in FLOAT64
--             and remain distinct. Odd numbers at this scale round to a neighbor,
--             causing ID collisions — deliberately avoided here.
--             These rows confirm that large-integer FLOATs above the 2^53 boundary
--             still produce clean integer strings via TO_VARCHAR(ROUND(float_id, 0)).
-- ---------------------------------------------------------------------------
INSERT INTO LOCID.CONSUMER_TEST.NA_TEST_INPUT (row_id, float_id, ip_addr, event_ts)
SELECT
    id,
    CASE
        -- Rows 1–100: 13-digit integers (5000000000001, 5000000000002, ...)
        WHEN ROW_NUMBER() OVER (ORDER BY id) <= 100
            THEN (5000000000000 + ROW_NUMBER() OVER (ORDER BY id))::FLOAT
        -- Rows 101–110: even offsets above 2^53 → all distinct and representable
        --   9007199254740994, 9007199254740996, ..., 9007199254741012
        ELSE (9007199254740992 + (ROW_NUMBER() OVER (ORDER BY id) - 100) * 2)::FLOAT
    END AS float_id,
    ip_address,
    ts
FROM LOCID.STAGING.CUSTOMER_TEST_INPUT;


-- ---------------------------------------------------------------------------
-- STEP 4: Verify
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS rows_loaded FROM LOCID.CONSUMER_TEST.NA_TEST_INPUT;
-- Expected: 110 (100 IPv4 + 10 IPv6 rows)

-- Preview first 5 rows
SELECT * FROM LOCID.CONSUMER_TEST.NA_TEST_INPUT LIMIT 5;

-- Verify float_id range and precision boundary rows
SELECT
    MIN(float_id)                                               AS float_id_min,
    MAX(float_id)                                               AS float_id_max,
    COUNT(CASE WHEN float_id < 9007199254740992 THEN 1 END)     AS rows_below_2p53,
    COUNT(CASE WHEN float_id >= 9007199254740992 THEN 1 END)    AS rows_at_or_above_2p53
FROM LOCID.CONSUMER_TEST.NA_TEST_INPUT;
-- Expected: float_id_min = 5000000000001, float_id_max = 9007199254741002
--           rows_below_2p53 = 100, rows_at_or_above_2p53 = 10

-- Spot-check: verify TO_VARCHAR(ROUND(float_id, 0)) produces clean integer strings
-- (no trailing .0 or decimal artifacts) — validates the "ID to VARCHAR" fix
SELECT float_id,
       TO_VARCHAR(float_id)               AS to_varchar_raw,
       TO_VARCHAR(ROUND(float_id, 0))     AS to_varchar_rounded
FROM LOCID.CONSUMER_TEST.NA_TEST_INPUT
WHERE float_id >= 9007199254740990
ORDER BY float_id;
-- Rows near 2^53 should show to_varchar_rounded as clean integer strings.


-- ---------------------------------------------------------------------------
-- STEP 5: Grant the Native App access
--         Set $app_name and $my_warehouse in the CONFIGURATION block above,
--         then uncomment and run after the app is installed (Phase 3 of the
--         test guide).
-- ---------------------------------------------------------------------------

-- Allow the app to read the input table
-- EXECUTE IMMEDIATE 'GRANT SELECT ON TABLE LOCID.CONSUMER_TEST.NA_TEST_INPUT TO APPLICATION ' || $app_name;

-- Allow the app to create/write the output table in this schema
-- EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA LOCID.CONSUMER_TEST TO APPLICATION ' || $app_name;
-- EXECUTE IMMEDIATE 'GRANT CREATE TABLE ON SCHEMA LOCID.CONSUMER_TEST TO APPLICATION ' || $app_name;

-- Allow the app to use the test warehouse
-- EXECUTE IMMEDIATE 'GRANT USAGE ON WAREHOUSE ' || $my_warehouse || ' TO APPLICATION ' || $app_name;


-- ---------------------------------------------------------------------------
-- REFERENCE: Expected output columns written by LOCID_ENCRYPT
--   (app creates the output table automatically on first job run)
--
--   row_id | tx_cloc | encrypted_locid | tier |
--   locid_country | locid_country_code | locid_region | locid_region_code |
--   locid_city | locid_city_code | locid_postal_code |
--   locid_horizontal_accuracy | run_dt
--
-- Compare output against LOCID.STAGING.CUSTOMER_TEST_OUTPUT
-- for end-to-end validation (see docs/20260420_NativeApp_Test_Steps.md).
-- ---------------------------------------------------------------------------
