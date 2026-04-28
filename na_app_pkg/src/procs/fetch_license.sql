-- =============================================================================
-- src/procs/fetch_license.sql
-- LocID Native App — LOCID_FETCH_LICENSE Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/fetch_license.sql';
--
-- Purpose:
--   Fetches license metadata, entitlements, and cryptographic secrets from
--   LocID Central and caches the full response in APP_SCHEMA.APP_CONFIG.
--
--   This procedure exists because Snowflake Native Apps do not support
--   EXTERNAL_ACCESS_INTEGRATIONS on Streamlit objects (error 092839). All
--   outbound HTTPS calls must be made from stored procedures that declare the
--   EAI. Streamlit views call this procedure via session.call() to perform
--   license validation and cache refresh without making direct HTTP calls.
--
-- Workflow:
--   1. If LICENSE_ID is empty, read license_id_ref from APP_SCHEMA.APP_CONFIG
--   2. GET /api/0/location_id/license/{license_id} → full license payload
--   3. Cache raw response JSON in APP_CONFIG.cached_license
--   4. Return full license payload as VARIANT
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_FETCH_LICENSE(
    LICENSE_ID  VARCHAR    -- license key; pass '' to re-use stored license_id_ref
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'fetch_license_handler'
AS $$
import errno
import json
import time
import urllib.request
import urllib.error

import snowflake.snowpark as snowpark

CENTRAL_BASE_URL = "https://central.locid.com/api/0/location_id"

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

# Retry config for transient EBUSY errors in Snowflake's sandboxed network stack.
_EBUSY_RETRIES = 3
_EBUSY_DELAYS  = (0.5, 1.0, 2.0)  # seconds between successive attempts


def _get_config(session, key: str):
    rows = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = ? AND is_active = TRUE LIMIT 1",
        params=[key]
    ).collect()
    return rows[0][0] if rows else None


def _urlopen_with_retry(req: urllib.request.Request, timeout: int):
    """Open req with automatic retry on transient EBUSY errors."""
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
                time.sleep(_EBUSY_DELAYS[attempt])
            else:
                raise


def fetch_license_handler(session: snowpark.Session, license_id: str) -> dict:
    lic = license_id.strip() if license_id else ""
    if not lic:
        lic = _get_config(session, "license_id_ref") or ""
    if not lic:
        raise RuntimeError("License not configured. Complete the Setup Wizard first.")

    url = f"{CENTRAL_BASE_URL}/license/{lic}"
    req = urllib.request.Request(url)

    try:
        with _urlopen_with_retry(req, 15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"LocID Central license fetch failed: HTTP {e.code}") from e
    except Exception as e:
        raise RuntimeError(f"LocID Central license fetch failed: {e}") from e

    session.sql(_UPSERT_SQL, params=["cached_license", json.dumps(data)]).collect()
    return data
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_FETCH_LICENSE(VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
