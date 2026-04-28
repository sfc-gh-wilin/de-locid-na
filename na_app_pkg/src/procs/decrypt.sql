-- =============================================================================
-- src/procs/decrypt.sql
-- LocID Native App — LOCID_DECRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/decrypt.sql';
--
-- Workflow:
--   1. Validate entitlement (allow_decrypt)
--   2. Fetch scheme_secret (+ base_locid_secret, client_id, namespace_guid)
--      from LocID Central (cached)
--   3. Decode each TX_CLOC via LOCID_TXCLOC_DECRYPT into a temp table
--      → location_id (plaintext), timestamp, enc_client_id
--   4. Generate STABLE_CLOC via LOCID_STABLE_CLOC_FROM_PLAIN (if entitled)
--   5. Apply entitlement filter on output columns
--   6. CREATE OR REPLACE TABLE → customer output table
--   7. Log run to APP_SCHEMA.JOB_LOG
--   8. POST usage statistics to LocID Central
--
-- Geo context limitation:
--   Geo context fields (country, region, city, postal code) are NOT embedded in
--   TX_CLOC. In the decrypt path they are returned as NULL. A future version may
--   recover them via a secondary lookup, but this is de-scoped from v1.
--
-- Tier for STABLE_CLOC:
--   Tier is not embedded in TX_CLOC. The procedure defaults to 'T0' (rooftop).
--   A future version may accept tier as a parameter.
-- =============================================================================

-- Consumer references used by this procedure (declared in manifest.yml):
--   INPUT_TABLE   — consumer input table; read via reference('INPUT_TABLE')
--   APP_WAREHOUSE — warehouse for job execution; set via
--                   USE WAREHOUSE reference('APP_WAREHOUSE') at proc start.
--
-- Output table: auto-generated in APP_SCHEMA as LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS.
-- The app owns APP_SCHEMA — no consumer GRANT needed.
-- SELECT is granted to APP_ADMIN and APP_VIEWER after creation.
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_DECRYPT(
    ID_COL        VARCHAR,    -- column name for unique row identifier
    TXCLOC_COL    VARCHAR,    -- column name for TX_CLOC values
    OUTPUT_COLS   ARRAY       -- requested output column names (empty = all entitled)
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'decrypt_handler'
AS $$
import json
import re
import time
import urllib.request
import urllib.error
import uuid

import snowflake.snowpark as snowpark

# =============================================================================
# Helpers (self-contained — mirrors encrypt.sql helpers)
# =============================================================================

def _sql_lit(s: str) -> str:
    """Wrap s in a SQL VARCHAR literal, escaping embedded single quotes."""
    return "'" + str(s).replace("'", "''") + "'"


def _validate_id(name: str) -> str:
    """Raise ValueError if name contains characters that could enable SQL injection."""
    if not re.match(r'^[A-Za-z0-9_$."]+$', name):
        raise ValueError(f"Invalid identifier: {name!r}")
    return name


def _get_config(session, key: str):
    rows = session.sql(
        "SELECT config_value, last_refreshed_at FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0] if rows else None


def _extract_secrets(session, data: dict) -> dict:
    secrets      = data.get('secrets', {})
    license_info = data.get('license', {})

    k_row  = _get_config(session, 'api_key_id')
    sel_id = int(k_row[0]) if k_row and k_row[0] else None

    entry = None
    for item in data.get('access', []):
        if item.get('status') == 'ACTIVE':
            if sel_id is None or item.get('api_key_id') == sel_id:
                entry = item
                if sel_id is not None:
                    break

    if not entry:
        raise RuntimeError(
            "No active API key found in license. Check your configuration."
        )

    return {
        'base_locid_secret': secrets.get('base_locid_secret', ''),
        'scheme_secret':     secrets.get('scheme_secret', ''),
        'client_id':         int(license_info.get('client_id', 0)),
        'namespace_guid':    entry.get('namespace_guid', ''),
    }


def _get_secrets(session) -> dict:
    cached = _get_config(session, 'cached_license')
    if cached and cached[1]:
        if time.time() - cached[1].timestamp() < 3600:
            return _extract_secrets(session, json.loads(cached[0]))

    lic_row = _get_config(session, 'license_id_ref')
    if not lic_row or not lic_row[0]:
        raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    url = f"https://central.locid.com/api/0/location_id/license/{lic_row[0]}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"LocID Central license fetch failed: HTTP {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"LocID Central license fetch failed: {exc}") from exc

    session.sql(
        "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
        "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
        "WHEN MATCHED THEN UPDATE SET config_value = s.v, last_refreshed_at = CURRENT_TIMESTAMP "
        "WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active) "
        "VALUES (s.k, s.v, CURRENT_TIMESTAMP, TRUE)",
        params=['cached_license', json.dumps(data)]
    ).collect()

    return _extract_secrets(session, data)


def _check_entitlement(session, flag: str) -> None:
    cached = _get_config(session, 'cached_license')
    if not cached or not cached[0]:
        raise PermissionError("License not configured. Complete the Setup Wizard first.")

    data  = json.loads(cached[0])
    k_row = _get_config(session, 'api_key_id')
    sel   = int(k_row[0]) if k_row and k_row[0] else None

    for item in data.get('access', []):
        if item.get('status') == 'ACTIVE':
            if sel is None or item.get('api_key_id') == sel:
                if item.get(flag):
                    return
                break

    raise PermissionError(
        f"Your LocID license does not include '{flag}'. "
        "Contact LocID to upgrade your access."
    )


def _entitled_cols(session, operation: str) -> list:
    active_flags = set()
    cached = _get_config(session, 'cached_license')
    if cached and cached[0]:
        data  = json.loads(cached[0])
        k_row = _get_config(session, 'api_key_id')
        sel   = int(k_row[0]) if k_row and k_row[0] else None
        for item in data.get('access', []):
            if item.get('status') == 'ACTIVE' and (sel is None or item.get('api_key_id') == sel):
                active_flags = {
                    f for f in (
                        'allow_encrypt', 'allow_decrypt', 'allow_tx',
                        'allow_stable', 'allow_geo_context'
                    ) if item.get(f)
                }
                break

    rows = session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key LIKE 'output_col.%' AND is_active = TRUE"
    ).collect()

    cols = []
    for row in rows:
        meta   = json.loads(row[1]) if row[1] else {}
        col_op = meta.get('operation', 'both')
        req_f  = meta.get('requires_entitlement', '')
        if col_op not in (operation, 'both'):
            continue
        if req_f and req_f not in active_flags:
            continue
        cols.append(row[0].replace('output_col.', ''))
    return cols


def _post_stats(session, rows_processed: int, runtime_s: float, metric_key: str) -> None:
    api_row = _get_config(session, 'api_key')
    lic_row = _get_config(session, 'license_id_ref')
    if not api_row or not lic_row:
        return

    payload = json.dumps([{
        'identifier': lic_row[0],
        'source':     'snowflake-native-app',
        'timestamp':  int(time.time() * 1000),
        'data_type':  'usage_metrics',
        'data': {
            'metric_key':      metric_key,
            'dimensions':      {'api_key': api_row[0], 'hit': 1, 'tier': 0},
            'metric_value':    rows_processed,
            'metric_datatype': 'Long',
        },
    }]).encode()

    try:
        req = urllib.request.Request(
            'https://central.locid.com/api/0/location_id/stats',
            data=payload,
            headers={'Content-Type': 'application/json', 'de-access-token': api_row[0]},
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception:
        pass


def _log_job(session, job_id, operation, rows_in, rows_matched, rows_out,
             runtime_s, status, error_msg, input_table, output_table,
             warehouse, output_cols) -> None:
    session.sql(
        "INSERT INTO APP_SCHEMA.JOB_LOG "
        "(job_id, operation, rows_in, rows_matched, rows_out, runtime_s, "
        " status, error_msg, input_table, output_table, warehouse, output_cols) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params=[
            job_id, operation, rows_in, rows_matched, rows_out, runtime_s,
            status, error_msg, input_table, output_table,
            warehouse, json.dumps(output_cols),
        ]
    ).collect()


def _log_perf(session, job_id: str, phases: dict) -> None:
    """Write phase-level timing to APP_SCHEMA.APP_LOGS. Non-blocking."""
    try:
        msg = json.dumps({'job_id': job_id, 'phases': phases})
        session.sql(
            "INSERT INTO APP_SCHEMA.APP_LOGS (level, message) VALUES (?, ?)",
            params=['PERF', msg]
        ).collect()
    except Exception:
        pass  # Perf logging must not abort the job


# =============================================================================
# Main handler
# =============================================================================

def decrypt_handler(
    session: snowpark.Session,
    id_col: str, txcloc_col: str,
    output_cols: list,
) -> dict:

    job_id   = str(uuid.uuid4())
    start_ts = time.time()
    rows_in = rows_matched = rows_out = 0

    # Auto-generate output table name in APP_SCHEMA (UTC timestamp)
    output_table = f"LOCID_DECRYPT_OUTPUT_{time.strftime('%Y%m%d_%H%M%S', time.gmtime())}"

    for name in (id_col, txcloc_col):
        _validate_id(name)

    cur_wh = None  # resolved after APP_WAREHOUSE reference is set (Step 0)

    phases: dict = {}
    _pt = time.perf_counter()

    try:
        # ------------------------------------------------------------------
        # Step 0: Set job warehouse from bound APP_WAREHOUSE reference
        # ------------------------------------------------------------------
        session.sql("USE WAREHOUSE reference('APP_WAREHOUSE')").collect()
        cur_wh = session.sql("SELECT CURRENT_WAREHOUSE()").collect()[0][0]
        phases['warehouse_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 1: Entitlement check
        # ------------------------------------------------------------------
        _check_entitlement(session, 'allow_decrypt')
        phases['entitlement_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 2: Fetch secrets from LocID Central (cached)
        # ------------------------------------------------------------------
        sec        = _get_secrets(session)
        scheme_key = _sql_lit(sec['scheme_secret'])
        client_id  = sec['client_id']
        ns_guid    = _sql_lit(sec['namespace_guid'])

        rows_in = session.sql("SELECT COUNT(*) FROM reference('INPUT_TABLE')").collect()[0][0]
        phases['secrets_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 3: Decode TX_CLOC → location_id, timestamp, enc_client_id
        #
        # Results are cached in a temp table to avoid re-running the UDF
        # three times (once per extracted field).
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TEMPORARY TABLE _locid_decoded AS
            SELECT
                {id_col}       AS _id,
                {txcloc_col}   AS _txcloc,
                PARSE_JSON(
                    APP_CODE.LOCID_TXCLOC_DECRYPT({txcloc_col}, {scheme_key})
                ) AS _decoded
            FROM reference('INPUT_TABLE')
            WHERE {txcloc_col} IS NOT NULL
        """).collect()

        rows_matched = session.sql(
            "SELECT COUNT(*) FROM _locid_decoded"
        ).collect()[0][0]
        phases['decode_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 4 + 5: Apply entitlement filter; build output SELECT list
        # ------------------------------------------------------------------
        entitled    = _entitled_cols(session, 'decrypt')
        requested   = set(output_cols) if output_cols else set(entitled)
        active_cols = [c for c in entitled if c in requested]

        # Map output column name → SQL expression over _locid_decoded columns.
        # STABLE_CLOC: uses LOCID_STABLE_CLOC_FROM_PLAIN since we have the
        #   plaintext location_id from LOCID_TXCLOC_DECRYPT.
        #   - dec_client_id = license client_id (the consumer)
        #   - enc_client_id = enc_client_id embedded in the TX_CLOC
        #   - tier defaults to 'T0' — not recoverable from TX_CLOC in v1.
        # Geo context: not embedded in TX_CLOC; returned as NULL in v1.
        COL_SQL = {
            'stable_cloc': (
                f"APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN("
                f"  _decoded:location_id::VARCHAR, {ns_guid}, "
                f"  {client_id}::INT, _decoded:enc_client_id::INT, 'T0')"
            ),
            # Geo context columns: not available in decrypt path (v1)
            'locid_country':      'NULL::VARCHAR',
            'locid_country_code': 'NULL::VARCHAR',
            'locid_region':       'NULL::VARCHAR',
            'locid_region_code':  'NULL::VARCHAR',
            'locid_city':         'NULL::VARCHAR',
            'locid_city_code':    'NULL::VARCHAR',
            'locid_postal_code':  'NULL::VARCHAR',
        }

        select_exprs = [f"_id AS {id_col}"] + [
            f"{COL_SQL.get(c, c)} AS {c}" for c in active_cols
        ]

        # ------------------------------------------------------------------
        # Step 6: Write output table into APP_SCHEMA and grant read access
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TABLE APP_SCHEMA.{output_table} AS
            SELECT {', '.join(select_exprs)}
            FROM _locid_decoded
        """).collect()

        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_ADMIN"
        ).collect()
        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_VIEWER"
        ).collect()

        rows_out  = session.sql(f"SELECT COUNT(*) FROM APP_SCHEMA.{output_table}").collect()[0][0]
        runtime_s = round(time.time() - start_ts, 2)
        phases['udf_output_s'] = round(time.perf_counter() - _pt, 3)
        phases['total_s'] = runtime_s
        _log_perf(session, job_id, phases)

        # ------------------------------------------------------------------
        # Step 7: Log to JOB_LOG
        # ------------------------------------------------------------------
        _log_job(
            session, job_id, 'DECRYPT', rows_in, rows_matched, rows_out,
            runtime_s, 'SUCCESS', None, 'reference(INPUT_TABLE)',
            f"APP_SCHEMA.{output_table}",
            cur_wh, active_cols,
        )

        # ------------------------------------------------------------------
        # Step 8: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        _post_stats(session, rows_matched, runtime_s, 'decrypt_usage')

        return {
            'job_id':        job_id,
            'status':        'SUCCESS',
            'output_table':  f"APP_SCHEMA.{output_table}",
            'rows_in':       rows_in,
            'rows_matched':  rows_matched,
            'rows_out':      rows_out,
            'runtime_s':     runtime_s,
        }

    except Exception as exc:
        runtime_s = round(time.time() - start_ts, 2)
        phases['total_s'] = runtime_s
        _log_perf(session, job_id, phases)
        _log_job(
            session, job_id, 'DECRYPT', rows_in, rows_matched, rows_out,
            runtime_s, 'FAILED', str(exc), 'reference(INPUT_TABLE)',
            f"APP_SCHEMA.{output_table}",
            cur_wh, [],
        )
        raise RuntimeError(f'LOCID_DECRYPT failed: {exc}') from exc
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_DECRYPT(
    VARCHAR, VARCHAR, ARRAY
) TO APPLICATION ROLE APP_ADMIN;


