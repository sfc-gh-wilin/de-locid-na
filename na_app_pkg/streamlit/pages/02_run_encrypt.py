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

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_active_output_cols, check_entitlement

session = get_active_session()

st.title("Run Encrypt")
st.caption("Match IP + timestamp data against the LocID data lake.")
st.divider()

# ---------------------------------------------------------------------------
# Step state
# ---------------------------------------------------------------------------
if "enc_step" not in st.session_state:
    st.session_state.enc_step = 1

step = st.session_state.enc_step
steps = ["Input", "Map Columns", "Output", "Options", "Review & Run"]

# Progress bar
st.progress((step - 1) / (len(steps) - 1), text=f"Step {step} of {len(steps)}: {steps[step-1]}")
st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Select Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader("Step 1 — Select Input Table")
    # TODO: query INFORMATION_SCHEMA for tables the app has SELECT on
    input_table = st.text_input("Input table (fully qualified)",
                                placeholder="MY_DB.MY_SCHEMA.MY_TABLE")
    if input_table:
        st.caption("Preview (first 5 rows):")
        # TODO: SELECT * FROM <input_table> LIMIT 5
        st.info("Table preview will appear here.")
    if st.button("Next →", disabled=not input_table):
        st.session_state.enc_input_table = input_table
        st.session_state.enc_step = 2
        st.rerun()

# ---------------------------------------------------------------------------
# Step 2 — Map Columns
# ---------------------------------------------------------------------------
elif step == 2:
    st.subheader("Step 2 — Map Columns")
    # TODO: load column list from selected input table
    columns = ["(load columns from table)"]
    col_id = st.selectbox("Unique Row ID", columns)
    col_ip = st.selectbox("IP Address",    columns)
    col_ts = st.selectbox("Timestamp",     columns)
    ts_fmt = st.selectbox("Timestamp Format",
                          ["epoch_sec", "epoch_ms", "timestamp_string"])
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 1; st.rerun()
    with col2:
        if st.button("Next →"):
            st.session_state.enc_col_id = col_id
            st.session_state.enc_col_ip = col_ip
            st.session_state.enc_col_ts = col_ts
            st.session_state.enc_ts_fmt = ts_fmt
            st.session_state.enc_step   = 3; st.rerun()

# ---------------------------------------------------------------------------
# Step 3 — Configure Output
# ---------------------------------------------------------------------------
elif step == 3:
    st.subheader("Step 3 — Configure Output")
    output_mode  = st.radio("", ["Create new table", "Overwrite existing table"])
    output_table = st.text_input("Output table (fully qualified)",
                                 placeholder="MY_DB.MY_SCHEMA.LOCID_RESULTS")
    if output_mode == "Overwrite existing table" and output_table:
        st.warning(f"This will overwrite **{output_table}**. Existing data will be lost.")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 2; st.rerun()
    with col2:
        if st.button("Next →", disabled=not output_table):
            st.session_state.enc_output_table = output_table
            st.session_state.enc_step = 4; st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader("Step 4 — Select Output Columns")
    available_cols = get_active_output_cols(session, "encrypt")
    selected = []
    for col in available_cols:
        disabled = not col["enabled"]
        label    = col["col_name"]
        tooltip  = f"Requires entitlement: {col['requires_entitlement']}" if disabled else ""
        checked  = st.checkbox(label, value=col["enabled"],
                               disabled=disabled, help=tooltip or None)
        if checked:
            selected.append(col["col_name"])
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 3; st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.enc_output_cols = selected
            st.session_state.enc_step = 5; st.rerun()

# ---------------------------------------------------------------------------
# Step 5 — Review & Run
# ---------------------------------------------------------------------------
elif step == 5:
    st.subheader("Step 5 — Review & Run")
    st.write(f"**Input table:** `{st.session_state.get('enc_input_table')}`")
    st.write(f"**Output table:** `{st.session_state.get('enc_output_table')}`")
    st.write(f"**Columns mapped:** ID={st.session_state.get('enc_col_id')}, "
             f"IP={st.session_state.get('enc_col_ip')}, TS={st.session_state.get('enc_col_ts')}")
    st.write(f"**Output columns:** {', '.join(st.session_state.get('enc_output_cols', []))}")

    # TODO: warehouse selector (dropdown of warehouses app has USAGE on)
    warehouse = st.text_input("Warehouse", placeholder="MY_WAREHOUSE")

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.enc_step = 4; st.rerun()
    with col2:
        if st.button("Run Job", disabled=not warehouse, type="primary"):
            with st.spinner("Running LocID Encrypt job…"):
                # TODO: call LOCID_ENCRYPT stored procedure
                # session.call("APP_SCHEMA.LOCID_ENCRYPT", ...)
                st.success("Job completed successfully.")  # placeholder
            st.session_state.enc_step = 1  # reset for next run
