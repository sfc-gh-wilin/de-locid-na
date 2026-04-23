"""
streamlit/app.py
LocID Native App — Home (View 1)

Entry point for the multi-page Streamlit app. Displays the status dashboard:
  - License status card
  - LocID Central connectivity card
  - Last job summary card
  - Quick-action buttons
  - Entitlements panel
  - Recent activity feed
"""

import json
from datetime import timezone

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils import logger

st.set_page_config(page_title="LocID for Snowflake", layout="wide")
st.logo("logo.svg")

session = get_active_session()


# ---------------------------------------------------------------------------
# Batched config fetch — one round-trip for all home-view keys
# ---------------------------------------------------------------------------
@st.cache_data(ttl=60, show_spinner=False)
def _load_home_data(_session_id: int) -> dict:
    """
    Fetch APP_CONFIG rows needed for the home view in a single query.
    Keyed by _session_id (an int proxy) to scope cache per Snowflake session.
    Returns a flat dict: {config_key: config_value}.
    """
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT config_key, config_value, last_refreshed_at "
        "FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key IN ('onboarding_complete', 'cached_license') "
        "AND is_active = TRUE"
    ).collect()
    return {r[0]: (r[1], r[2]) for r in rows}


@st.cache_data(ttl=30, show_spinner=False)
def _load_last_job(_session_id: int) -> dict | None:
    """Return the most recent JOB_LOG row as a dict, or None."""
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT job_id, operation, rows_in, rows_out, runtime_s, status, run_dt "
        "FROM APP_SCHEMA.JOB_LOG ORDER BY run_dt DESC LIMIT 1"
    ).collect()
    if not rows:
        return None
    r = rows[0]
    return {
        "job_id": r[0], "operation": r[1], "rows_in": r[2],
        "rows_out": r[3], "runtime_s": r[4], "status": r[5], "run_dt": r[6],
    }


@st.cache_data(ttl=30, show_spinner=False)
def _load_recent_jobs(_session_id: int) -> list:
    """Return up to 5 recent JOB_LOG rows for the activity feed."""
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT job_id, operation, rows_out, status "
        "FROM APP_SCHEMA.JOB_LOG ORDER BY run_dt DESC LIMIT 5"
    ).collect()
    return [{"job_id": r[0], "operation": r[1], "rows_out": r[2], "status": r[3]}
            for r in rows]


# Stable proxy for cache keying — uses Snowflake session ID (int)
@st.cache_resource(show_spinner=False)
def _session_id() -> int:
    from snowflake.snowpark.context import get_active_session as _gas
    try:
        return int(_gas().sql("SELECT CURRENT_SESSION()").collect()[0][0])
    except Exception:
        return 0


sid = _session_id()
config    = _load_home_data(sid)
last_job  = _load_last_job(sid)

onboarding_complete = config.get("onboarding_complete", ("false", None))[0] == "true"

# ---------------------------------------------------------------------------
# Onboarding banner
# ---------------------------------------------------------------------------
if not onboarding_complete:
    st.warning(
        "Setup is not complete. Open **Setup Wizard** from the sidebar to "
        "finish configuring your LocID license and connectivity.",
        icon=":material/warning:"
    )

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
st.markdown("## :material/dashboard: LocID for Snowflake")
st.caption("Location identity enrichment — running entirely inside your Snowflake account.")
st.divider()

# ---------------------------------------------------------------------------
# Status cards (License · LocID Central · Last Job)
# ---------------------------------------------------------------------------
def _parse_license(raw: str | None) -> tuple[str, str, str]:
    """Return (status, client_name, expiry_label) from cached_license JSON."""
    if not raw:
        return "NOT CONFIGURED", "—", "—"
    try:
        lic     = json.loads(raw).get("license", {})
        status  = lic.get("status", "UNKNOWN")
        client  = lic.get("client_name", "—")
        expiry  = lic.get("expiration_date", "")
        exp_str = expiry[:10] if expiry else "—"
        return status, client, exp_str
    except Exception:
        return "UNKNOWN", "—", "—"


def _central_refresh_label(refreshed_at) -> tuple[str, bool]:
    """Return (label, is_fresh) where is_fresh = refreshed within 24 h."""
    if not refreshed_at:
        return "Never refreshed", False
    try:
        from snowflake.snowpark.context import get_active_session as _gas
        rows = _gas().sql(
            "SELECT DATEDIFF('minute', ?, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))",
            params=[refreshed_at]
        ).collect()
        mins = int(rows[0][0]) if rows and rows[0][0] is not None else None
        if mins is None:
            return "Unknown", False
        fresh = mins < 1440  # 24 hours
        if mins < 2:
            return "Just now", fresh
        if mins < 60:
            return f"Refreshed {mins}m ago", fresh
        return f"Refreshed {mins // 60}h ago", fresh
    except Exception:
        return "Unknown", False


cached_raw, refreshed_at = config.get("cached_license", (None, None))
lic_status, client_name, lic_expiry = _parse_license(cached_raw)
central_label, central_fresh = _central_refresh_label(refreshed_at)

col_lic, col_central, col_job = st.columns(3)

with col_lic:
    st.markdown("#### :material/verified_user: License")
    st.metric("Status", lic_status)
    st.caption(f"Client: {client_name} · Exp: {lic_expiry}")

with col_central:
    st.markdown("#### :material/cloud: LocID Central")
    st.metric("Status", "CONNECTED" if central_fresh else "STALE")
    st.caption(central_label)

with col_job:
    st.markdown("#### :material/history: Last Job")
    if last_job:
        st.metric("Status", last_job["status"])
        rows_label = f"{last_job['rows_out']:,}" if last_job["rows_out"] is not None else "—"
        st.caption(
            f"{last_job['operation']} · {rows_label} rows · "
            f"{last_job['runtime_s'] or 0:.1f}s"
        )
    else:
        st.metric("Status", "—")
        st.caption("No jobs run yet")

st.divider()

# ---------------------------------------------------------------------------
# Quick-action buttons
# ---------------------------------------------------------------------------
btn1, btn2, btn3 = st.columns(3)
with btn1:
    if st.button(":material/lock: Run Encrypt", use_container_width=True,
                 disabled=not onboarding_complete):
        st.switch_page("pages/02_run_encrypt.py")
with btn2:
    if st.button(":material/lock_open: Run Decrypt", use_container_width=True,
                 disabled=not onboarding_complete):
        st.switch_page("pages/03_run_decrypt.py")
with btn3:
    if st.button(":material/history: View Job History", use_container_width=True):
        st.switch_page("pages/04_job_history.py")

st.divider()

# ---------------------------------------------------------------------------
# Entitlements + Recent Activity (two-column layout matching mockup)
# ---------------------------------------------------------------------------
ent_col, act_col = st.columns(2)

with ent_col:
    st.markdown("#### :material/verified: Your Entitlements")
    st.caption("Fetched from LocID Central — drives output columns.")

    ALL_FLAGS = ["allow_encrypt", "allow_decrypt", "allow_tx",
                 "allow_stable", "allow_geo_context"]
    active_flags: set[str] = set()
    if cached_raw:
        try:
            data = json.loads(cached_raw)
            for entry in data.get("access", []):
                if entry.get("status") == "ACTIVE":
                    active_flags = {f for f in ALL_FLAGS if entry.get(f) is True}
                    break
        except Exception:
            pass

    flag_cols = st.columns(3)
    for i, flag in enumerate(ALL_FLAGS):
        with flag_cols[i % 3]:
            if flag in active_flags:
                st.success(f"✓ {flag}", icon=None)
            else:
                st.error(f"✗ {flag}", icon=None)

with act_col:
    st.markdown("#### :material/timeline: Recent Activity")
    recent = _load_recent_jobs(sid)
    if recent:
        for job in recent:
            icon  = ":material/check_circle:" if job["status"] == "SUCCESS" else ":material/error:"
            rows  = f"{job['rows_out']:,}" if job["rows_out"] is not None else "—"
            color = "green" if job["status"] == "SUCCESS" else "red"
            st.markdown(
                f"{icon} `{job['job_id'][:8]}` &nbsp; **{job['operation']}** &nbsp; "
                f"{rows} rows &nbsp; :{color}[{job['status']}]",
                unsafe_allow_html=False,
            )
    else:
        st.info("No jobs run yet.")

# ---------------------------------------------------------------------------
# Sidebar footer — client info
# ---------------------------------------------------------------------------
if client_name != "—":
    st.sidebar.markdown("---")
    st.sidebar.caption(f"**{client_name}**")

logger.debug(session, "app.main", "Home view loaded")
