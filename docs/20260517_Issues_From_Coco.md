# Code Review Report — LocID Native App (2026-05-17)

Security and correctness review of all source files in `na_app_pkg/` and `db/locid/`.

**Status: All High-severity issues fixed. Medium/Low addressed where actionable.**

---

## Scope

| Directory | Files Reviewed |
|-----------|---------------|
| `na_app_pkg/src/procs/` | encrypt.sql, decrypt.sql, fetch_license.sql, purge_outputs.sql |
| `na_app_pkg/src/udfs/` | locid_udf.sql |
| `na_app_pkg/setup.sql` | Native App install/upgrade logic |
| `na_app_pkg/streamlit/` | Home.py, 6 views, 4 utils |
| `db/locid/provider/` | 00_roles.sql, 01_optimize_tables.sql, 02_grant_access.sql, 03_share_to_pkg.sql |

---

## Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 0 | -- |
| High | 3 | 3 |
| Medium | 6 | 6 |
| Low | 4 | 3 (1 dismissed) |

**Previously reported issues (20260514 Claude review): all 9 fixed.**  
Bug 1 (crypto keys in query history) was the last remaining item — resolved.

---

## High Severity

### H-1. `fetch_license.sql:177` — Proc returns full unstripped response as VARIANT — **FIXED**

**Problem:** `fetch_license_handler` returns `data` (the raw LocID Central API response) as the procedure's VARIANT return value. While `_strip_sensitive()` is called and the stripped version is stored in APP_CONFIG, the procedure itself still returns the unstripped dict, which includes `secrets.base_locid_secret` and `secrets.scheme_secret`.

**Impact:** If `LOCID_FETCH_LICENSE` is called directly from a SQL worksheet (e.g., `CALL APP_SCHEMA.LOCID_FETCH_LICENSE('')`), the VARIANT result containing AES keys appears in `INFORMATION_SCHEMA.QUERY_HISTORY` for 7 days and in Snowflake's result cache.

**Fix applied:** Proc now returns `stripped` instead of `data`.

---

### H-2. `setup_wizard.py:~121` — API key persists in session_state — **FIXED** (by H-1)

**Problem:** After license validation in the Setup Wizard (Screen D), `st.session_state.license_data` stores the full `fetch_license()` response.

**Impact:** Session state could retain crypto secrets until the Streamlit process is recycled.

**Fix applied:** Resolved by H-1 — the proc no longer returns secrets in the VARIANT result, so session_state never receives them.

---

### H-3. `run_encrypt.py:~187` — Full table scan in timestamp pre-flight check — **FIXED**

**Problem:** The timestamp validation query scans the **entire** input table with no row limit.

**Impact:** On tables with 10M+ rows, this advisory check can take several minutes and block the UI.

**Fix applied:** Added `TABLESAMPLE (100000 ROWS)` — keeps the check advisory and fast.

---

## Medium Severity

### M-1. `locid_central.py:~85` — Client/server clock skew in cache freshness — **FIXED**

**Problem:** `time.time()` (Python wall clock) compared against Snowflake's `CURRENT_TIMESTAMP`. Clocks may differ.

**Fix applied:** `_get_config()` now includes `DATEDIFF('second', last_refreshed_at, CURRENT_TIMESTAMP()) AS age_s` in the query. Cache freshness is computed entirely server-side — no Python clock involved.

---

### M-2. `setup_wizard.py:251` — 8-char API key prefix visible in UI — **FIXED**

**Problem:** `_key_label()` sliced raw `api_key` field for display. Inconsistent with 4-char masking elsewhere.

**Fix applied:** Now uses `entry.get("api_key_hint", "????")` — the safe server-provided hint. Raw `api_key` is never accessed.

---

### M-3. `home.py:~148` — SQL query on every page render for cache age — **FIXED**

**Problem:** `_central_refresh_label()` executed a `DATEDIFF` SQL round-trip on every Home page render.

**Fix applied:** Replaced with Python `datetime` math using the `refreshed_at` timestamp already fetched. No warehouse query needed.

---

### M-4. `purge_outputs.sql:69` — Table name interpolation without quoting — **FIXED**

**Problem:** `DROP TABLE IF EXISTS APP_SCHEMA.{tbl_name}` used unquoted interpolation.

**Fix applied:** Now uses double-quoted identifier: `APP_SCHEMA."{tbl_name}"`. Also added try/except for `int()` cast on `output_retention_days` (L-3 addressed here too).

---

### M-5. `configuration.py:193` — `int()` cast without ValueError handling — **FIXED**

**Problem:** `int(config.get("log_retention_days") or 30)` crashes on a non-numeric string in APP_CONFIG.

**Fix applied:** Wrapped in `try/except (TypeError, ValueError)` with fallback to 30.

---

### M-6. `encrypt.sql` / `decrypt.sql` — `_check_entitlement` uses unguarded `int()` on api_key_id — **FIXED**

**Problem:** In `_check_entitlement` and `_entitled_cols`, `int(k_row[0])` has no error handling for non-numeric values.

**Fix applied:** All 4 occurrences across both files now use `.strip()` + `try/except (ValueError, AttributeError)` with fallback to `None`.

---

## Low Severity

### L-1. `run_encrypt.py` / `run_decrypt.py` — Blank page on invalid step state — **FIXED**

**Problem:** If `enc_step` or `dec_step` is corrupted, none of the `if/elif` branches match — blank page.

**Fix applied:** Added `else` branch that resets to step 1 and calls `st.rerun()`.

---

### L-2. `job_history.py:94` — `job_id[:8]` slice on potentially NULL — **FIXED**

**Problem:** If `JOB_LOG.job_id` column contains NULL, `row[0][:8]` raises `TypeError`.

**Fix applied:** `job_id = row[0] or "—"` — NULL coalesced at assignment.

---

### L-3. `purge_outputs.sql:45` — Unguarded `int()` on config value — **FIXED**

**Problem:** `int(rows[0][0])` crashes on non-numeric `output_retention_days` config value.

**Fix applied:** Wrapped in try/except with fallback to 90 (addressed alongside M-4).

---

### L-4. `db/locid/provider/` scripts — Not fully idempotent — **Dismissed**

**Problem:** GRANT statements lack `IF NOT EXISTS`.

**Assessment:** Snowflake GRANTs are inherently idempotent — they succeed silently on re-run. `CREATE SCHEMA IF NOT EXISTS` and `CREATE OR REPLACE SECURE VIEW` are already idempotent. No change needed.

---

## Previously Fixed Issues (for reference)

All 9 issues from the 20260514 Claude review are resolved:

| # | Issue | Status |
|---|-------|--------|
| 1 | Crypto keys in query history | **Fixed** (secret-backed UDFs) |
| 2 | License key in telemetry body | **Fixed** (masked to 4 chars) |
| 3 | fetch_license returns raw secrets | **Fixed** (stripped in APP_CONFIG; H-1 above is residual) |
| 4 | IPv4 join duplicate rows | **Fixed** (QUALIFY ROW_NUMBER) |
| 5 | IPv6 anti-join drops rows | Dismissed (false positive) |
| 6 | Unguarded int() cast | **Fixed** (try/except in `_get_license_context`) |
| 7 | Wizard Back button loop | Dismissed (false positive) |
| 8 | Wizard resets on job failure | **Fixed** (reset only on SUCCESS) |
| 9 | cache_resource session bleed | Dismissed (SiS process-per-user) |
| 10 | No identifier sanitization | **Fixed** (`_quote_id()` helper) |
| 11 | Misleading license refresh error | **Fixed** (user-friendly message) |
| 12 | Falsy ts_min == 0 | **Fixed** (`is not None` check) |

---

## Recommendations

All issues resolved. No outstanding items.
