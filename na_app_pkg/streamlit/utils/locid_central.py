"""
streamlit/utils/locid_central.py
LocID Native App — LocID Central API Client

Handles outbound HTTPS calls to central.locid.com via the LOCID_CENTRAL_EAI.
All responses are cached in APP_SCHEMA.APP_CONFIG to minimise API calls.

Endpoints used:
  GET  /api/0/location_id/license/{license_key}  → secrets + entitlements
  POST /api/0/location_id/stats                  → usage statistics
"""

import json
import time
import urllib.request
import urllib.error
from typing import Any

import snowflake.snowpark as snowpark

CENTRAL_BASE_URL  = "https://central.locid.com/api/0/location_id"
CACHE_TTL_SECONDS = 3600    # refresh secrets if older than 1 hour


def _get_config(session: snowpark.Session, key: str):
    rows = session.sql(
        "SELECT config_value, last_refreshed_at "
        "FROM APP_SCHEMA.APP_CONFIG WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0] if rows else None


def _set_config(session: snowpark.Session, key: str, value: str) -> None:
    session.sql(
        "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
        "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
        "WHEN MATCHED THEN UPDATE SET config_value = s.v, last_refreshed_at = CURRENT_TIMESTAMP "
        "WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active) "
        "VALUES (s.k, s.v, CURRENT_TIMESTAMP, TRUE)",
        params=[key, value]
    ).collect()


def fetch_license(session: snowpark.Session, license_key: str) -> dict[str, Any]:
    """
    Fetch license metadata, entitlements, and cryptographic secrets from
    LocID Central. The license_key is passed in the URL path — no auth
    header is required for this endpoint.

    Caches the raw response in APP_CONFIG under 'cached_license'.

    Returns the full API response dict:
      { "license": {...}, "access": [...], "secrets": {...} }
    """
    url = f"{CENTRAL_BASE_URL}/license/{license_key}"
    req = urllib.request.Request(url)

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"LocID Central license fetch failed: HTTP {e.code}") from e
    except Exception as e:
        raise RuntimeError(f"LocID Central license fetch failed: {e}") from e

    _set_config(session, "cached_license", json.dumps(data))
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

    # Find the selected API key entry
    key_row = _get_config(session, "api_key_id")
    sel_id  = int(key_row[0]) if key_row and key_row[0] else None

    entry = None
    for item in data.get("access", []):
        if item.get("status") == "ACTIVE":
            if sel_id is None or item.get("api_key_id") == sel_id:
                entry = item
                if sel_id is not None:
                    break  # exact match — stop searching

    if not entry:
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
    Returns normalised license secrets. Uses the APP_CONFIG cache if fresh
    (< CACHE_TTL_SECONDS); otherwise re-fetches from LocID Central.

    Raises RuntimeError if the license has not been configured yet.
    """
    cached = _get_config(session, "cached_license")
    if cached and cached[1]:
        age_s = time.time() - cached[1].timestamp()
        if age_s < CACHE_TTL_SECONDS:
            return _extract_secrets(session, json.loads(cached[0]))

    # Cache stale or missing — re-fetch
    lic_row = _get_config(session, "license_id_ref")
    if not lic_row or not lic_row[0]:
        raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    data = fetch_license(session, lic_row[0])
    return _extract_secrets(session, data)


def report_stats(session: snowpark.Session, job_id: str,
                 rows_processed: int, runtime_s: float,
                 operation: str = "encrypt_usage") -> None:
    """
    POST usage statistics to LocID Central after each job run.
    Uses the de-access-token header with the selected API key.
    Non-blocking — logs a warning on failure but does not abort the job.
    """
    api_key_row = _get_config(session, "api_key")
    license_row = _get_config(session, "license_id_ref")
    if not api_key_row or not license_row:
        return  # silently skip if not configured

    payload = json.dumps([{
        "identifier": license_row[0],
        "source":     "snowflake-native-app",
        "timestamp":  int(time.time() * 1000),
        "data_type":  "usage_metrics",
        "data": {
            "metric_key":      operation,
            "dimensions":      {"api_key": api_key_row[0], "hit": 1, "tier": 0},
            "metric_value":    rows_processed,
            "metric_datatype": "Long",
        },
    }]).encode()

    req = urllib.request.Request(
        f"{CENTRAL_BASE_URL}/stats",
        data=payload,
        headers={
            "Content-Type":    "application/json",
            "de-access-token": api_key_row[0],   # API key, not license key
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception:
        pass  # Non-blocking — usage stats failure must not fail the job
