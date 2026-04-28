"""
streamlit/utils/locid_central.py
LocID Native App — LocID Central API Client

Handles outbound HTTPS calls to central.locid.com via the LOCID_CENTRAL_EAI.
All responses are cached in APP_SCHEMA.APP_CONFIG to minimise API calls.
All timestamps written to APP_CONFIG use UTC (TIMESTAMP_NTZ).

Endpoints used:
  GET  /api/0/location_id/license/{license_key}  → secrets + entitlements
  POST /api/0/location_id/stats                  → usage statistics
"""

import errno
import json
import time
import urllib.request
import urllib.error
from typing import Any, Optional

import snowflake.snowpark as snowpark
from utils import logger

CENTRAL_BASE_URL  = "https://central.locid.com/api/0/location_id"
CACHE_TTL_SECONDS = 3600    # refresh secrets if older than 1 hour

# Retry config for transient EBUSY errors in Snowflake's sandboxed network stack.
# OSError(EBUSY) can occur on the first connection attempt while the sandbox
# network interface initialises; retrying with backoff resolves this reliably.
_EBUSY_RETRIES = 3
_EBUSY_DELAYS  = (0.5, 1.0, 2.0)  # seconds between successive attempts


def _urlopen_with_retry(
    req: urllib.request.Request,
    timeout: int,
    session: Optional[snowpark.Session] = None,
    source: str = "",
):
    """Open req with automatic retry on transient EBUSY errors.

    If session is provided, each retry and final exhaustion are logged as
    WARNING rows in APP_SCHEMA.APP_LOGS so operators can see the attempt count.
    """
    _src = source or "locid_central"
    for attempt in range(_EBUSY_RETRIES + 1):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except (OSError, urllib.error.URLError) as exc:
            is_ebusy = (
                (isinstance(exc, OSError) and exc.errno == errno.EBUSY)
                or (isinstance(exc, urllib.error.URLError)
                    and isinstance(exc.reason, OSError)
                    and exc.reason.errno == errno.EBUSY)
            )
            if is_ebusy and attempt < _EBUSY_RETRIES:
                delay = _EBUSY_DELAYS[attempt]
                if session:
                    logger.warning(session, _src,
                        f"EBUSY on attempt {attempt + 1}/{_EBUSY_RETRIES + 1}"
                        f" — retrying in {delay:.1f}s")
                time.sleep(delay)
            else:
                if session and is_ebusy:
                    logger.warning(session, _src,
                        f"EBUSY persisted after {attempt + 1}/{_EBUSY_RETRIES + 1}"
                        " attempts — giving up")
                raise

_UPSERT_SQL = (
    "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
    "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
    "WHEN MATCHED THEN UPDATE SET config_value = s.v, "
    "last_refreshed_at = CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ "
    "WHEN NOT MATCHED THEN INSERT "
    "(config_key, config_value, last_refreshed_at, is_active) "
    "VALUES (s.k, s.v, "
    "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, TRUE)"
)


def _get_config(session: snowpark.Session, key: str):
    rows = session.sql(
        "SELECT config_value, last_refreshed_at "
        "FROM APP_SCHEMA.APP_CONFIG WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0] if rows else None


def _set_config(session: snowpark.Session, key: str, value: str) -> None:
    """Upsert a config value. Timestamps are written as UTC."""
    session.sql(_UPSERT_SQL, params=[key, value]).collect()


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
        with _urlopen_with_retry(req, 15, session, "locid_central.fetch_license") as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        logger.error(session, "locid_central.fetch_license",
                     f"HTTP {e.code} fetching license", exc=e)
        raise RuntimeError(f"LocID Central license fetch failed: HTTP {e.code}") from e
    except Exception as e:
        logger.error(session, "locid_central.fetch_license",
                     "Network error fetching license", exc=e)
        raise RuntimeError(f"LocID Central license fetch failed: {e}") from e

    _set_config(session, "cached_license", json.dumps(data))
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
    (< CACHE_TTL_SECONDS); otherwise re-fetches from LocID Central.

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
        return

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
            "de-access-token": api_key_row[0],
        },
        method="POST",
    )

    try:
        with _urlopen_with_retry(req, 10, session, "locid_central.report_stats"):
            logger.debug(session, "locid_central.report_stats",
                         f"Stats posted: job={job_id}, rows={rows_processed}")
    except Exception as e:
        logger.warning(session, "locid_central.report_stats",
                       f"Stats POST failed (non-fatal): {e}")
