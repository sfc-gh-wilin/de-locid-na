"""
streamlit/utils/entitlements.py
LocID Native App — Entitlement Check Helpers

Reads entitlement flags from the LocID Central license response (cached in
APP_CONFIG) and provides helpers for:
  - Checking whether an operation or output column is permitted
  - Building the active output column list for a given operation
"""

import json
from typing import Any

import snowflake.snowpark as snowpark


# Entitlement flags as returned by LocID Central in the access[] array.
# Each flag is a boolean field on the access entry object.
KNOWN_FLAGS = {
    "allow_encrypt",
    "allow_decrypt",
    "allow_tx",
    "allow_stable",
    "allow_geo_context",   # matches API field name (underscore)
    "allow_homebiz",       # future
}


def _get_active_entitlements(session: snowpark.Session) -> set[str]:
    """
    Returns the set of active entitlement flag names for the selected API key.

    Reads the cached LocID Central license response from APP_CONFIG, locates
    the selected API key entry (via api_key_id in APP_CONFIG), and returns the
    set of flags that are True on that entry.

    access[] structure from LocID Central:
      [{ "api_key_id": 4, "status": "ACTIVE",
         "allow_encrypt": true, "allow_decrypt": true, ... }, ...]
    """
    # 1. Read selected api_key_id
    key_rows = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = 'api_key_id' AND is_active = TRUE LIMIT 1"
    ).collect()
    selected_key_id = int(key_rows[0][0]) if key_rows and key_rows[0][0] else None

    # 2. Read cached license payload
    lic_rows = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = 'cached_license' AND is_active = TRUE LIMIT 1"
    ).collect()
    if not lic_rows or not lic_rows[0][0]:
        return set()

    data: dict[str, Any] = json.loads(lic_rows[0][0])

    # 3. Find the selected (or first ACTIVE) access entry
    entry = None
    for item in data.get("access", []):
        if item.get("status") == "ACTIVE":
            if selected_key_id is None or item.get("api_key_id") == selected_key_id:
                entry = item
                if selected_key_id is not None:
                    break  # exact match found

    if not entry:
        return set()

    # 4. Return flag names where the boolean value is True
    return {flag for flag in KNOWN_FLAGS if entry.get(flag) is True}


def check_entitlement(session: snowpark.Session, flag: str) -> None:
    """
    Raises PermissionError if the active API key's license does not include flag.
    Call at the start of each stored procedure before doing any work.
    """
    active = _get_active_entitlements(session)
    if flag not in active:
        raise PermissionError(
            f"Your LocID license does not include '{flag}'. "
            "Contact Digital Envoy to upgrade your access."
        )


def get_active_output_cols(session: snowpark.Session,
                           operation: str) -> list[dict[str, str]]:
    """
    Returns the list of output columns the customer is entitled to use
    for the given operation ('encrypt' | 'decrypt').

    Each item: { "config_key": "output_col.tx_cloc", "col_name": "tx_cloc",
                 "requires_entitlement": "allow_tx", "enabled": True/False }
    """
    rows = session.sql(
        "SELECT config_key, config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key LIKE 'output_col.%' AND is_active = TRUE"
    ).collect()

    active_flags = _get_active_entitlements(session)
    result = []

    for row in rows:
        key  = row[0]
        meta = json.loads(row[1]) if row[1] else {}
        col_operation = meta.get("operation", "both")
        required_flag = meta.get("requires_entitlement", "")

        # Filter by operation
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
