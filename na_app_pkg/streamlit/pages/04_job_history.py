"""
streamlit/pages/04_job_history.py
LocID Native App — Job History (View 5)

Full audit log of all Encrypt and Decrypt jobs.
Filters: operation, status, date range.
Expandable row detail with error messages and re-run shortcut.
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.title("Job History")
st.caption("Full audit log of all LocID enrichment jobs.")
st.divider()

# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------
fc1, fc2, fc3 = st.columns(3)
with fc1:
    op_filter = st.selectbox("Operation", ["All", "ENCRYPT", "DECRYPT"])
with fc2:
    st_filter = st.selectbox("Status", ["All", "SUCCESS", "FAILED"])
with fc3:
    date_range = st.date_input("Date range", value=[], help="Leave empty for all dates")

# ---------------------------------------------------------------------------
# Query JOB_LOG
# ---------------------------------------------------------------------------
where_clauses = []
if op_filter != "All":
    where_clauses.append(f"operation = '{op_filter}'")
if st_filter != "All":
    where_clauses.append(f"status = '{st_filter}'")
if len(date_range) == 2:
    where_clauses.append(f"run_dt::DATE BETWEEN '{date_range[0]}' AND '{date_range[1]}'")

where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
query      = f"""
    SELECT job_id, operation, run_dt, rows_in, rows_out, runtime_s,
           status, error_msg, input_table, output_table
    FROM APP_SCHEMA.JOB_LOG
    {where_sql}
    ORDER BY run_dt DESC
    LIMIT 200
"""

rows = session.sql(query).collect()

if not rows:
    st.info("No jobs found matching the selected filters.")
else:
    for row in rows:
        job_id    = row[0]
        operation = row[1]
        run_dt    = row[2]
        rows_in   = row[3] or 0
        rows_out  = row[4] or 0
        runtime_s = row[5] or 0
        status    = row[6]
        error_msg = row[7]

        icon  = "✓" if status == "SUCCESS" else "✗"
        label = (f"{icon} {job_id[:8]}  ·  {operation}  ·  {str(run_dt)[:16]}  ·  "
                 f"{rows_out:,} rows  ·  {runtime_s}s  ·  {status}")

        with st.expander(label):
            c1, c2 = st.columns(2)
            with c1:
                st.write(f"**Job ID:** `{job_id}`")
                st.write(f"**Input table:** `{row[8]}`")
                st.write(f"**Output table:** `{row[9]}`")
            with c2:
                st.metric("Rows in",  f"{rows_in:,}")
                st.metric("Rows out", f"{rows_out:,}")
                st.metric("Runtime",  f"{runtime_s}s")
            if error_msg:
                st.error(f"Error: {error_msg}")
            if st.button("Re-run with same settings", key=f"rerun_{job_id}"):
                # TODO: pre-fill Run Encrypt/Decrypt form with this job's settings
                page = "pages/02_run_encrypt.py" if operation == "ENCRYPT" else "pages/03_run_decrypt.py"
                st.switch_page(page)

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
if rows:
    import pandas as pd
    df = pd.DataFrame([dict(zip(
        ["job_id","operation","run_dt","rows_in","rows_out",
         "runtime_s","status","error_msg","input_table","output_table"], r
    )) for r in rows])
    st.download_button("Export as CSV", df.to_csv(index=False),
                       file_name="locid_job_history.csv", mime="text/csv")
