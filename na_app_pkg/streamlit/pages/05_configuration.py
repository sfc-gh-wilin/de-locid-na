"""
streamlit/pages/05_configuration.py
LocID Native App — Configuration (View 6)

Sections:
  - License & Credentials (masked, refresh from LocID Central)
  - Current Entitlements (live badge list)
  - Output Column Registry (read-only table from APP_CONFIG)
  - Advanced (re-run setup wizard)
"""

import json
import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.locid_central import get_secrets

session = get_active_session()

st.title("Configuration")
st.divider()

# ---------------------------------------------------------------------------
# Section 1 — License & Credentials
# ---------------------------------------------------------------------------
st.subheader("License & Credentials")

def mask(val: str | None, visible: int = 4) -> str:
    if not val:
        return "—"
    return val[:visible] + "-****-****-****"

# TODO: read from Snowflake SECRET (not APP_CONFIG plaintext)
license_key = "1569"   # placeholder — show prefix only
api_key_row = session.sql(
    "SELECT config_value FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'api_key' LIMIT 1"
).collect()
api_key = api_key_row[0][0] if api_key_row else None

col1, col2 = st.columns(2)
with col1:
    st.text_input("License Key", value=mask(license_key), disabled=True)
    st.text_input("API Key",     value=mask(api_key),     disabled=True)
with col2:
    # TODO: read client name and expiry from cached_license in APP_CONFIG
    st.text_input("Client",      value="—", disabled=True)
    st.text_input("Expires",     value="—", disabled=True)

colA, colB = st.columns(2)
with colA:
    if st.button("Update License Key"):
        st.switch_page("pages/01_setup_wizard.py")
with colB:
    if st.button("Refresh from LocID Central"):
        with st.spinner("Fetching latest secrets and entitlements…"):
            try:
                get_secrets(session)
                st.success("Secrets and entitlements refreshed.")
            except Exception as e:
                st.error(str(e))

st.divider()

# ---------------------------------------------------------------------------
# Section 2 — Current Entitlements
# ---------------------------------------------------------------------------
st.subheader("Current Entitlements")

cached_license_row = session.sql(
    "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
    "WHERE config_key = 'cached_license' AND is_active = TRUE LIMIT 1"
).collect()

ALL_FLAGS = [
    "allow_encrypt", "allow_decrypt", "allow_tx",
    "allow_stable",  "allow_geocontext", "allow_homebiz"
]

if cached_license_row and cached_license_row[0][0]:
    data        = json.loads(cached_license_row[0][0])
    active_flags = set(data.get("access", []))
else:
    active_flags = set()

badge_cols = st.columns(3)
for i, flag in enumerate(ALL_FLAGS):
    with badge_cols[i % 3]:
        if flag in active_flags:
            st.success(f"✓ {flag}")
        else:
            st.error(f"✗ {flag}")

st.divider()

# ---------------------------------------------------------------------------
# Section 3 — Output Column Registry
# ---------------------------------------------------------------------------
st.subheader("Output Column Registry")
st.caption("Managed by Digital Envoy via app version releases. Read-only.")

registry_rows = session.sql(
    "SELECT config_key, config_value, is_active "
    "FROM APP_SCHEMA.APP_CONFIG WHERE config_key LIKE 'output_col.%' "
    "ORDER BY config_key"
).collect()

if registry_rows:
    import pandas as pd
    records = []
    for row in registry_rows:
        meta = json.loads(row[1]) if row[1] else {}
        records.append({
            "Column":              row[0].replace("output_col.", ""),
            "Operation":           meta.get("operation", "—"),
            "Requires Entitlement": meta.get("requires_entitlement", "—"),
            "Active":              "✓" if row[2] else "—"
        })
    st.dataframe(pd.DataFrame(records), use_container_width=True, hide_index=True)
else:
    st.info("No output columns registered.")

st.divider()

# ---------------------------------------------------------------------------
# Section 4 — Advanced
# ---------------------------------------------------------------------------
st.subheader("Advanced")
if st.button("Re-run Setup Wizard"):
    st.switch_page("pages/01_setup_wizard.py")
