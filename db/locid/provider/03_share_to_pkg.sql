-- =============================================================================
-- 03_share_to_pkg.sql
-- LocID: Share provider data into the Native App Package
--
-- Run order: AFTER 01_optimize_tables.sql and 02_grant_access.sql, and snow app deploy.
--            Re-run whenever optimized tables are refreshed.
--
-- Role: LOCID_APP_ADMIN — this role owns LOCID_PKG because snowflake.yml
--       declares meta.role: LOCID_APP_ADMIN for the pkg entity.
--
-- What this does:
--   1. Creates a LOCID_SHARE schema inside the Application Package.
--   2. Creates Secure Views over LOCID.STAGING with inline VARIANT→VARCHAR
--      casts for the hex columns.
--   3. Grants REFERENCE_USAGE on LOCID so the package can query at runtime.
--   4. Grants SELECT on each view to the package share, making them visible
--      to every installed app instance.
--
-- Inside the installed app (setup.sql + stored procedures), the shared tables
-- are accessible as:
--   LOCID_SHARE.LOCID_BUILDS
--   LOCID_SHARE.LOCID_BUILDS_IPV4_EXPLODED
--   LOCID_SHARE.LOCID_BUILD_DATES
--
-- Consumer accounts cannot query these views directly — the Native App
-- Framework restricts access to the app's own stored procedures only.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;


-- ---------------------------------------------------------------------------
-- Step 1: Create shared schema inside the Application Package
-- ---------------------------------------------------------------------------
USE APPLICATION PACKAGE LOCID_PKG;

CREATE SCHEMA IF NOT EXISTS LOCID_SHARE;

GRANT USAGE ON SCHEMA LOCID_SHARE
    TO SHARE IN APPLICATION PACKAGE LOCID_PKG;


-- ---------------------------------------------------------------------------
-- Step 2: Secure Views over provider source tables (with inline type casts)
--         Note: Secure Views in an app package cannot reference other views —
--         they must reference base tables directly. The VARIANT→VARCHAR cast
--         is applied inline here.
--
--         If START_IP_INT_HEX and END_IP_INT_HEX have already been converted
--         to VARCHAR (see 01_optimize_tables.sql), the ::VARCHAR casts below
--         are harmless no-ops but can be removed for clarity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILDS AS
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

CREATE OR REPLACE SECURE VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILDS_IPV4_EXPLODED AS
SELECT
    BUILD_DT,
    IP_ADDRESS,
    START_IP,
    END_IP
FROM LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED;

CREATE OR REPLACE SECURE VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILD_DATES AS
SELECT
    BUILD_DT,
    START_DT,
    END_DT
FROM LOCID.STAGING.LOCID_BUILD_DATES;


-- ---------------------------------------------------------------------------
-- Step 3: REFERENCE_USAGE — allows the package to read LOCID at runtime
-- ---------------------------------------------------------------------------
GRANT REFERENCE_USAGE ON DATABASE LOCID
    TO SHARE IN APPLICATION PACKAGE LOCID_PKG;


-- ---------------------------------------------------------------------------
-- Step 4: Grant SELECT on each shared view to all app installations
-- ---------------------------------------------------------------------------
GRANT SELECT ON VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILDS
    TO SHARE IN APPLICATION PACKAGE LOCID_PKG;

GRANT SELECT ON VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILDS_IPV4_EXPLODED
    TO SHARE IN APPLICATION PACKAGE LOCID_PKG;

GRANT SELECT ON VIEW LOCID_PKG.LOCID_SHARE.LOCID_BUILD_DATES
    TO SHARE IN APPLICATION PACKAGE LOCID_PKG;


-- ---------------------------------------------------------------------------
-- Verify: list views in the shared schema
-- ---------------------------------------------------------------------------
SHOW VIEWS IN SCHEMA LOCID_PKG.LOCID_SHARE;
