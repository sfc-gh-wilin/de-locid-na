"""
streamlit/pages/02_run_encrypt.py
LocID Native App — Run Encrypt (View 3)

5-step job submission wizard:
  1. Select input table
  2. Map columns (unique_id, ip_address, timestamp)
  3. Configure output table
  4. Select output columns (gated by entitlement)
  5. Review & Run
"""

import json
import re
from datetime import datetime, timedelta, timezone

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_active_output_cols
from utils import logger

st.logo("logo.svg")

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

st.header("🔒 Run Encrypt")
st.caption("Match IP + timestamp data against the LocID data lake.")
st.divider()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _load_columns(table_fqn: str) -> list[str]:
    """Return ordered column names for a fully qualified table."""
    parts = [p.strip().strip('"') for p in table_fqn.strip().split(".")]
    if len(parts) != 3:
        return []
    db, schema_name, table_name = parts
    if not re.match(r'^[A-Za-z0-9_$]+$', db):
        return []
    try:
        rows = session.sql(
            f"SELECT COLUMN_NAME FROM {db}.INFORMATION_SCHEMA.COLUMNS "
            "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
            params=[schema_name.upper(), table_name.upper()]
        ).collect()
        return [r[0] for r in rows]
    except Exception as e:
        logger.warning(session, "02_run_encrypt._load_columns",
                       f"Failed to load columns for {table_fqn}: {e}")
        return []


def _validate_inputs(table: str, ip_col: str, ts_col: str, ts_fmt: str) -> dict:
    """
    Advisory pre-flight checks on the mapped columns.
    All cutoff math uses UTC. Never blocks the job.
    """
    result: dict = {}
    try:
        ip_rows = session.sql(f"""
            SELECT
                SUM(IFF({ip_col} IS NULL, 1, 0))                        AS null_ip,
                SUM(IFF({ip_col} IS NOT NULL
                        AND {ip_col} NOT LIKE '%:%'
                        AND TRY_CAST(SPLIT_PART({ip_col}, '.', 1) AS INT) IS NOT NULL
                        AND ARRAY_SIZE(SPLIT({ip_col}, '.')) = 4, 1, 0)) AS cnt_v4,
                SUM(IFF({ip_col} LIKE '%:%', 1, 0))                      AS cnt_v6,
                SUM(IFF({ip_col} IS NOT NULL
                        AND {ip_col} NOT LIKE '%:%'
                        AND NOT (TRY_CAST(SPLIT_PART({ip_col}, '.', 1) AS INT) IS NOT NULL
                                 AND ARRAY_SIZE(SPLIT({ip_col}, '.')) = 4), 1, 0)) AS cnt_bad
            FROM (SELECT {ip_col} FROM {table} LIMIT 1000)
        """).collect()[0]
        result["null_ip"] = int(ip_rows[0] or 0)
        result["cnt_v4"]  = int(ip_rows[1] or 0)
        result["cnt_v6"]  = int(ip_rows[2] or 0)
        result["bad_ip"]  = int(ip_rows[3] or 0)
    except Exception as e:
        logger.warning(session, "02_run_encrypt._validate_inputs",
                       f"IP validation failed: {e}")
        result["null_ip"] = result["cnt_v4"] = result["cnt_v6"] = result["bad_ip"] = None

    try:
        if ts_fmt == "epoch_ms":
            ts_expr = f"FLOOR({ts_col}::DOUBLE / 1000.0)::BIGINT"
        elif ts_fmt == "timestamp_string":
            ts_expr = f"DATE_PART(epoch_second, TRY_TO_TIMESTAMP({ts_col}))::BIGINT"
        else:
            ts_expr = f"{ts_col}::BIGINT"

        # UTC cutoff — 52 weeks back from now
        cutoff_epoch = int(
            (datetime.now(timezone.utc) - timedelta(weeks=52)).timestamp()
        )
        ts_rows = session.sql(f"""
            SELECT
                MIN({ts_expr})                           AS ts_min,
                MAX({ts_expr})                           AS ts_max,
                SUM(IFF({ts_col} IS NULL, 1, 0))        AS null_ts,
                SUM(IFF({ts_expr} < {cutoff_epoch}, 1, 0)) AS stale_cnt
            FROM {table}
        """).collect()[0]
        result["ts_min"]     = ts_rows[0]
        result["ts_max"]     = ts_rows[1]
        result["null_ts"]    = int(ts_rows[2] or 0)
        result["stale_count"] = int(ts_rows[3] or 0)
    except Exception as e:
        logger.warning(session, "02_run_encrypt._validate_inputs",
                       f"Timestamp validation failed: {e}")
        result["ts_min"] = result["ts_max"] = result["null_ts"] = result["stale_count"] = None

    return result


def _show_validation(v: dict) -> None:
    """Render advisory validation results."""
    if v.get("cnt_v4") is not None:
        v4, v6, bad, nul = v["cnt_v4"], v["cnt_v6"], v["bad_ip"], v["null_ip"]
        ip_parts = []
        if v4: ip_parts.append(f"IPv4: {v4:,}")
        if v6: ip_parts.append(f"IPv6: {v6:,}")
        st.info("IP types (sample 1,000): " + " · ".join(ip_parts) if ip_parts
                else "No parseable IPs found in sample")
        if bad:
            st.warning(f"{bad:,} unparseable IP value(s) — will be skipped during matching.",
                       icon="⚠️")
        if nul:
            st.warning(f"{nul:,} NULL IP value(s) — will be skipped.",
                       icon="⚠️")

    if v.get("stale_count") is not None:
        if v["stale_count"]:
            st.warning(
                f"{v['stale_count']:,} row(s) have timestamps older than 52 weeks. "
                "These will not match any LocID build and will be returned as unmatched.",
                icon="⚠️"
            )
        if v.get("null_ts"):
            st.warning(f"{v['null_ts']:,} NULL timestamp value(s) — will be skipped.",
                       icon="⚠️")
        if v["ts_min"] and v["stale_count"] == 0:
            st.success("Timestamp range looks good — all values within the 52-week window.",
                       icon="✅")


# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "enc_step" not in st.session_state:
    st.session_state.enc_step = 1

step  = st.session_state.enc_step
steps = ["Input", "Map Columns", "Output", "Options", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1),
            text=f"Step {step} of {len(steps)}: {steps[step-1]}")
st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Select Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader("📋 Step 1 — Select Input Table")
    input_table = st.text_input("Input table (fully qualified)",
                                placeholder="MY_DB.MY_SCHEMA.MY_TABLE",
                                key="enc_input_table_input")
    if input_table:
        st.caption("Preview (first 5 rows):")
        try:
            preview = session.sql(f"SELECT * FROM {input_table} LIMIT 5").to_pandas()
            st.dataframe(preview, use_container_width=True)
            del preview  # free memory — don't persist large DataFrame
        except Exception as e:
            logger.warning(session, "02_run_encrypt.step1", f"Preview failed: {e}")
            st.warning(f"Could not load preview: {e}")
    if st.button("Next →", disabled=not input_table):
        cols = _load_columns(input_table)
        if not cols:
            st.error("Could not read columns. Check the table name and your SELECT privilege.")
        else:
            st.session_state.enc_input_table   = input_table
            st.session_state.enc_input_columns = cols
            st.session_state.enc_step          = 2
            st.rerun()

# ---------------------------------------------------------------------------
# Step 2 — Map Columns
# ---------------------------------------------------------------------------
elif step == 2:
    st.subheader("📋 Step 2 — Map Columns")
    columns = st.session_state.get("enc_input_columns", [])
    if not columns:
        st.error("Column list is empty — go back and re-enter the table name.")
    else:
        col_id = st.selectbox("Unique Row ID", columns)
        col_ip = st.selectbox("IP Address",    columns)
        col_ts = st.selectbox("Timestamp",     columns)
        ts_fmt = st.selectbox("Timestamp Format",
                              ["epoch_sec", "epoch_ms", "timestamp_string"])
        st.divider()

        if st.button("✅ Run Input Validation"):
            with st.spinner("Checking IP format and timestamp range…"):
                v = _validate_inputs(
                    st.session_state.enc_input_table, col_ip, col_ts, ts_fmt
                )
                # Store only the lightweight result dict, not any DataFrame
                st.session_state.enc_validation      = v
                st.session_state.enc_validation_cols = (col_ip, col_ts, ts_fmt)

        if "enc_validation" in st.session_state:
            _show_validation(st.session_state.enc_validation)

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.pop("enc_validation", None)
            st.session_state.enc_step = 1
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not columns):
            st.session_state.enc_col_id = col_id
            st.session_state.enc_col_ip = col_ip
            st.session_state.enc_col_ts = col_ts
            st.session_state.enc_ts_fmt = ts_fmt
            st.session_state.enc_step   = 3
            st.rerun()

# ---------------------------------------------------------------------------
# Step 3 — Configure Output
# ---------------------------------------------------------------------------
elif step == 3:
    st.subheader("📤 Step 3 — Configure Output")
    output_mode  = st.radio("", ["Create new table", "Overwrite existing table"])
    output_table = st.text_input("Output table (fully qualified)",
                                 placeholder="MY_DB.MY_SCHEMA.LOCID_RESULTS")
    if output_mode == "Overwrite existing table" and output_table:
        st.warning(f"This will overwrite **{output_table}**. Existing data will be lost.",
                   icon="⚠️")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 2
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not output_table):
            st.session_state.enc_output_table = output_table
            st.session_state.enc_step = 4
            st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader("📊 Step 4 — Select Output Columns")
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
            st.session_state.enc_step = 3
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.enc_output_cols = selected
            st.session_state.enc_step = 5
            st.rerun()

# ---------------------------------------------------------------------------
# Step 5 — Review & Run
# ---------------------------------------------------------------------------
elif step == 5:
    st.subheader("▶️ Step 5 — Review & Run")
    st.write(f"**Input table:** `{st.session_state.get('enc_input_table')}`")
    st.write(f"**Output table:** `{st.session_state.get('enc_output_table')}`")
    st.write(
        f"**Columns mapped:** ID={st.session_state.get('enc_col_id')}, "
        f"IP={st.session_state.get('enc_col_ip')}, "
        f"TS={st.session_state.get('enc_col_ts')}"
    )
    st.write(f"**Output columns:** {', '.join(st.session_state.get('enc_output_cols', []))}")

    warehouse = st.text_input("Warehouse", placeholder="MY_WAREHOUSE")

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 4
            st.rerun()
    with col2:
        if st.button("▶️ Run Job", disabled=not warehouse, type="primary"):
            with st.spinner("Running LocID Encrypt job…"):
                try:
                    logger.info(session, "02_run_encrypt.run_job",
                                f"Job started: {st.session_state.enc_input_table} → "
                                f"{st.session_state.enc_output_table}")
                    raw = session.call(
                        "APP_SCHEMA.LOCID_ENCRYPT",
                        st.session_state.enc_input_table,
                        st.session_state.enc_output_table,
                        st.session_state.enc_col_id,
                        st.session_state.enc_col_ip,
                        st.session_state.enc_col_ts,
                        st.session_state.enc_ts_fmt,
                        st.session_state.enc_output_cols,
                        warehouse,
                    )
                    result = json.loads(raw) if isinstance(raw, str) else raw
                    status = result.get("status", "UNKNOWN")
                    if status == "SUCCESS":
                        st.success(
                            f"Job complete — "
                            f"{result.get('rows_matched', 0):,} rows matched "
                            f"out of {result.get('rows_in', 0):,} "
                            f"in {result.get('runtime_s', 0):.1f}s",
                            icon="✅"
                        )
                        st.caption(f"Job ID: {result.get('job_id', '—')}")
                        logger.info(session, "02_run_encrypt.run_job",
                                    f"Job SUCCESS: id={result.get('job_id')}, "
                                    f"matched={result.get('rows_matched')}")
                    else:
                        err = result.get("error", status)
                        st.error(f"Job failed — {err}", icon="❌")
                        logger.error(session, "02_run_encrypt.run_job",
                                     f"Job FAILED: {err}")
                except Exception as e:
                    logger.error(session, "02_run_encrypt.run_job",
                                 "Job threw an exception", exc=e)
                    st.error(f"Error running encrypt job: {e}", icon="❌")

            # Reset wizard for next run; discard heavy state
            for key in ("enc_input_columns", "enc_validation", "enc_validation_cols"):
                st.session_state.pop(key, None)
            st.session_state.enc_step = 1
