-- =============================================================================
-- Provider: Digital Envoy / Matchbook Data
-- Environment: DEV
-- Description: Database and schema setup for LocID data lake
-- =============================================================================

CREATE DATABASE IF NOT EXISTS LOCID_DEV;

CREATE SCHEMA IF NOT EXISTS LOCID_DEV.STAGING;
