-- =============================================================================
-- src/procs/decrypt.sql
-- LocID Native App — LOCID_DECRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/decrypt.sql';
--
-- Workflow:
--   1. Validate entitlement (allow_decrypt)
--   2. Fetch license context (client_id) from cached license; namespace_guid from SECRET
--      Crypto secrets are bound directly to UDFs via SECRETS clauses — never embedded in SQL.
--   3. Decode each TX_CLOC via LOCID_TXCLOC_DECRYPT into a temp table
--      → location_id (plaintext), timestamp, enc_client_id
--   4. Generate STABLE_CLOC via LOCID_STABLE_CLOC_FROM_PLAIN (if entitled)
--   5. Apply entitlement filter on output columns
--   6. CREATE OR REPLACE TABLE → customer output table
--   7. Log run to APP_SCHEMA.JOB_LOG
--   8. POST usage statistics to LocID Central
--
-- Geo context:
--   Geo context fields (country, region, city, postal code, codes) are now
--   embedded in TX_CLOC at encrypt time. The decrypt path extracts them from
--   the decoded payload. TX_CLOCs produced before the geo context update will
--   return NULL for these fields (absent fields decode as NULL).
--
-- Tier for STABLE_CLOC:
--   Tier is extracted from the decoded TX_CLOC payload. Falls back to 'T0'
--   if not present (backwards compat with pre-geo TX_CLOCs).
-- =============================================================================

-- Consumer references used by this procedure (declared in manifest.yml):
--   DECRYPT_INPUT_TABLE — consumer input table; read via reference('DECRYPT_INPUT_TABLE')
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
SECRETS = (
    'license_key' = APP_SCHEMA.LOCID_LICENSE_KEY,
    'api_key'     = APP_SCHEMA.LOCID_API_KEY,
    'ns_guid'     = APP_SCHEMA.LOCID_NAMESPACE_GUID,
    'central_url' = APP_SCHEMA.LOCID_CENTRAL_URL
)
HANDLER = 'decrypt_handler'
AS $$
import json
import re
import time
import urllib.request
import urllib.error
import uuid

import snowflake.snowpark as snowpark
import _snowflake

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


def _get_license_context(session) -> dict:
    """Return non-secret license context (client_id).

    Refreshes via LOCID_FETCH_LICENSE if the cached license is older than 1 hour
    or missing. LOCID_FETCH_LICENSE writes/refreshes the crypto secrets directly
    into APP_SCHEMA.LOCID_BASE_SECRET, LOCID_SCHEME_SECRET, and
    LOCID_NAMESPACE_GUID; this proc reads namespace_guid from its SECRETS clause.
    """
    cached = _get_config(session, 'cached_license')
    if not (cached and cached[1] and time.time() - cached[1].timestamp() < 3600):
        # Cache stale or missing — delegate refresh to LOCID_FETCH_LICENSE
        try:
            session.call("APP_SCHEMA.LOCID_FETCH_LICENSE", "")
        except Exception as exc:
            raise RuntimeError(
                "License refresh failed. Check network connectivity to LocID Central "
                "and verify your license is still valid."
            ) from exc
        cached = _get_config(session, 'cached_license')
        if not cached or not cached[0]:
            raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    # Read non-secret fields from stripped cached JSON
    data     = json.loads(cached[0])
    lic_info = data.get('license', {})
    k_row    = _get_config(session, 'api_key_id')
    try:
        sel_id = int(k_row[0].strip()) if k_row and k_row[0] else None
    except (ValueError, AttributeError):
        sel_id = None

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
        'client_id': int(lic_info.get('client_id', 0)),
    }


def _check_entitlement(session, flag: str) -> None:
    cached = _get_config(session, 'cached_license')
    if not cached or not cached[0]:
        raise PermissionError("License not configured. Complete the Setup Wizard first.")

    data  = json.loads(cached[0])
    k_row = _get_config(session, 'api_key_id')
    try:
        sel = int(k_row[0].strip()) if k_row and k_row[0] else None
    except (ValueError, AttributeError):
        sel = None

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


def _resolve_ref_name(session, ref_name: str) -> str:
    """Resolve a reference binding to its fully-qualified consumer table name.

    Uses SYSTEM$GET_ALL_REFERENCES(name, TRUE) which returns a JSON array of
    {database, schema, name} objects. Falls back to 'reference(<ref_name>)' if
    resolution fails (e.g. reference not yet bound).
    """
    try:
        rows = session.sql(
            "SELECT SYSTEM$GET_ALL_REFERENCES(?, TRUE)", params=[ref_name]
        ).collect()
        if rows and rows[0][0]:
            bindings = json.loads(rows[0][0])
            if bindings:
                b = bindings[0]
                db, schema, name = b.get('database', ''), b.get('schema', ''), b.get('name', '')
                if db and schema and name:
                    return f"{db}.{schema}.{name}"
    except Exception:
        pass
    return f"reference({ref_name})"


def _entitled_cols(session, operation: str) -> list:
    active_flags = set()
    cached = _get_config(session, 'cached_license')
    if cached and cached[0]:
        data  = json.loads(cached[0])
        k_row = _get_config(session, 'api_key_id')
        try:
            sel = int(k_row[0].strip()) if k_row and k_row[0] else None
        except (ValueError, AttributeError):
            sel = None
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


def _timer(count: int, duration_ms: float) -> dict:
    """Build a Timer-shaped metric_value per the batch telemetry convention."""
    rate = count / (duration_ms / 1000.0) if count and duration_ms else 0
    mean = duration_ms / max(count, 1) if duration_ms else 0
    return {
        'count': count, 'meanRate': round(rate, 1),
        'oneMinuteRate': round(rate, 1), 'mean': round(mean, 5),
        'median': round(duration_ms), 'p95': round(duration_ms), 'p99': round(duration_ms),
    }


def _post_stats(session, job_id: str, client_id: int, rows_in: int,
                rows_matched: int, rows_out: int, phases: dict,
                tier_counts: dict, op: str, rows_skipped: int = 0) -> bool:
    """POST batch-metrics telemetry to LocID Central.
    Returns True on success, False on failure.
    Failure is logged to APP_LOGS (ERROR) and must be reflected in JOB_LOG by the caller.
    """
    api_key_val = _snowflake.get_generic_secret_string('api_key')
    lic_key_val = _snowflake.get_generic_secret_string('license_key')
    if not api_key_val or not lic_key_val:
        return True  # Nothing to post — not a failure

    identifier = f"{lic_key_val[:4]}****_{job_id}"
    ts_ms      = int(time.time() * 1000)
    client_str = str(client_id)
    base = {'identifier': identifier, 'source': 'snowflake-native-app',
            'timestamp': ts_ms, 'data_type': 'batch_metrics'}

    stats = []

    # batch-hits — one Counter per tier
    for tier_val, count in tier_counts.items():
        stats.append({**base, 'data': {
            'metric_key': f'batch-hits.{op}',
            'dimensions': {'api_key': api_key_val, 'client_id': client_str,
                           'tier': str(tier_val), 'job_id': job_id},
            'metric_value': count,
            'metric_datatype': 'Counter',
        }})

    # batch-outcomes (§4.3): matched always emitted; others only when non-zero.
    # unmatched excludes rows_skipped (invalid input) — they go to the 'invalid' bucket.
    # Integrity invariant: matched + unmatched + invalid == rows_in.
    unmatched = max(rows_in - rows_matched - rows_skipped, 0)
    for outcome, val, always in [
        ('matched',   rows_matched,  True),   # always emitted per §4.3
        ('unmatched', unmatched,     False),
        ('invalid',   rows_skipped,  False),  # rows skipped due to bad input format
    ]:
        if always or val > 0:
            stats.append({**base, 'data': {
                'metric_key': f'batch-outcomes.{op}',
                'dimensions': {'api_key': api_key_val, 'client_id': client_str,
                               'outcome': outcome, 'job_id': job_id},
                'metric_value': val,
                'metric_datatype': 'Counter',
            }})

    # batch-runtime — Timer per stage
    match_ms = phases.get('match_s', 0) * 1000
    udf_ms   = phases.get('udf_s', 0) * 1000
    write_ms = phases.get('write_s', 0) * 1000
    total_ms = phases.get('total_s', 0) * 1000

    for stage, dur_ms, cnt in [
        ('match', match_ms, rows_in),
        ('udf',   udf_ms,   rows_matched),
        ('write', write_ms,  rows_out),
        ('total', total_ms,  rows_in),
    ]:
        stats.append({**base, 'data': {
            'metric_key': f'batch-runtime.{op}',
            'dimensions': {'api_key': api_key_val, 'client_id': client_str,
                           'job_id': job_id, 'stage': stage},
            'metric_value': _timer(cnt, dur_ms),
            'metric_datatype': 'Timer',
        }})

    try:
        log_summary = json.dumps({
            'job_id': job_id, 'op': op,
            'rows_in': rows_in, 'rows_matched': rows_matched, 'rows_out': rows_out,
            'tier_counts': tier_counts,
            'phases': phases,
            'metrics_count': len(stats),
        })
        session.sql(
            "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
            params=['TELEMETRY', f'locid_{op}._post_stats', log_summary]
        ).collect()
    except Exception:
        pass  # Logging must not abort the job

    try:
        _central_url = _snowflake.get_generic_secret_string('central_url').strip().rstrip('/')
        req = urllib.request.Request(
            f'{_central_url}/stats',
            data=json.dumps(stats).encode(),
            headers={'Content-Type': 'application/json', 'de-access-token': api_key_val},
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10):
            pass
        return True
    except Exception as exc:
        try:
            session.sql(
                "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
                params=['ERROR', f'locid_{op}._post_stats', f'Stats POST failed: {exc}']
            ).collect()
        except Exception:
            pass
        return False


def _log_job_start(session, job_id, operation, input_table, warehouse) -> None:
    """Insert a STARTED row so the job is visible even if cancelled externally."""
    session.sql(
        "INSERT INTO APP_SCHEMA.JOB_LOG "
        "(job_id, operation, run_dt, rows_in, rows_matched, rows_out, runtime_s, "
        " status, error_msg, input_table, output_table, warehouse, output_cols) "
        "VALUES (?, ?, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, "
        "        NULL, NULL, NULL, NULL, 'STARTED', NULL, ?, NULL, ?, NULL)",
        params=[job_id, operation, input_table, warehouse],
    ).collect()


def _log_job_end(session, job_id, rows_in, rows_matched, rows_out,
                 runtime_s, status, error_msg, input_table, output_table,
                 output_cols) -> None:
    """Update the STARTED row with final outcome."""
    session.sql(
        "UPDATE APP_SCHEMA.JOB_LOG SET "
        "rows_in = ?, rows_matched = ?, rows_out = ?, runtime_s = ?, "
        "status = ?, error_msg = ?, input_table = ?, output_table = ?, output_cols = ? "
        "WHERE job_id = ?",
        params=[
            rows_in, rows_matched, rows_out, runtime_s,
            status, error_msg, input_table, output_table, json.dumps(output_cols),
            job_id,
        ]
    ).collect()



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
    client_id = 0  # resolved in Step 2; default used if job fails before that
    input_table_name = 'reference(DECRYPT_INPUT_TABLE)'  # fallback; resolved in try block

    job_sfx     = job_id.replace('-', '')[:12].upper()
    TBL_DECODED = f'APP_SCHEMA._LOCID_DECODED_{job_sfx}'
    _interim_tbls = [TBL_DECODED]

    # Auto-generate output table name: UTC timestamp + job suffix ensures uniqueness
    # even when two jobs start within the same UTC second.
    output_table = f"LOCID_DECRYPT_OUTPUT_{time.strftime('%Y%m%d_%H%M%S', time.gmtime())}_{job_sfx}"

    # CURRENT_WAREHOUSE() is blocked in Native App procs; warehouse is inherited
    # from the caller's session and cannot be queried or changed within the proc.
    cur_wh = None

    phases: dict = {}
    _pt = time.perf_counter()

    try:
        # Resolve consumer table name from reference binding for logging
        try:
            input_table_name = _resolve_ref_name(session, 'DECRYPT_INPUT_TABLE')
        except Exception:
            pass  # Keep fallback value if resolution fails

        # Record job start immediately — visible in Job History even if cancelled
        _log_job_start(session, job_id, 'DECRYPT', input_table_name, cur_wh)

        # Opportunistic log cleanup — non-fatal; runs quickly before main work
        try:
            session.sql("CALL APP_SCHEMA.LOCID_PURGE_LOGS()").collect()
        except Exception:
            pass

        # Validate caller-supplied identifiers before embedding in SQL
        for name in (id_col, txcloc_col):
            _validate_id(name)

        # ------------------------------------------------------------------
        # Step 1: Entitlement check
        # ------------------------------------------------------------------
        _check_entitlement(session, 'allow_decrypt')
        phases['entitlement_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 2: Fetch license context (client_id) + namespace_guid from secret.
        # Crypto secrets are bound directly to the UDFs (see locid_udf.sql)
        # and are NEVER read into proc-local variables or embedded in SQL.
        # ------------------------------------------------------------------
        sec        = _get_license_context(session)
        client_id  = sec['client_id']
        ns_guid    = _sql_lit(_snowflake.get_generic_secret_string('ns_guid'))

        rows_in = session.sql("SELECT COUNT(*) FROM reference('DECRYPT_INPUT_TABLE')").collect()[0][0]
        phases['secrets_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 3: Decode TX_CLOC → location_id, timestamp, enc_client_id
        #
        # Results are cached in a temp table to avoid re-running the UDF
        # three times (once per extracted field).
        #
        # LOCID_TXCLOC_DECRYPT reads scheme_secret from APP_SCHEMA.LOCID_SCHEME_SECRET
        # via its UDF-level SECRETS clause — no key is passed as an argument.
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_DECODED} AS
            SELECT
                {id_col}       AS _id,
                {txcloc_col}   AS _txcloc,
                PARSE_JSON(
                    APP_CODE.LOCID_TXCLOC_DECRYPT({txcloc_col})
                ) AS _decoded
            FROM reference('DECRYPT_INPUT_TABLE')
            WHERE {txcloc_col} IS NOT NULL
        """).collect()

        rows_matched = session.sql(
            f"SELECT COUNT(*) FROM {TBL_DECODED} WHERE _decoded IS NOT NULL"
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
        #   - tier is extracted from the decoded TX_CLOC payload.
        # Geo context: extracted from TX_CLOC if embedded at encrypt time.
        COL_SQL = {
            'stable_cloc': (
                f"APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN("
                f"  _decoded:base_loc_id::VARCHAR, {ns_guid}, "
                f"  {client_id}::INT, _decoded:enc_client_id::INT, "
                f"  COALESCE(_decoded:tier::VARCHAR, 'T0'))"
            ),
            # Geo context columns: extracted from decoded TX_CLOC payload
            'locid_country':      '_decoded:country::VARCHAR',
            'locid_country_code': '_decoded:country_code::VARCHAR',
            'locid_region':       '_decoded:region::VARCHAR',
            'locid_region_code':  '_decoded:region_code::VARCHAR',
            'locid_city':         '_decoded:city::VARCHAR',
            'locid_city_code':    '_decoded:city_code::VARCHAR',
            'locid_postal_code':  '_decoded:postal_code::VARCHAR',
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
            FROM {TBL_DECODED}
            WHERE _decoded IS NOT NULL
        """).collect()
        phases['udf_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_ADMIN"
        ).collect()
        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_VIEWER"
        ).collect()

        rows_out  = session.sql(f"SELECT COUNT(*) FROM APP_SCHEMA.{output_table}").collect()[0][0]
        phases['write_s'] = round(time.perf_counter() - _pt, 3)
        runtime_s = round(time.time() - start_ts, 2)
        phases['match_s'] = phases.get('decode_s', 0)
        phases['total_s'] = runtime_s

        # ------------------------------------------------------------------
        # Step 7: Log to JOB_LOG
        # ------------------------------------------------------------------
        _log_job_end(
            session, job_id, rows_in, rows_matched, rows_out,
            runtime_s, 'SUCCESS', None, input_table_name,
            f"APP_SCHEMA.{output_table}", active_cols,
        )

        # ------------------------------------------------------------------
        # Step 8: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        tier_counts = {}
        try:
            tier_rows = session.sql(
                f"SELECT COALESCE(_decoded:tier::VARCHAR, 'T0') AS tier, COUNT(*) "
                f"FROM {TBL_DECODED} WHERE _decoded IS NOT NULL GROUP BY tier"
            ).collect()
            for row in tier_rows:
                tier_counts[row[0] or 'T0'] = row[1]
        except Exception:
            tier_counts = {'T0': rows_matched}

        stats_ok = _post_stats(session, job_id, client_id, rows_in,
                               rows_matched, rows_out, phases, tier_counts, 'decrypt')
        if not stats_ok:
            _log_job_end(
                session, job_id, rows_in, rows_matched, rows_out,
                runtime_s, 'FAILED',
                f'Usage stats could not be posted to LocID Central. '
                f'Data was processed successfully — output table APP_SCHEMA.{output_table} was created.',
                input_table_name, f"APP_SCHEMA.{output_table}", active_cols,
            )

        return {
            'job_id':        job_id,
            'status':        'SUCCESS',
            'input_table':   input_table_name,
            'output_table':  f"APP_SCHEMA.{output_table}",
            'rows_in':       rows_in,
            'rows_matched':  rows_matched,
            'rows_out':      rows_out,
            'runtime_s':     runtime_s,
        }

    except Exception as exc:
        runtime_s = round(time.time() - start_ts, 2)
        phases['total_s'] = runtime_s
        try:
            session.sql(
                "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
                params=['ERROR', 'locid_decrypt.decrypt_handler', str(exc)]
            ).collect()
        except Exception:
            pass
        _log_job_end(
            session, job_id, rows_in, rows_matched, rows_out,
            runtime_s, 'FAILED', str(exc), input_table_name,
            f"APP_SCHEMA.{output_table}", [],
        )
        try:
            _post_stats(session, job_id, client_id, rows_in,
                        rows_matched, rows_out, phases, {'T0': rows_matched}, 'decrypt')
        except Exception:
            pass  # Error-path stats are best-effort — never suppress the original raise
        raise RuntimeError(f'LOCID_DECRYPT failed: {exc}') from exc

    finally:
        # Drop all interim work tables unconditionally (success or failure).
        for _t in _interim_tbls:
            try:
                session.sql(f"DROP TABLE IF EXISTS {_t}").collect()
            except Exception:
                pass
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_DECRYPT(
    VARCHAR, VARCHAR, ARRAY
) TO APPLICATION ROLE APP_ADMIN;


