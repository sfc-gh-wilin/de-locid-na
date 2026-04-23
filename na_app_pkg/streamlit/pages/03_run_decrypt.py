"""
streamlit/pages/03_run_decrypt.py
LocID Native App — Run Decrypt (View 4)

5-step job submission wizard:
  1. Select input table
  2. Map columns (unique_id, tx_cloc)
  3. Configure output table
  4. Select output columns (gated by entitlement)
  5. Review & Run
"""

import json
import re

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

st.markdown("## :material/lock_open: Run Decrypt")
st.caption("Decode TX_CLOC values back to STABLE_CLOC and geo context.")
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
        logger.warning(session, "03_run_decrypt._load_columns",
                       f"Failed to load columns for {table_fqn}: {e}")
        return []


# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "dec_step" not in st.session_state:
    st.session_state.dec_step = 1

step  = st.session_state.dec_step
steps = ["Input", "Map Columns", "Output", "Options", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1),
            text=f"Step {step} of {len(steps)}: {steps[step-1]}")
st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Select Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader(":material/table: Step 1 — Select Input Table")
    input_table = st.text_input("Input table (fully qualified)",
                                placeholder="MY_DB.MY_SCHEMA.MY_TABLE",
                                key="dec_input_table_input")
    if input_table:
        st.caption("Preview (first 5 rows):")
        try:
            preview = session.sql(f"SELECT * FROM {input_table} LIMIT 5").to_pandas()
            st.dataframe(preview, use_container_width=True)
            del preview  # free memory
        except Exception as e:
            logger.warning(session, "03_run_decrypt.step1", f"Preview failed: {e}")
            st.warning(f"Could not load preview: {e}")
    if st.button("Next →", disabled=not input_table):
        cols = _load_columns(input_table)
        if not cols:
            st.error("Could not read columns. Check the table name and your SELECT privilege.")
        else:
            st.session_state.dec_input_table   = input_table
            st.session_state.dec_input_columns = cols
            st.session_state.dec_step          = 2
            st.rerun()

# ---------------------------------------------------------------------------
# Step 2 — Map Columns
# ---------------------------------------------------------------------------
elif step == 2:
    st.subheader(":material/table_rows: Step 2 — Map Columns")
    columns = st.session_state.get("dec_input_columns", [])
    if not columns:
        st.error("Column list is empty — go back and re-enter the table name.")
    else:
        col_id    = st.selectbox("Unique Row ID", columns)
        col_txclo = st.selectbox("TX_CLOC",       columns)
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 1
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not columns):
            st.session_state.dec_col_id    = col_id
            st.session_state.dec_col_txclo = col_txclo
            st.session_state.dec_step      = 3
            st.rerun()

# ---------------------------------------------------------------------------
# Step 3 — Configure Output
# ---------------------------------------------------------------------------
elif step == 3:
    st.subheader(":material/output: Step 3 — Configure Output")
    output_mode  = st.radio("", ["Create new table", "Overwrite existing table"])
    output_table = st.text_input("Output table (fully qualified)",
                                 placeholder="MY_DB.MY_SCHEMA.LOCID_RESULTS")
    if output_mode == "Overwrite existing table" and output_table:
        st.warning(f"This will overwrite **{output_table}**. Existing data will be lost.",
                   icon=":material/warning:")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 2
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not output_table):
            st.session_state.dec_output_table = output_table
            st.session_state.dec_step = 4
            st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader(":material/view_column: Step 4 — Select Output Columns")
    available_cols = get_active_output_cols(sid, "decrypt")
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
            st.session_state.dec_step = 3
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.dec_output_cols = selected
            st.session_state.dec_step = 5
            st.rerun()

# ---------------------------------------------------------------------------
# Step 5 — Review & Run
# ---------------------------------------------------------------------------
elif step == 5:
    st.subheader(":material/play_circle: Step 5 — Review & Run")
    st.write(f"**Input table:** `{st.session_state.get('dec_input_table')}`")
    st.write(f"**Output table:** `{st.session_state.get('dec_output_table')}`")
    st.write(
        f"**Columns mapped:** ID={st.session_state.get('dec_col_id')}, "
        f"TX_CLOC={st.session_state.get('dec_col_txclo')}"
    )
    st.write(f"**Output columns:** {', '.join(st.session_state.get('dec_output_cols', []))}")

    warehouse = st.text_input("Warehouse", placeholder="MY_WAREHOUSE")

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 4
            st.rerun()
    with col2:
        if st.button(":material/play_arrow: Run Job", disabled=not warehouse, type="primary"):
            with st.spinner("Running LocID Decrypt job…"):
                try:
                    logger.info(session, "03_run_decrypt.run_job",
                                f"Job started: {st.session_state.dec_input_table} → "
                                f"{st.session_state.dec_output_table}")
                    raw = session.call(
                        "APP_SCHEMA.LOCID_DECRYPT",
                        st.session_state.dec_input_table,
                        st.session_state.dec_output_table,
                        st.session_state.dec_col_id,
                        st.session_state.dec_col_txclo,
                        st.session_state.dec_output_cols,
                        warehouse,
                    )
                    result = json.loads(raw) if isinstance(raw, str) else raw
                    status = result.get("status", "UNKNOWN")
                    if status == "SUCCESS":
                        st.success(
                            f"Job complete — "
                            f"{result.get('rows_out', 0):,} rows decoded "
                            f"out of {result.get('rows_in', 0):,} "
                            f"in {result.get('runtime_s', 0):.1f}s",
                            icon=":material/check_circle:"
                        )
                        st.caption(f"Job ID: {result.get('job_id', '—')}")
                        logger.info(session, "03_run_decrypt.run_job",
                                    f"Job SUCCESS: id={result.get('job_id')}, "
                                    f"rows_out={result.get('rows_out')}")
                    else:
                        err = result.get("error", status)
                        st.error(f"Job failed — {err}", icon=":material/error:")
                        logger.error(session, "03_run_decrypt.run_job",
                                     f"Job FAILED: {err}")
                except Exception as e:
                    logger.error(session, "03_run_decrypt.run_job",
                                 "Job threw an exception", exc=e)
                    st.error(f"Error running decrypt job: {e}", icon=":material/error:")

            # Reset for next run; discard heavy state
            for key in ("dec_input_columns",):
                st.session_state.pop(key, None)
            st.session_state.dec_step = 1
