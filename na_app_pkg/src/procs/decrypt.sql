-- =============================================================================
-- src/procs/decrypt.sql
-- LocID Native App — LOCID_DECRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/decrypt.sql';
--
-- Workflow:
--   1. Validate entitlements (allow_decrypt must be TRUE)
--   2. Fetch scheme_secret from LocID Central (EAI, cached)
--   3. For each input row: call LOCID_TXCLOC_DECRYPT to decode TX_CLOC
--         → base LocID + timestamp + enc_client_id
--   4. Generate STABLE_CLOC using decoded base LocID (if allow_stable)
--   5. Apply entitlement filter to output column list
--   6. INSERT INTO customer output table
--   7. Log run to APP_SCHEMA.JOB_LOG
--   8. POST usage statistics to LocID Central
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_DECRYPT(
    INPUT_TABLE   VARCHAR,    -- fully qualified: MY_DB.MY_SCHEMA.MY_TABLE
    OUTPUT_TABLE  VARCHAR,    -- fully qualified: MY_DB.MY_SCHEMA.LOCID_RESULTS
    ID_COL        VARCHAR,    -- column name for unique row identifier
    TXCLOC_COL    VARCHAR,    -- column name for TX_CLOC values
    OUTPUT_COLS   ARRAY,      -- array of output column names to include
    WAREHOUSE     VARCHAR     -- warehouse to execute job on
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'decrypt_handler'
AS $$
import snowflake.snowpark as snowpark
from snowflake.snowpark.context import get_active_session
import json
import uuid
import time

# TODO: import locid_central utilities once utils/ is wired into PYTHONPATH

def decrypt_handler(session: snowpark.Session,
                    input_table: str, output_table: str,
                    id_col: str, txcloc_col: str,
                    output_cols: list, warehouse: str) -> dict:

    job_id   = str(uuid.uuid4())
    start_ts = time.time()

    try:
        # ------------------------------------------------------------------
        # Step 1: Validate entitlements
        # ------------------------------------------------------------------
        # TODO: call entitlements.check_entitlement(session, 'allow_decrypt')

        # ------------------------------------------------------------------
        # Step 2: Fetch scheme_secret from LocID Central (cached)
        # ------------------------------------------------------------------
        # TODO: call locid_central.get_secrets(session)
        # Returns: { 'scheme_secret': str, 'client_id': int,
        #            'enc_client_id': int, 'namespace_guid': str }

        # ------------------------------------------------------------------
        # Step 3: Decode TX_CLOC via LOCID_TXCLOC_DECRYPT
        # ------------------------------------------------------------------
        # TODO:
        #   SELECT
        #     id_col,
        #     PARSE_JSON(APP_SCHEMA.LOCID_TXCLOC_DECRYPT(txcloc_col, scheme_key)):location_id::VARCHAR AS location_id,
        #     PARSE_JSON(APP_SCHEMA.LOCID_TXCLOC_DECRYPT(txcloc_col, scheme_key)):timestamp::BIGINT    AS ts,
        #     PARSE_JSON(APP_SCHEMA.LOCID_TXCLOC_DECRYPT(txcloc_col, scheme_key)):enc_client_id::INT   AS enc_client_id
        #   FROM <input_table>
        #
        # Note: cache the decoded JSON in a temp table to avoid triple UDF call.

        # ------------------------------------------------------------------
        # Step 4: Generate STABLE_CLOC (if allow_stable entitlement)
        # ------------------------------------------------------------------
        # TODO: call LOCID_STABLE_CLOC using base_locid_key from LocID Central
        # and namespace_guid from APP_CONFIG.

        # ------------------------------------------------------------------
        # Step 5: Apply entitlement filter on output columns
        # ------------------------------------------------------------------
        # TODO: filter output_cols against entitlements

        # ------------------------------------------------------------------
        # Step 6: INSERT INTO output table
        # ------------------------------------------------------------------
        # TODO: CREATE OR REPLACE TABLE <output_table> AS SELECT ...

        # ------------------------------------------------------------------
        # Step 7: Log to JOB_LOG
        # ------------------------------------------------------------------
        runtime_s = round(time.time() - start_ts, 2)
        # TODO: INSERT INTO APP_SCHEMA.JOB_LOG (...)

        # ------------------------------------------------------------------
        # Step 8: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        # TODO: call locid_central.report_stats(session, job_id, rows_in, rows_out, runtime_s)

        return {'job_id': job_id, 'status': 'SUCCESS', 'runtime_s': runtime_s}

    except Exception as e:
        runtime_s = round(time.time() - start_ts, 2)
        # TODO: INSERT failure row into JOB_LOG
        raise RuntimeError(f'LOCID_DECRYPT failed: {e}') from e
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_DECRYPT(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, ARRAY, VARCHAR
) TO APPLICATION ROLE APP_ADMIN;
