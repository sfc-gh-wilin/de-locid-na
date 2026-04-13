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
-- Upload the JAR
--
-- Run from SnowSQL or Snowflake CLI (snow stage copy).
-- Do NOT run PUT from Snowsight — it is a SnowSQL-only command.
--
-- Option A — absolute path:
--
--   PUT file:///absolute/path/to/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar
--       @LOCID_DEV.STAGING.LOCID_STAGE
--       AUTO_COMPRESS = FALSE
--       OVERWRITE     = TRUE;
--
-- Option B — from repo root (SnowSQL invoked in repo directory):
--
--   PUT file://Coco/tmp/encode-lib-2.1.4-feature-OLDE-262-SNAPSHOT-fat.jar
--       @LOCID_DEV.STAGING.LOCID_STAGE
--       AUTO_COMPRESS = FALSE
--       OVERWRITE     = TRUE;
--
-- IMPORTANT: AUTO_COMPRESS=FALSE is required.
--            Snowflake must not gzip the JAR — a gzipped JAR cannot be loaded
--            as a UDF dependency.
-- ---------------------------------------------------------------------------

-- Verify upload — expected: one row for the .jar file
LIST @LOCID_DEV.STAGING.LOCID_STAGE;
