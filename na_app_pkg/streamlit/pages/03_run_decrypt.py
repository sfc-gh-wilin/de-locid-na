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

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_active_output_cols

session = get_active_session()

st.title("Run Decrypt")
st.caption("Decode TX_CLOC values back to STABLE_CLOC and geo context.")
st.divider()

if "dec_step" not in st.session_state:
    st.session_state.dec_step = 1

step  = st.session_state.dec_step
steps = ["Input", "Map Columns", "Output", "Options", "Review & Run"]

st.progress((step - 1) / (len(steps) - 1), text=f"Step {step} of {len(steps)}: {steps[step-1]}")
st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Select Input Table
# ---------------------------------------------------------------------------
if step == 1:
    st.subheader("Step 1 — Select Input Table")
    input_table = st.text_input("Input table (fully qualified)",
                                placeholder="MY_DB.MY_SCHEMA.MY_TABLE")
    if input_table:
        st.caption("Preview (first 5 rows):")
        st.info("Table preview will appear here.")  # TODO
    if st.button("Next →", disabled=not input_table):
        st.session_state.dec_input_table = input_table
        st.session_state.dec_step = 2; st.rerun()

# ---------------------------------------------------------------------------
# Step 2 — Map Columns
# ---------------------------------------------------------------------------
elif step == 2:
    st.subheader("Step 2 — Map Columns")
    columns = ["(load columns from table)"]  # TODO
    col_id    = st.selectbox("Unique Row ID", columns)
    col_txclo = st.selectbox("TX_CLOC",       columns)
    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 1; st.rerun()
    with col2:
        if st.button("Next →"):
            st.session_state.dec_col_id    = col_id
            st.session_state.dec_col_txclo = col_txclo
            st.session_state.dec_step      = 3; st.rerun()

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
            st.session_state.dec_step = 2; st.rerun()
    with col2:
        if st.button("Next →", disabled=not output_table):
            st.session_state.dec_output_table = output_table
            st.session_state.dec_step = 4; st.rerun()

# ---------------------------------------------------------------------------
# Step 4 — Select Output Columns
# ---------------------------------------------------------------------------
elif step == 4:
    st.subheader("Step 4 — Select Output Columns")
    available_cols = get_active_output_cols(session, "decrypt")
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
            st.session_state.dec_step = 3; st.rerun()
    with col2:
        if st.button("Next →", disabled=not selected):
            st.session_state.dec_output_cols = selected
            st.session_state.dec_step = 5; st.rerun()

# ---------------------------------------------------------------------------
# Step 5 — Review & Run
# ---------------------------------------------------------------------------
elif step == 5:
    st.subheader("Step 5 — Review & Run")
    st.write(f"**Input table:** `{st.session_state.get('dec_input_table')}`")
    st.write(f"**Output table:** `{st.session_state.get('dec_output_table')}`")
    st.write(f"**Columns mapped:** ID={st.session_state.get('dec_col_id')}, "
             f"TX_CLOC={st.session_state.get('dec_col_txclo')}")
    st.write(f"**Output columns:** {', '.join(st.session_state.get('dec_output_cols', []))}")

    warehouse = st.text_input("Warehouse", placeholder="MY_WAREHOUSE")

    col1, col2 = st.columns(2)
    with col1:
        if st.button("← Back"):
            st.session_state.dec_step = 4; st.rerun()
    with col2:
        if st.button("Run Job", disabled=not warehouse, type="primary"):
            with st.spinner("Running LocID Decrypt job…"):
                # TODO: call LOCID_DECRYPT stored procedure
                # session.call("APP_SCHEMA.LOCID_DECRYPT", ...)
                st.success("Job completed successfully.")  # placeholder
            st.session_state.dec_step = 1
