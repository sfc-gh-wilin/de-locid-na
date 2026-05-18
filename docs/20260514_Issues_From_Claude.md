# Issues Report — Claude AI Security Review (2025-05-14)

Response to issues identified by Claude AI code review on the LocID Native App.

---

## Summary

| # | Severity | Issue | Resolution |
|---|----------|-------|------------|
| 1 | Critical | Crypto keys in query history | **Fixed** |
| 2 | High | License key in telemetry body | **Fixed** |
| 3 | High | fetch_license returns raw secrets | **Fixed** |
| 4 | High | IPv4 join duplicate rows | **Fixed** |
| 5 | High | IPv6 anti-join drops rows | Dismissed — false positive |
| 6 | Medium | Unguarded int() cast | **Fixed** |
| 7 | Medium | Wizard Back button loop | Dismissed — false positive |
| 8 | Medium | Wizard resets on job failure | **Fixed** |
| 9 | Medium | cache_resource session bleed | Dismissed — not applicable |
| 10 | Medium | No identifier sanitization in pre-flight | **Fixed** |
| 11 | Medium | Misleading license refresh error | **Fixed** |
| 12 | Low | Falsy ts_min == 0 | **Fixed** |

**9 fixed, 3 dismissed.**

---

## Fixed Issues

### Bug 1 — Crypto keys in query history (Critical)

**Problem:** AES keys were passed as SQL string literals to UDF calls and appeared in `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`.

**Fix:** Migrated all crypto-using UDFs to secret-backed mode. Each UDF now declares `EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)` and `SECRETS = ('alias' = APP_SCHEMA.LOCID_*_SECRET)`, reading keys via `_snowflake.get_generic_secret_string()` inside the handler. The key parameters have been removed from UDF signatures entirely. The encrypt/decrypt stored procedures no longer read or embed crypto secrets — only non-secret license context (`client_id`, `namespace_guid`) is used.

**Note:** This is a forward-only fix. Historical `QUERY_HISTORY` rows containing keys persist for up to 365 days. Post-deploy key rotation at LocID Central is recommended for complete remediation.

**Files:** `src/udfs/locid_udf.sql`, `src/procs/encrypt.sql`, `src/procs/decrypt.sql`

---

### Bug 2 — License key in telemetry body (High)

**Problem:** Full license key was included in the telemetry POST identifier field.

**Fix:** Masked to first 4 characters + `****` (e.g., `1569****_<job_id>`). The API key header already authenticates the request; the full license key is no longer sent in the body.

**Files:** `encrypt.sql`, `decrypt.sql`

---

### Bug 3 — fetch_license returns raw secrets (High)

**Problem:** The `LOCID_FETCH_LICENSE` procedure returned the full API response including cryptographic secrets, which could persist in Streamlit session memory.

**Fix:** The Streamlit-facing helper now strips the `secrets` field from the response before returning. Cryptographic secrets are only stored in Snowflake SECRET objects and never held in Streamlit session state.

**Files:** `streamlit/utils/locid_central.py`

---

### Bug 4 — IPv4 join duplicate rows (High)

**Problem:** If `LOCID_BUILD_DATES` had overlapping date ranges, a single input row could match multiple `build_dt` values, producing duplicate output rows.

**Fix:** Added `QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY lb.build_dt DESC) = 1` to the IPv4 match query, ensuring exactly one output row per input row (most recent build preferred).

**Files:** `encrypt.sql`

---

### Bug 6 — Unguarded int() cast on api_key_id (Medium)

**Problem:** `int(k_row[0])` would crash with `ValueError` if the config value contained whitespace or non-digit characters.

**Fix:** Added `.strip()` before cast and wrapped in `try/except (ValueError, AttributeError)` with graceful fallback to `None` (which selects the first active key).

**Files:** `encrypt.sql`, `decrypt.sql`

---

### Bug 8 — Wizard resets on job failure (Medium)

**Problem:** After job execution, the UI state (column mappings, step position) was reset unconditionally — including on failure. Users had to re-enter all settings from scratch after a failed job.

**Fix:** State reset now only occurs on `SUCCESS`. On failure or exception, users remain on the Review & Run step with their configuration intact.

**Files:** `run_encrypt.py`, `run_decrypt.py`

---

### Bug 10 — No identifier sanitization in pre-flight SQL (Medium)

**Problem:** Column names from UI selection were interpolated directly into pre-flight validation SQL without quoting. Column names with spaces or special characters could break the queries.

**Fix:** Added `_quote_id()` helper that double-quotes identifiers. All column references in pre-flight validation SQL now use quoted identifiers.

**Files:** `run_encrypt.py`

---

### Bug 11 — Misleading license refresh error (Medium)

**Problem:** If `LOCID_FETCH_LICENSE` threw an exception (e.g., network timeout), users saw a raw Snowpark exception instead of a helpful message.

**Fix:** Wrapped the license refresh call in `try/except` with a user-friendly error: *"License refresh failed. Check network connectivity to LocID Central and verify your license is still valid."*

**Files:** `encrypt.sql`, `decrypt.sql`

---

### Bug 12 — Falsy ts_min == 0 hides success message (Low)

**Problem:** Python's falsy check `if v["ts_min"]` treated a timestamp value of `0` (Unix epoch) as `False`, suppressing the "looks good" confirmation message.

**Fix:** Changed to `if v["ts_min"] is not None`, which correctly handles zero-valued timestamps.

**Files:** `run_encrypt.py`

---

## Dismissed — False Positives

### Bug 5 — IPv6 anti-join drops rows sharing an IP (High)

**Assessment:** Not a bug. The `inp` CTE in each pass selects **all** rows from the dated input table for IPs not yet seen. When a pass matches IP X, **all** input rows with IP X are inserted into the results table in the same pass. The seen-IPs accumulator then prevents redundant re-matching in subsequent passes. Two rows sharing the same IPv6 address are both matched in the same pass — neither is dropped.

---

### Bug 7 — Wizard Back button D/E loop (Medium)

**Assessment:** Not a bug. The wizard flow is:
- B (Have a key?) → E (Approve Network) → D (Enter Key) → F (Create Objects) → H (Select API Key) → I (Complete)

Navigation:
- E "Back" → B (correct)
- E "Continue" → D (correct)
- D "Back" → E (correct — previous step)
- D "Continue" → F (correct)

There is no infinite loop. Users can always reach screen B by pressing Back from E.

---

### Bug 9 — @st.cache_resource session bleed (Medium)

**Assessment:** Not applicable in Snowflake Native App deployment. Each user in a Native App gets their own isolated Streamlit process. `@st.cache_resource` is global per process, but since processes are per-user, there is no cross-user session bleed. This would only be an issue in a shared-server deployment model, which Snowflake Native Apps do not use.
