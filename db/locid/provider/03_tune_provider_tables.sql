-- =============================================================================
-- 03_tune_provider_tables.sql
-- LocID: Tune provider tables for Native App performance
--
-- Run order: BEFORE 01_share_to_pkg.sql (first deploy) or any time after
--            provider data is reloaded.
--
-- Requires: ACCOUNTADMIN or a role with ALTER TABLE on LOCID.STAGING.
--
-- Problems this fixes:
--   1. START_IP_INT_HEX / END_IP_INT_HEX stored as VARIANT — the encrypt
--      procedure uses SUBSTR() on these columns for IPv6 prefix matching.
--      SUBSTR(VARIANT, ...) returns NULL → IPv6 matching fails silently.
--      Fix: ALTER COLUMN to VARCHAR.
--
--   2. No clustering keys — without clustering, Snowflake performs full table
--      scans on tables with hundreds of millions of rows. The procedure's
--      query plan depends on micro-partition pruning via clustering.
--      Fix: Add clustering keys matching the procedure's access patterns.
--
-- Note: ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE is a metadata-only
-- operation for VARIANT → VARCHAR when the underlying data is already string.
-- ALTER TABLE ... CLUSTER BY triggers a background reclustering process
-- (automatic clustering must be enabled on the account).
-- =============================================================================

USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- 1. Fix column types: VARIANT → VARCHAR
--    SUBSTR() on VARIANT returns NULL; the IPv6 prefix matching requires VARCHAR.
-- =============================================================================

ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    ALTER COLUMN START_IP_INT_HEX SET DATA TYPE VARCHAR;

ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    ALTER COLUMN END_IP_INT_HEX SET DATA TYPE VARCHAR;


-- =============================================================================
-- 2. Add clustering keys
--    These align with the stored procedure's access patterns:
--      - LOCID_BUILDS: filtered by build_dt (via LOCID_BUILD_DATES range join)
--      - LOCID_BUILDS_IPV4_EXPLODED: equi-joined on ip_address, filtered by build_dt
--      - LOCID_BUILD_DATES: small table, but clustering on build_dt is good practice
-- =============================================================================

ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    CLUSTER BY (BUILD_DT);

ALTER TABLE LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED
    CLUSTER BY (IP_ADDRESS, BUILD_DT);

ALTER TABLE LOCID.STAGING.LOCID_BUILD_DATES
    CLUSTER BY (BUILD_DT);


-- =============================================================================
-- 3. Verify
-- =============================================================================

-- Confirm column types
DESCRIBE TABLE LOCID.STAGING.LOCID_BUILDS;
-- Expected: START_IP_INT_HEX = VARCHAR, END_IP_INT_HEX = VARCHAR

-- Confirm clustering
SHOW TABLES LIKE 'LOCID_BUILDS%' IN SCHEMA LOCID.STAGING;
-- Expected: cluster_by columns populated
