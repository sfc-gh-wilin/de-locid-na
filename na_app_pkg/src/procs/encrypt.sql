-- =============================================================================
-- src/procs/encrypt.sql
-- LocID Native App — LOCID_ENCRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/encrypt.sql';
--
-- Workflow:
--   1. Validate entitlements (allow_encrypt must be TRUE)
--   2. Fetch base_locid_secret + scheme_secret from LocID Central (EAI, cached)
--   3. Filter LOCID_BUILD_DATES to builds whose range covers the input timestamps
--   4. Match input IPs against the LocID data lake:
--        IPv4 — equi-join via LOCID_BUILDS_IPV4_EXPLODED
--        IPv6 — 6-pass cascading hex-prefix range join
--   5. For each matched row: call LOCID_TXCLOC_ENCRYPT + LOCID_STABLE_CLOC
--   6. Apply entitlement filter to output column list
--   7. INSERT INTO customer output table
--   8. Log run to APP_SCHEMA.JOB_LOG
--   9. POST usage statistics to LocID Central
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_ENCRYPT(
    INPUT_TABLE   VARCHAR,    -- fully qualified: MY_DB.MY_SCHEMA.MY_TABLE
    OUTPUT_TABLE  VARCHAR,    -- fully qualified: MY_DB.MY_SCHEMA.LOCID_RESULTS
    ID_COL        VARCHAR,    -- column name for unique row identifier
    IP_COL        VARCHAR,    -- column name for IP address
    TS_COL        VARCHAR,    -- column name for timestamp
    TS_FORMAT     VARCHAR,    -- 'epoch_sec' | 'epoch_ms' | 'timestamp'
    OUTPUT_COLS   ARRAY,      -- array of output column names to include
    WAREHOUSE     VARCHAR     -- warehouse to execute job on
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'encrypt_handler'
AS $$
import snowflake.snowpark as snowpark
from snowflake.snowpark.context import get_active_session
import json
import uuid
import time

# TODO: import locid_central utilities once utils/ is wired into PYTHONPATH

def encrypt_handler(session: snowpark.Session,
                    input_table: str, output_table: str,
                    id_col: str, ip_col: str, ts_col: str,
                    ts_format: str, output_cols: list,
                    warehouse: str) -> dict:

    job_id   = str(uuid.uuid4())
    start_ts = time.time()

    try:
        # ------------------------------------------------------------------
        # Step 1: Validate entitlements
        # ------------------------------------------------------------------
        # TODO: call entitlements.check_entitlement(session, 'allow_encrypt')
        # Raise if not entitled.

        # ------------------------------------------------------------------
        # Step 2: Fetch secrets from LocID Central (cached in APP_CONFIG)
        # ------------------------------------------------------------------
        # TODO: call locid_central.get_secrets(session)
        # Returns: { 'base_locid_secret': str, 'scheme_secret': str,
        #            'client_id': int, 'enc_client_id': int,
        #            'namespace_guid': str }

        # ------------------------------------------------------------------
        # Step 3: Identify relevant build dates
        #         (builds whose date range covers any input timestamp)
        # ------------------------------------------------------------------
        # TODO: SELECT DISTINCT build_dt FROM share.LOCID_BUILD_DATES
        #       WHERE start_dt <= MAX(input.timestamp) AND end_dt >= MIN(input.timestamp)

        # ------------------------------------------------------------------
        # Step 4: IP Matching
        # ------------------------------------------------------------------
        # IPv4 — equi-join via LOCID_BUILDS_IPV4_EXPLODED
        # TODO: JOIN input ON exploded.ip_address = input.ip
        #       JOIN LOCID_BUILDS ON (build_dt, start_ip, end_ip)

        # IPv6 — 6-pass cascading hex-prefix range join
        # TODO: implement passes 1-6 per example_sql_for_snowflake_locid_matching.sql
        #       UNION ALL IPv4 + IPv6 results

        # ------------------------------------------------------------------
        # Step 5: Generate TX_CLOC and STABLE_CLOC via UDFs
        # ------------------------------------------------------------------
        # TODO: SELECT
        #         id_col,
        #         APP_SCHEMA.LOCID_TXCLOC_ENCRYPT(encrypted_locid, base_key, scheme_key, ts, client_id) AS tx_cloc,
        #         APP_SCHEMA.LOCID_STABLE_CLOC(encrypted_locid, base_key, namespace, client_id, enc_client_id, tier) AS stable_cloc,
        #         geo context columns (if entitlement allows)
        #       FROM matched_results

        # ------------------------------------------------------------------
        # Step 6: Apply entitlement filter on output columns
        # ------------------------------------------------------------------
        # TODO: filter output_cols against entitlements from APP_CONFIG

        # ------------------------------------------------------------------
        # Step 7: INSERT INTO output table
        # ------------------------------------------------------------------
        # TODO: CREATE OR REPLACE TABLE <output_table> AS SELECT ...

        # ------------------------------------------------------------------
        # Step 8: Log to JOB_LOG
        # ------------------------------------------------------------------
        runtime_s = round(time.time() - start_ts, 2)
        # TODO: INSERT INTO APP_SCHEMA.JOB_LOG (...)

        # ------------------------------------------------------------------
        # Step 9: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        # TODO: call locid_central.report_stats(session, job_id, rows_in, rows_out, runtime_s)

        return {'job_id': job_id, 'status': 'SUCCESS', 'runtime_s': runtime_s}

    except Exception as e:
        runtime_s = round(time.time() - start_ts, 2)
        # TODO: INSERT failure row into JOB_LOG
        raise RuntimeError(f'LOCID_ENCRYPT failed: {e}') from e
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_ENCRYPT(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, ARRAY, VARCHAR
) TO APPLICATION ROLE APP_ADMIN;
