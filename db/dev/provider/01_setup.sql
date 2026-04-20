-- =============================================================================
-- Provider: Digital Envoy / Matchbook Data
-- Environment: DEV
-- Description: Database and schema setup for LocID data lake
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;

CREATE DATABASE IF NOT EXISTS LOCID_DEV;

CREATE SCHEMA IF NOT EXISTS LOCID_DEV.STAGING;

-- Grant LOCID_APP_ADMIN ownership/usage on the dev database and schema.
-- These grants are needed so the role can create objects (tables, stages,
-- UDFs, Application Packages) inside LOCID_DEV without ACCOUNTADMIN.
GRANT USAGE ON DATABASE LOCID_DEV        TO ROLE LOCID_APP_ADMIN;
GRANT USAGE ON SCHEMA   LOCID_DEV.STAGING TO ROLE LOCID_APP_ADMIN;
GRANT CREATE TABLE  ON SCHEMA LOCID_DEV.STAGING TO ROLE LOCID_APP_ADMIN;
GRANT CREATE STAGE  ON SCHEMA LOCID_DEV.STAGING TO ROLE LOCID_APP_ADMIN;
GRANT CREATE FUNCTION ON SCHEMA LOCID_DEV.STAGING TO ROLE LOCID_APP_ADMIN;
