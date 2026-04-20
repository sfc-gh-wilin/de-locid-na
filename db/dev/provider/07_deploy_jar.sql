-- =============================================================================
-- 07_deploy_jar.sql
-- LocID Dev: Upload encode-lib JAR to the Native App package stage
--
-- Run order: before or after 06_udfs.sql — the JAR must be on stage before
--            the UDFs are created (or recreated after an upgrade).
--
-- IMPORTANT — Snow CLI (run from repository root):
--   File upload uses `snow object stage copy`, not SQL.
--   Run the commands below in your terminal from the repository root.
--
-- JAR file location: Coco/tmp/20260415/
--   encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
-- =============================================================================


-- =============================================================================
-- CONFIGURATION — set this value before running
-- =============================================================================
SET app_pkg_name = 'LOCID_DEV_PKG';  -- application package name
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1: Upload JAR to stage /lib/ directory
--         Run in terminal from the repository root.
--         Replace $app_pkg_name below with your actual package name.
--
-- snow object stage copy \
--     "Coco/tmp/20260415/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar" \
--     @LOCID_DEV_PKG.APP_SCHEMA.APP_STAGE/lib/ \
--     --overwrite --connection wl_sandbox
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- STEP 2: Verify upload (run as SQL via: snow -c wl_sandbox sql -f this_file)
--         Expected: one row for encode-lib-*.jar under lib/
-- ---------------------------------------------------------------------------
EXECUTE IMMEDIATE 'LIST @' || $app_pkg_name || '.APP_SCHEMA.APP_STAGE/lib/';
-- Expected file: lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
