"""
streamlit/app.py
LocID Native App — Home View (View 1)

Entry point for the multi-page Streamlit app. Displays the status dashboard:
  - License status card
  - LocID Central connectivity card
  - Last job summary card
  - Quick-action buttons
  - Setup banner (if onboarding not complete)
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.entitlements import get_entitlements

st.set_page_config(page_title="LocID for Snowflake", layout="wide")

session = get_active_session()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def get_config(key: str) -> str | None:
    rows = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0][0] if rows else None


def get_last_job() -> dict | None:
    rows = session.sql(
        "SELECT operation, rows_in, rows_out, runtime_s, status, run_dt "
        "FROM APP_SCHEMA.JOB_LOG ORDER BY run_dt DESC LIMIT 1"
    ).collect()
    if not rows:
        return None
    r = rows[0]
    return {
        "operation": r[0], "rows_in": r[1], "rows_out": r[2],
        "runtime_s": r[3], "status": r[4], "run_dt": r[5]
    }


# ---------------------------------------------------------------------------
# Onboarding banner
# ---------------------------------------------------------------------------
onboarding_complete = get_config("onboarding_complete") == "true"
if not onboarding_complete:
    st.warning(
        "Setup is not complete. Open **Setup Wizard** from the sidebar to "
        "finish configuring your LocID license and connectivity.",
        icon="⚠️"
    )

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
st.title("LocID for Snowflake")
st.caption("Digital Envoy / Matchbook Data — Batch LocID Enrichment")
st.divider()

# ---------------------------------------------------------------------------
# Status cards
# ---------------------------------------------------------------------------
col_lic, col_central, col_job = st.columns(3)

with col_lic:
    st.subheader("License")
    # TODO: read license status from APP_CONFIG / LocID Central cache
    st.metric("Status", "ACTIVE")          # placeholder
    st.caption("Exp: 2027-01")             # placeholder

with col_central:
    st.subheader("LocID Central")
    # TODO: read last_refreshed_at from APP_CONFIG
    st.metric("Status", "CONNECTED")       # placeholder
    st.caption("Refreshed 2m ago")         # placeholder

with col_job:
    st.subheader("Last Job")
    last = get_last_job()
    if last:
        label = f"{last['operation']} · {last['rows_out']:,} rows"
        st.metric("Status", last["status"])
        st.caption(label)
    else:
        st.metric("Status", "—")
        st.caption("No jobs run yet")

st.divider()

# ---------------------------------------------------------------------------
# Quick-action buttons
# ---------------------------------------------------------------------------
btn_col1, btn_col2, btn_col3 = st.columns(3)
with btn_col1:
    if st.button("Run Encrypt", use_container_width=True, disabled=not onboarding_complete):
        st.switch_page("pages/02_run_encrypt.py")
with btn_col2:
    if st.button("Run Decrypt", use_container_width=True, disabled=not onboarding_complete):
        st.switch_page("pages/03_run_decrypt.py")
with btn_col3:
    if st.button("View History", use_container_width=True):
        st.switch_page("pages/04_job_history.py")
