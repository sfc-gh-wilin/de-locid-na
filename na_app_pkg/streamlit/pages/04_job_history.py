"""
streamlit/pages/04_job_history.py
LocID Native App — Job History (View 5)

Full audit log of all Encrypt and Decrypt jobs.
Filters: operation, status, date range.
Expandable row detail with error messages and re-run shortcut.
CSV export with immediate memory cleanup.
"""

import pandas as pd

import streamlit as st
from snowflake.snowpark.context import get_active_session
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

st.markdown("## :material/history: Job History")
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
# Cached query (TTL 30 s — short enough to see new jobs quickly)
# ---------------------------------------------------------------------------
@st.cache_data(ttl=30, show_spinner=False)
def _fetch_jobs(_session_id: int, op: str, status: str,
                dr_start: str, dr_end: str) -> list:
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()

    where_parts = []
    if op != "All":
        where_parts.append(f"operation = '{op}'")
    if status != "All":
        where_parts.append(f"status = '{status}'")
    if dr_start and dr_end:
        where_parts.append(
            f"run_dt::DATE BETWEEN '{dr_start}' AND '{dr_end}'"
        )
    where_sql = ("WHERE " + " AND ".join(where_parts)) if where_parts else ""

    rows = _session.sql(f"""
        SELECT job_id, operation, run_dt, rows_in, rows_out,
               runtime_s, status, error_msg, input_table, output_table
        FROM APP_SCHEMA.JOB_LOG
        {where_sql}
        ORDER BY run_dt DESC
        LIMIT 200
    """).collect()
    return [tuple(r) for r in rows]


dr_start = str(date_range[0]) if len(date_range) == 2 else ""
dr_end   = str(date_range[1]) if len(date_range) == 2 else ""

rows = _fetch_jobs(sid, op_filter, st_filter, dr_start, dr_end)

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
if not rows:
    st.info("No jobs found matching the selected filters.")
else:
    st.caption(f"Showing {len(rows)} job(s)")
    for row in rows:
        job_id    = row[0]
        operation = row[1]
        run_dt    = row[2]
        rows_in   = row[3] or 0
        rows_out  = row[4] or 0
        runtime_s = row[5] or 0
        status    = row[6]
        error_msg = row[7]

        status_icon = ":material/check_circle:" if status == "SUCCESS" else ":material/error:"
        label = (
            f"{status_icon} `{job_id[:8]}` · **{operation}** · "
            f"{str(run_dt)[:16]} · {rows_out:,} rows · {runtime_s}s · {status}"
        )

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
                st.error(f"Error: {error_msg}", icon=":material/error:")
            if st.button(":material/replay: Re-run with same settings",
                         key=f"rerun_{job_id}"):
                logger.info(session, "04_job_history.rerun",
                            f"Re-run requested for job {job_id}")
                page = ("pages/02_run_encrypt.py" if operation == "ENCRYPT"
                        else "pages/03_run_decrypt.py")
                st.switch_page(page)

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
if rows:
    cols = ["job_id", "operation", "run_dt", "rows_in", "rows_out",
            "runtime_s", "status", "error_msg", "input_table", "output_table"]
    df = pd.DataFrame(rows, columns=cols)
    csv_bytes = df.to_csv(index=False).encode()
    del df  # free memory immediately after serialising

    st.download_button(
        label=":material/download: Export as CSV",
        data=csv_bytes,
        file_name="locid_job_history.csv",
        mime="text/csv",
    )
    logger.debug(session, "04_job_history.export",
                 f"CSV export prepared: {len(rows)} rows")
