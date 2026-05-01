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

-- READ on APP_STAGE is intentionally NOT granted to APP_ADMIN or APP_VIEWER.
-- The stage contains the encode-lib JAR and SQL source files; granting READ
-- would allow consumers with the APP_ADMIN role to download those files.
-- Procedures and UDFs reference the stage internally — no consumer-facing
-- READ access is required at runtime.


-- =============================================================================
-- 4. APP_CONFIG Table
--    Stores license metadata, cached entitlements, and output column registry.
--    Sensitive values (license key, api_key, cryptographic secrets) are stored
--    in Snowflake SECRETs (section 4a). APP_CONFIG holds only masked display
--    hints (license_id_ref = first-4-chars + "****", api_key_hint = first-8-chars)
--    and stripped cached_license JSON (no secrets field, no api_key values).
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
    ('onboarding_complete',  'false', TRUE),
    ('scheme_version',       '0',     TRUE),
    ('log_retention_days',   '30',    TRUE)
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
-- 4a. Snowflake SECRETs
--
--   Sensitive credentials are stored here — NOT as plain VARCHAR in APP_CONFIG.
--   All secret writes go through stored procedures (EXECUTE AS OWNER), which
--   have OWNERSHIP on these objects. APP_ADMIN is granted READ so that proc
--   SECRETS = (...) clauses resolve; WRITE on secrets is NOT grantable to
--   APPLICATION ROLEs (Snowflake restriction), hence the proc-mediated design.
--
--   LOCID_LICENSE_KEY  — full license key (written by LOCID_FETCH_LICENSE)
--   LOCID_API_KEY      — selected API bearer token (written by LOCID_SET_API_KEY)
--   LOCID_BASE_SECRET  — base_locid_secret AES key (written by LOCID_FETCH_LICENSE)
--   LOCID_SCHEME_SECRET— scheme_secret AES key (written by LOCID_FETCH_LICENSE)
-- =============================================================================
CREATE SECRET IF NOT EXISTS APP_SCHEMA.LOCID_LICENSE_KEY
    TYPE          = GENERIC_STRING
    SECRET_STRING = ''
    COMMENT       = 'Full LocID license key. Written only by LOCID_FETCH_LICENSE stored procedure.';

CREATE SECRET IF NOT EXISTS APP_SCHEMA.LOCID_API_KEY
    TYPE          = GENERIC_STRING
    SECRET_STRING = ''
    COMMENT       = 'Selected API bearer token. Written only by LOCID_SET_API_KEY stored procedure.';

CREATE SECRET IF NOT EXISTS APP_SCHEMA.LOCID_BASE_SECRET
    TYPE          = GENERIC_STRING
    SECRET_STRING = ''
    COMMENT       = 'base_locid_secret AES key from LocID Central. Written only by LOCID_FETCH_LICENSE.';

CREATE SECRET IF NOT EXISTS APP_SCHEMA.LOCID_SCHEME_SECRET
    TYPE          = GENERIC_STRING
    SECRET_STRING = ''
    COMMENT       = 'scheme_secret AES key from LocID Central. Written only by LOCID_FETCH_LICENSE.';

-- Grant READ so that proc SECRETS = (...) clauses can reference these secrets.
-- (WRITE is not grantable to APPLICATION ROLEs — all writes go through procs.)
GRANT READ ON SECRET APP_SCHEMA.LOCID_LICENSE_KEY   TO APPLICATION ROLE APP_ADMIN;
GRANT READ ON SECRET APP_SCHEMA.LOCID_API_KEY       TO APPLICATION ROLE APP_ADMIN;
GRANT READ ON SECRET APP_SCHEMA.LOCID_BASE_SECRET   TO APPLICATION ROLE APP_ADMIN;
GRANT READ ON SECRET APP_SCHEMA.LOCID_SCHEME_SECRET TO APPLICATION ROLE APP_ADMIN;


-- =============================================================================
-- 4b. Upgrade migration — move existing APP_CONFIG sensitive data into SECRETs
--
--   Runs at every upgrade. Checks each secret: if it is still empty AND the
--   corresponding APP_CONFIG row holds a full (non-masked) value, the value is
--   migrated into the secret and APP_CONFIG is updated to the masked hint.
--   Idempotent: once migrated, the secret is non-empty and the block is a no-op.
-- =============================================================================
EXECUTE IMMEDIATE $$
DECLARE
    v_lic    VARCHAR DEFAULT NULL;
    v_api    VARCHAR DEFAULT NULL;
    v_cache  VARIANT DEFAULT NULL;
BEGIN
    -- ----------------------------------------------------------------
    -- Migrate license key (only when APP_CONFIG has a full key > 12 chars)
    -- ----------------------------------------------------------------
    SELECT config_value INTO v_lic
        FROM APP_SCHEMA.APP_CONFIG
        WHERE config_key = 'license_id_ref' AND is_active = TRUE LIMIT 1;
    IF (v_lic IS NOT NULL AND LENGTH(v_lic) > 12) THEN
        ALTER SECRET APP_SCHEMA.LOCID_LICENSE_KEY SET SECRET_STRING = :v_lic;
        UPDATE APP_SCHEMA.APP_CONFIG
            SET config_value = SUBSTR(:v_lic, 1, 4) || '-****',
                last_refreshed_at = CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
            WHERE config_key = 'license_id_ref';
    END IF;

    -- ----------------------------------------------------------------
    -- Migrate api_key (APP_CONFIG key 'api_key' → LOCID_API_KEY secret
    -- + new 'api_key_hint' row with first-8-chars)
    -- ----------------------------------------------------------------
    SELECT config_value INTO v_api
        FROM APP_SCHEMA.APP_CONFIG
        WHERE config_key = 'api_key' AND is_active = TRUE LIMIT 1;
    IF (v_api IS NOT NULL AND LENGTH(v_api) > 8) THEN
        ALTER SECRET APP_SCHEMA.LOCID_API_KEY SET SECRET_STRING = :v_api;
        MERGE INTO APP_SCHEMA.APP_CONFIG AS t
            USING (SELECT 'api_key_hint' AS k,
                          SUBSTR(:v_api, 1, 8) AS v,
                          CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS ts) AS s
                ON t.config_key = s.k
            WHEN MATCHED THEN UPDATE SET config_value = s.v, last_refreshed_at = s.ts
            WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active)
                VALUES (s.k, s.v, s.ts, TRUE);
        DELETE FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'api_key';
    END IF;

    -- ----------------------------------------------------------------
    -- Migrate crypto secrets from cached_license JSON
    -- (strip secrets field + replace api_key with api_key_hint in access[])
    -- ----------------------------------------------------------------
    SELECT PARSE_JSON(config_value) INTO v_cache
        FROM APP_SCHEMA.APP_CONFIG
        WHERE config_key = 'cached_license' AND is_active = TRUE LIMIT 1;
    IF (v_cache IS NOT NULL) THEN
        LET v_base_val   VARCHAR := :v_cache:secrets:base_locid_secret::VARCHAR;
        LET v_scheme_val VARCHAR := :v_cache:secrets:scheme_secret::VARCHAR;
        IF (v_base_val IS NOT NULL AND LENGTH(:v_base_val) > 0) THEN
            ALTER SECRET APP_SCHEMA.LOCID_BASE_SECRET   SET SECRET_STRING = :v_base_val;
        END IF;
        IF (v_scheme_val IS NOT NULL AND LENGTH(:v_scheme_val) > 0) THEN
            ALTER SECRET APP_SCHEMA.LOCID_SCHEME_SECRET SET SECRET_STRING = :v_scheme_val;
        END IF;
        -- Strip secrets field; replace api_key with api_key_hint in access entries
        UPDATE APP_SCHEMA.APP_CONFIG
            SET config_value = (
                SELECT OBJECT_CONSTRUCT_KEEP_NULL(
                    'license',  :v_cache:license,
                    'access',   (
                        SELECT ARRAY_AGG(
                            CASE WHEN a.value:api_key IS NOT NULL
                                 THEN OBJECT_INSERT(
                                          OBJECT_DELETE(a.value::OBJECT, 'api_key'),
                                          'api_key_hint',
                                          SUBSTR(a.value:api_key::VARCHAR, 1, 8),
                                          TRUE
                                      )
                                 ELSE a.value::OBJECT
                            END
                        )
                        FROM TABLE(FLATTEN(:v_cache:access)) a
                    )
                )::VARCHAR
            )
            WHERE config_key = 'cached_license';
    END IF;

    RETURN 'Migration complete.';
END;
$$;


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
    ALLOWED_NETWORK_RULES          = (APP_SCHEMA.LOCID_CENTRAL_RULE)
    ALLOWED_AUTHENTICATION_SECRETS = (
        APP_SCHEMA.LOCID_LICENSE_KEY,
        APP_SCHEMA.LOCID_API_KEY,
        APP_SCHEMA.LOCID_BASE_SECRET,
        APP_SCHEMA.LOCID_SCHEME_SECRET
    )
    ENABLED = TRUE;

-- App specification: registers the host:port with Snowflake so the consumer
-- can approve the outbound connection in Snowsight (Settings → Connections).
-- Without an approved spec the EAI exists but network calls return EBUSY.
ALTER APPLICATION SET SPECIFICATION LOCID_CENTRAL_EAI_SPEC
    TYPE        = EXTERNAL_ACCESS
    LABEL       = 'LocID Central API Access'
    DESCRIPTION = 'Allows the app to connect to central.locid.com (HTTPS 443) for license validation. No customer data is sent.'
    HOST_PORTS  = ('central.locid.com:443');


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
-- 7b. LOCID_SET_API_KEY Procedure  (Python, inline)
--
--   Called from Setup Wizard Screen H when the consumer selects an API key.
--   Receives the full api_key value directly from the caller (Streamlit session
--   state) — the key is never read from APP_CONFIG, so it is never stored in
--   plain text in any table.
--
--   Writes the api_key to the LOCID_API_KEY Snowflake SECRET, stores a masked
--   hint in APP_CONFIG, and removes any legacy plain-text 'api_key' row.
--
--   Runs EXECUTE AS OWNER (default) — required because APP_ADMIN cannot ALTER
--   a Snowflake SECRET directly (WRITE privilege is not grantable to APPLICATION
--   ROLEs). The proc's OWNER context has OWNERSHIP on all app-created objects.
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_SET_API_KEY(
    API_KEY_ID    INTEGER,
    API_KEY_VALUE VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'set_api_key_handler'
AS $$
import snowflake.snowpark as snowpark

_UPSERT_SQL = (
    "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
    "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
    "WHEN MATCHED THEN UPDATE SET config_value = s.v, "
    "last_refreshed_at = CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ "
    "WHEN NOT MATCHED THEN INSERT "
    "(config_key, config_value, last_refreshed_at, is_active) "
    "VALUES (s.k, s.v, "
    "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, TRUE)"
)


def set_api_key_handler(session: snowpark.Session,
                        api_key_id: int, api_key_value: str) -> str:
    if not api_key_value:
        raise RuntimeError("API key value is required.")

    # Write full key directly to secret — never touches APP_CONFIG
    session.sql(
        "ALTER SECRET APP_SCHEMA.LOCID_API_KEY SET SECRET_STRING = ?",
        params=[api_key_value]
    ).collect()

    # Write masked hint to APP_CONFIG
    session.sql(_UPSERT_SQL, params=['api_key_hint', api_key_value[:8]]).collect()

    # Remove legacy plain-text 'api_key' row if it exists from older versions
    session.sql(
        "DELETE FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'api_key'"
    ).collect()

    return f"API key {api_key_id} stored in LOCID_API_KEY secret."
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_SET_API_KEY(INTEGER, VARCHAR)
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
--       ENCRYPT_INPUT_TABLE — consumer input table for Encrypt jobs (SELECT)
--       DECRYPT_INPUT_TABLE — consumer input table for Decrypt jobs (SELECT)
--       APP_WAREHOUSE       — warehouse for job runs                (USAGE)
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
-- 12. Log Cleanup Procedure
--     Deletes JOB_LOG and APP_LOGS rows older than log_retention_days
--     (default 30). Called opportunistically at the start of every Encrypt /
--     Decrypt job so logs self-trim without requiring a scheduled Task or any
--     additional consumer-approved privilege.
--
--     log_retention_days is stored in APP_CONFIG and is consumer-updatable
--     from the Configuration view (minimum 1, maximum 365).
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_PURGE_LOGS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    retention_days NUMBER DEFAULT 30;
    cutoff         TIMESTAMP_NTZ;
    job_deleted    NUMBER DEFAULT 0;
    app_deleted    NUMBER DEFAULT 0;
BEGIN
    -- Read retention setting from APP_CONFIG (fall back to 30 if missing)
    LET cfg RESULTSET := (
        SELECT TRY_TO_NUMBER(config_value) AS retention_val
        FROM APP_SCHEMA.APP_CONFIG
        WHERE config_key = 'log_retention_days' AND is_active = TRUE
        LIMIT 1
    );
    FOR rec IN cfg DO
        IF (rec.retention_val IS NOT NULL AND rec.retention_val >= 1) THEN
            retention_days := rec.retention_val;
        END IF;
    END FOR;

    cutoff := DATEADD('day', -:retention_days, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ);

    DELETE FROM APP_SCHEMA.JOB_LOG WHERE run_dt < :cutoff;
    job_deleted := SQLROWCOUNT;

    DELETE FROM APP_SCHEMA.APP_LOGS WHERE logged_at < :cutoff;
    app_deleted := SQLROWCOUNT;

    RETURN 'Purged ' || :job_deleted || ' job log row(s) and ' || :app_deleted || ' app log row(s) older than ' || :retention_days || ' day(s).';
END;
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_PURGE_LOGS()
    TO APPLICATION ROLE APP_ADMIN;


-- =============================================================================
-- 13. Final Grants
-- =============================================================================
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA APP_SCHEMA TO APPLICATION ROLE APP_ADMIN;
