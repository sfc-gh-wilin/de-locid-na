# LocID Snowflake Native App — Architecture

**Version:** 3.0  
**Provider:** LocID  
**Prepared by:** Snowflake Solutions Architecture

---

## Overview

The LocID Native App brings LocID's location identity enrichment capabilities natively into a customer's Snowflake account. Customers who today call cloud or on-premise APIs to enrich data with LocID identifiers can now run the same enrichment as a batch workflow — entirely within their own Snowflake environment, with no data leaving their account.

**Two operations are supported:**

| Operation | Customer Provides | App Returns |
|-----------|-------------------|-------------|
| **Encrypt** | Table of `(unique_id, ip_address, timestamp)` | `TX_CLOC`, `STABLE_CLOC`, geo context |
| **Decrypt** | Table of `(unique_id, tx_cloc)` | `STABLE_CLOC`, geo context |

---

## How It Works

The app is distributed via the Snowflake Native App Framework. LocID publishes the app to the Snowflake Marketplace; customers install it in their own account in a few clicks.

```
┌─────────────────────────────────┐      ┌──────────────────────────────┐
│   LocID (Provider)      │      │   Customer (Consumer)        │
│                                 │      │                              │
│  LOCID_BUILDS (shared)          │◄─────│  App queries via share       │
│  LOCID_BUILDS_IPV4_EXPLODED     │      │                              │
│  LOCID_BUILD_DATES              │      │  Customer input table        │
│                                 │      │  → App stored procedure      │
│  mb_locid_encoding WHL (bundled) │      │  → Customer output table     │
│  LocID Central API              │◄─────│  App reports usage stats     │
└─────────────────────────────────┘      └──────────────────────────────┘
```

**All customer data stays in the customer's Snowflake account.** LocID's data lake is shared as read-only — no customer rows are written to LocID's account.

> **Data visibility:** The shared LocID tables (`LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, `LOCID_BUILD_DATES`) are **not directly queryable by consumers**. The Snowflake Native App Framework enforces this boundary at the platform level — only the app's own stored procedures and UDFs, executing within the app container, can read those tables. Consumer account users and roles have no visibility into LocID's underlying data.

---

## What LocID Provides

| Component | Description |
|-----------|-------------|
| **LocID Build Tables** | Three tables shared to the app: `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, `LOCID_BUILD_DATES`. Updated weekly via an Airflow DAG. |
| **mb_locid_encoding WHL** | Python wheel bundled in the app stage. Handles all TX_CLOC and STABLE_CLOC cryptographic operations via vectorized UDFs. |
| **LocID Central** | HTTPS API at `central.locid.com` — validates license keys, delivers cryptographic secrets, and receives usage statistics after each job run. |

---

## Technical Architecture

### App Package Structure

```
na_app_pkg/
├── manifest.yml                  # App manifest (privileges, references, default_streamlit)
├── setup.sql                     # Bootstrap: schemas, objects, grants
├── snowflake.yml                 # Snow CLI project config (artifacts, deploy targets)
├── src/
│   ├── procs/
│   │   ├── encrypt.sql           # Encrypt stored procedure
│   │   ├── decrypt.sql           # Decrypt stored procedure
│   │   └── fetch_license.sql     # License fetch stored procedure (EXTERNAL_ACCESS_INTEGRATIONS = LOCID_CENTRAL_EAI)
│   ├── udfs/
│   │   └── locid_udf.sql         # Python vectorized UDF definitions (APP_CODE versioned schema)
│   └── lib/
│       └── mb_locid_encoding-*.whl # Bundled Python wheel (mb-locid-encoding)
└── streamlit/
    ├── Home.py                   # Main Streamlit entry point (dashboard)
    ├── environment.yml           # Conda dependencies (runtime version is fixed by Snowflake)
    ├── logo.svg                  # App logo
    ├── .streamlit/
    │   └── config.toml           # Streamlit theme config
    ├── views/
    │   ├── home.py
    │   ├── run_encrypt.py
    │   ├── run_decrypt.py
    │   ├── job_history.py
    │   ├── sql_guide.py
    │   ├── configuration.py
    │   └── setup_wizard.py
    └── utils/
        ├── locid_central.py      # LocID Central client — delegates HTTP to LOCID_FETCH_LICENSE stored procedure (Streamlit cannot make direct HTTP calls in Native Apps)
        ├── entitlements.py       # Entitlement check helpers
        ├── errors.py             # Error display helpers
        └── logger.py             # App logging utilities
```

### Snowflake Objects (App Side — installed in customer account)

```
-- APP_SCHEMA (non-versioned): tables, stage, network rule, procedures, Streamlit
APP_SCHEMA.APP_CONFIG                       -- Masked credential hints, entitlements, output column registry; full secrets in GENERIC_STRING SECRET objects
APP_SCHEMA.JOB_LOG                          -- Job run history (job_id, run_dt, rows_in, rows_out, runtime_s, status)
APP_SCHEMA.APP_LOGS                         -- Diagnostic log table (log_id UUID, level, message, created_at)
APP_SCHEMA.APP_STAGE                        -- Internal stage: WHL, UDF SQL, proc SQL
APP_SCHEMA.LOCID_CENTRAL_RULE               -- Network rule (allowlist: central.locid.com:443)
APP_SCHEMA.LOCID_CENTRAL_EAI                -- External Access Integration (created at install time)
LOCID_CENTRAL_EAI_SPEC                      -- App specification (consumer must approve before EAI is usable; see Setup Wizard Screen E)
APP_SCHEMA.HTTP_PING()                      -- Python UDF to verify EAI connectivity during setup
APP_SCHEMA.LOCID_FETCH_LICENSE(VARCHAR)     -- Python stored procedure — fetches license from LocID Central; writes crypto keys to GENERIC_STRING SECRETs; stores stripped cache in APP_CONFIG
APP_SCHEMA.LOCID_SET_API_KEY(INTEGER)       -- Python stored procedure — writes selected API key to LOCID_API_KEY SECRET; stores api_key_hint in APP_CONFIG; scrubs full key from cached_license
APP_SCHEMA.register_single_callback(...)    -- Callback proc for input table references
APP_SCHEMA.LOCID_ENCRYPT(...)               -- Encrypt stored procedure
APP_SCHEMA.LOCID_DECRYPT(...)               -- Decrypt stored procedure
APP_SCHEMA.LOCID_PURGE_LOGS()              -- Purge JOB_LOG / APP_LOGS rows older than log_retention_days
APP_SCHEMA.LOCID_APP                        -- Streamlit application object

-- APP_CODE (versioned schema): Python vectorized UDFs — required by Snowflake for UDFs with WHL IMPORTS
APP_CODE.LOCID_BASE_ENCRYPT(...)            -- Decrypt base LocID, return encrypted form
APP_CODE.LOCID_BASE_DECRYPT(...)            -- Decrypt base LocID, return plain form
APP_CODE.LOCID_TXCLOC_ENCRYPT(...)          -- Generate TX_CLOC from base LocID
APP_CODE.LOCID_TXCLOC_DECRYPT(...)          -- Decode TX_CLOC → base LocID + metadata
APP_CODE.LOCID_STABLE_CLOC(...)             -- Generate STABLE_CLOC (UUID format)
APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN(...)  -- Generate STABLE_CLOC from plain base LocID
```

### Python Vectorized UDF Design

The `mb_locid_encoding` WHL (Python 3) is bundled in the app stage. All six Python vectorized UDFs are registered under the `APP_CODE` versioned schema (`CREATE OR ALTER VERSIONED SCHEMA APP_CODE`) — Snowflake Native Apps require a versioned schema for any UDF that specifies `IMPORTS`. Each UDF uses `LANGUAGE PYTHON RUNTIME_VERSION = '3.11'` with a `@vectorized` batch handler and a relative IMPORTS path (`/lib/mb_locid_encoding-*.whl`).

> **Note:** The project migrated from Scala scalar UDFs (encode-lib JAR) to Python vectorized UDFs in May 2026. Python vectorized UDFs using pandas DataFrames achieve 5.7× throughput improvement over Scala scalar at 50M rows due to batch dispatch and columnar processing.

### IP Matching Strategy

**IPv4** — Exploded equi-join for maximum performance:
```
customer_input.ip_address = locid_builds_ipv4_exploded.ip_address
joined back to locid_builds on (build_dt, start_ip, end_ip)
```

**IPv6** — Optimised 6-pass cascading hex-prefix range join:
```
Pre-step: materialise IPv6 input rows once (ip_hex pre-computed)
          materialise relevant IPv6 build rows once (date-filtered)
          pre-join each input row to its build_dt (avoids 6× DATES range join)

Pass 1: hex prefix[0:12] match + range join  → matched rows accumulated
Pass 2: prefix[0:10], exclude matched IPs    → (single accumulator anti-join)
Pass 3: prefix[0:8],  exclude matched IPs    → (single accumulator anti-join)
Pass 4: prefix[0:6],  exclude matched IPs    → (single accumulator anti-join)
Pass 5: prefix[0:4],  exclude matched IPs    → (single accumulator anti-join)
Pass 6: full range join on remaining rows    → (single accumulator anti-join)
```

Key optimisations vs. the original LocID reference POC:
- `PARSE_IP` / `ip_hex` computed once per row (not 6×)
- `LOCID_BUILDS` scanned once (not 6×), pre-filtered to relevant build dates
- Prefix filter applied **before** the range join on the builds side
- Single accumulator anti-join per pass (O(1)) vs. growing exclusion chain

Both strategies filter to relevant build dates covering the input timestamp.

---

## LocID Central Integration

**License endpoint:**

```
GET  https://central.locid.com/api/0/location_id/license/{license_key}
→  {
     "license":  { "client_id", "client_name", "license_key", "expiration_date", "scheme_version" },
     "access":   [
       { "api_key", "api_key_id", "client_id", "provider_id", "status",
         "namespace_guid", "allow_encrypt", "allow_decrypt", "allow_tx",
         "allow_stable", "allow_geo_context" },
       …
     ],
     "secrets":  { "base_locid_secret", "scheme_secret", "scheme_version" }
   }
```

`access[]` may contain multiple entries. Each entry has its own `namespace_guid`, `provider_id`, and entitlement flags. Only entries with `"status": "ACTIVE"` are valid. `secrets` are license-level — shared across all API keys.

The customer selects one API key during onboarding. The selected `api_key_id`, `namespace_guid`, and `provider_id` are stored in `APP_CONFIG` and used for all STABLE_CLOC calculations and stats reporting.

**Usage stats:**

```
POST https://central.locid.com/api/0/location_id/stats
  Header: de-access-token: <selected_api_key>
  → usage metrics after each job run (rows processed, runtime, job_id)
```

**Caching and refresh strategy:**
- On app launch: if `license_last_verified_at` in `APP_CONFIG` is older than 24 hours, re-fetch and refresh.
- On job run: use cached values. If cache is missing, the job is aborted — secrets are required.
- If a refresh fails, cached values are used and a warning is logged.

Sensitive values are stored as Snowflake `GENERIC_STRING` SECRETs (`LOCID_LICENSE_KEY`, `LOCID_API_KEY`, `LOCID_BASE_SECRET`, `LOCID_SCHEME_SECRET`). `APP_CONFIG` holds only masked hints (`license_id_ref` = first 4 chars + `-****`; `api_key_hint` = first 8 chars). The cached license payload (`cached_license`) is stripped of the `secrets` field before storage.

---

## Customer Onboarding Workflow

A guided wizard runs once after install and can be re-accessed from the Configuration view.

```
[Welcome]
    └── [Have a LocID license key?]
            ├── No  → [Contact LocID Sales] → END
            └── Yes → [Approve Network Access (EAI spec — ACCOUNTADMIN action)]
                        → [Enter License Key + Validate against LocID Central]
                            → [Create App Objects]
                                → [Select API Key]
                                    → [Setup Complete]
```

| Screen | Purpose |
|--------|---------|
| **A. Welcome** | Introduction and "Get started" CTA |
| **B. Have a key?** | Gate — Yes/No selection |
| **C. Contact Sales** | Dead end for users without a key — shows LocID contact info |
| **E. Approve Network Access** | Shows `ALTER APPLICATION APPROVE SPECIFICATION` SQL for ACCOUNTADMIN; also `GRANT USAGE ON INTEGRATION`; **must run before Screen D** |
| **D. Enter License Key** | Masked input; calls `APP_SCHEMA.LOCID_FETCH_LICENSE` stored procedure (requires EAI spec approved at Screen E); caches full license payload in `APP_CONFIG` |
| **F. Create App Objects** | Bootstraps `APP_CONFIG`, `JOB_LOG`, and the `HTTP_PING` UDF |
| **H. Select API Key** | Lists ACTIVE entries using `api_key_hint` (first 8 chars); user selects which API key to use; calls `APP_SCHEMA.LOCID_SET_API_KEY` to write full key to `LOCID_API_KEY` SECRET and scrub cache; `api_key_id`, `namespace_guid`, `client_id` stored in `APP_CONFIG` |
| **I. Success** | Summary checklist and "Launch App" button |

---

## Customer Data Workflow

### Encrypt (IP → LocID)

```
Customer Input Table
  (unique_id, ip_address, timestamp)
         │
         ▼
  LOCID_ENCRYPT stored procedure
         │
         ├─ 1. Fetch secrets + entitlements from LocID Central (cached)
         │       Resolve selected API key from APP_CONFIG:
         │       namespace_guid, provider_id, client_id → used for STABLE_CLOC
         │
         ├─ 2. IP Matching (IPv4 equi-join + IPv6 cascading prefix join)
         │       → unique_id, encrypted_locid, tier, geo_context, build_dt
         │
         ├─ 3. Call LOCID_UDF per matched row
         │       encrypted_locid → decrypt base LocID → re-encrypt
         │       → TX_CLOC, STABLE_CLOC
         │
         ├─ 4. Apply entitlement filter on output columns
         │
         ├─ 5. INSERT INTO customer output table
         │
         └─ 6. POST usage stats to LocID Central
```

### Decrypt (TX_CLOC → STABLE_CLOC)

```
Customer Input Table
  (unique_id, tx_cloc)
         │
         ▼
  LOCID_DECRYPT stored procedure
         │
         ├─ 1. Fetch secrets + entitlements from LocID Central (cached)
         │       Resolve selected API key from APP_CONFIG:
         │       namespace_guid, provider_id, client_id → used for STABLE_CLOC
         │
         ├─ 2. Call LOCID_UDF per row
         │       tx_cloc → decrypt → base LocID + embedded geo context
         │       → STABLE_CLOC, geo fields
         │
         ├─ 3. Apply entitlement filter on output columns
         │
         ├─ 4. INSERT INTO customer output table
         │
         └─ 5. POST usage stats to LocID Central
```

---

## Customer Entitlements

Entitlements are fetched from LocID Central and cached in `APP_CONFIG`. They control which operations are permitted and which output columns are included.

| Entitlement Flag | Controls |
|-----------------|---------|
| `allow_encrypt` | Permission to run Encrypt jobs |
| `allow_decrypt` | Permission to run Decrypt jobs |
| `allow_tx` | TX_CLOC column included in output |
| `allow_stable` | STABLE_CLOC column included in output |
| `allow_geo_context` | Geo context fields included in output |
| *(future — de-scoped from v1)* `allow_homebiz` | HomeBiz_Type field included in output |

Output columns are **not hardcoded**. They are driven by `APP_CONFIG` rows, so new entitlements and fields can be added by LocID without app code changes — only a config update and, if the schema changes, a new app version release.

---

## Streamlit Views

The app has seven views accessible from a left-side navigation bar. All views run entirely within the customer's Snowflake account.

---

### View 1 — Home

**Purpose:** Status dashboard. The first screen a customer sees when they open the app.

```
┌────────────────────────────────────────────────────┐
│  LocID for Snowflake                               │
├──────────────┬──────────────┬──────────────────────┤
│ License      │ LocID Central│ Last Job             │
│ ACTIVE       │ CONNECTED    │ Encrypt · 1.2M rows  │
│ Exp: 2027-01 │ Refreshed 2m │ 4m 12s · SUCCESS     │
├──────────────┴──────────────┴──────────────────────┤
│ [ Run Encrypt ]   [ Run Decrypt ]  [ View History] │
└────────────────────────────────────────────────────┘
```

**Key elements:**
- **License card** — client name, status (Active / Expired / Not configured), expiration date
- **LocID Central card** — connectivity status, time since last secret refresh
- **Last job card** — operation type, row counts, runtime, pass/fail
- **Quick-action buttons** — shortcuts to Run Encrypt, Run Decrypt, Job History
- **Setup banner** — shown only if onboarding wizard has not been completed

---

### View 2 — Run Encrypt

**Purpose:** Submit a batch Encrypt job — match customer IP + timestamp data against the LocID data lake and produce TX_CLOC / STABLE_CLOC output.

**Workflow (5-step stepper):**

```
[1. Input]  [2. Map Columns]  [3. Output]  [4. Options]  [5. Review & Run]
```

**Step 1 — Select Input Table**
- Dropdown: all tables and views the app has been granted access to
- Preview: row count + first 5 rows shown inline after selection
- IP version hint: auto-detects IPv4, IPv6, or mixed (shown as info badge)

**Step 2 — Map Columns**

| Required Field | Map to Column |
|---------------|---------------|
| Unique Row ID | `[dropdown]` |
| IP Address    | `[dropdown]` |
| Timestamp     | `[dropdown]` |

- Dropdowns are pre-filled with best-guess matches (e.g. a column named `ip` auto-selects for IP Address)
- Timestamp format selector: epoch seconds, epoch milliseconds, or TIMESTAMP string

**Input Validation (on column selection)**

Validation runs automatically after columns are mapped and is **advisory** — warnings are shown but the job can still proceed:

| Check | How | Behavior |
|-------|-----|----------|
| **IP format** | Sample 100 rows from the IP column; test each against IPv4 (`x.x.x.x`) and IPv6 (`hex-colon`) patterns | Badge shows `IPv4 / IPv6 / Mixed`; error count shown if unparseable values found |
| **Timestamp range** | Check min/max of the timestamp column | Warning if any timestamps are older than 52 weeks — those rows will not match any LocID build and will be returned as unmatched |
| **Null / empty values** | Count NULL or empty values in IP and timestamp columns | Shown as informational — nulls are skipped during matching |

> **Note from LocID (2026-04-20):** These validation checks are in scope for v1. Timestamp age limit of 52 weeks aligns with LocID's build retention window.

**Step 3 — Configure Output**
- Radio: *Create new table* or *Overwrite existing table*
- Text input: output table name (e.g. `MY_DB.MY_SCHEMA.LOCID_RESULTS`)
- Confirmation prompt if overwriting

**Step 4 — Select Output Columns**

| Column | Entitlement Required | Default |
|--------|---------------------|---------|
| TX_CLOC | `allow_tx` | ✓ |
| STABLE_CLOC | `allow_stable` | ✓ |
| Country / Country Code | `allow_geo_context` | ✓ |
| Region / Region Code | `allow_geo_context` | ✓ |
| City / City Code | `allow_geo_context` | ✓ |
| Postal Code | `allow_geo_context` | ✓ |

Columns the customer is not entitled to are shown greyed out with a tooltip explaining why.

**Step 5 — Review & Run**
- Summary card: input table, row count, output table, selected columns, warehouse
- Warehouse selector: dropdown of warehouses the customer has access to
- **Run Job** button

**During execution:**
- Live progress bar with status messages (e.g. "Matching IP records…", "Generating LocIDs…", "Writing output…")
- Cancel button available during run

**On completion:**
- Result summary: rows in, rows matched, rows written, unmatched count, runtime
- Links: "View output table" and "View in Job History"

---

### View 3 — Run Decrypt

**Purpose:** Submit a batch Decrypt job — decode TX_CLOC values back to STABLE_CLOC and optional geo context.

**Workflow (same 5-step stepper as Encrypt):**

**Step 2 — Map Columns**

| Required Field | Map to Column |
|---------------|---------------|
| Unique Row ID | `[dropdown]` |
| TX_CLOC       | `[dropdown]` |

**Step 4 — Select Output Columns**

| Column | Entitlement Required | Default |
|--------|---------------------|---------|
| STABLE_CLOC | `allow_stable` | ✓ |
| Country / Country Code | `allow_geo_context` | ✓ |
| Region / Region Code | `allow_geo_context` | ✓ |
| City / City Code | `allow_geo_context` | ✓ |
| Postal Code | `allow_geo_context` | ✓ |

**On completion:**
- Result summary: rows in, rows decoded, rows written, runtime
- Links to output table and Job History

---

### View 4 — Job History

**Purpose:** Full audit log of all Encrypt and Decrypt jobs run through the app.

```
┌────────────────────────────────────────────────────────────────┐
│  Filter: [ All Operations ▼ ]  [ All Statuses ▼ ]  [ Date ▼ ]  │
├──────────┬───────────┬──────────────┬────────┬────────┬────────┤
│ Job ID   │ Operation │ Run Date     │ Rows In│ Matched│ Status │
├──────────┼───────────┼──────────────┼────────┼────────┼────────┤
│ job_0042 │ Encrypt   │ 2026-04-08   │ 1.2M   │ 980K   │ ✓ OK   │
│ job_0041 │ Decrypt   │ 2026-04-07   │ 450K   │ 450K   │ ✓ OK   │
│ job_0040 │ Encrypt   │ 2026-04-05   │ 800K   │ 612K   │ ✗ FAIL │
└──────────┴───────────┴──────────────┴────────┴────────┴────────┘
```

**Expandable row detail (click any row):**
- Input table, output table, warehouse used
- Runtime breakdown (matching phase, UDF phase, write phase)
- Error message with guidance if status is FAIL
- Output columns used for the job

**Actions:**
- Filter by operation, status, and date range
- Re-run: pre-fills Run Encrypt or Run Decrypt with the same settings as a previous job
- Export job log as CSV

---

### View 5 — SQL Guide

**Purpose:** Reference guide for consumers who want to run Encrypt and Decrypt jobs via SQL stored procedure calls instead of the Streamlit UI. All jobs submitted via SQL are tracked in Job History identically to UI jobs.

**Sections:**
- **Role note** — `GRANT APPLICATION ROLE <app>.APP_ADMIN TO ROLE <your_role>` with live app name pre-filled
- **Step 1** — Grant `SELECT` on input table to the application
- **Step 2** — Reference binding: Snowsight UI tab + SQL tab (`CALL register_single_callback(...)`)
- **Step 3** — `CALL LOCID_ENCRYPT(...)` with expandable parameter reference
- **Step 4** — `CALL LOCID_DECRYPT(...)` with expandable parameter reference
- **Step 5** — Query `APP_SCHEMA.JOB_LOG` to monitor job status
- **Scheduling example** — Snowflake Task snippet for automated jobs

---

### View 6 — Configuration

**Purpose:** Manage license credentials, view current entitlements, and review the output column registry.

**License & Credentials**
- License key: shown masked (`1569-****-****-****`), with "Update" button that re-triggers the Enter Key screen
- Client name and expiration date (read-only, from LocID Central)
- **Refresh from LocID Central** button — manually re-fetches secrets and entitlements; daily auto-refresh also runs at app launch

**API Key Selection**
- Table of all `access[]` entries from the last LocID Central fetch:

  | API Key | Key ID | Provider ID | Namespace GUID | Status | Use |
  |---------|--------|-------------|----------------|--------|-----|
  | `2c7c****` | 4 | 2844 | `fb71a5a0-…` | ACTIVE | ◉ |
  | `dbf4****` | 3 | 2844 | `044a471b-…` | INACTIVE | — |

- Only ACTIVE entries are selectable. Changing the key updates `api_key_id`, `namespace_guid`, `provider_id` in `APP_CONFIG` and takes effect on the next job run.
- Each API key has its own `namespace_guid` — switching keys changes the STABLE_CLOC output for new jobs.

**Current Entitlements**

```
✓ allow_encrypt    ✓ allow_decrypt
✓ allow_tx         ✓ allow_stable
✓ allow_geo_context 
```

**Output Column Registry**

| Column Name | Operation | Requires Entitlement | Active |
|------------|-----------|---------------------|--------|
| TX_CLOC | Encrypt | allow_tx | ✓ |
| STABLE_CLOC | Both | allow_stable | ✓ |
| locid_country | Both | allow_geo_context | ✓ |
| … | … | … | … |

Read-only for customers. Updated by LocID via app version releases when new fields are added.

**Log Retention**
- Number input (1–365 days) for how long `JOB_LOG` and `APP_LOGS` rows are kept (default: 30 days)
- Saved to `APP_CONFIG` key `log_retention_days`; applied opportunistically at the start of each job via `LOCID_PURGE_LOGS()`
- **Purge Now** button — runs `CALL APP_SCHEMA.LOCID_PURGE_LOGS()` immediately and displays rows deleted

**Advanced**
- "Re-run Setup Wizard" link — for re-registering credentials or troubleshooting connectivity

---

### View 7 — Setup Wizard

**Purpose:** One-time post-install onboarding. Guides the customer from a fresh install to a fully connected and verified app in approximately 5 minutes.

See **[Customer Onboarding Workflow](#customer-onboarding-workflow)** for the full 8-screen flow. The wizard is re-accessible from the Configuration view if credentials need to be updated.

---

## Security & Data Boundary

- All customer data remains in the customer's Snowflake account at all times.
- LocID's data lake is shared as read-only objects — no customer rows are written to LocID's account.
- All sensitive credentials are stored as Snowflake `GENERIC_STRING` SECRET objects — never in plain `APP_CONFIG` rows or query results:
  - `APP_SCHEMA.LOCID_LICENSE_KEY` — full LocID license key (written by `LOCID_FETCH_LICENSE`)
  - `APP_SCHEMA.LOCID_API_KEY` — selected API bearer token (written by `LOCID_SET_API_KEY`)
  - `APP_SCHEMA.LOCID_BASE_SECRET` — `base_locid_secret` AES key (written by `LOCID_FETCH_LICENSE`)
  - `APP_SCHEMA.LOCID_SCHEME_SECRET` — `scheme_secret` AES key (written by `LOCID_FETCH_LICENSE`)
- `APP_CONFIG` stores only masked hints: `license_id_ref` (first 4 chars + `-****`) and `api_key_hint` (first 8 chars).
- All SECRET writes are routed through stored procedures (`EXECUTE AS OWNER`) — `GRANT WRITE ON SECRET TO APPLICATION ROLE` is not a valid privilege; OWNER context is required.
- The cached license payload (`cached_license`) is stripped before storage: the `secrets` field is removed and `api_key` values are replaced with `api_key_hint` entries — so full credentials never appear in APP_CONFIG.
- Masking policy on `APP_CONFIG.config_value` for sensitive configuration rows.

---

## Role Setup for App Package & App Deployment

Using `ACCOUNTADMIN` for day-to-day deployment is a common concern in enterprise environments. The custom roles below minimize privilege scope while covering everything needed to build, publish, and install the LocID Native App.

### Provider Account — `LOCID_APP_ADMIN`

Used by LocID's engineering or ops team to manage the Application Package, stage contents, and Marketplace listing.

```sql
-- Run as ACCOUNTADMIN (one-time setup)
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_ADMIN;

-- Manage the Application Package and its versions/patches
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;
-- Create and manage the provider-side database (LOCID_BUILDS, staging objects)
GRANT CREATE DATABASE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;
-- Create the data share that backs the app's shared read-only objects
GRANT CREATE SHARE ON ACCOUNT TO ROLE LOCID_APP_ADMIN;
-- Create and manage listings (Specified Consumers + Marketplace)
-- NOTE: Requires Marketplace access for public listings; Specified Consumers works on all accounts.
-- The publishing role must own the Application Package (or have MODIFY on the listing).
GRANT CREATE LISTING ON ACCOUNT TO ROLE LOCID_APP_ADMIN;
-- Warehouse for builds and testing
GRANT USAGE ON WAREHOUSE <provider_warehouse> TO ROLE LOCID_APP_ADMIN;

-- Assign to user(s) who manage the app
GRANT ROLE LOCID_APP_ADMIN TO USER <username>;
```

Once `LOCID_APP_ADMIN` owns the Application Package, all routine operations — adding versions, applying patches, updating release directives — are performed under this role. No further `ACCOUNTADMIN` involvement is needed for day-to-day work.

### Consumer Account — `LOCID_APP_INSTALLER`

Used by the customer's admin team to install, configure, and manage the LocID Native App instance.

```sql
-- Run as ACCOUNTADMIN (one-time setup)
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER;

-- Install Native Apps from the Snowflake Marketplace
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
-- Create the output database/schema for job results (if using a new database)
GRANT CREATE DATABASE ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
-- Warehouse access for running Encrypt / Decrypt jobs
GRANT USAGE ON WAREHOUSE <customer_warehouse> TO ROLE LOCID_APP_INSTALLER;

-- Assign to user(s) who install and manage the app
GRANT ROLE LOCID_APP_INSTALLER TO USER <username>;
```

After installation, the app's `setup.sql` creates all internal objects (schemas, tables, UDFs, stored procedures) within the app container. One additional post-install step is required: the consumer must approve the `LOCID_CENTRAL_EAI_SPEC` app specification so the EAI can make outbound HTTPS calls. The Setup Wizard (Screen E) provides the exact SQL.

### Notes

- The one-time `GRANT ... TO ROLE` steps must be executed by `ACCOUNTADMIN`. This is unavoidable, but it is a **one-time setup only** — all routine operations use the custom role thereafter.
- The app's onboarding wizard (Screen E — Approve Network Access) guides the installer through approving the `LOCID_CENTRAL_EAI_SPEC` app specification and granting `USAGE ON INTEGRATION` — required before the license can be validated at Screen D.
- If the customer's environment uses a standard role hierarchy (e.g. `SYSADMIN` → custom roles), grant `LOCID_APP_INSTALLER` to `SYSADMIN` for hierarchy compliance:
  ```sql
  GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
  ```
- For Marketplace installs, `CREATE APPLICATION` on a custom role is the supported least-privilege path. `ACCOUNTADMIN` is not required for the install itself once the grant is in place.

### Deployment Workflow (Provider Side)

From the `na_app_pkg/` directory, using the `LOCID_APP_ADMIN` role:

```bash
# 1. Upload all artifacts to the app package stage
snow app deploy --connection wl_sandbox_dcr

# 2. Create or overwrite the named version
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr

# 3. Install / upgrade the app to the named version
snow app run --version v1_0 --connection wl_sandbox_dcr
```

`snow app deploy` syncs local files to the stage. `snow app version create` bundles the stage snapshot as a named version — required because `APP_CODE` is a versioned schema and Python UDFs with WHL `IMPORTS` must live in a versioned schema. `snow app run --version` installs or upgrades the app using the named version (not dev-mode).

### Version & Patch Updates (Push to Consumer)

After the initial deployment, subsequent updates follow this workflow:

```bash
# 1. Deploy updated artifacts to the app package stage
cd na_app_pkg
snow app deploy --connection wl_sandbox_dcr --role LOCID_APP_ADMIN

# 2. Create a new patch on the existing version (auto-increments patch number)
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

```sql
-- 3. Check current versions/patches
USE ROLE LOCID_APP_ADMIN;
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_DEV_PKG;

-- 4. Update the default release directive to push the new patch to all consumers
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = <new_patch_number>;
```

> **What happens:** Snowflake queues all installed consumer apps for automatic upgrade. The setup script re-runs in each consumer account. Typically completes within minutes.

**Consumer: Check installed version**

- **Snowsight:** Navigate to Catalog → Apps → LOCID_APP — version and patch shown in app details.
- **SQL:** `DESCRIBE APPLICATION LOCID_APP;` — shows `version`, `patch`, `upgrade_state`.

**Consumer: Manually trigger upgrade** (if not waiting for auto-upgrade):

```sql
ALTER APPLICATION LOCID_APP UPGRADE;
```

**Provider: Monitor upgrade status:**

```sql
SELECT * FROM SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE
WHERE APPLICATION_NAME = 'LOCID_DEV_PKG';
-- Check upgrade_state: COMPLETE, UPGRADING, QUEUED, FAILED
```

---

## Performance Considerations

- **Clustering** on `LOCID_BUILDS`: `(build_dt)` — aligns with the date-range filter on `LOCID_BUILD_DATES`.
- **Clustering** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the IPv4 equi-join.
- **Search Optimization Service** candidate on the IPv4 exploded table for equality predicate on `ip_address`.
- IPv6 temp tables: materialized as transient tables within the job transaction to avoid recompute.
- Warehouse sizing recommendation: Medium or Large for large batch jobs given the multi-pass IPv6 matching.

---

## Python Vectorized UDFs (Implemented)

### Background

The previous implementation used Scala scalar UDFs backed by the `encode-lib` JAR. Each UDF was a scalar function — Snowflake called it once per row within a SQL query. Within each node the per-row call overhead accumulated:

- Key derivation (`Base64.decode` + `SecretKeySpec`) ran per row (partially mitigated via JVM-level caching)
- Object allocation (`BaseLocIdEncryption`, `EncScheme0`) ran per row
- JVM call dispatch overhead applied to every row

For workloads in the tens or hundreds of millions of rows, this per-row overhead became measurable wall-clock time.

There was also an ongoing practical concern: the JAR had to be compiled to match Snowflake's supported JVM target. This caused one integration delay (Java 17 vs. Java 11 — see prior discussion). Each new Snowflake runtime version would require a JAR recompile and re-bundle.

The migration to Python vectorized UDFs (completed 2026-05-05) eliminated all of these concerns.

### Snowflake Python Vectorized UDFs

Snowflake supports **vectorized Python UDFs** (`LANGUAGE PYTHON` with `@vectorized`). Instead of receiving one scalar value per call, the function receives a `pandas.Series` containing a **batch of rows** (typically thousands at a time) and returns a `pandas.Series`. This eliminates per-row dispatch overhead and allows the encoding logic to operate on the full batch using efficient array operations.

```
Scalar UDF (previous):     Python vectorized UDF (current):
  call(row_1) → result         call(Series[row_1, row_2, ... row_N]) 
  call(row_2) → result           → Series[result_1, ... result_N]
  ...
  call(row_N) → result
  (N function calls)           (1 function call per batch)
```

Benchmark context (Snowflake engineering guidance): Python vectorized UDFs typically show **5–10× throughput improvement** over equivalent scalar Python UDFs for string transformation workloads. The improvement is most pronounced at larger warehouse sizes and larger batch sizes. Our measured result: **5.7× improvement** (Python vectorized WHL vs Scala scalar at 50M rows).

### Performance Results

Snowflake auto-tunes the vectorized batch size to approximately **1,000–8,192 rows per batch** per worker node. The throughput gain for this specific workload comes from two sources:

- **Fewer dispatch crossings** — the Python–SQL boundary is crossed `ceil(N / batch_size)` times instead of `N` times.
- **Amortised key setup** — `scheme_key` and `base_locid_key` are constants per query. A vectorized handler initialises cipher objects once per batch (or once per worker via `_scheme_cache`) instead of once per row.

| Row count    | Measured/expected improvement vs. Scala scalar UDFs        |
|--------------|------------------------------------------------------------|
| < 1M         | Marginal — IP matching SQL dominates runtime               |
| 1M – 10M     | 3–5× UDF throughput improvement                            |
| 10M – 100M   | 5–10× UDF throughput improvement                           |
| > 100M       | 5–10× or more — key-setup amortisation most impactful      |

> These estimates apply to the **UDF execution phase** only. The IP matching phase (Steps 3–4 of the stored procedure) is pure Snowflake SQL, already fully parallelised, and is unaffected by the UDF language change.

**Sandbox benchmark results — SNOWPARK_OPT_WH (MEDIUM), 50M rows, CTAS forced materialization (2026-05-05)**

| Approach | UDF | Avg Elapsed (s) | Throughput (krows/s) | Speedup vs A | Notes |
|----------|-----|:---------------:|:--------------------:|:------------:|-------|
| A — Scala scalar (JAR) | `LOCID_BASE_ENCRYPT` | ~145 | ~373 | 1.0× | AES-128 ECB via encode-lib; warm JVM avg of runs 2–3 |
| B — Python scalar proxy | `PROXY_SCALAR` | ~23 | ~2,152 | 6.3× | SHA-256 per row |
| C — Python vectorized proxy | `PROXY_VECTORIZED` | ~20 | ~2,480 | 7.2× | numpy BLAS polynomial hash; no Python loop |
| D — Python vectorized (WHL) | `PROXY_WHL` | ~25 | ~2,040 | 5.7× | `StableCloc.encode()` SHA-1 UUID5 via production WHL |

> **Interpretation:** D (production WHL) is **5.7× faster** than A (Scala scalar, warm JVM) at 50M rows. All Python approaches (B, C, D) cluster in the 20–26s range — the `@vectorized` batch dispatch effectively eliminates the Python/SQL boundary overhead. D is slightly slower than C because it performs real SHA-1 UUID5 with object construction vs C's pure-C numpy polynomial hash.

> **Note on JVM cold-start (historical):** The Scala path showed a 209s first-run penalty (JVM init + JAR load) before settling to ~113s steady-state. This concern is eliminated with the Python path — Python UDFs have no equivalent cold-start overhead.

### What LocID Has Provided

LocID delivered `mb_locid_encoding-0.0.0-py3-none-any.whl` — a pure-Python wheel implementing all encoding operations previously provided by `encode-lib` (Scala JAR). The wheel is staged to `@APP_STAGE/lib/` via `snow app deploy` and referenced by all Python vectorized UDFs via `IMPORTS`.

**Deployed UDFs (all Python vectorized, @vectorized batch dispatch):**

| UDF | Python handler | Operation |
|-----|---------------|-----------|
| `LOCID_BASE_ENCRYPT` | `locid_sf.encrypt_base_loc_id` | AES-GCM encrypt raw base LocID |
| `LOCID_BASE_DECRYPT` | `locid_sf.decrypt_base_loc_id` | AES-GCM decrypt ciphertext |
| `LOCID_TXCLOC_ENCRYPT` | Custom (decrypt + build JSON + EncScheme0) | encrypted_locid → TX_CLOC |
| `LOCID_TXCLOC_DECRYPT` | `locid_sf.decrypt_tx_cloc` | TX_CLOC → JSON |
| `LOCID_STABLE_CLOC` | `locid_sf.stable_cloc_from_encrypted` | encrypted_locid → STABLE_CLOC |
| `LOCID_STABLE_CLOC_FROM_PLAIN` | `locid_sf.encode_stable_cloc` | plaintext locid → STABLE_CLOC |

### Production UDF Example

```sql
-- LOCID_TXCLOC_DECRYPT — Python vectorized (WHL delivery)
CREATE OR REPLACE FUNCTION APP_CODE.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')
PACKAGES = ('cryptography>=41,<47', 'protobuf>=5.29,<7', 'pandas')
HANDLER = 'decrypt_batch'
AS $$
import os, sys, glob
for _dir in list(sys.path):
    if _dir and os.path.isdir(_dir):
        for _whl in glob.glob(os.path.join(_dir, '*.whl')):
            if _whl not in sys.path:
                sys.path.insert(0, _whl)

import pandas as pd
from _snowflake import vectorized
from locid import snowflake as locid_sf

@vectorized(input=pd.DataFrame)
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    return locid_sf.decrypt_tx_cloc(df.iloc[:, 0], df.iloc[:, 1])
$$;
```

No changes are required to the stored procedures (`encrypt.sql`, `decrypt.sql`) — they call the UDFs via SQL and are unaffected by the language change.

> **Why the `sys.path` wheel-loading snippet is required:** Since `snow snowpark package upload` cannot be used for consumer app deployment, the `.whl` is staged via `IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')`. When Snowflake imports a `.whl` file this way, it places it on the filesystem but does **not** automatically unpack it onto `sys.path`. The snippet manually adds the `.whl` to `sys.path` so that `from locid import ...` resolves correctly. This is the standard pattern for consuming `.whl` files delivered via `IMPORTS` in Snowflake Python UDFs. Performance impact is negligible (~10–50 μs one-time per worker process).

### Benefits of Python over JAR

| Concern | JAR (previous) | Python (current) |
|---------|--------------|-----------------|
| JVM version compatibility | Must compile to match Snowflake's supported JVM target; caused one integration delay | No JVM dependency — runs on CPython 3.11 |
| Distribution | Bundle `.jar` in app stage; re-bundle on JAR changes | Stage `.py` file(s) alongside other app sources — same process already in place |
| Testing | Requires Snowflake sandbox to validate | Standard `pytest` on any developer machine |
| Customer inspection | Opaque binary | Python source — auditable if LocID prefers |

### ~~Request to LocID~~ (Completed)

> **Fulfilled:** LocID delivered `mb_locid_encoding-0.0.0-py3-none-any.whl`. Python vectorized UDFs are deployed and benchmarked at 5.7× improvement over the Scala scalar path.

---

## Usage Telemetry

After each job run, the stored procedure reports usage statistics to LocID Central (best-effort — failures are logged but do not block the job). The telemetry contract is defined in the [Telemetry Catalog Addendum](../Tmp/tmp/20260505/locid-central-telemetry-catalog-native-app-addendum.md).

### Endpoint & Envelope

```
POST /api/0/location_id/stats
Content-Type: application/json
de-access-token: <api_key>
```

Body is a JSON array of `Stat` objects. Envelope-level fields:

| Field        | Value |
|--------------|-------|
| `identifier` | `"{license_key}_{job_id}"` — one identifier per job run |
| `source`     | `"snowflake-native-app"` |
| `data_type`  | `"batch_metrics"` |
| `timestamp`  | epoch ms at time of report |

### Metric Catalog (6 metric keys)

| metric_key | datatype | dimensions | description |
|------------|----------|------------|-------------|
| `batch-hits.encrypt` | Counter | api_key, client_id, tier, job_id | Rows matched at each tier |
| `batch-hits.decrypt` | Counter | api_key, client_id, tier, job_id | Rows matched at each tier |
| `batch-runtime.encrypt` | Timer | api_key, client_id, job_id, stage | Per-phase timing (match, udf, write, total) |
| `batch-runtime.decrypt` | Timer | api_key, client_id, job_id, stage | Per-phase timing (match, udf, write, total) |
| `batch-outcomes.encrypt` | Counter | api_key, client_id, outcome, job_id | Rows per outcome (matched, unmatched, invalid, error) |
| `batch-outcomes.decrypt` | Counter | api_key, client_id, outcome, job_id | Rows per outcome (matched, unmatched, invalid, error) |

### Example (Counter)

```json
{
  "identifier": "1569-3f8c9b2e_a4d2c1f0-7e3b-4f1a-9d8e-0c2b5f7a1e34",
  "source": "snowflake-native-app",
  "timestamp": 1746401234567,
  "data_type": "batch_metrics",
  "data": {
    "metric_key": "batch-hits.encrypt",
    "dimensions": { "api_key": "ak_3f8c9b2e", "client_id": "1042", "tier": "T0", "job_id": "a4d2c1f0-..." },
    "metric_value": 827341,
    "metric_datatype": "Counter"
  }
}
```

### Cadence

One flush per job, immediately after the matching/UDF/write phases complete and `JOB_LOG` is finalized. Each Counter value represents that job's totals (delta semantics — not cumulative since process start).

### Integrity Invariants

- `sum(batch-outcomes.{op} across all outcomes) == JOB_LOG.rows_in`
- `sum(batch-hits.{op} across all tiers) == batch-outcomes.{op} where outcome='matched'`

Job metadata (rows_in, rows_out, runtime_s, success flag) is also written to `APP_SCHEMA.JOB_LOG` for the customer's own visibility.

---

## Delivery Roadmap

| Milestone | Deliverable |
|-----------|-------------|
| **1 — Foundation** | Provider DB DDL (build tables, clustering, exploded IPv4 table) |
| | Native App package scaffold (`manifest.yml`, `setup.sql`, directory structure) |
| | External Access Integration (network rule + EAI for `central.locid.com`) |
| **2 — Core Engine** | Python vectorized UDFs (encrypt, decrypt, stable CLOC) registered via bundled WHL |
| | APP_CONFIG table + entitlement logic (dynamic output column registry) |
| | LocID Central integration (fetch/cache secrets, report usage stats) |
| **3 — Processing** | Encrypt stored procedure (IPv4 + IPv6 matching → UDF → output table) |
| | Decrypt stored procedure (TX_CLOC decode → STABLE_CLOC + geo context) |
| **4 — UI** | Streamlit onboarding wizard (8-screen setup flow) |
| | Streamlit main views (Home, Run Encrypt, Run Decrypt, History, SQL Guide, Config) |
| **5 — Polish** | Performance tuning (clustering keys, Search Optimization Service evaluation) |
| | End-to-end testing (encrypt/decrypt round-trip, IPv4 + IPv6, entitlement gates) |
