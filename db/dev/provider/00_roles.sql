-- =============================================================================
-- 00_roles.sql
-- LocID Dev: Custom role setup for Native App Package and App deployment
--
-- Run order: FIRST — before all other scripts in db/dev/provider/.
-- Requires: ACCOUNTADMIN (one-time setup only).
--
-- Roles created:
--   LOCID_APP_ADMIN    — Provider side: manages the Application Package,
--                         stage contents, versions, and Marketplace listing.
--   LOCID_APP_INSTALLER — Consumer side: installs and manages the Native App
--                         instance.
--
-- SANDBOX NOTE:
--   In a sandbox environment the provider and consumer share one Snowflake
--   account. Both roles are created here in a single script.
--   In production, run the LOCID_APP_ADMIN block on the provider account and
--   the LOCID_APP_INSTALLER block on the consumer account.
-- =============================================================================


-- =============================================================================
-- CONFIGURATION — set these values before running
-- =============================================================================
SET my_warehouse = 'WLIN_WH_XS';  -- warehouse name for both roles
SET my_username  = 'WILIN';  -- Snowflake username to receive both roles
-- =============================================================================


USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- ROLE 1: LOCID_APP_ADMIN (Provider account)
--
-- Used by the engineering / ops team to manage the Application Package,
-- stage artifacts, version lifecycle, and Marketplace listing.
-- =============================================================================

CREATE ROLE IF NOT EXISTS LOCID_APP_ADMIN
    COMMENT = 'LocID Native App — provider-side deployment and package management';

-- Manage the Application Package and its versions / patches
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;

-- Create and manage the provider-side database (LOCID_DEV, staging objects)
GRANT CREATE DATABASE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;

-- Create the data share that backs the app's shared read-only objects
GRANT CREATE SHARE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;

-- Create and manage Snowflake listings (Specified Consumers + Marketplace).
-- NOTE: The role that publishes a listing must be the same role that owns the
-- Application Package (or have MODIFY on the listing if a different role owns it).
-- Trial/sandbox accounts support Specified Consumers listings.
-- Snowflake Marketplace (public) listings additionally require a provider profile.
GRANT CREATE LISTING ON ACCOUNT TO ROLE LOCID_APP_ADMIN;

-- Warehouse access for builds and testing
GRANT USAGE ON WAREHOUSE IDENTIFIER($my_warehouse) TO ROLE LOCID_APP_ADMIN;

-- Assign to the user who manages the app package
GRANT ROLE LOCID_APP_ADMIN TO USER IDENTIFIER($my_username);


-- =============================================================================
-- ROLE 2: LOCID_APP_INSTALLER (Consumer account)
--
-- Used by the customer's admin team to install, configure, and manage the
-- LocID Native App instance.
-- =============================================================================

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER
    COMMENT = 'LocID Native App — consumer-side installation and management';

-- Install Native Apps from the Snowflake Marketplace
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;

-- Create the output database/schema for job results (if using a new database)
GRANT CREATE DATABASE ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;

-- Warehouse access for running Encrypt / Decrypt jobs
GRANT USAGE ON WAREHOUSE IDENTIFIER($my_warehouse) TO ROLE LOCID_APP_INSTALLER;

-- Assign to the user who installs and manages the app
GRANT ROLE LOCID_APP_INSTALLER TO USER IDENTIFIER($my_username);

-- Optional: integrate into the standard role hierarchy
-- GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;


-- =============================================================================
-- NOTES
-- =============================================================================
-- 1. The one-time GRANT statements above must run as ACCOUNTADMIN.
--    All routine operations (add version, apply patch, install app) use
--    the custom roles — ACCOUNTADMIN is not needed day-to-day.
--
-- 2. Database-level grants for LOCID_APP_ADMIN on LOCID_DEV are in
--    01_setup.sql (executed after the database and schema are created).
--
-- 3. The app's Setup Wizard (Screen E — Review Privileges) surfaces any
--    missing consumer-side grants with remediation SQL.
-- =============================================================================
