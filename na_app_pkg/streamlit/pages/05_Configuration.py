"""
streamlit/pages/05_configuration.py
LocID Native App — Configuration (View 6)

Sections:
  - License & Credentials (masked, refresh from LocID Central)
  - Current Entitlements (live badge list)
  - Output Column Registry (read-only table from APP_CONFIG)
  - Advanced (re-run setup wizard)

All APP_CONFIG reads are batched into a single query per page load.
"""

import json

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.locid_central import get_secrets
from utils.entitlements import _get_active_entitlements
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

st.header("⚙️ Configuration")
st.divider()


# ---------------------------------------------------------------------------
# Batched config fetch — all four keys in one round-trip
# ---------------------------------------------------------------------------
@st.cache_data(ttl=120, show_spinner=False)
def _load_config(_session_id: int) -> dict[str, str | None]:
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key IN ('license_id_ref', 'api_key', 'cached_license', 'api_key_id') "
        "AND is_active = TRUE"
    ).collect()
    return {r[0]: r[1] for r in rows}


config = _load_config(sid)

license_key  = config.get("license_id_ref")
api_key      = config.get("api_key")
cached_raw   = config.get("cached_license")

client_name, lic_expiry = "—", "—"
if cached_raw:
    try:
        _ld        = json.loads(cached_raw).get("license", {})
        client_name = _ld.get("client_name", "—")
        exp        = _ld.get("expiration_date", "")
        lic_expiry = exp[:10] if exp else "—"
    except Exception as e:
        logger.warning(session, "05_configuration.parse_license",
                       f"Failed to parse cached_license: {e}")


def _mask(val: str | None, visible: int = 4) -> str:
    if not val:
        return "—"
    return val[:visible] + "-****-****-****"


# ---------------------------------------------------------------------------
# Section 1 — License & Credentials
# ---------------------------------------------------------------------------
st.subheader("🔑 License & Credentials")

col1, col2 = st.columns(2)
with col1:
    st.text_input("License Key", value=_mask(license_key), disabled=True)
    st.text_input("API Key",     value=_mask(api_key),     disabled=True)
with col2:
    st.text_input("Client",  value=client_name, disabled=True)
    st.text_input("Expires", value=lic_expiry,  disabled=True)

colA, colB = st.columns(2)
with colA:
    if st.button("✏️ Update License Key"):
        st.switch_page("pages/01_Setup_Wizard.py")
with colB:
    if st.button("🔄 Refresh from LocID Central"):
        with st.spinner("Fetching latest secrets and entitlements…"):
            try:
                get_secrets(session)
                # Invalidate config cache so the page reflects the new values
                _load_config.clear()
                logger.info(session, "05_configuration.refresh",
                            "Secrets and entitlements refreshed")
                st.success("Secrets and entitlements refreshed.",
                           icon="✅")
                st.rerun()
            except Exception as e:
                logger.error(session, "05_configuration.refresh",
                             "Refresh failed", exc=e)
                st.error(str(e), icon="❌")

st.divider()

# ---------------------------------------------------------------------------
# Section 2 — Current Entitlements
# ---------------------------------------------------------------------------
st.subheader("✅ Current Entitlements")

ALL_FLAGS = [
    "allow_encrypt", "allow_decrypt",
    "allow_tx",      "allow_stable",
    "allow_geo_context",
]

active_flags = _get_active_entitlements(sid)

badge_cols = st.columns(3)
for i, flag in enumerate(ALL_FLAGS):
    with badge_cols[i % 3]:
        if flag in active_flags:
            st.success(f"✓ {flag}", icon=None)
        else:
            st.error(f"✗ {flag}", icon=None)

st.divider()

# ---------------------------------------------------------------------------
# Section 3 — Output Column Registry
# ---------------------------------------------------------------------------
st.subheader("📊 Output Column Registry")
st.caption("Managed by LocID via app version releases. Read-only.")


@st.cache_data(ttl=300, show_spinner=False)
def _load_registry(_session_id: int) -> list:
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT config_key, config_value, is_active "
        "FROM APP_SCHEMA.APP_CONFIG WHERE config_key LIKE 'output_col.%' "
        "ORDER BY config_key"
    ).collect()
    return [tuple(r) for r in rows]


registry_rows = _load_registry(sid)

if registry_rows:
    records = []
    for row in registry_rows:
        meta = json.loads(row[1]) if row[1] else {}
        records.append({
            "Column":               row[0].replace("output_col.", ""),
            "Operation":            meta.get("operation", "—"),
            "Requires Entitlement": meta.get("requires_entitlement", "—"),
            "Active":               "✓" if row[2] else "—",
        })
    df = pd.DataFrame(records)
    st.dataframe(df, use_container_width=True, hide_index=True)
    del df
else:
    st.info("No output columns registered.")

st.divider()

# ---------------------------------------------------------------------------
# Section 4 — Advanced
# ---------------------------------------------------------------------------
st.subheader("🔧 Advanced")
if st.button("✨ Re-run Setup Wizard"):
    st.switch_page("pages/01_Setup_Wizard.py")
