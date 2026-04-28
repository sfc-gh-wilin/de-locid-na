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
    Fetch license metadata and entitlements from LocID Central.

    Delegates to APP_SCHEMA.LOCID_FETCH_LICENSE, which has the required
    EXTERNAL_ACCESS_INTEGRATIONS and handles HTTPS, EBUSY retry, and
    APP_CONFIG caching.  Cryptographic secrets are written to Snowflake
    SECRET objects by the proc and are not returned here.

    Returns the stripped API response dict:
      { "license": {...}, "access": [...] }
      (access[] entries contain api_key_hint instead of api_key;
       the secrets field is omitted)
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


def get_secrets(session: snowpark.Session) -> None:
    """
    Ensure the license cache is fresh.  Re-fetches from LocID Central via
    LOCID_FETCH_LICENSE if the cached_license entry is older than
    CACHE_TTL_SECONDS.

    Cryptographic secrets are stored in Snowflake SECRET objects by the proc
    and are not accessible from Streamlit.

    Raises RuntimeError if no license has been configured yet.
    """
    lic_row = _get_config(session, "license_id_ref")
    if not lic_row or not lic_row[0]:
        raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    cached = _get_config(session, "cached_license")
    if cached and cached[1]:
        age_s = time.time() - cached[1].timestamp()
        if age_s < CACHE_TTL_SECONDS:
            return

    logger.info(session, "locid_central.get_secrets",
                "Cache stale — re-fetching from LocID Central")
    fetch_license(session, "")
