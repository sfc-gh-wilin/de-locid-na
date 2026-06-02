"""
streamlit/views/run_encrypt.py
LocID Native App — Run Encrypt (View 3)

4-step job submission wizard:
  1. Input table   (auto-populated from ENCRYPT_INPUT_TABLE reference if bound)
  2. Map columns   (unique_id, ip_address, timestamp)
  3. Output columns (gated by entitlement)
  4. Review & Run
"""

import json
import time
from datetime import datetime, timedelta, timezone

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_active_output_cols, get_active_entitlements
from utils import logger
from utils.errors import show_error

session = get_active_session()


# ---------------------------------------------------------------------------
# Session-scoped cache key
# ---------------------------------------------------------------------------
@st.cache_resource(show_spinner=False)
def _session_id() -> int:
    from snowflake.snowpark.context import get_active_session as _gas
    try:
        return int(_gas().sql("SELECT CURRENT_SESSION()").collect()[0][0])
    except Exception:
        return 0


sid = _session_id()

st.header(":material/lock: Run Encrypt")
st.caption("Match IP + timestamp data against the LocID data lake.")
with st.expander("💡 Tips", expanded=False):
    st.markdown(
        "#### Long-running jobs\n\n"
        "**Important:** If you navigate away from this tab or minimize the browser, "
        "the session may terminate and your job will be cancelled.\n\n"
        "For any job that may take more than a few minutes, run via **SQL worksheet** instead:\n\n"
        "- Open a SQL worksheet in Snowsight\n"
        "- See the **SQL Guide** page for full syntax\n"
        "- SQL worksheets have **no session timeout** — the job runs to completion\n"
        "- Results appear in **Job History** when done\n\n"
        "---\n\n"
        "#### Warehouse\n\n"
        "**For best performance, use a Snowpark-optimized warehouse.**\n\n"
        "| Row count | Recommendation |\n"
        "|-----------|---------------|\n"
        "| < 1M rows | Medium Snowpark-optimized |\n"
        "| 1M–10M rows | Medium/Large Snowpark-optimized |\n"
        "| 10M+ rows | Large+ Snowpark-optimized |\n\n"
        "For concurrent jobs, set `MAX_CLUSTER_COUNT = 2–3` (multi-cluster).\n\n"
        "**Recommended warehouse DDL:**\n"
        "```sql\n"
        "CREATE OR REPLACE WAREHOUSE LOCID_WH\n"
        "    WAREHOUSE_SIZE = 'LARGE'\n"
        "    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'\n"
        "    MIN_CLUSTER_COUNT = 1\n"
        "    MAX_CLUSTER_COUNT = 3\n"
        "    SCALING_POLICY = 'STANDARD'\n"
        "    AUTO_SUSPEND = 300\n"
        "    AUTO_RESUME = TRUE;\n"
        "\n"
        "-- Grant usage to your app installer role:\n"
        "GRANT USAGE ON WAREHOUSE LOCID_WH TO ROLE LOCID_APP_INSTALLER;\n"
        "\n"
        "-- Grant usage to the application:\n"
        "GRANT USAGE ON WAREHOUSE LOCID_WH TO APPLICATION LOCID_APP;\n"
        "```\n\n"
        "---\n\n"
        "#### Can't find your table in the picker?\n\n"
        "Snowsight's table picker cannot browse tables inside the **app's own database**. "
        "If your input table lives in the app database, bind it via SQL instead:\n\n"
        "```sql\n"
        "CALL <app_database>.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(\n"
        "    'ENCRYPT_INPUT_TABLE', 'ADD',\n"
        "    SYSTEM$REFERENCE('TABLE', '<db>.<schema>.<table>', 'PERSISTENT', 'SELECT')\n"
        ");\n"
        "```\n\n"
        "See the **SQL Guide** page for full details and required grants.\n\n"
        "---\n\n"
        "#### How to abort a running job\n\n"
        "**From Snowsight:**\n"
        "1. Open **Monitoring → Query History**\n"
        "2. Filter by Status = **Running** and your username\n"
        "3. Find the long-running query (SQL text shows `<redacted>` for Native App jobs)\n"
        "4. Click the query row → click **Cancel** (✕) button\n\n"
        "**From SQL:**\n"
        "```sql\n"
        "-- Find your running query ID:\n"
        "SELECT query_id, start_time, total_elapsed_time/1000 AS elapsed_s\n"
        "FROM TABLE(information_schema.query_history())\n"
        "WHERE execution_status = 'RUNNING'\n"
        "ORDER BY start_time DESC;\n"
        "\n"
        "-- Cancel it:\n"
        "SELECT SYSTEM$CANCEL_QUERY('<query_id>');\n"
        "```"
    )
st.divider()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _quote_id(name: str) -> str:
    """Double-quote a Snowflake identifier to handle spaces/special chars safely."""
    return '"' + name.replace('"', '""') + '"'


# Sample size options for validation queries (label → row count; 0 = full table).
_SAMPLE_OPTIONS: dict[str, int] = {
    "1,000 rows":        1_000,
    "10,000 rows":      10_000,
    "100,000 rows":    100_000,   # default
    "500,000 rows":    500_000,
    "1,000,000 rows":  1_000_000,
    "5,000,000 rows":  5_000_000,
    "Full table":              0,
}


def _get_bound_table(ref_name: str) -> str | None:
    """Return FQN of the currently bound table for ref_name, or None.

    SYSTEM$GET_ALL_REFERENCES(name, TRUE) returns a JSON array of
    {alias, database, schema, name} objects for each association.
    """
    try:
        rows = session.sql(
            "SELECT SYSTEM$GET_ALL_REFERENCES(?, TRUE)", params=[ref_name]
        ).collect()
        if not rows or not rows[0][0]:
            return None
        bindings = json.loads(rows[0][0])
        if not bindings:
            return None
        b      = bindings[0]
        db     = b.get('database', '')
        schema = b.get('schema', '')
        name   = b.get('name', '')
        if db and schema and name:
            return f"{db}.{schema}.{name}"
    except Exception as e:
        logger.warning(session, "run_encrypt._get_bound_table",
                       f"Failed to resolve reference {ref_name}: {e}")
    return None


def _get_ref_col_info(ref_name: str) -> tuple[list[str], dict[str, str]]:
    """Return (ordered names, {name: data_type_str}) from DESCRIBE TABLE reference.

    Data type is the second column returned by DESCRIBE, e.g.:
      'TIMESTAMP_NTZ(9)', 'NUMBER(38,0)', 'VARCHAR(16777216)', etc.
    Used to auto-select the correct Timestamp Format in Step 2.
    """
    try:
        rows = session.sql(f"DESCRIBE TABLE reference('{ref_name}')").collect()
        names = [r[0] for r in rows]
        types = {r[0]: r[1] for r in rows}
        return names, types
    except Exception as e:
        logger.warning(session, "run_encrypt._get_ref_col_info",
                       f"Failed to describe reference {ref_name}: {e}")
        return [], {}


def _best_match(columns: list[str], hints: list[str]) -> int:
    """Return the selectbox index of the best-matching column, or 0 if none found.

    Priority:
      1. Exact case-insensitive match.
      2. Column name contains a hint, or hint contains the column name.
    """
    lower = [c.lower() for c in columns]
    for hint in hints:                          # exact pass
        for i, col in enumerate(lower):
            if col == hint:
                return i
    for hint in hints:                          # substring pass
        for i, col in enumerate(lower):
            if hint in col or col in hint:
                return i
    return 0


def _validate_inputs(table: str, ip_col: str, ts_col: str, ts_fmt: str,
                     sample_rows: int = 100_000) -> dict:
    """
    Advisory pre-flight checks on the mapped columns.
    All cutoff math uses UTC. Never blocks the job.
    sample_rows: rows to sample (TABLESAMPLE); 0 = full table scan.
    """
    result: dict = {}
    q_ip = _quote_id(ip_col)
    q_ts = _quote_id(ts_col)
    sample_clause = f"TABLESAMPLE ({sample_rows} ROWS)" if sample_rows > 0 else ""
    try:
        ip_rows = session.sql(f"""
            SELECT
                SUM(IFF({q_ip} IS NULL, 1, 0))                           AS null_ip,
                SUM(IFF({q_ip} IS NOT NULL
                        AND NOT {q_ip} LIKE '%:%'
                        AND {q_ip} LIKE '%.%.%.%', 1, 0))                AS cnt_v4,
                SUM(IFF({q_ip} LIKE '%:%', 1, 0))                        AS cnt_v6,
                SUM(IFF({q_ip} IS NOT NULL
                        AND NOT {q_ip} LIKE '%:%'
                        AND NOT {q_ip} LIKE '%.%.%.%', 1, 0))            AS cnt_bad
            FROM (SELECT {q_ip} FROM {table} {sample_clause})
        """).collect()[0]
        result["null_ip"] = int(ip_rows[0] or 0)
        result["cnt_v4"]  = int(ip_rows[1] or 0)
        result["cnt_v6"]  = int(ip_rows[2] or 0)
        result["bad_ip"]  = int(ip_rows[3] or 0)
    except Exception as e:
        logger.warning(session, "run_encrypt._validate_inputs",
                       f"IP validation failed: {e}")
        result["null_ip"] = result["cnt_v4"] = result["cnt_v6"] = result["bad_ip"] = None

    try:
        if ts_fmt == "epoch_ms":
            ts_expr = f"FLOOR({q_ts}::DOUBLE / 1000.0)::BIGINT"
        elif ts_fmt == "timestamp":
            ts_expr = f"DATE_PART(epoch_second, {q_ts}::TIMESTAMP_NTZ)::BIGINT"
        else:   # epoch_sec (default)
            ts_expr = f"{q_ts}::BIGINT"

        # Cutoff — use earliest build date from provider data (not hardcoded 52 weeks)
        try:
            min_dt_row = session.sql(
                "SELECT MIN(start_dt) FROM LOCID_SHARE.LOCID_BUILD_DATES"
            ).collect()[0][0]
            if min_dt_row:
                cutoff_epoch = int(datetime.combine(
                    min_dt_row if hasattr(min_dt_row, 'year') else datetime.strptime(str(min_dt_row), '%Y-%m-%d').date(),
                    datetime.min.time(),
                    tzinfo=timezone.utc
                ).timestamp())
            else:
                cutoff_epoch = int((datetime.now(timezone.utc) - timedelta(weeks=52)).timestamp())
        except Exception:
            cutoff_epoch = int((datetime.now(timezone.utc) - timedelta(weeks=52)).timestamp())

        ts_rows = session.sql(f"""
            SELECT
                MIN({ts_expr})                              AS ts_min,
                MAX({ts_expr})                              AS ts_max,
                SUM(IFF({q_ts} IS NULL, 1, 0))           AS null_ts,
                SUM(IFF({ts_expr} < {cutoff_epoch}, 1, 0)) AS stale_cnt
            FROM (SELECT {q_ts} FROM {table} {sample_clause})
        """).collect()[0]
        result["ts_min"]      = ts_rows[0]
        result["ts_max"]      = ts_rows[1]
        result["null_ts"]     = int(ts_rows[2] or 0)
        result["stale_count"] = int(ts_rows[3] or 0)
    except Exception as e:
        logger.warning(session, "run_encrypt._validate_inputs",
                       f"Timestamp validation failed: {e}")
        result["ts_min"] = result["ts_max"] = result["null_ts"] = result["stale_count"] = None

    return result


def _show_validation(v: dict, sample_label: str = "100,000 rows") -> None:
    """Render advisory validation results."""
    ip_ok = v.get("cnt_v4") is not None
    ts_ok = v.get("stale_count") is not None

    if not ip_ok and not ts_ok:
        st.error(
            "Validation could not run — unable to access the input table. "
            "Ensure the table is bound via **⚙ Settings → Permissions**.",
            icon="❌",
        )
        return

    if ip_ok:
        v4, v6, bad, nul = v["cnt_v4"], v["cnt_v6"], v["bad_ip"], v["null_ip"]
        ip_parts = []
        if v4: ip_parts.append(f"IPv4: {v4:,}")
        if v6: ip_parts.append(f"IPv6: {v6:,}")
        st.info("IP types (sample " + sample_label + "): " + " · ".join(ip_parts) if ip_parts
                else f"No parseable IPs found in sample ({sample_label})")
        if bad:
            st.warning(f"{bad:,} unparseable IP value(s) — will be skipped during matching.",
                       icon="⚠️")
        if nul:
            st.warning(f"{nul:,} NULL IP value(s) — will be skipped.", icon="⚠️")

    if not ts_ok:
        st.warning(
            "Timestamp validation failed — check that the correct **Timestamp Format** "
            "is selected for this column.",
            icon="⚠️",
        )

    if v.get("stale_count") is not None:
        if v["stale_count"]:
            st.warning(
                f"{v['stale_count']:,} row(s) have timestamps older than the earliest LocID build date. "
                "These will not match any LocID build and will be returned as unmatched.",
                icon="⚠️"
            )
        if v.get("null_ts"):
            st.warning(f"{v['null_ts']:,} NULL timestamp value(s) — will be skipped.",
                       icon="⚠️")
        if v["ts_min"] is not None and v["stale_count"] == 0:
            st.success("Timestamp range looks good — all values within LocID build coverage.",
                       icon="✅")

def _check_id_uniqueness(table: str, id_col: str, sample_rows: int = 100_000) -> dict:
    """Check whether id_col has duplicate values in the input table.

    The LOCID_ENCRYPT procedure deduplicates to one output row per unique ID
    (via QUALIFY ROW_NUMBER()). Duplicates are not an error, but customers
    should know their output row count may be lower than their input.
    sample_rows: rows to sample; 0 = full table scan.
    """
    q_id = _quote_id(id_col)
    sample_clause = f"TABLESAMPLE ({sample_rows} ROWS)" if sample_rows > 0 else ""
    try:
        rows = session.sql(f"""
            SELECT COUNT(*) AS total, COUNT(DISTINCT {q_id}) AS distinct_count
            FROM (SELECT {q_id} FROM {table} {sample_clause})
        """).collect()[0]
        return {
            "id_total":    int(rows[0] or 0),
            "id_distinct": int(rows[1] or 0),
        }
    except Exception as e:
        logger.warning(session, "run_encrypt._check_id_uniqueness",
                       f"ID uniqueness check failed: {e}")
        return {"id_error": str(e)}


@st.cache_data(ttl=600, show_spinner=False)
def _get_table_row_count(_sid: int) -> int | None:
    """Return row count for the bound ENCRYPT_INPUT_TABLE.

    Uses INFORMATION_SCHEMA.TABLES (metadata-only, fast) with COUNT(*) fallback.
    Cached 10 minutes per session — the table size won't change within a submission.
    Returns None if the count cannot be determined.
    """
    try:
        bound = _get_bound_table('ENCRYPT_INPUT_TABLE')
        if bound:
            parts = bound.split('.')
            if len(parts) == 3:
                db, schema, tbl = parts
                rows = session.sql(
                    f"SELECT row_count FROM {db}.INFORMATION_SCHEMA.TABLES "
                    "WHERE TABLE_SCHEMA = UPPER(?) AND TABLE_NAME = UPPER(?)",
                    params=[schema, tbl]
                ).collect()
                if rows and rows[0][0] is not None:
                    return int(rows[0][0])
    except Exception:
        pass
    # Fallback: COUNT(*) via reference binding
    try:
        row = session.sql(
            "SELECT COUNT(*) FROM reference('ENCRYPT_INPUT_TABLE')"
        ).collect()[0]
        return int(row[0] or 0)
    except Exception:
        return None


def _smart_sample_options(table_count: int | None) -> tuple[list[str], int]:
    """Return (option_labels, default_index) filtered and defaulted by table size.

    Rules:
    - Options where sample_rows >= table_count are hidden (they'd scan the full table anyway).
    - "Full table" is always shown.
    - Default: "Full table" for tables ≤ 100K rows (fast enough); "100,000 rows" for larger.
    - Falls back to all options with "100,000 rows" default when count is unknown.
    """
    all_labels = list(_SAMPLE_OPTIONS.keys())

    if table_count is None:
        return all_labels, 2   # unknown size — all options, 100K default

    # Keep options whose sample size is smaller than the table; always keep Full table
    filtered = [
        lbl for lbl in all_labels
        if _SAMPLE_OPTIONS[lbl] == 0 or _SAMPLE_OPTIONS[lbl] < table_count
    ]
    # Guarantee at least "1,000 rows" and "Full table" are always present
    for must_have in ("1,000 rows", "Full table"):
        if must_have not in filtered:
            filtered.append(must_have)

    default_label = "Full table" if table_count <= 100_000 else "100,000 rows"
    if default_label not in filtered:
        default_label = filtered[-1]   # fallback to last option
    return filtered, filtered.index(default_label)


def _show_id_check(r: dict, id_col: str, sample_label: str) -> None:
    """Render ID uniqueness check results."""
    if "id_error" in r:
        st.warning(f"ID uniqueness check failed: {r['id_error']}", icon="⚠️")
        return
    total    = r.get("id_total", 0)
    distinct = r.get("id_distinct", 0)
    dups     = total - distinct
    st.caption(f"Last checked — ID: `{id_col}` · Sample: {sample_label}")
    if total == 0:
        st.info("No rows in sample — table may be empty.", icon="ℹ️")
    elif dups == 0:
        st.success(
            f"All {total:,} sampled ID values are unique.",
            icon="✅",
        )
    else:
        st.warning(
            f"{dups:,} duplicate ID value(s) found in {total:,} sampled rows "
            f"({distinct:,} unique). The procedure outputs **one result per unique ID** — "
            "duplicate IDs in the input will be deduplicated in the output.",
            icon="⚠️",
        )



if 'allow_encrypt' not in get_active_entitlements(sid):
    st.error(
        "Your LocID license does not include the **Encrypt** entitlement (`allow_encrypt`). "
        "Contact LocID to upgrade your access.",
        icon="🔒",
    )
    st.stop()


# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "enc_step" not in st.session_state:
    st.session_state.enc_step = 1

step  = st.session_state.enc_step
steps = ["Input", "Map Columns", "Output Columns", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1),
            text=f"Step {step} of {len(steps)}: {steps[step-1]}")
# st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader(":material/table_view: Step 1 — Input Table")

    bound = _get_bound_table('ENCRYPT_INPUT_TABLE')

    if bound:
        st.info(f"Using pre-configured input table: `{bound}`", icon="✅")
        st.caption(
            "To use a different table, click the **⚙ Settings** icon (top right) "
            "→ **Permissions** → re-bind **Input Table for Encrypt**."
        )
        st.caption("Preview (first 5 rows):")
        try:
            preview = session.sql(
                "SELECT * FROM reference('ENCRYPT_INPUT_TABLE') LIMIT 5"
            ).to_pandas()
            st.dataframe(preview, use_container_width=True)
            del preview
        except Exception as e:
            st.warning(f"Could not load preview: {e}")
        if st.button("Next →", type="primary"):
            cols, col_types = _get_ref_col_info('ENCRYPT_INPUT_TABLE')
            if not cols:
                st.error("Could not read columns. Check that the table exists and the app has SELECT access.")
            else:
                st.session_state.enc_input_table    = bound
                st.session_state.enc_input_columns  = cols
                st.session_state.enc_col_types      = col_types
                st.session_state.enc_step           = 2
                st.rerun()
    else:
        st.warning(
            "No input table is configured yet. "
            "Click the **⚙ Settings** icon (top right) → **Permissions** → "
            "grant and bind **Input Table for Encrypt**.",
            icon="⚠️",
        )

# ---------------------------------------------------------------------------
# Step 2 — Map Columns
# ---------------------------------------------------------------------------
elif step == 2:
    st.subheader(":material/table_rows: Step 2 — Map Columns")
    columns = st.session_state.get("enc_input_columns", [])
    if not columns:
        st.error("Column list is empty — go back and re-enter the table name.")
    else:
        col_id = st.selectbox("Unique Row ID", columns,
                              index=_best_match(columns,
                                  ['id', 'row_id', 'unique_id', 'uid',
                                   'customer_id', 'user_id', 'record_id', 'key']))
        col_ip = st.selectbox("IP Address",    columns,
                              index=_best_match(columns,
                                  ['ip_address', 'ip_addr', 'ip',
                                   'client_ip', 'source_ip']))
        col_ts = st.selectbox("Timestamp",     columns,
                              index=_best_match(columns,
                                  ['ts', 'timestamp', 'event_ts', 'event_time',
                                   'time', 'datetime']))

        # Auto-detect timestamp column type → pre-select the right format.
        # TIMESTAMP_NTZ / TIMESTAMP_LTZ / TIMESTAMP_TZ → "timestamp"
        # Numeric with values > 10^12 → likely "epoch_ms" (current epoch_sec ~ 1.7×10^9)
        # All other numeric types → "epoch_sec" (default)
        col_types     = st.session_state.get("enc_col_types", {})
        ts_type       = col_types.get(col_ts, '').upper()
        if 'TIMESTAMP' in ts_type:
            default_fmt = 2  # timestamp
        elif 'NUMBER' in ts_type or 'INT' in ts_type or 'FLOAT' in ts_type:
            # Sample max value to detect ms vs sec
            try:
                max_val = session.sql(
                    f"SELECT MAX({_quote_id(col_ts)}) FROM reference('ENCRYPT_INPUT_TABLE') LIMIT 1"
                ).collect()[0][0]
                default_fmt = 1 if max_val and float(max_val) > 1e12 else 0
            except Exception:
                default_fmt = 0
        else:
            default_fmt = 0

        ts_fmt = st.selectbox("Timestamp Format",
                              ["epoch_sec", "epoch_ms", "timestamp"],
                              index=default_fmt,
                              help=(
                                  "**epoch_sec** — integer Unix seconds (e.g. 1716000000)  \n"
                                  "**epoch_ms** — integer Unix milliseconds (e.g. 1716000000000)  \n"
                                  "**timestamp** — Snowflake TIMESTAMP_NTZ column  \n\n"
                                  "Auto-detected based on column type and value range."
                              ))

        st.divider()

        id_to_varchar = st.checkbox(
            "Convert ID column to VARCHAR in output",
            value=False,
            help=(
                "When checked, the ID column is cast to VARCHAR in the output table. "
                "Leave unchecked to preserve the original column data type."
            ),
        )

        # Validation: columns must be distinct
        if len({col_id, col_ip, col_ts}) < 3:
            st.warning(
                "Each mapping must use a **different column**. "
                "ID, IP Address, and Timestamp cannot share the same column.",
                icon="⚠️",
            )

        st.divider()

        # Sample size selector — smart: filtered and defaulted by actual table row count
        _tbl_count    = _get_table_row_count(sid)
        _sample_opts, _sample_default = _smart_sample_options(_tbl_count)

        if _tbl_count is not None:
            st.caption(f"Input table: **{_tbl_count:,} rows**")

        sample_label = st.selectbox(
            "Validation sample size",
            _sample_opts,
            index=_sample_default,
            help=(
                "Rows sampled for format and ID uniqueness checks.  \n"
                "Options larger than the table are automatically hidden.  \n"
                "Tables ≤ 100K rows default to **Full table** (fast enough to scan completely)."
            ),
        )
        sample_rows = _SAMPLE_OPTIONS[sample_label]

        # Show coverage percentage and warn for large full-table scans
        if sample_rows > 0 and _tbl_count and _tbl_count > 0:
            pct = min(100.0, sample_rows / _tbl_count * 100)
            st.caption(f"≈ {pct:.1f}% of table")
        elif sample_rows == 0 and _tbl_count and _tbl_count > 1_000_000:
            st.warning(
                f"Full table scan — {_tbl_count:,} rows may take a while on large datasets.",
                icon="⚠️",
            )

        btn_col1, btn_col2 = st.columns(2)
        with btn_col1:
            if st.button("✅ Run Format Validation"):
                with st.spinner("Checking IP format and timestamp range…"):
                    v = _validate_inputs(
                        "reference('ENCRYPT_INPUT_TABLE')", col_ip, col_ts, ts_fmt,
                        sample_rows,
                    )
                    st.session_state.enc_validation       = v
                    st.session_state.enc_validation_cols  = (col_ip, col_ts, ts_fmt, sample_label)
        with btn_col2:
            if st.button("🔑 Run ID Unique Check"):
                with st.spinner("Checking ID column for duplicate values…"):
                    r = _check_id_uniqueness(
                        "reference('ENCRYPT_INPUT_TABLE')", col_id, sample_rows
                    )
                    st.session_state.enc_id_check       = r
                    st.session_state.enc_id_check_label = (col_id, sample_label)

        if "enc_validation" in st.session_state:
            vcols = st.session_state.get("enc_validation_cols", ())
            if vcols:
                st.caption(
                    f"Last validated — IP: `{vcols[0]}` · TS: `{vcols[1]}` "
                    f"· Format: `{vcols[2]}` · Sample: {vcols[3] if len(vcols) > 3 else '—'}"
                )
            _show_validation(
                st.session_state.enc_validation,
                vcols[3] if len(vcols) > 3 else "100,000 rows",
            )

        if "enc_id_check" in st.session_state:
            id_label = st.session_state.get("enc_id_check_label", ("—", "—"))
            _show_id_check(
                st.session_state.enc_id_check,
                id_label[0],
                id_label[1],
            )

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.pop("enc_validation", None)
            st.session_state.pop("enc_id_check", None)
            st.session_state.enc_step = 1
            st.rerun()
    with col2:
        cols_valid = columns and len({col_id, col_ip, col_ts}) == 3
        if st.button("Next →", disabled=not cols_valid):
            st.session_state.enc_col_id = col_id
            st.session_state.enc_col_ip = col_ip
            st.session_state.enc_col_ts = col_ts
            st.session_state.enc_ts_fmt = ts_fmt
            st.session_state.enc_id_to_varchar = id_to_varchar
            st.session_state.enc_step   = 3
            st.rerun()

# ---------------------------------------------------------------------------
# Step 3 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 3:
    st.subheader(":material/view_column: Step 3 — Select Output Columns")
    available_cols = get_active_output_cols(sid, "encrypt")
    selected = []
    for col in available_cols:
        disabled = not col["enabled"]
        tooltip  = f"Requires entitlement: {col['requires_entitlement']}" if disabled else ""
        checked  = st.checkbox(col["col_name"], value=col["enabled"],
                               disabled=disabled, help=tooltip or None)
        if checked:
            selected.append(col["col_name"])
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 2
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.enc_output_cols = selected
            st.session_state.enc_step = 4
            st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Review & Run
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader(":material/play_arrow: Step 4 — Review & Run")

    # --- Warehouse confirmation ---
    try:
        _cur_wh = session.sql("SELECT CURRENT_WAREHOUSE()").collect()[0][0]
    except Exception:
        _cur_wh = None

    if _cur_wh:
        st.info(
            f"**Active warehouse:** `{_cur_wh}`\n\n"
            "To switch warehouses, use the warehouse selector in the **top-right corner** "
            "of Snowsight. The app will restart and run on the newly selected warehouse.",
            icon=":material/warehouse:",
        )
    else:
        st.warning(
            "The app is running on the warehouse selected in the **top-right corner** of Snowsight. "
            "To switch warehouses, change it there — the app will restart on the newly selected warehouse.",
            icon=":material/warehouse:",
        )

    st.write(f"**Input table:** `{st.session_state.get('enc_input_table')}`")
    st.write(
        f"**Columns mapped:** ID={st.session_state.get('enc_col_id')}, "
        f"IP={st.session_state.get('enc_col_ip')}, "
        f"TS={st.session_state.get('enc_col_ts')}"
    )
    st.write(f"**Output columns:** {', '.join(st.session_state.get('enc_output_cols', []))}")
    st.write(
        f"**ID to VARCHAR:** {'Yes' if st.session_state.get('enc_id_to_varchar') else 'No (preserve original type)'}"
    )
    st.caption(
        "Output will be written to an auto-named table in APP_SCHEMA "
        "(e.g. LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX)."
    )

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 3
            st.rerun()
    with col2:
        if st.button(":material/play_arrow: Run Job", type="primary"):
            t_start = time.time()
            with st.status("Running LocID Encrypt job…", expanded=True) as job_status:
                st.write(f"**Started at:** {datetime.now(timezone.utc).strftime('%H:%M:%S')} UTC")
                try:
                    logger.info(session, "run_encrypt.run_job",
                                f"Job started: input={st.session_state.enc_input_table}")
                    raw = session.call(
                        "APP_SCHEMA.LOCID_ENCRYPT",
                        st.session_state.enc_col_id,
                        st.session_state.enc_col_ip,
                        st.session_state.enc_col_ts,
                        st.session_state.enc_ts_fmt,
                        st.session_state.enc_output_cols,
                        st.session_state.get('enc_id_to_varchar', False),
                    )
                    elapsed = time.time() - t_start
                    result = json.loads(raw) if isinstance(raw, str) else raw
                    status = result.get("status", "UNKNOWN")
                    if status == "SUCCESS":
                        job_status.update(
                            label=f"Job complete — elapsed {elapsed:.1f}s",
                            state="complete", expanded=True,
                        )
                        st.success(
                            f"{result.get('rows_matched', 0):,} rows matched "
                            f"out of {result.get('rows_in', 0):,} "
                            f"in {result.get('runtime_s', 0):.1f}s",
                            icon="✅"
                        )
                        if result.get('rows_skipped_invalid_ts', 0) > 0:
                            st.warning(
                                f"{result['rows_skipped_invalid_ts']:,} row(s) skipped "
                                f"due to invalid timestamp values.",
                                icon="⚠️"
                            )
                        st.info(f"Output table: `{result.get('output_table', '—')}`")
                        st.caption(f"Job ID: {result.get('job_id', '—')}")
                        logger.info(session, "run_encrypt.run_job",
                                    f"Job SUCCESS: id={result.get('job_id')}, "
                                    f"matched={result.get('rows_matched')}, "
                                    f"elapsed={elapsed:.1f}s")
                        # Reset wizard for next run; discard heavy state
                        for key in ("enc_input_columns", "enc_validation", "enc_validation_cols"):
                            st.session_state.pop(key, None)
                        st.session_state.enc_step = 1
                    else:
                        elapsed = time.time() - t_start
                        job_status.update(
                            label=f"Job failed — elapsed {elapsed:.1f}s",
                            state="error", expanded=True,
                        )
                        err = result.get("error", status)
                        show_error(f"Job failed — {err}")
                        logger.error(session, "run_encrypt.run_job",
                                     f"Job FAILED: {err}")
                except Exception as e:
                    elapsed = time.time() - t_start
                    job_status.update(
                        label=f"Job error — elapsed {elapsed:.1f}s",
                        state="error", expanded=True,
                    )
                    logger.error(session, "run_encrypt.run_job",
                                 "Job threw an exception", exc=e)
                    # Fallback: write to JOB_LOG so the failure shows in Job History
                    # even if the procedure never started (e.g. warehouse/session error).
                    try:
                        import uuid as _uuid
                        session.sql(
                            "INSERT INTO APP_SCHEMA.JOB_LOG "
                            "(job_id, operation, rows_in, rows_matched, rows_out, "
                            " runtime_s, status, error_msg, input_table, output_table, "
                            " warehouse, output_cols) "
                            "VALUES (?, 'ENCRYPT', NULL, NULL, NULL, ?, 'FAILED', ?, ?, NULL, NULL, NULL)",
                            params=[
                                str(_uuid.uuid4()), round(elapsed, 2), str(e)[:2000],
                                st.session_state.get('enc_input_table', '—'),
                            ],
                        ).collect()
                    except Exception:
                        pass  # Best-effort — don't mask the original error
                    show_error(f"Encrypt job failed unexpectedly (elapsed: {elapsed:.1f}s).",
                               detail=e)

else:
    # Invalid step state — reset to prevent blank page
    st.session_state.enc_step = 1
    st.rerun()
