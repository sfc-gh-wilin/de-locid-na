-- =============================================================================
-- setup_dev.sql
-- LocID Native App — DEV setup script (provider sandbox only)
--
-- Used by snowflake-dev.yml when deploying LOCID_PKG_DEV / LOCID_APP_DEV.
-- This package is NEVER published to Snowflake Marketplace.
-- Marketplace consumers always receive the standard setup.sql via LOCID_PKG.
--
-- This script:
--   1. Runs the full prod setup (EXECUTE IMMEDIATE FROM ./setup.sql)
--   2. Overrides the endpoint and network config to point at the DEV host:
--        - LOCID_CENTRAL_URL secret → central.matchbookdata-dev.com
--        - LOCID_CENTRAL_RULE network rule → adds dev host
--        - EAI app spec → includes dev host (provider approves once in Snowsight)
--        - APP_CONFIG.central_env = 'dev'  (Streamlit sidebar shows DEV badge)
--
-- After snow app run, the app is immediately in DEV mode — no further proc
-- calls or manual steps needed beyond the one-time Snowsight spec approval:
--   LOCID_APP_DEV → Settings → Connections → LocID Central API Access → Approve
-- =============================================================================


-- Step 1: Run full prod setup
EXECUTE IMMEDIATE FROM './setup.sql';


-- Step 2: Switch to DEV endpoint (runs at install time — no manual call needed)

-- 2a. Set endpoint URL in secret
ALTER SECRET APP_SCHEMA.LOCID_CENTRAL_URL
    SET SECRET_STRING = 'https://central.matchbookdata-dev.com/api/0/location_id';

-- 2b. Set network rule to dev host only
ALTER NETWORK RULE APP_SCHEMA.LOCID_CENTRAL_RULE
    SET VALUE_LIST = ('central.matchbookdata-dev.com:443');

-- 2c. Update EAI app spec — provider approves once in Snowsight after install
--     LOCID_APP_DEV → Settings → Connections → LocID Central API Access → Approve
ALTER APPLICATION SET SPECIFICATION LOCID_CENTRAL_EAI_SPEC
    TYPE        = EXTERNAL_ACCESS
    LABEL       = 'LocID Central API Access'
    DESCRIPTION = 'Allows the app to connect to central.matchbookdata-dev.com (HTTPS 443) for license validation. Provider sandbox use only.'
    HOST_PORTS  = ('central.matchbookdata-dev.com:443');

-- 2d. Flag DEV in APP_CONFIG so Streamlit sidebar shows the DEV badge
MERGE INTO APP_SCHEMA.APP_CONFIG AS t
USING (SELECT 'central_env' AS k, 'dev' AS v) AS s ON t.config_key = s.k
WHEN MATCHED THEN UPDATE SET
    config_value = s.v,
    last_refreshed_at = CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active)
    VALUES (s.k, s.v, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, TRUE);
