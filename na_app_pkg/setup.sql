-- =============================================================================
-- setup.sql
-- LocID Native App — Setup Script
--
-- Runs at install time and at each version upgrade.
-- All objects are created within the app's own APPLICATION database.
-- No USE DATABASE / USE SCHEMA required — the app operates in its own context.
-- =============================================================================


-- =============================================================================
-- 1. Application Roles
--    APP_ADMIN  — full access: run jobs, view history, manage configuration
--    APP_VIEWER — read-only access: view job history only
-- =============================================================================
CREATE APPLICATION ROLE IF NOT EXISTS APP_ADMIN;
CREATE APPLICATION ROLE IF NOT EXISTS APP_VIEWER;


-- =============================================================================
-- 2. Main Schema
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS APP_SCHEMA;

GRANT USAGE ON SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_VIEWER;


-- =============================================================================
-- 3. App Stage
--    Stores the encode-lib JAR and modular SQL scripts.
--    After creating the app package version, upload:
--      - src/lib/encode-lib-*.jar       → @APP_STAGE/lib/
--      - src/udfs/locid_udf.sql         → @APP_STAGE/src/udfs/
--      - src/procs/encrypt.sql          → @APP_STAGE/src/procs/
--      - src/procs/decrypt.sql          → @APP_STAGE/src/procs/
-- =============================================================================
CREATE STAGE IF NOT EXISTS APP_SCHEMA.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);

GRANT READ ON STAGE APP_SCHEMA.APP_STAGE TO APPLICATION ROLE APP_ADMIN;


-- =============================================================================
-- 4. APP_CONFIG Table
--    Stores license metadata, cached entitlements, and output column registry.
--    Sensitive values (license key, api_key) are stored as Snowflake SECRETs
--    and are NOT written here in plaintext.
-- =============================================================================
CREATE TABLE IF NOT EXISTS APP_SCHEMA.APP_CONFIG (
    config_key         VARCHAR        NOT NULL,
    config_value       VARCHAR,
    last_refreshed_at  TIMESTAMP_NTZ,
    is_active          BOOLEAN        DEFAULT TRUE,
    CONSTRAINT pk_app_config PRIMARY KEY (config_key)
);

GRANT SELECT, INSERT, UPDATE ON TABLE APP_SCHEMA.APP_CONFIG
    TO APPLICATION ROLE APP_ADMIN;
GRANT SELECT ON TABLE APP_SCHEMA.APP_CONFIG
    TO APPLICATION ROLE APP_VIEWER;

-- Seed initial state (idempotent — skips rows that already exist)
INSERT INTO APP_SCHEMA.APP_CONFIG (config_key, config_value, is_active)
SELECT col, val, active FROM (VALUES
    ('onboarding_complete', 'false',    TRUE),
    ('scheme_version',      '0',        TRUE)
) AS t(col, val, active)
WHERE NOT EXISTS (
    SELECT 1 FROM APP_SCHEMA.APP_CONFIG WHERE config_key = t.col
);

-- Output column registry (drives dynamic SELECT list in stored procedures)
-- config_value: JSON { "operation": "encrypt|decrypt|both", "requires_entitlement": "<flag>" }
INSERT INTO APP_SCHEMA.APP_CONFIG (config_key, config_value, is_active)
SELECT col, val, TRUE FROM (VALUES
    ('output_col.tx_cloc',             '{"operation":"encrypt","requires_entitlement":"allow_tx"}'),
    ('output_col.stable_cloc',         '{"operation":"both","requires_entitlement":"allow_stable"}'),
    ('output_col.locid_country',       '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_country_code',  '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_region',        '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_region_code',   '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_city',          '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_city_code',     '{"operation":"both","requires_entitlement":"allow_geocontext"}'),
    ('output_col.locid_postal_code',   '{"operation":"both","requires_entitlement":"allow_geocontext"}')
) AS t(col, val)
WHERE NOT EXISTS (
    SELECT 1 FROM APP_SCHEMA.APP_CONFIG WHERE config_key = t.col
);


-- =============================================================================
-- 5. JOB_LOG Table
--    Full audit trail of all Encrypt and Decrypt jobs.
-- =============================================================================
CREATE TABLE IF NOT EXISTS APP_SCHEMA.JOB_LOG (
    job_id        VARCHAR         NOT NULL,
    operation     VARCHAR         NOT NULL,      -- 'ENCRYPT' | 'DECRYPT'
    run_dt        TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    rows_in       NUMBER,
    rows_matched  NUMBER,
    rows_out      NUMBER,
    runtime_s     NUMBER(10, 2),
    status        VARCHAR         NOT NULL,      -- 'SUCCESS' | 'FAILED'
    error_msg     VARCHAR,
    input_table   VARCHAR,
    output_table  VARCHAR,
    warehouse     VARCHAR,
    output_cols   VARCHAR                        -- JSON array of selected output columns
);

GRANT SELECT, INSERT ON TABLE APP_SCHEMA.JOB_LOG
    TO APPLICATION ROLE APP_ADMIN;
GRANT SELECT ON TABLE APP_SCHEMA.JOB_LOG
    TO APPLICATION ROLE APP_VIEWER;


-- =============================================================================
-- 6. Network Rule — LocID Central
--    Schema-level object; referenced by LOCID_CENTRAL_EAI declared in manifest.yml.
--    The External Access Integration itself is an account-level object and is
--    declared in manifest.yml (external_access_integrations), not created here.
-- =============================================================================
CREATE OR REPLACE NETWORK RULE APP_SCHEMA.LOCID_CENTRAL_RULE
    TYPE       = HOST_PORT
    MODE       = EGRESS
    VALUE_LIST = ('central.locid.com:443');


-- =============================================================================
-- 7. HTTP_PING UDF  (Python)
--    Used in the onboarding wizard (Screen G) to verify EAI connectivity.
--    Returns 'OK (<status_code>)' on success, 'FAILED: <message>' otherwise.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.HTTP_PING()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
HANDLER = 'ping'
AS $$
import urllib.request
import urllib.error

def ping() -> str:
    try:
        req = urllib.request.Request('https://central.locid.com', method='HEAD')
        with urllib.request.urlopen(req, timeout=10) as resp:
            return f'OK ({resp.status})'
    except urllib.error.HTTPError as e:
        # Any HTTP response means the host is reachable
        return f'OK ({e.code})'
    except Exception as e:
        return f'FAILED: {e}'
$$;

GRANT USAGE ON FUNCTION APP_SCHEMA.HTTP_PING()
    TO APPLICATION ROLE APP_ADMIN;


-- =============================================================================
-- 8. Scala UDFs  (encode-lib JAR)
--
-- ⚠ BLOCKED: encode-lib JAR must be recompiled with -release 11 (Java 11)
--   before these UDFs can be deployed. The io.ol.locationid.proto classes
--   are currently compiled with Java 17 which Snowflake's Scala 2.12
--   runtime (Java 11 max) cannot load. DE has been notified.
--
-- Once a Java 11-compatible JAR is confirmed:
--   1. Upload JAR to @APP_SCHEMA.APP_STAGE/lib/
--   2. Uncomment the EXECUTE IMMEDIATE line below
-- =============================================================================
-- EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/udfs/locid_udf.sql';


-- =============================================================================
-- 9. Stored Procedures
--    Uncomment after UDFs are deployed and LocID Central integration is complete.
-- =============================================================================
-- EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/encrypt.sql';
-- EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/decrypt.sql';


-- =============================================================================
-- 10. Final Grants
-- =============================================================================
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
