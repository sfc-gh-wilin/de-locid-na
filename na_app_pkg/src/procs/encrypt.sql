-- =============================================================================
-- src/procs/encrypt.sql
-- LocID Native App — LOCID_ENCRYPT Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/encrypt.sql';
--
-- Workflow:
--   1. Validate entitlement (allow_encrypt)
--   2. Fetch base_locid_secret + scheme_secret from LocID Central (cached)
--   3. IPv4 matching — equi-join via LOCID_BUILDS_IPV4_EXPLODED
--   4. IPv6 matching — 6-pass cascading hex-prefix range join
--   5. Call LOCID_TXCLOC_ENCRYPT + LOCID_STABLE_CLOC per matched row
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
--   APP_WAREHOUSE       — warehouse for job execution; set via
--                         USE WAREHOUSE reference('APP_WAREHOUSE') at proc start.
--
-- Output table: auto-generated in APP_SCHEMA as LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS.
-- The app owns APP_SCHEMA — no consumer GRANT needed.
-- SELECT is granted to APP_ADMIN and APP_VIEWER after creation.
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_ENCRYPT(
    ID_COL        VARCHAR,    -- column name for unique row identifier
    IP_COL        VARCHAR,    -- column name for IP address
    TS_COL        VARCHAR,    -- column name for timestamp
    TS_FORMAT     VARCHAR,    -- 'epoch_sec' | 'epoch_ms' | 'timestamp'
    OUTPUT_COLS   ARRAY       -- requested output column names (empty = all entitled)
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
SECRETS = (
    'license_key'   = APP_SCHEMA.LOCID_LICENSE_KEY,
    'api_key'       = APP_SCHEMA.LOCID_API_KEY,
    'base_secret'   = APP_SCHEMA.LOCID_BASE_SECRET,
    'scheme_secret' = APP_SCHEMA.LOCID_SCHEME_SECRET
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


def _get_secrets(session) -> dict:
    """Return license secrets. Refreshes via LOCID_FETCH_LICENSE if cache is > 1 hour old.
    Crypto secrets are read from Snowflake SECRETs via _snowflake module — never from APP_CONFIG.
    """
    cached = _get_config(session, 'cached_license')
    if not (cached and cached[1] and time.time() - cached[1].timestamp() < 3600):
        # Cache stale or missing — delegate refresh to LOCID_FETCH_LICENSE
        # (proc writes fresh secrets to LOCID_BASE/SCHEME_SECRET and stripped JSON to APP_CONFIG)
        session.call("APP_SCHEMA.LOCID_FETCH_LICENSE", "")
        cached = _get_config(session, 'cached_license')
        if not cached or not cached[0]:
            raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    # Read crypto secrets from Snowflake SECRETs (never from APP_CONFIG)
    base_locid_secret = _snowflake.get_generic_secret_string('base_secret')
    scheme_secret     = _snowflake.get_generic_secret_string('scheme_secret')

    # Read non-secret fields from stripped cached JSON
    data     = json.loads(cached[0])
    lic_info = data.get('license', {})
    k_row    = _get_config(session, 'api_key_id')
    sel_id   = int(k_row[0]) if k_row and k_row[0] else None

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
        'base_locid_secret': base_locid_secret,
        'scheme_secret':     scheme_secret,
        'client_id':         int(lic_info.get('client_id', 0)),
        'namespace_guid':    entry.get('namespace_guid', ''),
    }


def _check_entitlement(session, flag: str) -> None:
    """Raise PermissionError if the active API key does not carry flag."""
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
    """Return ordered list of output column names the active license entitles."""
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
    """POST usage stats to LocID Central. Non-blocking — silently ignores failures."""
    api_key_val = _snowflake.get_generic_secret_string('api_key')
    lic_key_val = _snowflake.get_generic_secret_string('license_key')
    if not api_key_val or not lic_key_val:
        return

    payload = json.dumps([{
        'identifier': lic_key_val,
        'source':     'snowflake-native-app',
        'timestamp':  int(time.time() * 1000),
        'data_type':  'usage_metrics',
        'data': {
            'metric_key':      metric_key,
            'dimensions':      {'api_key': api_key_val, 'hit': 1, 'tier': 0},
            'metric_value':    rows_processed,
            'metric_datatype': 'Long',
        },
    }]).encode()

    try:
        req = urllib.request.Request(
            'https://central.locid.com/api/0/location_id/stats',
            data=payload,
            headers={'Content-Type': 'application/json', 'de-access-token': api_key_val},
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception:
        pass  # Stats failure must not abort the job


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
            "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
            params=['PERF', 'locid_encrypt._log_perf', msg]
        ).collect()
    except Exception:
        pass  # Perf logging must not abort the job


# =============================================================================
# Main handler
# =============================================================================

def encrypt_handler(
    session: snowpark.Session,
    id_col: str, ip_col: str, ts_col: str,
    ts_format: str, output_cols: list,
) -> dict:

    job_id   = str(uuid.uuid4())
    start_ts = time.time()
    rows_in = rows_matched = rows_out = 0

    # Auto-generate output table name in APP_SCHEMA (UTC timestamp)
    output_table = f"LOCID_ENCRYPT_OUTPUT_{time.strftime('%Y%m%d_%H%M%S', time.gmtime())}"

    # Interim work tables — job-scoped TRANSIENT in APP_SCHEMA.
    # Native Apps prohibit TEMPORARY TABLE (session-scoped), so we use TRANSIENT
    # tables with a unique suffix derived from job_id, dropped in the finally block.
    job_sfx       = job_id.replace('-', '')[:12].upper()
    TBL_IPV4      = f'APP_SCHEMA._LOCID_IPV4_{job_sfx}'
    TBL_V6_INP    = f'APP_SCHEMA._LOCID_V6_INP_{job_sfx}'
    TBL_V6_BUILDS = f'APP_SCHEMA._LOCID_V6_BLDS_{job_sfx}'
    TBL_V6_DATED  = f'APP_SCHEMA._LOCID_V6_DATD_{job_sfx}'
    TBL_IPV6      = f'APP_SCHEMA._LOCID_IPV6_{job_sfx}'
    TBL_V6_SEEN   = f'APP_SCHEMA._LOCID_V6_SEEN_{job_sfx}'
    TBL_MATCHED   = f'APP_SCHEMA._LOCID_MTCHD_{job_sfx}'
    _interim_tbls = [
        TBL_IPV4, TBL_V6_INP, TBL_V6_BUILDS, TBL_V6_DATED,
        TBL_IPV6, TBL_V6_SEEN, TBL_MATCHED,
    ]

    # Validate caller-supplied identifiers before embedding in SQL
    for name in (id_col, ip_col, ts_col):
        _validate_id(name)

    cur_wh = None  # resolved after APP_WAREHOUSE reference is set (Step 0)

    BUILDS    = f'{_PROVIDER_SCHEMA}.LOCID_BUILDS'
    BUILDS_V4 = f'{_PROVIDER_SCHEMA}.LOCID_BUILDS_IPV4_EXPLODED'
    DATES     = f'{_PROVIDER_SCHEMA}.LOCID_BUILD_DATES'

    phases: dict = {}
    _pt = time.perf_counter()

    try:
        # ------------------------------------------------------------------
        # Step 0: Set job warehouse from bound APP_WAREHOUSE reference
        # ------------------------------------------------------------------
        session.sql("USE WAREHOUSE reference('APP_WAREHOUSE')").collect()
        cur_wh = 'APP_WAREHOUSE'   # CURRENT_WAREHOUSE() is not permitted in Native App procs
        phases['warehouse_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # Opportunistic log cleanup — non-fatal; runs quickly before main work
        try:
            session.sql("CALL APP_SCHEMA.LOCID_PURGE_LOGS()").collect()
        except Exception:
            pass

        # ------------------------------------------------------------------
        # Step 1: Entitlement check
        # ------------------------------------------------------------------
        _check_entitlement(session, 'allow_encrypt')
        phases['entitlement_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 2: Fetch secrets from LocID Central (cached)
        # NOTE: Secrets are embedded in UDF calls as SQL string literals and
        #       will appear in Snowflake query history. They are not persisted
        #       in any table. This is an acceptable v1 trade-off.
        # ------------------------------------------------------------------
        sec        = _get_secrets(session)
        base_key   = _sql_lit(sec['base_locid_secret'])
        scheme_key = _sql_lit(sec['scheme_secret'])
        client_id  = sec['client_id']          # int — embedded directly
        ns_guid    = _sql_lit(sec['namespace_guid'])

        rows_in = session.sql("SELECT COUNT(*) FROM reference('ENCRYPT_INPUT_TABLE')").collect()[0][0]

        # Timestamp → epoch-seconds SQL expression
        if ts_format == 'epoch_ms':
            ts_expr = f"FLOOR({ts_col}::DOUBLE / 1000.0)::BIGINT"
        elif ts_format == 'timestamp':
            ts_expr = f"DATE_PART(epoch_second, {ts_col}::TIMESTAMP_NTZ)::BIGINT"
        else:   # epoch_sec (default)
            ts_expr = f"{ts_col}::BIGINT"

        phases['secrets_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 2b: JVM warm-up — load Scala JAR before the main query
        #   The first Scala UDF call after a warehouse resume incurs ~200 ms
        #   of cold-JVM overhead (JVM init + JAR load from stage). Running a
        #   single-row warm-up here eliminates that latency from the main
        #   production data query. On a warm JVM this completes in <1 ms.
        # ------------------------------------------------------------------
        try:
            session.sql(f"""
                SELECT APP_CODE.LOCID_BASE_ENCRYPT('WARMUP00000000000000X', {base_key})
                FROM TABLE(GENERATOR(ROWCOUNT => 1))
            """).collect()
        except Exception:
            pass  # Non-fatal; JVM is loaded even if the dummy call fails
        phases['jvm_warmup_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 3: IPv4 matching — equi-join via LOCID_BUILDS_IPV4_EXPLODED
        # ------------------------------------------------------------------
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_IPV4} AS
            WITH inp AS (
                SELECT {id_col} AS _id, {ip_col} AS _ip, {ts_expr} AS _ts
                FROM reference('ENCRYPT_INPUT_TABLE')
                WHERE {ip_col} NOT LIKE '%:%'
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
                i._id, i._ip, i._ts,
                lb.encrypted_locid, lb.tier,
                lb.locid_country,      lb.locid_country_code,
                lb.locid_region,       lb.locid_region_code,
                lb.locid_city,         lb.locid_city_code,
                lb.locid_postal_code,  lb.build_dt
            FROM inp i
            JOIN {DATES} b
                ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN b.start_dt AND b.end_dt
            JOIN fv4 l
                ON b.build_dt = l.build_dt AND i._ip = l.ip_address
            JOIN {BUILDS} lb
                ON l.build_dt = lb.build_dt
               AND l.start_ip = lb.start_ip
               AND l.end_ip   = lb.end_ip
        """).collect()
        phases['ipv4_match_s'] = round(time.perf_counter() - _pt, 3); _pt = time.perf_counter()

        # ------------------------------------------------------------------
        # Step 4: IPv6 matching — optimised 6-pass cascading hex-prefix range join
        #
        # Performance strategy (big-data focused):
        #
        #   4-a  Pre-materialise IPv6 input rows with ip_hex computed ONCE.
        #        Avoids calling PARSE_IP + GET_PATH 6× per row (one per pass).
        #
        #   4-b  Pre-materialise relevant IPv6 LOCID_BUILDS rows for the date
        #        range covering this job's input timestamps.
        #        Avoids a full LOCID_BUILDS scan on every pass.
        #
        #   4-c  Pre-join each input row to its matching build_dt.
        #        Avoids the LOCID_BUILD_DATES range join inside every pass.
        #
        #   4-d  Prefix pre-filter applied to the BUILDS side BEFORE the range
        #        join (not after). Dramatically reduces range-join cardinality.
        #
        #   4-e  Single accumulator table (_locid_v6_seen) updated after each
        #        pass. Each pass uses ONE anti-join (O(1)) instead of a growing
        #        chain (reference impl: 0+1+2+3+4+5 = 15 hash joins total).
        #
        #   4-f  Results accumulated directly into _locid_ipv6 via INSERT,
        #        eliminating the final 6-table UNION ALL.
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
        """).collect()

        # 4-b: Relevant IPv6 build rows, pre-filtered to date range of this job
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_BUILDS} AS
            SELECT l.*
            FROM {BUILDS} l
            JOIN (
                SELECT DISTINCT bd.build_dt
                FROM {DATES} bd
                JOIN {TBL_V6_INP} i
                    ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN bd.start_dt AND bd.end_dt
            ) rel_dates ON l.build_dt = rel_dates.build_dt
            WHERE l.start_ip LIKE '%:%'
        """).collect()

        # 4-c: Pre-join each input row to its matching build_dt
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_DATED} AS
            SELECT i._id, i._ip, i._ts, i.ip_hex, bd.build_dt
            FROM {TBL_V6_INP} i
            JOIN {DATES} bd
                ON TO_DATE(TO_TIMESTAMP(i._ts)) BETWEEN bd.start_dt AND bd.end_dt
        """).collect()

        # 4-d / 4-e / 4-f: 6-pass loop with pre-filtered builds and O(1) anti-join
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_IPV6} (
                _id VARCHAR, _ip VARCHAR, _ts BIGINT,
                encrypted_locid VARCHAR, tier VARCHAR,
                locid_country VARCHAR,      locid_country_code VARCHAR,
                locid_region  VARCHAR,      locid_region_code  VARCHAR,
                locid_city    VARCHAR,      locid_city_code    VARCHAR,
                locid_postal_code VARCHAR,  build_dt DATE
            )
        """).collect()

        # Accumulator: IPs already matched — single anti-join target per pass
        session.sql(f"""
            CREATE OR REPLACE TRANSIENT TABLE {TBL_V6_SEEN} (_ip VARCHAR)
        """).collect()

        for pass_num, prefix in enumerate([12, 10, 8, 6, 4, 0]):

            # Single anti-join against the accumulator (constant cost per pass)
            if pass_num > 0:
                excl_join  = f"LEFT JOIN {TBL_V6_SEEN} xs ON i._ip = xs._ip"
                excl_where = "AND xs._ip IS NULL"
            else:
                excl_join  = ""
                excl_where = ""

            # Prefix pre-filter on BUILDS — applied before the range join
            if prefix > 0:
                pfx_build_filter = (
                    f"AND SUBSTR(start_ip_int_hex, 1, {prefix}) = "
                    f"    SUBSTR(end_ip_int_hex,   1, {prefix})"
                )
                pfx_inp_cond = (
                    f"AND SUBSTR(i.ip_hex, 1, {prefix}) = "
                    f"    SUBSTR(l.start_ip_int_hex, 1, {prefix})"
                )
            else:
                pfx_build_filter = ""
                pfx_inp_cond     = ""

            session.sql(f"""
                INSERT INTO {TBL_IPV6}
                WITH inp AS (
                    SELECT i._id, i._ip, i._ts, i.ip_hex, i.build_dt
                    FROM {TBL_V6_DATED} i
                    {excl_join}
                    WHERE TRUE {excl_where}
                ),
                builds AS (
                    SELECT *
                    FROM {TBL_V6_BUILDS}
                    WHERE TRUE {pfx_build_filter}
                )
                SELECT
                    i._id, i._ip, i._ts,
                    l.encrypted_locid, l.tier,
                    l.locid_country,      l.locid_country_code,
                    l.locid_region,       l.locid_region_code,
                    l.locid_city,         l.locid_city_code,
                    l.locid_postal_code,  l.build_dt
                FROM inp i
                JOIN builds l
                    ON  i.build_dt = l.build_dt
                    {pfx_inp_cond}
                    AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
            """).collect()

            # Update accumulator with IPs matched so far (for next pass anti-join)
            session.sql(f"""
                INSERT INTO {TBL_V6_SEEN}
                SELECT DISTINCT _ip FROM {TBL_IPV6}
                EXCEPT SELECT _ip FROM {TBL_V6_SEEN}
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

        # Map output column name → SQL expression over _locid_matched columns
        # STABLE_CLOC: for the encrypt path both client IDs are the same value
        # (publisher = consumer; see developer-integration-guide.md)
        COL_SQL = {
            'tx_cloc': (
                f"APP_CODE.LOCID_TXCLOC_ENCRYPT("
                f"  encrypted_locid, {base_key}, {scheme_key}, _ts, {client_id}::INT)"
            ),
            'stable_cloc': (
                f"APP_CODE.LOCID_STABLE_CLOC("
                f"  encrypted_locid, {base_key}, {ns_guid}, "
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

        select_exprs = [f"_id AS {id_col}"] + [
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
        # Step 8: Log to JOB_LOG
        # ------------------------------------------------------------------
        _log_job(
            session, job_id, 'ENCRYPT', rows_in, rows_matched, rows_out,
            runtime_s, 'SUCCESS', None, 'reference(ENCRYPT_INPUT_TABLE)',
            f"APP_SCHEMA.{output_table}",
            cur_wh, active_cols,
        )

        # ------------------------------------------------------------------
        # Step 9: POST usage stats to LocID Central
        # ------------------------------------------------------------------
        _post_stats(session, rows_matched, runtime_s, 'encrypt_usage')

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
            session, job_id, 'ENCRYPT', rows_in, rows_matched, rows_out,
            runtime_s, 'FAILED', str(exc), 'reference(ENCRYPT_INPUT_TABLE)',
            f"APP_SCHEMA.{output_table}",
            cur_wh, [],
        )
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
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, ARRAY
) TO APPLICATION ROLE APP_ADMIN;


