-- =============================================================================
-- Table: LOCID_BUILD_DATES
-- Description: Weekly build date reference. Maps each build to the date range
--              of IP records it covers. Used by matching procedures to filter
--              relevant builds for a given input timestamp.
-- Rows: ~52 per year (one per weekly build). No clustering needed.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;

CREATE OR REPLACE TABLE LOCID_DEV.STAGING.LOCID_BUILD_DATES (
    build_dt  DATE  NOT NULL,  -- weekly build identifier
    start_dt  DATE  NOT NULL,  -- date range start (inclusive)
    end_dt    DATE  NOT NULL   -- date range end (inclusive)
);
