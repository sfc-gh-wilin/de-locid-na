-- =============================================================================
-- 01_optimize_tables.sql
-- LocID: Create optimized provider tables for Native App performance
--
-- Run order: FIRST (before 02 and 03). Re-run whenever
--            LocID reloads data into LOCID.STAGING.
--
-- Requires: ACCOUNTADMIN (or a role with CREATE SCHEMA + CREATE TABLE on LOCID).
--
-- Strategy:
--   Instead of altering LocID's source tables (which their pipelines own),
--   we create a separate LOCID.STAGING_OPTIMIZED schema with derived tables
--   that have correct column types and clustering keys.
--
-- Problems this solves:
--   1. START_IP_INT_HEX / END_IP_INT_HEX stored as VARIANT in LOCID.STAGING —
--      the encrypt procedure uses SUBSTR() which requires VARCHAR.
--      Fix: Cast to VARCHAR in the CTAS.
--
--   2. No clustering keys on source tables — without clustering, Snowflake
--      performs full table scans on hundreds of millions of rows.
--      Fix: CLUSTER BY on the new tables matching the procedure's access patterns.
--
-- Re-run this script whenever LocID reloads LOCID.STAGING to pick up fresh data.
-- All statements are idempotent (CREATE OR REPLACE).
-- =============================================================================

USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- 1. Create the optimized schema
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS LOCID.STAGING_OPTIMIZED
    COMMENT = 'Optimized provider tables for Native App. Derived from LOCID.STAGING with correct types and clustering.';


-- =============================================================================
-- 2. LOCID_BUILDS — cast VARIANT hex columns to VARCHAR + cluster by build_dt
-- =============================================================================

CREATE OR REPLACE TABLE LOCID.STAGING_OPTIMIZED.LOCID_BUILDS
    CLUSTER BY (BUILD_DT)
AS
SELECT
    BUILD_DT,
    START_IP,
    END_IP,
    START_IP_INT_HEX::VARCHAR   AS START_IP_INT_HEX,
    END_IP_INT_HEX::VARCHAR     AS END_IP_INT_HEX,
    TIER,
    LOCID_COUNTRY,
    LOCID_COUNTRY_CODE,
    LOCID_REGION,
    LOCID_REGION_CODE,
    LOCID_CITY,
    LOCID_CITY_CODE,
    LOCID_POSTAL_CODE,
    ENCRYPTED_LOCID,
    LOCID_HORIZONTAL_ACCURACY
FROM LOCID.STAGING.LOCID_BUILDS;


-- =============================================================================
-- 3. LOCID_BUILDS_IPV4_EXPLODED — cluster by (ip_address, build_dt)
-- =============================================================================

CREATE OR REPLACE TABLE LOCID.STAGING_OPTIMIZED.LOCID_BUILDS_IPV4_EXPLODED
    CLUSTER BY (IP_ADDRESS, BUILD_DT)
AS
SELECT
    BUILD_DT,
    IP_ADDRESS,
    START_IP,
    END_IP
FROM LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED;


-- =============================================================================
-- 4. LOCID_BUILD_DATES — small table, cluster by build_dt for consistency
-- =============================================================================

CREATE OR REPLACE TABLE LOCID.STAGING_OPTIMIZED.LOCID_BUILD_DATES
    CLUSTER BY (BUILD_DT)
AS
SELECT
    BUILD_DT,
    START_DT,
    END_DT
FROM LOCID.STAGING.LOCID_BUILD_DATES;


-- =============================================================================
-- 5. Grant access to LOCID_APP_ADMIN (needed for Secure Views in the package)
-- =============================================================================

GRANT USAGE ON SCHEMA LOCID.STAGING_OPTIMIZED TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON ALL TABLES IN SCHEMA LOCID.STAGING_OPTIMIZED TO ROLE LOCID_APP_ADMIN;


-- =============================================================================
-- 6. Verify
-- =============================================================================

-- Confirm column types (START_IP_INT_HEX should be VARCHAR, not VARIANT)
DESCRIBE TABLE LOCID.STAGING_OPTIMIZED.LOCID_BUILDS;

-- Confirm clustering
SHOW TABLES IN SCHEMA LOCID.STAGING_OPTIMIZED;

-- Confirm row counts match source
SELECT 'LOCID_BUILDS' AS tbl,
       (SELECT COUNT(*) FROM LOCID.STAGING.LOCID_BUILDS) AS src,
       (SELECT COUNT(*) FROM LOCID.STAGING_OPTIMIZED.LOCID_BUILDS) AS opt
UNION ALL
SELECT 'LOCID_BUILDS_IPV4_EXPLODED',
       (SELECT COUNT(*) FROM LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED),
       (SELECT COUNT(*) FROM LOCID.STAGING_OPTIMIZED.LOCID_BUILDS_IPV4_EXPLODED)
UNION ALL
SELECT 'LOCID_BUILD_DATES',
       (SELECT COUNT(*) FROM LOCID.STAGING.LOCID_BUILD_DATES),
       (SELECT COUNT(*) FROM LOCID.STAGING_OPTIMIZED.LOCID_BUILD_DATES);

