"""
streamlit/Home.py
LocID Native App — navigation entry point

Sets page config and logo, then defines the multi-page app via st.navigation().
All view content lives in streamlit/views/.
Requires Streamlit 1.36+ (bundled via environment.yml: streamlit=1.42.0).

Sidebar footer is rendered here so it appears consistently on every page.
"""

import json

import streamlit as st

st.set_page_config(page_title="LocID for Snowflake", layout="wide")
st.logo("logo.svg")

pg = st.navigation([
    st.Page("views/home.py",          title="Home",          icon=":material/home:"),
    st.Page("views/run_encrypt.py",   title="Run Encrypt",   icon=":material/lock:"),
    st.Page("views/run_decrypt.py",   title="Run Decrypt",   icon=":material/lock_open:"),
    st.Page("views/job_history.py",   title="Job History",   icon=":material/history:"),
    st.Page("views/sql_guide.py",     title="SQL Guide",     icon=":material/terminal:"),
    st.Page("views/configuration.py", title="Configuration", icon=":material/tune:"),
    st.Page("views/setup_wizard.py", title="Setup Wizard", icon=":material/settings:"),
])
pg.run()


# =============================================================================
# Sidebar footer — rendered after every page so it appears on all views.
# Reads: client name (from cached_license), app version, and central_env
# (written by LOCID_SET_DEV_ENV) in a single APP_CONFIG query.
# =============================================================================

@st.cache_data(ttl=60, show_spinner=False)
def _sidebar_footer_data() -> dict:
    """Single-query fetch of all sidebar footer fields."""
    from snowflake.snowpark.context import get_active_session as _gas
    _s = _gas()
    try:
        rows = _s.sql(
            "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
            "WHERE config_key IN ('cached_license', 'central_env') "
            "AND is_active = TRUE"
        ).collect()
        return {r[0]: r[1] for r in rows}
    except Exception:
        return {}


@st.cache_data(ttl=300, show_spinner=False)
def _get_app_version() -> str:
    from snowflake.snowpark.context import get_active_session as _gas
    _s = _gas()
    try:
        rows = _s.sql(
            "SELECT SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'CURRENT_VERSION'), "
            "SYS_CONTEXT('SNOWFLAKE$APPLICATION', 'CURRENT_PATCH')"
        ).collect()
        ver   = rows[0][0] if rows and rows[0][0] else "—"
        patch = rows[0][1] if rows and rows[0][1] is not None else "0"
        return f"{ver} · {patch}"
    except Exception:
        return "—"


footer = _sidebar_footer_data()

# Client name from cached_license JSON
client_name = "—"
try:
    lic_raw = footer.get("cached_license")
    if lic_raw:
        client_name = json.loads(lic_raw).get("license", {}).get("client_name", "—") or "—"
except Exception:
    pass

if client_name != "—":
    st.sidebar.caption(f"**{client_name}**")

st.sidebar.caption(f"App {_get_app_version()}")

# DEV environment badge — shown when LOCID_SET_DEV_ENV(TRUE) has been called
if footer.get("central_env") == "dev":
    st.sidebar.warning("DEV environment", icon=":material/science:")
