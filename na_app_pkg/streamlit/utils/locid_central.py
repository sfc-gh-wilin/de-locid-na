"""
streamlit/utils/locid_central.py
LocID Native App — LocID Central API Client

All outbound HTTPS calls to central.locid.com are delegated to the
APP_SCHEMA.LOCID_FETCH_LICENSE stored procedure, which carries the required
EXTERNAL_ACCESS_INTEGRATIONS. Snowflake Native Apps do not support
EXTERNAL_ACCESS_INTEGRATIONS on Streamlit objects (error 092839), so
direct HTTP calls from Streamlit Python are not permitted.

Endpoints used (via stored procedure):
  GET  /api/0/location_id/license/{license_key}  → secrets + entitlements

Usage statistics are reported by the encrypt/decrypt stored procedures
directly via their own inline _post_stats helper (unrelated to this module).
"""

import json
import time
from typing import Any

import snowflake.snowpark as snowpark
from utils import logger

CACHE_TTL_SECONDS = 3600    # refresh secrets if older than 1 hour


def _get_config(session: snowpark.Session, key: str):
    rows = session.sql(
        "SELECT config_value, last_refreshed_at "
        "FROM APP_SCHEMA.APP_CONFIG WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0] if rows else None


def fetch_license(session: snowpark.Session, license_key: str) -> dict[str, Any]:
    """
    Fetch license metadata, entitlements, and cryptographic secrets from
    LocID Central.

    Delegates to APP_SCHEMA.LOCID_FETCH_LICENSE, which has the required
    EXTERNAL_ACCESS_INTEGRATIONS and handles HTTPS, EBUSY retry, and
    APP_CONFIG caching.

    Returns the full API response dict:
      { "license": {...}, "access": [...], "secrets": {...} }
    """
    try:
        raw = session.call("APP_SCHEMA.LOCID_FETCH_LICENSE", license_key)
    except Exception as e:
        logger.error(session, "locid_central.fetch_license",
                     "License fetch failed", exc=e)
        raise RuntimeError(f"LocID Central license fetch failed: {e}") from e

    data = json.loads(raw) if isinstance(raw, str) else raw
    logger.info(session, "locid_central.fetch_license", "License fetched and cached")
    return data


def _extract_secrets(session: snowpark.Session, data: dict[str, Any]) -> dict[str, Any]:
    """
    Normalise the full LocID Central license response into the fields needed
    for UDF calls and entitlement checks.

    Returns:
      base_locid_secret, scheme_secret — AES key strings (Base64-URL + ~ padding)
      client_id                        — license.client_id (int)
      namespace_guid                   — from the selected API key's access entry
    """
    secrets      = data.get("secrets", {})
    license_info = data.get("license", {})

    key_row = _get_config(session, "api_key_id")
    sel_id  = int(key_row[0]) if key_row and key_row[0] else None

    entry = None
    for item in data.get("access", []):
        if item.get("status") == "ACTIVE":
            if sel_id is None or item.get("api_key_id") == sel_id:
                entry = item
                if sel_id is not None:
                    break

    if not entry:
        logger.error(session, "locid_central._extract_secrets",
                     "No active API key found in license response")
        raise RuntimeError(
            "No active API key found in license. Check your configuration."
        )

    return {
        "base_locid_secret": secrets.get("base_locid_secret", ""),
        "scheme_secret":     secrets.get("scheme_secret", ""),
        "client_id":         int(license_info.get("client_id", 0)),
        "namespace_guid":    entry.get("namespace_guid", ""),
    }


def get_secrets(session: snowpark.Session) -> dict[str, Any]:
    """
    Return normalised license secrets. Uses the APP_CONFIG cache if fresh
    (< CACHE_TTL_SECONDS); otherwise re-fetches via the LOCID_FETCH_LICENSE
    stored procedure.

    Raises RuntimeError if the license has not been configured yet.
    """
    cached = _get_config(session, "cached_license")
    if cached and cached[1]:
        age_s = time.time() - cached[1].timestamp()
        if age_s < CACHE_TTL_SECONDS:
            return _extract_secrets(session, json.loads(cached[0]))

    lic_row = _get_config(session, "license_id_ref")
    if not lic_row or not lic_row[0]:
        raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    logger.info(session, "locid_central.get_secrets", "Cache stale — re-fetching from LocID Central")
    data = fetch_license(session, lic_row[0])
    return _extract_secrets(session, data)
