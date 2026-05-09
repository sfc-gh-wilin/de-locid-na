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
-- Add clustering keys matching the stored procedure's access patterns
-- =============================================================================

-- LOCID_BUILDS: filtered by build_dt (via LOCID_BUILD_DATES range join)
ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    CLUSTER BY (BUILD_DT);

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

