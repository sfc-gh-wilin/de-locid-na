-- =============================================================================
-- 01_optimize_tables.sql
-- LocID: Add clustering keys to provider tables for Native App performance
--
-- Run order: FIRST (before 02 and 03). One-time setup.
--
-- Requires: ACCOUNTADMIN (or a role with ALTER TABLE on LOCID.STAGING).
--
-- Why this is needed:
--   Without clustering, Snowflake performs full table scans on tables with
--   billions of rows. The stored procedure's query plan depends on
--   micro-partition pruning via clustering keys.
--
-- Note:
--   ALTER TABLE ... CLUSTER BY is a metadata-only operation — it declares
--   the clustering key but does not move data immediately. Snowflake's
--   Automatic Clustering service reclusters in the background. On tables
--   with billions of rows, initial reclustering may take hours to days.
--   Queries will progressively improve as reclustering progresses.
-- =============================================================================

USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- (Optional) Convert VARIANT columns to VARCHAR for better performance
--
-- If START_IP_INT_HEX and END_IP_INT_HEX are VARIANT, converting them to
-- VARCHAR eliminates the need for inline casts in the Secure Views
-- (04_share_to_pkg.sql) and improves join/filter performance.
--
-- Skip this section if the columns are already VARCHAR.
-- =============================================================================

-- Check current data types first:
-- DESCRIBE TABLE LOCID.STAGING.LOCID_BUILDS;

-- To convert (creates a new table — requires sufficient storage temporarily):
--
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS ADD COLUMN START_IP_INT_HEX_V2 VARCHAR;
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS ADD COLUMN END_IP_INT_HEX_V2 VARCHAR;
--
-- UPDATE LOCID.STAGING.LOCID_BUILDS
--     SET START_IP_INT_HEX_V2 = START_IP_INT_HEX::VARCHAR,
--         END_IP_INT_HEX_V2   = END_IP_INT_HEX::VARCHAR;
--
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS DROP COLUMN START_IP_INT_HEX;
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS DROP COLUMN END_IP_INT_HEX;
--
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS RENAME COLUMN START_IP_INT_HEX_V2 TO START_IP_INT_HEX;
-- ALTER TABLE LOCID.STAGING.LOCID_BUILDS RENAME COLUMN END_IP_INT_HEX_V2 TO END_IP_INT_HEX;


-- =============================================================================
-- Add clustering keys matching the stored procedure's access patterns
-- =============================================================================

-- LOCID_BUILDS: filtered by build_dt, then range-joined on START_IP_INT_HEX
-- for IPv6 matching. Compound key enables micro-partition pruning on both
-- the date filter AND the hex BETWEEN range join.
ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    CLUSTER BY (BUILD_DT, START_IP_INT_HEX);

-- LOCID_BUILDS_IPV4_EXPLODED: equi-joined on ip_address, filtered by build_dt
ALTER TABLE LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED
    CLUSTER BY (IP_ADDRESS, BUILD_DT);

-- LOCID_BUILD_DATES: small table, cluster for consistency
ALTER TABLE LOCID.STAGING.LOCID_BUILD_DATES
    CLUSTER BY (BUILD_DT);


-- =============================================================================
-- Verify
-- =============================================================================

SHOW TABLES LIKE 'LOCID_BUILD%' IN SCHEMA LOCID.STAGING;
-- Expected: cluster_by columns populated for all 3 tables

