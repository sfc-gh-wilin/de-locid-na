"""
streamlit/views/run_decrypt.py
LocID Native App — Run Decrypt (View 4)

4-step job submission wizard:
  1. Input table   (auto-populated from DECRYPT_INPUT_TABLE reference if bound)
  2. Map columns   (unique_id, tx_cloc)
  3. Output columns (gated by entitlement)
  4. Review & Run
"""

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_active_output_cols
from utils import logger

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

st.header(":material/lock_open: Run Decrypt")
st.caption("Decode TX_CLOC values back to STABLE_CLOC and geo context.")
st.divider()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
        logger.warning(session, "run_decrypt._get_bound_table",
                       f"Failed to resolve reference {ref_name}: {e}")
    return None


def _get_ref_columns(ref_name: str) -> list[str]:
    """Return ordered column names for a table bound via reference.

    Uses DESCRIBE TABLE reference(...) — the only authorized path inside a
    Native App for consumer tables accessed through a reference binding.
    """
    try:
        rows = session.sql(f"DESCRIBE TABLE reference('{ref_name}')").collect()
        return [r[0] for r in rows]
    except Exception as e:
        logger.warning(session, "run_decrypt._get_ref_columns",
                       f"Failed to describe reference {ref_name}: {e}")
        return []


# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "dec_step" not in st.session_state:
    st.session_state.dec_step = 1

step  = st.session_state.dec_step
steps = ["Input", "Map Columns", "Output Columns", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1),
            text=f"Step {step} of {len(steps)}: {steps[step-1]}")
st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader(":material/table_view: Step 1 — Input Table")

    bound = _get_bound_table('DECRYPT_INPUT_TABLE')

    if bound:
        st.info(f"Using pre-configured input table: `{bound}`", icon="✅")
        st.caption(
            "To use a different table, click the **⚙ Settings** icon (top right) "
            "→ **Permissions** → re-bind **Input Table for Decrypt**."
        )
        st.caption("Preview (first 5 rows):")
        try:
            preview = session.sql(
                "SELECT * FROM reference('DECRYPT_INPUT_TABLE') LIMIT 5"
            ).to_pandas()
            st.dataframe(preview, use_container_width=True)
            del preview
        except Exception as e:
            st.warning(f"Could not load preview: {e}")
        if st.button("Next →", type="primary"):
            cols = _get_ref_columns('DECRYPT_INPUT_TABLE')
            if not cols:
                st.error("Could not read columns. Check that the table exists and the app has SELECT access.")
            else:
                st.session_state.dec_input_table   = bound
                st.session_state.dec_input_columns = cols
                st.session_state.dec_step          = 2
                st.rerun()
    else:
        st.warning(
            "No input table is configured yet. "
            "Click the **⚙ Settings** icon (top right) → **Permissions** → "
            "grant and bind **Input Table for Decrypt**.",
            icon="⚠️",
        )

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
# Step 3 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 3:
    st.subheader(":material/view_column: Step 3 — Select Output Columns")
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
            st.session_state.dec_step = 2
            st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.dec_output_cols = selected
            st.session_state.dec_step = 4
            st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Review & Run
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader(":material/play_arrow: Step 4 — Review & Run")
    st.write(f"**Input table:** `{st.session_state.get('dec_input_table')}`")
    st.write(
        f"**Columns mapped:** ID={st.session_state.get('dec_col_id')}, "
        f"TX_CLOC={st.session_state.get('dec_col_txclo')}"
    )
    st.write(f"**Output columns:** {', '.join(st.session_state.get('dec_output_cols', []))}")
    st.caption(
        "Output will be written to an auto-named table in APP_SCHEMA "
        "(e.g. LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS)."
    )

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 3
            st.rerun()
    with col2:
        if st.button(":material/play_arrow: Run Job", type="primary"):
            with st.spinner("Running LocID Decrypt job…"):
                try:
                    logger.info(session, "run_decrypt.run_job",
                                f"Job started: input={st.session_state.dec_input_table}")
                    raw = session.call(
                        "APP_SCHEMA.LOCID_DECRYPT",
                        st.session_state.dec_col_id,
                        st.session_state.dec_col_txclo,
                        st.session_state.dec_output_cols,
                    )
                    result = json.loads(raw) if isinstance(raw, str) else raw
                    status = result.get("status", "UNKNOWN")
                    if status == "SUCCESS":
                        st.success(
                            f"Job complete — "
                            f"{result.get('rows_out', 0):,} rows decoded "
                            f"out of {result.get('rows_in', 0):,} "
                            f"in {result.get('runtime_s', 0):.1f}s",
                            icon="✅"
                        )
                        st.info(f"Output table: `{result.get('output_table', '—')}`")
                        st.caption(f"Job ID: {result.get('job_id', '—')}")
                        logger.info(session, "run_decrypt.run_job",
                                    f"Job SUCCESS: id={result.get('job_id')}, "
                                    f"rows_out={result.get('rows_out')}")
                    else:
                        err = result.get("error", status)
                        st.error(f"Job failed — {err}", icon="❌")
                        logger.error(session, "run_decrypt.run_job",
                                     f"Job FAILED: {err}")
                except Exception as e:
                    logger.error(session, "run_decrypt.run_job",
                                 "Job threw an exception", exc=e)
                    st.error(f"Error running decrypt job: {e}", icon="❌")

            # Reset for next run; discard heavy state
            for key in ("dec_input_columns",):
                st.session_state.pop(key, None)
            st.session_state.dec_step = 1
