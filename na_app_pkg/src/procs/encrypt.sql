-- =============================================================================
-- src/procs/encrypt.sql
-- LocID Native App — LOCID_ENCRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/encrypt.sql';
--
-- Workflow:
--   1. Validate entitlement (allow_encrypt)
--   2. Fetch license context (client_id) from cached license; namespace_guid from SECRET
--      Crypto secrets are bound directly to UDFs via SECRETS clauses — never embedded in SQL.
--   3. IPv4 matching — equi-join via LOCID_BUILDS_IPV4_EXPLODED
--   4. IPv6 matching — prefix_56 equi-join (Stage 1) + 5-pass wide-range cascade (Stage 2)
--   5. Call LOCID_TXCLOC_ENCRYPT (with geo context) + LOCID_STABLE_CLOC per matched row
--   6. Apply entitlement filter on output columns
--   7. CREATE OR REPLACE TABLE → customer output table
--   8. Log run to APP_SCHEMA.JOB_LOG
--   9. POST usage statistics to LocID Central
--
-- Provider data reference:
--   _PROVIDER_SCHEMA constant (below) must match the schema where LocID's shared
--   LOCID_BUILDS, LOCID_BUILDS_IPV4_EXPLODED, and LOCID_BUILD_DATES tables are
--   exposed via the app package's included share. Update before app deployment.
-- =============================================================================

-- Consumer references used by this procedure (declared in manifest.yml):
--   ENCRYPT_INPUT_TABLE — consumer input table; read via reference('ENCRYPT_INPUT_TABLE')
--
-- Output table: auto-generated in APP_SCHEMA as LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX.
-- The app owns APP_SCHEMA — no consumer GRANT needed.
-- SELECT is granted to APP_ADMIN and APP_VIEWER after creation.

-- Drop old 5-param overload to avoid ambiguous overloading with the new DEFAULT param.
DROP PROCEDURE IF EXISTS APP_SCHEMA.LOCID_ENCRYPT(VARCHAR, VARCHAR, VARCHAR, VARCHAR, ARRAY);

CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_ENCRYPT(
    ID_COL        VARCHAR,    -- column name for unique row identifier
    IP_COL        VARCHAR,    -- column name for IP address
    TS_COL        VARCHAR,    -- column name for timestamp
    TS_FORMAT     VARCHAR,    -- 'epoch_sec' | 'epoch_ms' | 'timestamp'
    OUTPUT_COLS   ARRAY,      -- requested output column names (empty = all entitled)
    ID_TO_VARCHAR BOOLEAN DEFAULT FALSE  -- TRUE = cast ID to VARCHAR in output; FALSE = preserve original type
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
HANDLER = 'encrypt_handler'
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
# Provider-shared table references.
# Must match the schema where LocID's LOCID data is exposed in the app package.
# Update this constant to match the final app package share configuration.
# =============================================================================
_PROVIDER_SCHEMA = 'LOCID_SHARE'

# =============================================================================
# Helpers (self-contained — no imports from utils/)
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
        # (proc writes fresh secrets to LOCID_BASE/SCHEME_SECRET and stripped JSON to APP_CONFIG)
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
    """Raise PermissionError if the active API key does not carry flag."""
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
    """Return ordered list of output column names the active license entitles."""
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
        ('invalid',   rows_skipped,  False),  # rows skipped due to bad IP/timestamp format
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

def encrypt_handler(
    session: snowpark.Session,
    id_col: str, ip_col: str, ts_col: str,
    ts_format: str, output_cols: list,
    id_to_varchar: bool = False,
) -> dict:

    job_id   = str(uuid.uuid4())
    start_ts = time.time()
    rows_in = rows_matched = rows_out = rows_skipped = 0
    client_id   = 0    # resolved in Step 2; default used if job fails before that
    tier_counts = {}   # populated after matching; default used if job fails before that
    input_table_name = 'reference(ENCRYPT_INPUT_TABLE)'  # fallback; resolved in try block

    # Auto-generate output table name: UTC timestamp + job suffix ensures uniqueness
    # even when two jobs start within the same UTC second.
    output_table = f"LOCID_ENCRYPT_OUTPUT_{time.strftime('%Y%m%d_%H%M%S', time.gmtime())}_{job_id.replace('-', '')[:12].upper()}"

    # Interim work tables — job-scoped TRANSIENT in APP_SCHEMA.
    # Native Apps prohibit TEMPORARY TABLE (session-scoped), so we use TRANSIENT
    # tables with a unique suffix derived from job_id, dropped in the finally block.
    job_sfx       = job_id.replace('-', '')[:12].upper()
    TBL_IPV4      = f'APP_SCHEMA._LOCID_IPV4_{job_sfx}'
    TBL_V6_INP    = f'APP_SCHEMA._LOCID_V6_INP_{job_sfx}'
    TBL_V6_DATED  = f'APP_SCHEMA._LOCID_V6_DATD_{job_sfx}'
    TBL_V6_RANGE  = f'APP_SCHEMA._LOCID_V6_RNG_{job_sfx}'
    TBL_IPV6      = f'APP_SCHEMA._LOCID_IPV6_{job_sfx}'
    TBL_V6_WIDE   = f'APP_SCHEMA._LOCID_V6_WIDE_{job_sfx}'
    TBL_V6_UNMTCH = f'APP_SCHEMA._LOCID_V6_UNMT_{job_sfx}'
    TBL_V6_SEEN   = f'APP_SCHEMA._LOCID_V6_SEEN_{job_sfx}'
    TBL_MATCHED   = f'APP_SCHEMA._LOCID_MTCHD_{job_sfx}'
    _interim_tbls = [
        TBL_IPV4, TBL_V6_INP, TBL_V6_DATED,
        TBL_V6_RANGE, TBL_IPV6, TBL_V6_WIDE,
        TBL_V6_UNMTCH, TBL_V6_SEEN, TBL_MATCHED,
    ]

    # CURRENT_WAREHOUSE() is blocked in Native App procs; warehouse is inherited
    # from the caller's session and cannot be queried or changed within the proc.
    cur_wh = None

    BUILDS    = f'{_PROVIDER_SCHEMA}.LOCID_BUILDS'
    BUILDS_V4 = f'{_PROVIDER_SCHEMA}.LOCID_BUILDS_IPV4_EXPLODED'
    BUILDS_V6 = f'{_PROVIDER_SCHEMA}.LOCID_BUILDS_IPV6_EXPLODED'
    DATES     = f'{_PROVIDER_SCHEMA}.LOCID_BUILD_DATES'

    phases: dict = {}
    _pt = time.perf_counter()

    try:
        # Resolve consumer table name from reference binding for logging
        try:
            input_table_name = _resolve_ref_name(session, 'ENCRYPT_INPUT_TABLE')
        except Exception:
            pass  # Keep fallback value if resolution fails

        # Record job start immediately — visible in Job History even if cancelled
        _log_job_start(session, job_id, 'ENCRYPT', input_table_name, cur_wh)

        # Opportunistic log cleanup — non-fatal; runs quickly before main work
        try:
            session.sql("CALL APP_SCHEMA.LOCID_PURGE_LOGS()").collect()
        except Exception:
            pass

        # Validate caller-supplied identifiers before embedding in SQL
        for name in (id_col, ip_col, ts_col):
            _validate_id(name)

        # ------------------------------------------------------------------
        # Step 1: Entitlement check
        # ------------------------------------------------------------------
        _check_entitlement(session, 'allow_encrypt')
        phases['entitlement_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 2: Fetch license context (client_id) + namespace_guid from secret.
        # Crypto secrets are bound directly to the UDFs (see locid_udf.sql)
        # and are NEVER read into proc-local variables or embedded in SQL.
        # ------------------------------------------------------------------
        sec       = _get_license_context(session)
        client_id = sec['client_id']                  # int — embedded directly
        ns_guid   = _sql_lit(_snowflake.get_generic_secret_string('ns_guid'))

        rows_in = session.sql("SELECT COUNT(*) FROM reference('ENCRYPT_INPUT_TABLE')").collect()[0][0]

        # Timestamp → epoch-seconds SQL expression
        # TRY_CAST is forbidden between numeric types (e.g. NUMBER(38,5) → BIGINT).
        # For epoch_ms and epoch_sec, probe with LIMIT 0 first: if TRY_CAST compiles
        # the column is string-compatible and TRY_ error-tolerance is preserved;
        # if it fails the column is numeric and a direct ::BIGINT cast is used instead.
        if ts_format == 'epoch_ms':
            try:
                session.sql(
                    f"SELECT TRY_CAST({ts_col} AS BIGINT) "
                    f"FROM reference('ENCRYPT_INPUT_TABLE') LIMIT 0"
                ).collect()
                ts_expr = f"FLOOR(TRY_CAST({ts_col} AS BIGINT) / 1000)::BIGINT"
            except Exception:
                ts_expr = f"FLOOR({ts_col}::BIGINT / 1000)::BIGINT"
        elif ts_format == 'timestamp':
            # Probe the actual column type using a zero-row compile check.
            # TRY_CAST(col AS TIMESTAMP_NTZ) raises a SQL compilation error when col
            # is already TIMESTAMP_NTZ (Snowflake disallows same-type TRY_CAST).
            # If the probe succeeds → col is VARCHAR/other → use TRY_CAST (safe NULL on bad values).
            # If the probe errors  → col is TIMESTAMP → use DATE_PART directly (no cast, no round-trip).
            try:
                session.sql(
                    f"SELECT TRY_CAST({ts_col} AS TIMESTAMP_NTZ) "
                    f"FROM reference('ENCRYPT_INPUT_TABLE') LIMIT 0"
                ).collect()
                ts_expr = f"DATE_PART(epoch_second, TRY_CAST({ts_col} AS TIMESTAMP_NTZ))::BIGINT"
            except Exception:
                ts_expr = f"DATE_PART(epoch_second, {ts_col})::BIGINT"
        else:   # epoch_sec (default)
            try:
                session.sql(
                    f"SELECT TRY_CAST({ts_col} AS BIGINT) "
                    f"FROM reference('ENCRYPT_INPUT_TABLE') LIMIT 0"
                ).collect()
                ts_expr = f"TRY_CAST({ts_col} AS BIGINT)"
            except Exception:
                ts_expr = f"{ts_col}::BIGINT"

        # Count rows with valid timestamps; difference = skipped due to invalid ts
        rows_valid_ts = session.sql(
            f"SELECT COUNT(*) FROM reference('ENCRYPT_INPUT_TABLE') WHERE {ts_expr} IS NOT NULL"
        ).collect()[0][0]
        rows_skipped = rows_in - rows_valid_ts

        phases['secrets_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 3: IPv4 matching — equi-join via LOCID_BUILDS_IPV4_EXPLODED
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_IPV4} AS
            WITH inp AS (
                SELECT {id_col} AS _id, {ip_col} AS _ip, {ts_expr} AS _ts
                FROM reference('ENCRYPT_INPUT_TABLE')
                WHERE {ip_col} NOT LIKE '%:%'
                  AND {ts_expr} IS NOT NULL
            ),
            rel_builds AS (
                SELECT DISTINCT b.build_dt
                FROM {DATES} b
                JOIN inp i ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN b.start_dt AND b.end_dt
            ),
            fv4 AS (
                SELECT l.*
                FROM {BUILDS_V4} l
                JOIN rel_builds rb ON l.build_dt = rb.build_dt
            )
            SELECT
                TO_VARCHAR(i._id) AS _id, i._ip, i._ts,
                lb.encrypted_locid, lb.tier,
                lb.locid_country,      lb.locid_country_code,
                lb.locid_region,       lb.locid_region_code,
                lb.locid_city,         lb.locid_city_code,
                lb.locid_postal_code,  lb.locid_horizontal_accuracy,
                lb.build_dt
            FROM inp i
            JOIN {DATES} b
                ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN b.start_dt AND b.end_dt
            JOIN fv4 l
                ON b.build_dt = l.build_dt AND i._ip = l.ip_address
            JOIN {BUILDS} lb
                ON l.build_dt = lb.build_dt
               AND l.start_ip = lb.start_ip
               AND l.end_ip   = lb.end_ip
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY lb.build_dt DESC) = 1
        """).collect()
        phases['ipv4_match_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 4: IPv6 matching — prefix_56 equi-join (Stage 1) + 5-pass wide-range cascade (Stage 2)
        #
        # Performance strategy:
        #
        #   Stage 1a: Equi-join + range filter against LOCID_BUILDS_IPV6_EXPLODED
        #             (prefix_56 + BETWEEN). Materialise in TBL_V6_RANGE so Snowflake
        #             can optimise the geo-context lookup independently.
        #             Split confirmed significant speedup by client (Ryan Bessey, 2026-05-27).
        #
        #   Stage 1b: Join TBL_V6_RANGE to LOCID_BUILDS for geo context. QUALIFY
        #             deduplicates per _id.
        #
        #   Stage 2:  5-pass cascading fallback for IDs unmatched in Stage 1.
        #             Wide ranges (span > /48) are excluded from the exploded table.
        #             Pre-materialise candidates (TBL_V6_WIDE) and unmatched inputs
        #             (TBL_V6_UNMTCH), then cascade through progressively shorter
        #             shared-prefix equi-joins (prefix 10→8→6→4→pure BETWEEN).
        #             Each pass narrows candidates via equi-join before BETWEEN,
        #             and TBL_V6_SEEN prevents re-processing already-matched IDs.
        #             Benchmarked by client (Ryan Bessey, 2026-06-01):
        #               1 M rows → 8 min, 10 M → 9 min, 100 M → 14 min (Large WH).
        # ------------------------------------------------------------------

        # 4-a: IPv6 input with ip_hex pre-computed
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_INP} AS
            SELECT
                {id_col}  AS _id,
                {ip_col}  AS _ip,
                {ts_expr} AS _ts,
                GET_PATH(PARSE_IP({ip_col}, 'INET'), 'hex_ipv6') AS ip_hex
            FROM reference('ENCRYPT_INPUT_TABLE')
            WHERE {ip_col} LIKE '%:%'
              AND {ts_expr} IS NOT NULL
        """).collect()

        # 4-b: Pre-join each input row to its matching build_dt
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_DATED} AS
            SELECT i._id, i._ip, i._ts, i.ip_hex, bd.build_dt
            FROM {TBL_V6_INP} i
            JOIN {DATES} bd
                ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN bd.start_dt AND bd.end_dt
        """).collect()

        # Create empty IPv6 results accumulator
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_IPV6} (
                _id VARCHAR, _ip VARCHAR, _ts BIGINT,
                encrypted_locid VARCHAR, tier VARCHAR,
                locid_country VARCHAR,      locid_country_code VARCHAR,
                locid_region  VARCHAR,      locid_region_code  VARCHAR,
                locid_city    VARCHAR,      locid_city_code    VARCHAR,
                locid_postal_code VARCHAR,  locid_horizontal_accuracy VARCHAR,
                build_dt DATE
            )
        """).collect()

        # Stage 1a: equi-join + range filter against LOCID_BUILDS_IPV6_EXPLODED.
        # Materialise the range-join result first so Snowflake can optimise the
        # geo-context lookup (join to LOCID_BUILDS) independently.
        # Split suggested by client (Ryan Bessey) — confirmed significant speedup.
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_RANGE} AS
            SELECT i._id, i._ip, i._ts,
                e.build_dt, e.start_ip, e.end_ip
            FROM {TBL_V6_DATED} i
            JOIN {BUILDS_V6} e
                ON  i.build_dt = e.build_dt
                AND SUBSTR(i.ip_hex, 1, 14) = e.prefix_56
                AND i.ip_hex BETWEEN e.start_ip_int_hex AND e.end_ip_int_hex
        """).collect()

        # Stage 1b: join the materialised range results to LOCID_BUILDS to get geo context.
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                lb.encrypted_locid, lb.tier,
                lb.locid_country,      lb.locid_country_code,
                lb.locid_region,       lb.locid_region_code,
                lb.locid_city,         lb.locid_city_code,
                lb.locid_postal_code,  lb.locid_horizontal_accuracy,
                lb.build_dt
            FROM {TBL_V6_RANGE} i
            JOIN {BUILDS} lb
                ON  i.build_dt = lb.build_dt
                AND i.start_ip  = lb.start_ip
                AND i.end_ip    = lb.end_ip
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY lb.build_dt DESC) = 1
        """).collect()

        # Stage 2: 5-pass cascading fallback for IDs unmatched in Stage 1.
        # Pre-materialise wide-range candidates and unmatched inputs, then cascade
        # through progressively shorter shared-prefix equi-joins so each pass uses
        # an equi-join to narrow candidates before the BETWEEN range filter.
        # TBL_V6_SEEN accumulates matched _ids across passes to skip re-processing.
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_WIDE} AS
            SELECT *
            FROM {BUILDS} l
            WHERE l.start_ip LIKE '%:%'
              AND SUBSTR(l.start_ip_int_hex, 1, 12) != SUBSTR(l.end_ip_int_hex, 1, 12)
              AND l.build_dt IN (SELECT DISTINCT build_dt FROM {TBL_V6_DATED})
            ORDER BY l.build_dt, l.start_ip_int_hex
        """).collect()

        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_UNMTCH} AS
            SELECT i.*
            FROM {TBL_V6_DATED} i
            LEFT JOIN {TBL_IPV6} matched ON i._id = matched._id
            WHERE matched._id IS NULL
        """).collect()

        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_SEEN} (_id VARCHAR)
        """).collect()

        # Pass 1 — prefix 10 chars (/40 boundary)
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                l.encrypted_locid, l.tier,
                l.locid_country,      l.locid_country_code,
                l.locid_region,       l.locid_region_code,
                l.locid_city,         l.locid_city_code,
                l.locid_postal_code,  l.locid_horizontal_accuracy,
                l.build_dt
            FROM {TBL_V6_UNMTCH} i
            JOIN {TBL_V6_WIDE} l
                ON  i.build_dt = l.build_dt
                AND SUBSTR(i.ip_hex, 1, 10) = SUBSTR(l.start_ip_int_hex, 1, 10)
                AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            WHERE SUBSTR(l.start_ip_int_hex, 1, 10) = SUBSTR(l.end_ip_int_hex, 1, 10)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
        """).collect()

        # Seed SEEN with all matched so far (Stage 1 + Pass 1)
        session.sql(f"""
            INSERT INTO {TBL_V6_SEEN}
            SELECT DISTINCT _id FROM {TBL_IPV6}
        """).collect()

        # Pass 2 — prefix 8 chars (/32 boundary)
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                l.encrypted_locid, l.tier,
                l.locid_country,      l.locid_country_code,
                l.locid_region,       l.locid_region_code,
                l.locid_city,         l.locid_city_code,
                l.locid_postal_code,  l.locid_horizontal_accuracy,
                l.build_dt
            FROM {TBL_V6_UNMTCH} i
            LEFT JOIN {TBL_V6_SEEN} xs ON i._id = xs._id
            JOIN {TBL_V6_WIDE} l
                ON  i.build_dt = l.build_dt
                AND SUBSTR(i.ip_hex, 1, 8) = SUBSTR(l.start_ip_int_hex, 1, 8)
                AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            WHERE xs._id IS NULL
              AND SUBSTR(l.start_ip_int_hex, 1, 8) = SUBSTR(l.end_ip_int_hex, 1, 8)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
        """).collect()

        session.sql(f"""
            INSERT INTO {TBL_V6_SEEN}
            SELECT DISTINCT _id FROM {TBL_IPV6}
            EXCEPT SELECT _id FROM {TBL_V6_SEEN}
        """).collect()

        # Pass 3 — prefix 6 chars (/24 boundary)
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                l.encrypted_locid, l.tier,
                l.locid_country,      l.locid_country_code,
                l.locid_region,       l.locid_region_code,
                l.locid_city,         l.locid_city_code,
                l.locid_postal_code,  l.locid_horizontal_accuracy,
                l.build_dt
            FROM {TBL_V6_UNMTCH} i
            LEFT JOIN {TBL_V6_SEEN} xs ON i._id = xs._id
            JOIN {TBL_V6_WIDE} l
                ON  i.build_dt = l.build_dt
                AND SUBSTR(i.ip_hex, 1, 6) = SUBSTR(l.start_ip_int_hex, 1, 6)
                AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            WHERE xs._id IS NULL
              AND SUBSTR(l.start_ip_int_hex, 1, 6) = SUBSTR(l.end_ip_int_hex, 1, 6)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
        """).collect()

        session.sql(f"""
            INSERT INTO {TBL_V6_SEEN}
            SELECT DISTINCT _id FROM {TBL_IPV6}
            EXCEPT SELECT _id FROM {TBL_V6_SEEN}
        """).collect()

        # Pass 4 — prefix 4 chars (/16 boundary)
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                l.encrypted_locid, l.tier,
                l.locid_country,      l.locid_country_code,
                l.locid_region,       l.locid_region_code,
                l.locid_city,         l.locid_city_code,
                l.locid_postal_code,  l.locid_horizontal_accuracy,
                l.build_dt
            FROM {TBL_V6_UNMTCH} i
            LEFT JOIN {TBL_V6_SEEN} xs ON i._id = xs._id
            JOIN {TBL_V6_WIDE} l
                ON  i.build_dt = l.build_dt
                AND SUBSTR(i.ip_hex, 1, 4) = SUBSTR(l.start_ip_int_hex, 1, 4)
                AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            WHERE xs._id IS NULL
              AND SUBSTR(l.start_ip_int_hex, 1, 4) = SUBSTR(l.end_ip_int_hex, 1, 4)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
        """).collect()

        session.sql(f"""
            INSERT INTO {TBL_V6_SEEN}
            SELECT DISTINCT _id FROM {TBL_IPV6}
            EXCEPT SELECT _id FROM {TBL_V6_SEEN}
        """).collect()

        # Pass 5 — pure BETWEEN, no equi-join (truly global ranges only)
        session.sql(f"""
            INSERT INTO {TBL_IPV6}
            SELECT i._id, i._ip, i._ts,
                l.encrypted_locid, l.tier,
                l.locid_country,      l.locid_country_code,
                l.locid_region,       l.locid_region_code,
                l.locid_city,         l.locid_city_code,
                l.locid_postal_code,  l.locid_horizontal_accuracy,
                l.build_dt
            FROM {TBL_V6_UNMTCH} i
            LEFT JOIN {TBL_V6_SEEN} xs ON i._id = xs._id
            JOIN {TBL_V6_WIDE} l
                ON  i.build_dt = l.build_dt
                AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            WHERE xs._id IS NULL
            QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
        """).collect()

        # Combine IPv4 and IPv6 results
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_MATCHED} AS
            SELECT * FROM {TBL_IPV4}
            UNION ALL
            SELECT * FROM {TBL_IPV6}
        """).collect()

        rows_matched = session.sql(
            f"SELECT COUNT(*) FROM {TBL_MATCHED}"
        ).collect()[0][0]
        phases['ipv6_match_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 5: Apply UDFs — TX_CLOC and STABLE_CLOC
        # Step 6: Apply entitlement filter on output columns
        # ------------------------------------------------------------------
        entitled  = _entitled_cols(session, 'encrypt')
        requested = set(output_cols) if output_cols else set(entitled)
        active_cols = [c for c in entitled if c in requested]

        # Map output column name → SQL expression over _locid_matched columns.
        # TX_CLOC: uses OBJECT_CONSTRUCT to build JSON with geo context fields.
        #   OBJECT_CONSTRUCT automatically drops NULL-valued keys, so absent geo
        #   fields produce clean JSON. NetAcuity numeric codes must be VARCHAR.
        # STABLE_CLOC: for the encrypt path both client IDs are the same value
        # (publisher = consumer; see developer-integration-guide.md)
        #
        # Crypto keys are NOT embedded — the UDFs read them from secrets.
        COL_SQL = {
            'tx_cloc': (
                f"APP_CODE.LOCID_TXCLOC_ENCRYPT("
                f"  OBJECT_CONSTRUCT("
                f"    'base_loc_id',         APP_CODE.LOCID_BASE_DECRYPT(encrypted_locid),"
                f"    'timestamp',           _ts,"
                f"    'enc_client_id',       {client_id},"
                f"    'country',             locid_country,"
                f"    'region',              locid_region,"
                f"    'city',                locid_city,"
                f"    'postal_code',         locid_postal_code,"
                f"    'country_code',        locid_country_code::VARCHAR,"
                f"    'region_code',         locid_region_code::VARCHAR,"
                f"    'city_code',           locid_city_code::VARCHAR,"
                f"    'horizontal_accuracy', locid_horizontal_accuracy::VARCHAR,"
                f"    'tier',                tier"
                f"  )::VARCHAR"
                f")"
            ),
            'stable_cloc': (
                f"APP_CODE.LOCID_STABLE_CLOC("
                f"  encrypted_locid, {ns_guid}, "
                f"  {client_id}::INT, {client_id}::INT, tier)"
            ),
            'locid_country':      'locid_country',
            'locid_country_code': 'locid_country_code',
            'locid_region':       'locid_region',
            'locid_region_code':  'locid_region_code',
            'locid_city':         'locid_city',
            'locid_city_code':    'locid_city_code',
            'locid_postal_code':  'locid_postal_code',
        }

        # ID output: strip trailing decimal for integer-valued numeric IDs (e.g. 12345.0 → '12345').
        # TRY_CAST(non-string AS NUMBER) is forbidden by Snowflake, and TRY_CAST on a
        # decimal string like '5.123' rounds silently to 5 instead of returning NULL.
        # Solution: convert _id to VARCHAR first (safe for FLOAT, NUMBER, or VARCHAR input),
        # then use REGEXP_LIKE to gate the cast — only strings that are truly integer-valued
        # (digits only, or digits + decimal followed solely by zeros) are cast to NUMBER.
        # All other values (e.g. '5.123') fall through unchanged.
        id_expr = (
            f"""CASE
                WHEN REGEXP_LIKE(TO_VARCHAR(_id), '-?[0-9]+([.][0]+)?')
                THEN TO_VARCHAR(TRY_CAST(TO_VARCHAR(_id) AS NUMBER(38,0)))
                ELSE TO_VARCHAR(_id)
            END AS {id_col}"""
            if id_to_varchar else f"_id AS {id_col}"
        )
        select_exprs = [id_expr] + [
            f"{COL_SQL.get(c, c)} AS {c}" for c in active_cols
        ]

        # ------------------------------------------------------------------
        # Step 7: Write output table into APP_SCHEMA and grant read access
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TABLE APP_SCHEMA.{output_table} AS
            SELECT {', '.join(select_exprs)}
            FROM {TBL_MATCHED}
        """).collect()
        phases['udf_s'] = round(time.perf_counter() - _pt, 3)

        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_ADMIN"
        ).collect()
        session.sql(
            f"GRANT SELECT ON TABLE APP_SCHEMA.{output_table} TO APPLICATION ROLE APP_VIEWER"
        ).collect()

        _pt = time.perf_counter()
        rows_out  = session.sql(f"SELECT COUNT(*) FROM APP_SCHEMA.{output_table}").collect()[0][0]
        phases['write_s'] = round(time.perf_counter() - _pt, 3)
        runtime_s = round(time.time() - start_ts, 2)
        phases['match_s'] = round(phases.get('ipv4_match_s', 0) + phases.get('ipv6_match_s', 0), 3)
        phases['total_s'] = runtime_s

        # ------------------------------------------------------------------
        # Step 8: Log to JOB_LOG
        # ------------------------------------------------------------------
        _log_job_end(
            session, job_id, rows_in, rows_matched, rows_out,
            runtime_s, 'SUCCESS', None, input_table_name,
            f"APP_SCHEMA.{output_table}", active_cols,
        )

        # ------------------------------------------------------------------
        # Step 9: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        tier_counts = {}
        try:
            tier_rows = session.sql(
                f"SELECT tier, COUNT(*) FROM {TBL_MATCHED} GROUP BY tier"
            ).collect()
            for row in tier_rows:
                tier_counts[row[0] or 'T0'] = row[1]
        except Exception:
            tier_counts = {'T0': rows_matched}

        stats_ok = _post_stats(session, job_id, client_id, rows_in,
                               rows_matched, rows_out, phases, tier_counts, 'encrypt',
                               rows_skipped=rows_skipped)
        if not stats_ok:
            _log_job_end(
                session, job_id, rows_in, rows_matched, rows_out,
                runtime_s, 'FAILED',
                f'Usage stats could not be posted to LocID Central. '
                f'Data was processed successfully — output table APP_SCHEMA.{output_table} was created.',
                input_table_name, f"APP_SCHEMA.{output_table}", active_cols,
            )

        result = {
            'job_id':        job_id,
            'status':        'SUCCESS',
            'input_table':   input_table_name,
            'output_table':  f"APP_SCHEMA.{output_table}",
            'rows_in':       rows_in,
            'rows_matched':  rows_matched,
            'rows_out':      rows_out,
            'rows_skipped_invalid_ts': rows_skipped,
            'runtime_s':     runtime_s,
        }
        if rows_skipped > 0:
            result['warnings'] = [
                f"{rows_skipped} row(s) skipped due to invalid timestamp values"
            ]
        return result

    except Exception as exc:
        runtime_s = round(time.time() - start_ts, 2)
        phases['total_s'] = runtime_s
        try:
            session.sql(
                "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
                params=['ERROR', 'locid_encrypt.encrypt_handler', str(exc)]
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
                        rows_matched, rows_out, phases, tier_counts, 'encrypt',
                        rows_skipped=rows_skipped)
        except Exception:
            pass  # Error-path stats are best-effort — never suppress the original raise
        raise RuntimeError(f'LOCID_ENCRYPT failed: {exc}') from exc
    finally:
        # Drop all interim work tables unconditionally (success or failure).
        for _t in _interim_tbls:
            try:
                session.sql(f"DROP TABLE IF EXISTS {_t}").collect()
            except Exception:
                pass
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_ENCRYPT(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, ARRAY, BOOLEAN
) TO APPLICATION ROLE APP_ADMIN;
