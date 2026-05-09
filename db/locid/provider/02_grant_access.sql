-- =============================================================================
-- 02_grant_access.sql
-- LocID: Grant LOCID_APP_ADMIN read access to provider tables
--
-- Run order: AFTER 01_optimize_tables.sql, BEFORE 03_share_to_pkg.sql
--            (or re-run if views fail with "Error in secure object").
--
-- Requires: ACCOUNTADMIN (one-time setup).
--
-- Why this is needed:
--   The Secure Views in LOCID_PKG.LOCID_SHARE reference tables in
--   LOCID.STAGING directly. The role that owns the Application Package
--   (LOCID_APP_ADMIN) must have SELECT on those tables for the views
--   to resolve at runtime. Without this, the installed app gets:
--     "SQL compilation error: Failure during expansion of view ... Error in secure object"
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Database and schema access
GRANT USAGE ON DATABASE LOCID TO ROLE LOCID_APP_ADMIN;
GRANT USAGE ON SCHEMA LOCID.STAGING TO ROLE LOCID_APP_ADMIN;

-- SELECT on the provider source tables (used by Secure Views in the package)
GRANT SELECT ON TABLE LOCID.STAGING.LOCID_BUILDS TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON TABLE LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON TABLE LOCID.STAGING.LOCID_BUILD_DATES TO ROLE LOCID_APP_ADMIN;

-- Grant access to the POC schema for test input tables
GRANT USAGE ON SCHEMA LOCID.POC TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON TABLE LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4 TO ROLE LOCID_APP_ADMIN;
GRANT SELECT ON TABLE LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV6 TO ROLE LOCID_APP_ADMIN;

-- Grant the consumer role (LOCID_APP_INSTALLER) access to bind test input tables
GRANT USAGE ON DATABASE LOCID TO ROLE LOCID_APP_INSTALLER;
GRANT USAGE ON SCHEMA LOCID.POC TO ROLE LOCID_APP_INSTALLER;
GRANT SELECT ON TABLE LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4 TO ROLE LOCID_APP_INSTALLER;
GRANT SELECT ON TABLE LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV6 TO ROLE LOCID_APP_INSTALLER;
