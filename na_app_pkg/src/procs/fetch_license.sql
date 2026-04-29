-- =============================================================================
-- src/procs/fetch_license.sql
-- LocID Native App — LOCID_FETCH_LICENSE Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/fetch_license.sql';
--
-- Purpose:
--   Fetches license metadata, entitlements, and cryptographic secrets from
--   LocID Central and stores them securely:
--
--   Secrets (written to Snowflake SECRETs via ALTER SECRET):
--     LOCID_LICENSE_KEY  — full license key (when a new key is provided)
--     LOCID_BASE_SECRET  — base_locid_secret AES key
--     LOCID_SCHEME_SECRET— scheme_secret AES key
--
--   APP_CONFIG (non-sensitive fields only):
--     license_id_ref     — masked hint: first-4-chars + "****"
--     cached_license     — JSON with 'secrets' removed, license_key masked to
--                          first-4-chars + "-****", and api_key values kept
--                          intact for LOCID_SET_API_KEY (Screen H) plus
--                          api_key_hint (first-8-chars) added for display.
--                          LOCID_SET_API_KEY scrubs api_key after selection.
--
--   This procedure exists because Snowflake Native Apps do not support
--   EXTERNAL_ACCESS_INTEGRATIONS on Streamlit objects (error 092839). All
--   outbound HTTPS calls must be made from stored procedures that declare the
--   EAI. Streamlit views call this procedure via session.call() to perform
--   license validation and cache refresh without making direct HTTP calls.
--
-- Workflow:
--   1. If LICENSE_ID is provided (non-empty): use it and write to LOCID_LICENSE_KEY secret
--   2. If LICENSE_ID is empty: read full key from LOCID_LICENSE_KEY secret
--   3. GET /api/0/location_id/license/{license_id} → full license payload
--   4. Write base_locid_secret → LOCID_BASE_SECRET secret
--   5. Write scheme_secret     → LOCID_SCHEME_SECRET secret
--   6. Store stripped JSON (no secrets, api_key_hint only) in APP_CONFIG.cached_license
--   7. Return full license payload as VARIANT
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_FETCH_LICENSE(
    LICENSE_ID  VARCHAR    -- license key; pass '' to re-use stored LOCID_LICENSE_KEY secret
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
PACKAGES = ('snowflake-snowpark-python')
SECRETS = (
    'license_key' = APP_SCHEMA.LOCID_LICENSE_KEY
)
HANDLER = 'fetch_license_handler'
AS $$
import errno
import json
import time
import urllib.request
import urllib.error

import _snowflake
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


def _strip_sensitive(data: dict) -> dict:
    """
    Return a copy of the LocID Central response safe to cache in APP_CONFIG:
      - Remove 'secrets' entirely (base_locid_secret, scheme_secret)
      - Mask license.license_key → first-4-chars + '-****'
      - Keep access[].api_key intact for LOCID_SET_API_KEY (Setup Wizard Screen H)
      - Add access[].api_key_hint (first 8 chars) for display
      LOCID_SET_API_KEY scrubs api_key → api_key_hint after key selection.
    """
    stripped = {k: v for k, v in data.items() if k != 'secrets'}

    # Mask license_key inside the license sub-object
    lic = dict(stripped.get('license', {}))
    raw_lic_key = lic.get('license_key', '')
    if raw_lic_key:
        lic['license_key'] = raw_lic_key[:4] + '-****'
    stripped['license'] = lic

    # Add api_key_hint for display; keep api_key for LOCID_SET_API_KEY
    clean_access = []
    for entry in stripped.get('access', []):
        e = dict(entry)
        if 'api_key' in e and 'api_key_hint' not in e:
            e['api_key_hint'] = e['api_key'][:8]
        clean_access.append(e)
    stripped['access'] = clean_access

    return stripped


def fetch_license_handler(session: snowpark.Session, license_id: str) -> dict:
    # Resolve license key: use provided value or fall back to stored secret
    lic = license_id.strip() if license_id else ""
    if not lic:
        lic = _snowflake.get_generic_secret_string('license_key').strip()
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

    # --- Write cryptographic secrets to Snowflake SECRETs ---
    raw_secrets = data.get('secrets', {})
    base_val   = raw_secrets.get('base_locid_secret', '')
    scheme_val = raw_secrets.get('scheme_secret', '')
    if base_val:
        session.sql(
            "ALTER SECRET APP_SCHEMA.LOCID_BASE_SECRET SET SECRET_STRING = ?",
            params=[base_val]
        ).collect()
    if scheme_val:
        session.sql(
            "ALTER SECRET APP_SCHEMA.LOCID_SCHEME_SECRET SET SECRET_STRING = ?",
            params=[scheme_val]
        ).collect()

    # --- If a new license key was provided, store it and write masked hint ---
    if license_id.strip():
        session.sql(
            "ALTER SECRET APP_SCHEMA.LOCID_LICENSE_KEY SET SECRET_STRING = ?",
            params=[lic]
        ).collect()
        session.sql(_UPSERT_SQL, params=["license_id_ref", lic[:4] + "-****"]).collect()

    # --- Cache stripped JSON (no secrets, api_key_hint only) in APP_CONFIG ---
    stripped = _strip_sensitive(data)
    session.sql(_UPSERT_SQL, params=["cached_license", json.dumps(stripped)]).collect()

    return data
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_FETCH_LICENSE(VARCHAR)
    TO APPLICATION ROLE APP_ADMIN;
