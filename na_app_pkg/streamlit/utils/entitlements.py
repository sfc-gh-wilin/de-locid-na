"""
streamlit/utils/entitlements.py
LocID Native App — Entitlement Check Helpers

Reads entitlement flags from the LocID Central license response (cached in
APP_CONFIG) and provides helpers for:
  - Checking whether an operation or output column is permitted
  - Building the active output column list for a given operation

Both APP_CONFIG lookups (api_key_id + cached_license) are batched into a
single query. Results are cached per-session for 5 minutes.
"""

import json
from typing import Any

import streamlit as st
import snowflake.snowpark as snowpark
from utils import logger

# Entitlement flags as returned by LocID Central in the access[] array.
KNOWN_FLAGS = {
    "allow_encrypt",
    "allow_decrypt",
    "allow_tx",
    "allow_stable",
    "allow_geo_context",
}


@st.cache_data(ttl=300, show_spinner=False)
def _get_active_entitlements(_session_id: int) -> frozenset[str]:
    """
    Return the frozenset of active entitlement flag names for the selected
    API key. Cached for 5 minutes per session.

    Batches api_key_id + cached_license into a single APP_CONFIG query.
    """
    from snowflake.snowpark.context import get_active_session
    _session = get_active_session()

    rows = _session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key IN ('api_key_id', 'cached_license') "
        "AND is_active = TRUE"
    ).collect()

    cfg: dict[str, str] = {r[0]: r[1] for r in rows}
    selected_key_id_raw = cfg.get("api_key_id")
    lic_raw             = cfg.get("cached_license")

    if not lic_raw:
        return frozenset()

    selected_key_id: int | None = None
    try:
        selected_key_id = int(selected_key_id_raw) if selected_key_id_raw else None
    except (TypeError, ValueError):
        pass

    try:
        data: dict[str, Any] = json.loads(lic_raw)
    except Exception:
        return frozenset()

    entry = None
    for item in data.get("access", []):
        if item.get("status") == "ACTIVE":
            if selected_key_id is None or item.get("api_key_id") == selected_key_id:
                entry = item
                if selected_key_id is not None:
                    break

    if not entry:
        return frozenset()

    return frozenset(flag for flag in KNOWN_FLAGS if entry.get(flag) is True)


def check_entitlement(session: snowpark.Session, flag: str, sid: int) -> None:
    """
    Raise PermissionError if the active API key does not include flag.
    sid  — Snowflake session ID integer, used as cache key.
    """
    active = _get_active_entitlements(sid)
    if flag not in active:
        msg = (
            f"Your LocID license does not include '{flag}'. "
            "Contact LocID to upgrade your access."
        )
        logger.warning(session, "entitlements.check_entitlement",
                       f"Entitlement denied: {flag}")
        raise PermissionError(msg)


@st.cache_data(ttl=300, show_spinner=False)
def get_active_output_cols(_session_id: int, operation: str) -> list[dict[str, Any]]:
    """
    Return the list of output columns the customer is entitled to use for
    the given operation ('encrypt' | 'decrypt').

    Each item: { "config_key": "output_col.tx_cloc", "col_name": "tx_cloc",
                 "requires_entitlement": "allow_tx", "enabled": True/False }

    Cached for 5 minutes — output column registry changes only on app upgrades.
    """
    from snowflake.snowpark.context import get_active_session
    _session = get_active_session()

    rows = _session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key LIKE 'output_col.%' AND is_active = TRUE"
    ).collect()

    active_flags = _get_active_entitlements(_session_id)
    result = []

    for row in rows:
        key  = row[0]
        meta = json.loads(row[1]) if row[1] else {}
        col_operation = meta.get("operation", "both")
        required_flag = meta.get("requires_entitlement", "")

        if col_operation not in (operation, "both"):
            continue

        col_name = key.replace("output_col.", "")
        enabled  = (not required_flag) or (required_flag in active_flags)

        result.append({
            "config_key":           key,
            "col_name":             col_name,
            "requires_entitlement": required_flag,
            "enabled":              enabled,
        })

    return result
