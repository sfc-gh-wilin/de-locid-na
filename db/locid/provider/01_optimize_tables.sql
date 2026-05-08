-- =============================================================================
-- 01_optimize_tables.sql
-- LocID: Create optimized views + add clustering for Native App performance
--
-- Run order: FIRST (before 02 and 03). Re-run only if schema is dropped.
--
-- Requires: ACCOUNTADMIN (or a role with CREATE SCHEMA + ALTER TABLE on LOCID).
--
-- Strategy:
--   LocID's source tables (LOCID.STAGING) have 58B+ and 253B+ rows.
--   Copying via CTAS is impractical at this scale. Instead:
--
--   1. Create LOCID.STAGING_OPTIMIZED as a VIEW layer over LOCID.STAGING.
--      Views cast VARIANT columns (START_IP_INT_HEX, END_IP_INT_HEX) to
--      VARCHAR inline — the encrypt procedure uses SUBSTR() which requires
--      VARCHAR (SUBSTR on VARIANT returns NULL).
--
--   2. Add clustering keys to the SOURCE tables directly.
--      Views cannot be clustered; the underlying tables need clustering
--      for micro-partition pruning. This is the only way to get query
--      performance at this scale without copying data.
--
-- Clustering note:
--   ALTER TABLE ... CLUSTER BY triggers Snowflake's Automatic Clustering
--   service. On tables with billions of rows, initial reclustering may take
--   hours to days and incurs compute costs. Once reclustered, maintenance
--   is incremental and much cheaper.
-- =============================================================================

USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- 1. Create the optimized schema (views live here)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS LOCID.STAGING_OPTIMIZED
    COMMENT = 'Optimized views over LOCID.STAGING for Native App. Casts VARIANT→VARCHAR and exposes correct types.';


-- =============================================================================
-- 2. Views with inline VARIANT → VARCHAR casts
-- =============================================================================

CREATE OR REPLACE VIEW LOCID.STAGING_OPTIMIZED.LOCID_BUILDS AS
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


CREATE OR REPLACE VIEW LOCID.STAGING_OPTIMIZED.LOCID_BUILDS_IPV4_EXPLODED AS
SELECT
    BUILD_DT,
    IP_ADDRESS,
    START_IP,
    END_IP
FROM LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED;


CREATE OR REPLACE VIEW LOCID.STAGING_OPTIMIZED.LOCID_BUILD_DATES AS
SELECT
    BUILD_DT,
    START_DT,
    END_DT
FROM LOCID.STAGING.LOCID_BUILD_DATES;


-- =============================================================================
-- 3. Add clustering keys to SOURCE tables
--    Views cannot be clustered — the underlying tables must be clustered
--    for micro-partition pruning to work at query time.
-- =============================================================================

ALTER TABLE LOCID.STAGING.LOCID_BUILDS
    CLUSTER BY (BUILD_DT);

ALTER TABLE LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED
    CLUSTER BY (IP_ADDRESS, BUILD_DT);

ALTER TABLE LOCID.STAGING.LOCID_BUILD_DATES
    CLUSTER BY (BUILD_DT);


-- =============================================================================
-- 4. Grant access to LOCID_APP_ADMIN (needed for Secure Views in the package)
-- =============================================================================

GRANT USAGE ON SCHEMA LOCID.STAGING_OPTIMIZED TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON ALL VIEWS IN SCHEMA LOCID.STAGING_OPTIMIZED TO ROLE LOCID_APP_ADMIN;


-- =============================================================================
-- 5. Verify
-- =============================================================================

-- Confirm views exist with correct column types
DESCRIBE VIEW LOCID.STAGING_OPTIMIZED.LOCID_BUILDS;
-- Expected: START_IP_INT_HEX = VARCHAR, END_IP_INT_HEX = VARCHAR

-- Confirm clustering is set (check cluster_by column)
SHOW TABLES LIKE 'LOCID_BUILDS%' IN SCHEMA LOCID.STAGING;

-- Check automatic clustering status
SELECT TABLE_NAME, CLUSTERING_KEY
FROM LOCID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'STAGING'
  AND TABLE_NAME LIKE 'LOCID_BUILDS%';

