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
-- Schema: LOCID_DEV.CONSUMER_TEST
--   Simulates a separate consumer database/schema.
--   The Native App is granted SELECT on NA_TEST_INPUT and
--   INSERT/SELECT on NA_TEST_OUTPUT (the app creates the output table itself).
-- =============================================================================

-- =============================================================================
-- CONFIGURATION — set these values before running Step 5
-- =============================================================================
SET app_name     = 'LOCID_DEV_APP';  -- installed application name
SET my_warehouse = 'DEV_WH';         -- warehouse for the app
-- =============================================================================

USE DATABASE LOCID_DEV;


-- ---------------------------------------------------------------------------
-- STEP 1: Consumer test schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS LOCID_DEV.CONSUMER_TEST
    COMMENT = 'Sandbox consumer simulation — mirrors a customer-owned schema for Native App testing';


-- ---------------------------------------------------------------------------
-- STEP 2: Input table
--         Column names are intentionally non-standard to test the column
--         mapping UI in the Setup Wizard / Run Encrypt screens.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT (
    row_id      VARCHAR        NOT NULL,   -- unique row identifier
    ip_addr     VARCHAR        NOT NULL,   -- IPv4 or IPv6 address
    event_ts    TIMESTAMP_NTZ(9) NOT NULL  -- event timestamp (Unix epoch or datetime)
)
COMMENT = 'Sandbox consumer input: 100-row sample for Native App Encrypt testing';


-- ---------------------------------------------------------------------------
-- STEP 3: Populate from test data loaded in 01_load_test_data.sql
--         Maps CUSTOMER_TEST_INPUT columns → NA_TEST_INPUT columns.
-- ---------------------------------------------------------------------------
INSERT INTO LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT (row_id, ip_addr, event_ts)
SELECT id, ip_address, ts
FROM   LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;


-- ---------------------------------------------------------------------------
-- STEP 4: Verify
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS rows_loaded FROM LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT;
-- Expected: 100

-- Preview first 5 rows
SELECT * FROM LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT LIMIT 5;


-- ---------------------------------------------------------------------------
-- STEP 5: Grant the Native App access
--         Set $app_name and $my_warehouse in the CONFIGURATION block above,
--         then uncomment and run after the app is installed (Phase 3 of the
--         test guide).
-- ---------------------------------------------------------------------------

-- Allow the app to read the input table
-- EXECUTE IMMEDIATE 'GRANT SELECT ON TABLE LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT TO APPLICATION ' || $app_name;

-- Allow the app to create/write the output table in this schema
-- EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA LOCID_DEV.CONSUMER_TEST TO APPLICATION ' || $app_name;
-- EXECUTE IMMEDIATE 'GRANT CREATE TABLE ON SCHEMA LOCID_DEV.CONSUMER_TEST TO APPLICATION ' || $app_name;

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
-- Compare output against LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT
-- for end-to-end validation (see docs/20260420_NativeApp_Test_Steps.md).
-- ---------------------------------------------------------------------------
