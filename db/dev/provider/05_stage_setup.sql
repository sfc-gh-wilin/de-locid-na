-- =============================================================================
-- 05_stage_setup.sql
-- LocID Dev: Internal stage for encode-lib JAR artifacts
--
-- Run order: after 01_setup.sql (LOCID_DEV database + STAGING schema must exist)
-- =============================================================================

USE DATABASE LOCID_DEV;
USE SCHEMA   LOCID_DEV.STAGING;

-- ---------------------------------------------------------------------------
-- Internal stage for UDF JARs
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS LOCID_DEV.STAGING.LOCID_STAGE
    DIRECTORY = ( ENABLE = TRUE )
    COMMENT   = 'Internal stage for LocID encode-lib JAR and related artifacts';

-- ---------------------------------------------------------------------------
-- Upload the JAR  (choose one option)
--
-- Option A — Snowsight UI (easiest):
--   Data → Databases → LOCID_DEV → STAGING → Stages → LOCID_STAGE
--   Click "+ Files" and select the JAR file.
--   Snowsight does not compress files, so no extra flags needed.
--
-- Option B — SnowSQL PUT (absolute path):
--
--   PUT file:///absolute/path/to/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar
--       @LOCID_DEV.STAGING.LOCID_STAGE
--       AUTO_COMPRESS = FALSE
--       OVERWRITE     = TRUE;
--
-- Option C — SnowSQL PUT (from repo root):
--
--   PUT file://Coco/tmp/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar
--       @LOCID_DEV.STAGING.LOCID_STAGE
--       AUTO_COMPRESS = FALSE
--       OVERWRITE     = TRUE;
--
-- Note: If using SnowSQL PUT, AUTO_COMPRESS=FALSE is required.
--       Snowflake must not gzip the JAR — a gzipped JAR cannot be loaded
--       as a UDF dependency. Snowsight upload does not have this issue.
-- ---------------------------------------------------------------------------

-- Verify upload — expected: one row for the .jar file
LIST @LOCID_DEV.STAGING.LOCID_STAGE;
