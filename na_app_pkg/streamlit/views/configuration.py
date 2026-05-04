"""
streamlit/views/configuration.py
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
from utils.entitlements import get_active_entitlements
from utils import logger
from utils.errors import show_error

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

st.header(":material/tune: Configuration")
st.divider()


# ---------------------------------------------------------------------------
# Batched config fetch — all keys in one round-trip
# ---------------------------------------------------------------------------
@st.cache_data(ttl=120, show_spinner=False)
def _load_config(_session_id: int) -> dict[str, str | None]:
    from snowflake.snowpark.context import get_active_session as _gas
    _session = _gas()
    rows = _session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key IN ('license_id_ref', 'api_key_hint', 'cached_license', 'api_key_id', 'log_retention_days') "
        "AND is_active = TRUE"
    ).collect()
    return {r[0]: r[1] for r in rows}


config = _load_config(sid)

license_key  = config.get("license_id_ref")
api_key_hint = config.get("api_key_hint")
cached_raw  = config.get("cached_license")

client_name, lic_expiry = "—", "—"
if cached_raw:
    try:
        _ld         = json.loads(cached_raw).get("license", {})
        client_name = _ld.get("client_name", "—")
        exp         = _ld.get("expiration_date", "")
        lic_expiry  = exp[:10] if exp else "—"
    except Exception as e:
        logger.warning(session, "configuration.parse_license",
                       f"Failed to parse cached_license: {e}")


def _mask(val: str | None, visible: int = 4) -> str:
    if not val:
        return "—"
    return val[:visible] + "-****-****-****"


# ---------------------------------------------------------------------------
# Section 1 — License & Credentials
# ---------------------------------------------------------------------------
st.subheader(":material/key: License & Credentials")

col1, col2 = st.columns(2)
with col1:
    st.text_input("License Key", value=_mask(license_key), disabled=True)
    st.text_input("API Key",     value=(api_key_hint + "****") if api_key_hint else "—", disabled=True)
with col2:
    st.text_input("Client",  value=client_name, disabled=True)
    st.text_input("Expires", value=lic_expiry,  disabled=True)

colA, colB = st.columns(2)
with colA:
    if st.button(":material/edit: Update License Key"):
        st.switch_page("views/setup_wizard.py")
with colB:
    if st.button(":material/refresh: Refresh from LocID Central"):
        with st.spinner("Fetching latest secrets and entitlements…"):
            try:
                get_secrets(session)
                _load_config.clear()
                logger.info(session, "configuration.refresh",
                            "Secrets and entitlements refreshed")
                st.success("Secrets and entitlements refreshed.", icon="✅")
                st.rerun()
            except Exception as e:
                logger.error(session, "configuration.refresh",
                             "Refresh failed", exc=e)
                show_error("Refresh failed.", detail=e)

st.divider()

# ---------------------------------------------------------------------------
# Section 2 — Current Entitlements
# ---------------------------------------------------------------------------
st.subheader(":material/verified_user: Current Entitlements")

ALL_FLAGS = [
    "allow_encrypt", "allow_decrypt",
    "allow_tx",      "allow_stable",
    "allow_geo_context",
]

active_flags = get_active_entitlements(sid)

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
st.subheader(":material/view_list: Output Column Registry")
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
# Section 4 — Log Retention
# ---------------------------------------------------------------------------
st.subheader(":material/delete_sweep: Log Retention")
st.caption(
    "Controls how long job history and application logs are kept. "
    "Cleanup runs automatically at the start of each Encrypt / Decrypt job."
)

_current_retention = int(config.get("log_retention_days") or 30)

with st.form("log_retention_form"):
    new_days = st.number_input(
        "Retention period (days)",
        min_value=1, max_value=365,
        value=_current_retention,
        step=1,
        help="Records older than this many days are deleted from Job History and App Logs.",
    )
    col_save, col_purge = st.columns(2)
    save_clicked  = col_save.form_submit_button(":material/save: Save", type="primary")
    purge_clicked = col_purge.form_submit_button(":material/delete_forever: Purge Now")

if save_clicked:
    try:
        session.sql(
            "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
            "USING (SELECT 'log_retention_days' AS k, ? AS v) AS s ON t.config_key = s.k "
            "WHEN MATCHED THEN UPDATE SET config_value = s.v, last_refreshed_at = CURRENT_TIMESTAMP() "
            "WHEN NOT MATCHED THEN INSERT (config_key, config_value, is_active) VALUES (s.k, s.v, TRUE)",
            params=[str(new_days)],
        ).collect()
        _load_config.clear()
        logger.info(session, "configuration.log_retention",
                    f"log_retention_days updated to {new_days}")
        st.success(f"Retention period saved: {new_days} day(s).", icon="✅")
        st.rerun()
    except Exception as e:
        logger.error(session, "configuration.log_retention", "Save failed", exc=e)
        show_error("Save failed.", detail=e)

if purge_clicked:
    try:
        result = session.sql("CALL APP_SCHEMA.LOCID_PURGE_LOGS()").collect()
        msg = result[0][0] if result else "Purge complete."
        logger.info(session, "configuration.purge_logs", msg)
        st.success(msg, icon="✅")
    except Exception as e:
        logger.error(session, "configuration.purge_logs", "Purge failed", exc=e)
        show_error("Purge failed.", detail=e)

st.divider()

# ---------------------------------------------------------------------------
# Section 5 — Advanced
# ---------------------------------------------------------------------------
st.subheader(":material/settings: Advanced")
if st.button(":material/restart_alt: Re-run Setup Wizard"):
    st.switch_page("views/setup_wizard.py")
