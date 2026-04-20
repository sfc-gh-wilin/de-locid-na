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

license_key_row = session.sql(
    "SELECT config_value FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'license_id_ref' LIMIT 1"
).collect()
license_key = license_key_row[0][0] if license_key_row else None

api_key_row = session.sql(
    "SELECT config_value FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'api_key' LIMIT 1"
).collect()
api_key = api_key_row[0][0] if api_key_row else None

# Read client name and expiry from cached_license
cached_lic_raw = session.sql(
    "SELECT config_value FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'cached_license' LIMIT 1"
).collect()
client_name, lic_expiry = "—", "—"
if cached_lic_raw and cached_lic_raw[0][0]:
    try:
        _ld = json.loads(cached_lic_raw[0][0]).get("license", {})
        client_name = _ld.get("client_name", "—")
        exp = _ld.get("expiration_date", "")
        lic_expiry  = exp[:10] if exp else "—"
    except Exception:
        pass

col1, col2 = st.columns(2)
with col1:
    st.text_input("License Key", value=mask(license_key), disabled=True)
    st.text_input("API Key",     value=mask(api_key),     disabled=True)
with col2:
    st.text_input("Client",  value=client_name, disabled=True)
    st.text_input("Expires", value=lic_expiry,  disabled=True)

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
    "allow_encrypt", "allow_decrypt",
    "allow_tx",      "allow_stable",
    "allow_geo_context", "allow_homebiz",
]

if cached_license_row and cached_license_row[0][0]:
    data        = json.loads(cached_license_row[0][0])
    # Find the selected API key entry and extract True-valued flags
    _key_row = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG WHERE config_key = 'api_key_id' LIMIT 1"
    ).collect()
    _sel_id = int(_key_row[0][0]) if _key_row and _key_row[0][0] else None
    _entry = None
    for _item in data.get("access", []):
        if _item.get("status") == "ACTIVE":
            if _sel_id is None or _item.get("api_key_id") == _sel_id:
                _entry = _item
                if _sel_id is not None:
                    break
    active_flags = {f for f in ALL_FLAGS if _entry and _entry.get(f) is True}
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
