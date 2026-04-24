-- =============================================================================
-- 08_share_to_pkg.sql
-- LocID Dev: Share provider data into the Native App Package
--
-- Run order: AFTER Phase 3.2 (snow app deploy has created LOCID_DEV_PKG).
--            Re-run whenever provider source tables are re-created.
--
-- What this does:
--   1. Creates a LOCID_SHARE schema inside the Application Package.
--   2. Creates Secure Views wrapping the three provider source tables.
--   3. Grants REFERENCE_USAGE on LOCID_DEV so the package can query at runtime.
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

-- =============================================================================
-- CONFIGURATION — set this value before running
-- =============================================================================
SET app_pkg_name = 'LOCID_DEV_PKG';   -- Application Package name
SET provider_db  = 'LOCID_DEV';       -- Provider source database
SET provider_sch = 'LOCID_DEV.STAGING'; -- Provider source schema
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Step 1: Create shared schema inside the Application Package
-- ---------------------------------------------------------------------------
USE APPLICATION PACKAGE LOCID_DEV_PKG;

CREATE SCHEMA IF NOT EXISTS LOCID_SHARE;

GRANT USAGE ON SCHEMA LOCID_SHARE
    TO SHARE IN APPLICATION PACKAGE LOCID_DEV_PKG;


-- ---------------------------------------------------------------------------
-- Step 2: Secure Views over provider source tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILDS
    AS SELECT * FROM LOCID_DEV.STAGING.LOCID_BUILDS;

CREATE OR REPLACE SECURE VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILDS_IPV4_EXPLODED
    AS SELECT * FROM LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED;

CREATE OR REPLACE SECURE VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILD_DATES
    AS SELECT * FROM LOCID_DEV.STAGING.LOCID_BUILD_DATES;


-- ---------------------------------------------------------------------------
-- Step 3: REFERENCE_USAGE — allows the package to read LOCID_DEV at runtime
-- ---------------------------------------------------------------------------
GRANT REFERENCE_USAGE ON DATABASE LOCID_DEV
    TO SHARE IN APPLICATION PACKAGE LOCID_DEV_PKG;


-- ---------------------------------------------------------------------------
-- Step 4: Grant SELECT on each shared view to all app installations
-- ---------------------------------------------------------------------------
GRANT SELECT ON VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILDS
    TO SHARE IN APPLICATION PACKAGE LOCID_DEV_PKG;

GRANT SELECT ON VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILDS_IPV4_EXPLODED
    TO SHARE IN APPLICATION PACKAGE LOCID_DEV_PKG;

GRANT SELECT ON VIEW LOCID_DEV_PKG.LOCID_SHARE.LOCID_BUILD_DATES
    TO SHARE IN APPLICATION PACKAGE LOCID_DEV_PKG;


-- ---------------------------------------------------------------------------
-- Verify: list views in the shared schema
-- ---------------------------------------------------------------------------
SHOW VIEWS IN SCHEMA LOCID_DEV_PKG.LOCID_SHARE;
