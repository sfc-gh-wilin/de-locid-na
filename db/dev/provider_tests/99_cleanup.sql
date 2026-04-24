-- =============================================================================
-- 99_cleanup.sql
-- LocID Dev: Sandbox environment cleanup
--
-- Three independent sections — run only the section(s) you need.
--
-- SECTION A — Full Teardown
--   Drops everything: app, package, provider DB (all tables / stages / UDFs),
--   EAI, network rule, and custom roles.
--   Use to start completely fresh.
--   Requires: ACCOUNTADMIN
--
-- SECTION B — App Reset (provider data preserved)
--   Drops the installed application and application package only.
--   Provider DB objects (LOCID_DEV) remain intact.
--   Use to redeploy after code changes without reloading data.
--   Requires: LOCID_APP_ADMIN (or ACCOUNTADMIN)
--
-- SECTION C — Test Data Reset (app and provider DB preserved)
--   Truncates provider test tables; drops consumer test schema and output tables.
--   Use to reload fresh test data without re-running Phase 1 or Phase 3.
--   Requires: LOCID_APP_ADMIN
--
-- Reference: docs/20260420_NativeApp_Test_Steps.md
-- =============================================================================


-- =============================================================================
-- CONFIGURATION — set these values before running
-- =============================================================================
SET app_name     = 'LOCID_DEV_APP';     -- installed application name
SET app_pkg_name = 'LOCID_DEV_PKG';    -- application package name
-- =============================================================================


-- =============================================================================
-- SECTION A — Full Teardown
-- =============================================================================
-- Drops every object created during sandbox deployment.
-- After running this section the account is back to a clean slate.
-- Re-start from Phase 0 (docs/20260420_NativeApp_Test_Steps.md) to redeploy.
--
-- Drop order:
--   1. Installed app first (holds references to app package + consumer grants)
--   2. Application package (all versions and patches)
--   3. EAI before DB (EAI references the network rule which lives inside the DB)
--   4. Provider DB (cascades: schemas, tables, stages, UDFs, network rule)
--   5. Custom roles
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- 1. Installed application
DROP APPLICATION IF EXISTS LOCID_DEV_APP;

-- 2. Application package (all versions and patches dropped with it)
DROP APPLICATION PACKAGE IF EXISTS LOCID_DEV_PKG;

-- 3. External access integration (must drop before the network rule)
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS LOCID_CENTRAL_EAI;

-- 4. Provider database — cascades all schemas, tables, stages, UDFs,
--    and the LOCID_CENTRAL_RULE network rule inside LOCID_DEV.STAGING
DROP DATABASE IF EXISTS LOCID_DEV;

-- 5. Custom deployment roles
DROP ROLE IF EXISTS LOCID_APP_ADMIN;
DROP ROLE IF EXISTS LOCID_APP_INSTALLER;


-- =============================================================================
-- SECTION B — App Reset (provider data preserved)
-- =============================================================================
-- Drops the installed app and app package only.
-- LOCID_DEV database, UDFs, test data, and stages are untouched.
-- After running this section, re-start from Phase 3
-- (docs/20260420_NativeApp_Test_Steps.md) to redeploy.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;

-- 1. Installed application
DROP APPLICATION IF EXISTS LOCID_DEV_APP;

-- 2. Application package (all versions and patches dropped with it)
DROP APPLICATION PACKAGE IF EXISTS LOCID_DEV_PKG;


-- =============================================================================
-- SECTION C — Test Data Reset (app and provider DB preserved)
-- =============================================================================
-- Clears test data so the load / generate scripts can be re-run cleanly.
-- Does NOT drop the app, app package, UDFs, or the JAR stage.
-- After running this section, re-start from Phase 2
-- (docs/20260420_NativeApp_Test_Steps.md) to reload test data.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;
USE DATABASE LOCID_DEV;

-- 1. Provider staging tables — truncate; re-run Phase 2 Option A or B to reload
TRUNCATE TABLE IF EXISTS LOCID_DEV.STAGING.LOCID_BUILD_DATES;
TRUNCATE TABLE IF EXISTS LOCID_DEV.STAGING.LOCID_BUILDS;
TRUNCATE TABLE IF EXISTS LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED;
TRUNCATE TABLE IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;
TRUNCATE TABLE IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT_2K;

-- 2. Consumer test schema — drops NA_TEST_INPUT and all app-created output tables
--    (NA_TEST_OUTPUT_ENC, NA_TEST_OUTPUT_DEC, any other runtime tables)
DROP SCHEMA IF EXISTS LOCID_DEV.CONSUMER_TEST;

-- 3. Test CSV stage — optional; remove to force re-upload of CSV source files
--    Comment this out if you want to keep the staged CSVs for faster reloads.
DROP STAGE IF EXISTS LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE;
