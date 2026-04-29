-- =============================================================================
-- 07_eai_setup.sql
-- LocID Dev: External Access Integration for LocID Central
--
-- Run order: one-time account-level setup BEFORE Phase 3 app installation.
--            The EAI must exist before `snow app run` can install the app.
--
-- manifest.yml declares LOCID_CENTRAL_EAI as a required EAI.
-- setup.sql creates APP_SCHEMA.LOCID_CENTRAL_RULE inside the app at install
-- time. This file creates the account-level EAI that wraps it for dev/sandbox.
--
-- Requires: a role with CREATE INTEGRATION privilege (e.g. ACCOUNTADMIN).
-- =============================================================================

USE ROLE ACCOUNTADMIN;


-- ---------------------------------------------------------------------------
-- STEP 1: Check if the EAI already exists (skip remaining steps if it does)
-- ---------------------------------------------------------------------------
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'LOCID_CENTRAL_EAI';


-- ---------------------------------------------------------------------------
-- STEP 2: Create network rule (schema-level, dev sandbox)
--         Allows outbound HTTPS to central.locid.com:443.
-- ---------------------------------------------------------------------------
CREATE NETWORK RULE IF NOT EXISTS LOCID_DEV.STAGING.LOCID_CENTRAL_RULE
    TYPE       = HOST_PORT
    MODE       = EGRESS
    VALUE_LIST = ('central.locid.com:443')
    COMMENT    = 'Allows the LocID Native App to reach central.locid.com over HTTPS';


-- ---------------------------------------------------------------------------
-- STEP 3: Create External Access Integration (account-level object)
--         References the network rule created above.
-- ---------------------------------------------------------------------------
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS LOCID_CENTRAL_EAI
    ALLOWED_NETWORK_RULES          = (LOCID_DEV.STAGING.LOCID_CENTRAL_RULE)
    ALLOWED_AUTHENTICATION_SECRETS = (ALL)
    ENABLED               = TRUE
    COMMENT               = 'LocID Central: license validation, secret retrieval, usage reporting';


-- If the EAI already existed (IF NOT EXISTS skipped the CREATE), update it
-- to include ALLOWED_AUTHENTICATION_SECRETS:
ALTER EXTERNAL ACCESS INTEGRATION LOCID_CENTRAL_EAI
    SET ALLOWED_AUTHENTICATION_SECRETS = (ALL);


-- ---------------------------------------------------------------------------
-- STEP 4: Verify
-- ---------------------------------------------------------------------------
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'LOCID_CENTRAL_EAI';
-- Expected: one row, ENABLED = true
