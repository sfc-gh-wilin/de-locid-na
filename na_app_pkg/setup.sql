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
-- 2. Schemas
--    APP_SCHEMA  — non-versioned, stateful: tables, stage, network rule, output tables
--    APP_CODE    — versioned, stateless: Scala UDFs with JAR imports
--                  (CREATE OR ALTER VERSIONED SCHEMA required for UDFs with IMPORTS)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS APP_SCHEMA;

GRANT USAGE ON SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_VIEWER;

CREATE OR ALTER VERSIONED SCHEMA APP_CODE;
GRANT USAGE ON SCHEMA APP_CODE TO APPLICATION ROLE APP_ADMIN;


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
    ('output_col.locid_country',       '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_country_code',  '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_region',        '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_region_code',   '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_city',          '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_city_code',     '{"operation":"both","requires_entitlement":"allow_geo_context"}'),
    ('output_col.locid_postal_code',   '{"operation":"both","requires_entitlement":"allow_geo_context"}')
) AS t(col, val)
WHERE NOT EXISTS (
    SELECT 1 FROM APP_SCHEMA.APP_CONFIG WHERE config_key = t.col
);


-- =============================================================================
-- 5. JOB_LOG Table
--    Full audit trail of all Encrypt and Decrypt jobs.
--    NOTE: run_dt is TIMESTAMP_NTZ — stored procedures must insert UTC values
--    explicitly: CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
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
-- 5b. APP_LOGS Table
--     Application-level log stream. Written by utils/logger.py.
--     All timestamps are UTC (TIMESTAMP_NTZ).
--     level: DEBUG | INFO | WARNING | ERROR | TRACE
-- =============================================================================
CREATE TABLE IF NOT EXISTS APP_SCHEMA.APP_LOGS (
    log_id      VARCHAR        NOT NULL
                    DEFAULT UUID_STRING(),
    level       VARCHAR        NOT NULL,         -- DEBUG|INFO|WARNING|ERROR|TRACE
    source      VARCHAR        NOT NULL,         -- "<file>.<function>"
    logged_at   TIMESTAMP_NTZ  NOT NULL
                    DEFAULT CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ,
    session_id  VARCHAR,                         -- Snowflake session ID (CURRENT_SESSION())
    message     VARCHAR        NOT NULL,
    traceback   VARCHAR                          -- full Python traceback on exceptions
);

GRANT SELECT, INSERT ON TABLE APP_SCHEMA.APP_LOGS
    TO APPLICATION ROLE APP_ADMIN;
GRANT SELECT ON TABLE APP_SCHEMA.APP_LOGS
    TO APPLICATION ROLE APP_VIEWER;


-- =============================================================================
-- 6. Network Rule + External Access Integration — LocID Central
--
--    The network rule is a schema-level object (created here in APP_SCHEMA).
--    The EAI is an account-level object created in the consumer account using
--    the CREATE EXTERNAL ACCESS INTEGRATION privilege declared in manifest.yml.
--    The consumer is prompted to approve this privilege during installation.
--
--    Both objects are referenced by name in:
--      APP_SCHEMA.HTTP_PING()         (section 7)
--      APP_SCHEMA.LOCID_ENCRYPT(...)  (src/procs/encrypt.sql)
--      APP_SCHEMA.LOCID_DECRYPT(...)  (src/procs/decrypt.sql)
--      Scala UDFs                     (src/udfs/locid_udf.sql)
-- =============================================================================
CREATE OR REPLACE NETWORK RULE APP_SCHEMA.LOCID_CENTRAL_RULE
    TYPE       = HOST_PORT
    MODE       = EGRESS
    VALUE_LIST = ('central.locid.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION LOCID_CENTRAL_EAI
    ALLOWED_NETWORK_RULES = (APP_SCHEMA.LOCID_CENTRAL_RULE)
    ENABLED = TRUE;


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
-- JAR: encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
--      (Scala 2.13 / Java 17 — validated 2026-04-15)
--
-- Upload JAR to @APP_SCHEMA.APP_STAGE/lib/ before installing this version.
-- UDFs defined: LOCID_BASE_ENCRYPT, LOCID_BASE_DECRYPT, LOCID_TXCLOC_ENCRYPT,
--               LOCID_TXCLOC_DECRYPT, LOCID_STABLE_CLOC, LOCID_STABLE_CLOC_FROM_PLAIN
-- =============================================================================
EXECUTE IMMEDIATE FROM 'src/udfs/locid_udf.sql';


-- =============================================================================
-- 9. Stored Procedures
-- =============================================================================
EXECUTE IMMEDIATE FROM 'src/procs/encrypt.sql';
EXECUTE IMMEDIATE FROM 'src/procs/decrypt.sql';
EXECUTE IMMEDIATE FROM 'src/procs/fetch_license.sql';


-- =============================================================================
-- 10. Reference Callback
--     Handles consumer object binding at configuration time.
--     Snowflake calls this procedure when the consumer binds or removes a
--     reference — either through the Streamlit setup wizard or by calling
--     LOCID_DEV_APP.APP_SCHEMA.register_single_callback(...) directly.
--
--     References declared in manifest.yml:
--       INPUT_TABLE   — consumer input table     (SELECT)
--       OUTPUT_SCHEMA — consumer output schema   (CREATE TABLE, USAGE)
--       APP_WAREHOUSE — warehouse for job runs   (USAGE)
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.register_single_callback(
    ref_name     STRING,
    operation    STRING,
    ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CASE (operation)
        WHEN 'ADD' THEN
            SELECT system$set_reference(:ref_name, :ref_or_alias);
        WHEN 'REMOVE' THEN
            SELECT system$remove_reference(:ref_name);
        WHEN 'CLEAR' THEN
            SELECT system$remove_reference(:ref_name);
        ELSE
            RETURN 'Unknown operation: ' || operation;
    END CASE;
    RETURN 'Operation ' || operation || ' succeeds.';
END;
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.register_single_callback(STRING, STRING, STRING)
    TO APPLICATION ROLE APP_ADMIN;


-- =============================================================================
-- 11. Streamlit App
--     FROM '/streamlit' → stage root's streamlit/ directory
--     MAIN_FILE = '/Home.py' → Home.py relative to FROM directory
--     Referenced by manifest.yml artifacts.default_streamlit: APP_SCHEMA.LOCID_APP
-- =============================================================================
CREATE OR REPLACE STREAMLIT APP_SCHEMA.LOCID_APP
    FROM '/streamlit'
    MAIN_FILE = '/Home.py';

GRANT USAGE ON STREAMLIT APP_SCHEMA.LOCID_APP TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON STREAMLIT APP_SCHEMA.LOCID_APP TO APPLICATION ROLE APP_VIEWER;


-- =============================================================================
-- 12. Final Grants
-- =============================================================================
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
