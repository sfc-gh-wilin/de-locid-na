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
import time
from datetime import datetime, timezone

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

st.header(":material/lock_open: Run Decrypt")
st.caption("Decode TX_CLOC values back to STABLE_CLOC and geo context.")
with st.expander("💡 Tips", expanded=False):
    st.markdown(
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
        "    'DECRYPT_INPUT_TABLE', 'ADD',\n"
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


# ---------------------------------------------------------------------------
# Entitlement gate — block the entire workflow if allow_decrypt is missing
# ---------------------------------------------------------------------------
if 'allow_decrypt' not in get_active_entitlements(sid):
    st.error(
        "Your LocID license does not include the **Decrypt** entitlement (`allow_decrypt`). "
        "Contact LocID to upgrade your access.",
        icon="🔒",
    )
    st.stop()


# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "dec_step" not in st.session_state:
    st.session_state.dec_step = 1

step  = st.session_state.dec_step
steps = ["Input", "Map Columns", "Output Columns", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1),
            text=f"Step {step} of {len(steps)}: {steps[step-1]}")
# st.divider()

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
        col_id    = st.selectbox("Unique Row ID", columns,
                                  index=_best_match(columns,
                                      ['id', 'row_id', 'unique_id', 'uid',
                                       'customer_id', 'user_id', 'record_id', 'key']))
        col_txclo = st.selectbox("TX_CLOC",       columns,
                                  index=_best_match(columns,
                                      ['tx_cloc', 'txcloc', 'cloc', 'tx_loc']))
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
            t_start = time.time()
            with st.status("Running LocID Decrypt job…", expanded=True) as job_status:
                st.write(f"**Started at:** {datetime.now(timezone.utc).strftime('%H:%M:%S')} UTC")
                try:
                    logger.info(session, "run_decrypt.run_job",
                                f"Job started: input={st.session_state.dec_input_table}")
                    raw = session.call(
                        "APP_SCHEMA.LOCID_DECRYPT",
                        st.session_state.dec_col_id,
                        st.session_state.dec_col_txclo,
                        st.session_state.dec_output_cols,
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
                            f"{result.get('rows_out', 0):,} rows decoded "
                            f"out of {result.get('rows_in', 0):,} "
                            f"in {result.get('runtime_s', 0):.1f}s",
                            icon="✅"
                        )
                        st.info(f"Output table: `{result.get('output_table', '—')}`")
                        st.caption(f"Job ID: {result.get('job_id', '—')}")
                        logger.info(session, "run_decrypt.run_job",
                                    f"Job SUCCESS: id={result.get('job_id')}, "
                                    f"rows_out={result.get('rows_out')}, "
                                    f"elapsed={elapsed:.1f}s")
                        # Reset for next run; discard heavy state
                        for key in ("dec_input_columns",):
                            st.session_state.pop(key, None)
                        st.session_state.dec_step = 1
                    else:
                        elapsed = time.time() - t_start
                        job_status.update(
                            label=f"Job failed — elapsed {elapsed:.1f}s",
                            state="error", expanded=True,
                        )
                        err = result.get("error", status)
                        show_error(f"Job failed — {err}")
                        logger.error(session, "run_decrypt.run_job",
                                     f"Job FAILED: {err}")
                except Exception as e:
                    elapsed = time.time() - t_start
                    job_status.update(
                        label=f"Job error — elapsed {elapsed:.1f}s",
                        state="error", expanded=True,
                    )
                    logger.error(session, "run_decrypt.run_job",
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
                            "VALUES (?, 'DECRYPT', NULL, NULL, NULL, ?, 'FAILED', ?, ?, NULL, NULL, NULL)",
                            params=[
                                str(_uuid.uuid4()), round(elapsed, 2), str(e)[:2000],
                                st.session_state.get('dec_input_table', '—'),
                            ],
                        ).collect()
                    except Exception:
                        pass  # Best-effort — don't mask the original error
                    show_error(f"Decrypt job failed unexpectedly (elapsed: {elapsed:.1f}s).",
                               detail=e)

else:
    # Invalid step state — reset to prevent blank page
    st.session_state.dec_step = 1
    st.rerun()
