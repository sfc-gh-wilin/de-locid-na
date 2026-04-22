# LocID Snowflake Native App — Architecture

**Version:** 2.0  
**Provider:** Digital Envoy / Matchbook Data  
**Prepared by:** Snowflake Solutions Architecture

---

## Overview

The LocID Native App brings Digital Envoy's location identity enrichment capabilities natively into a customer's Snowflake account. Customers who today call cloud or on-premise APIs to enrich data with LocID identifiers can now run the same enrichment as a batch workflow — entirely within their own Snowflake environment, with no data leaving their account.

**Two operations are supported:**

| Operation | Customer Provides | App Returns |
|-----------|-------------------|-------------|
| **Encrypt** | Table of `(unique_id, ip_address, timestamp)` | `TX_CLOC`, `STABLE_CLOC`, geo context |
| **Decrypt** | Table of `(unique_id, tx_cloc)` | `STABLE_CLOC`, geo context |

---

## How It Works

The app is distributed via the Snowflake Native App Framework. Digital Envoy publishes the app to the Snowflake Marketplace; customers install it in their own account in a few clicks.

```
┌─────────────────────────────────┐      ┌──────────────────────────────┐
│   Digital Envoy (Provider)      │      │   Customer (Consumer)        │
│                                 │      │                              │
│  LOCID_BUILDS (shared)          │◄─────│  App queries via share       │
│  LOCID_BUILDS_IPV4_EXPLODED     │      │                              │
│  LOCID_BUILD_DATES              │      │  Customer input table        │
│                                 │      │  → App stored procedure      │
│  encode-lib JAR (bundled)       │      │  → Customer output table     │
│  LocID Central API              │◄─────│  App reports usage stats     │
└─────────────────────────────────┘      └──────────────────────────────┘
```

**All customer data stays in the customer's Snowflake account.** Digital Envoy's LocID data lake is shared as read-only — no customer rows are written to Digital Envoy's account.

> **Data visibility:** The shared LocID tables (`LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, `LOCID_BUILD_DATES`) are **not directly queryable by consumers**. The Snowflake Native App Framework enforces this boundary at the platform level — only the app's own stored procedures and UDFs, executing within the app container, can read those tables. Consumer account users and roles have no visibility into DE's underlying data.

---

## What Digital Envoy Provides

| Component | Description |
|-----------|-------------|
| **LocID Build Tables** | Three tables shared to the app: `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, `LOCID_BUILD_DATES`. Updated weekly via an Airflow DAG. |
| **encode-lib JAR** | Scala library bundled in the app stage. Handles all TX_CLOC and STABLE_CLOC cryptographic operations. |
| **LocID Central** | HTTPS API at `central.locid.com` — validates license keys, delivers cryptographic secrets, and receives usage statistics after each job run. |

---

## Technical Architecture

### App Package Structure

```
locid-native-app/
├── manifest.yml                  # App manifest (privileges, references)
├── setup.sql                     # Bootstrap: schemas, objects, grants
├── src/
│   ├── procs/
│   │   ├── encrypt.sql           # Encrypt stored procedure
│   │   └── decrypt.sql           # Decrypt stored procedure
│   ├── udfs/
│   │   └── locid_udf.sql         # Scala UDF definitions wrapping the JAR
│   └── lib/
│       └── encode-lib-*.jar      # Bundled Java 17 fat JAR (stage artifact)
└── streamlit/
    ├── app.py                    # Main Streamlit entry point
    ├── pages/
    │   ├── 01_setup_wizard.py
    │   ├── 02_run_encrypt.py
    │   ├── 03_run_decrypt.py
    │   ├── 04_job_history.py
    │   └── 05_configuration.py
    └── utils/
        ├── locid_central.py      # LocID Central API calls (via EAI)
        └── entitlements.py       # Entitlement check helpers
```

### Snowflake Objects (App Side — installed in customer account)

```
APP_SCHEMA.APP_CONFIG          -- License key, cached secrets, entitlements, output column registry
APP_SCHEMA.JOB_LOG             -- Job run history (job_id, run_dt, rows_in, rows_out, runtime_s, status)
APP_SCHEMA.LOCID_ENCRYPT(...)  -- Encrypt stored procedure
APP_SCHEMA.LOCID_DECRYPT(...)  -- Decrypt stored procedure
APP_SCHEMA.LOCID_UDF(...)      -- Scala UDF (encrypt/decrypt via JAR)
APP_SCHEMA.HTTP_PING()         -- Python UDF to verify EAI connectivity during setup
```

### Scala UDF Design

The `encode-lib` JAR (Scala 2.13 / Java 17) is bundled in the app stage and registered as `LANGUAGE SCALA RUNTIME_VERSION = '2.13'` UDFs with inline Scala handlers — no external wrapper class required. Each UDF embeds its handler class in the `AS $$...$$` block, calling the JAR's public API directly.

### IP Matching Strategy

**IPv4** — Exploded equi-join for maximum performance:
```
customer_input.ip_address = locid_builds_ipv4_exploded.ip_address
joined back to locid_builds on (build_dt, start_ip, end_ip)
```

**IPv6** — Reference implementation: cascading 6-pass hex-prefix range join:
```
Pass 1: hex prefix[0:12] match + range join
Pass 2: prefix[0:10], excluding Pass 1 hits
  ...
Pass 6: full range join on remaining rows
UNION ALL all results
```

> **Implementation note:** The 6-pass cascading approach above is the reference implementation DE provided as one efficient strategy for IPv6 range joins in Snowflake. It is not prescribed — alternative strategies (e.g. a single full range join, a different prefix-length sequence, or Snowflake's native `ASOF JOIN`) are valid approaches. The right choice depends on data distribution and performance testing; DE is open to alternatives.

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

The license key is stored as a Snowflake `SECRET` object, referenced by the External Access Integration — never exposed in query results, logs, or the Streamlit UI.

---

## Customer Onboarding Workflow

A guided wizard runs once after install and can be re-accessed from the Configuration view.

```
[Welcome]
    └── [Have a LocID license key?]
            ├── No  → [Contact LocID Sales] → END
            └── Yes → [Enter License Key (masked)]
                        → [Review & Request Privileges]
                            → [Create App Objects]
                                → [Test Connectivity to LocID Central]
                                    → [Select API Key]
                                        → [Setup Complete]
```

| Screen | Purpose |
|--------|---------|
| **A. Welcome** | Introduction and "Get started" CTA |
| **B. Have a key?** | Gate — Yes/No selection |
| **C. Contact Sales** | Dead end for users without a key — shows DE contact info |
| **D. Enter License Key** | Masked input, format validation, stores key as Snowflake SECRET |
| **E. Review Privileges** | Checks required grants; provides SQL for ACCOUNTADMIN if missing |
| **F. Create App Objects** | Bootstraps `APP_CONFIG`, `JOB_LOG`, and the `HTTP_PING` UDF |
| **G. Test Connectivity** | Calls LocID Central license endpoint; shows status and latency |
| **H. Select API Key** | Lists ACTIVE entries from `access[]`; user selects which API key to use; `api_key_id`, `namespace_guid`, `provider_id` stored in `APP_CONFIG` |
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
| *(future — de-scoped from v1)* `allow_homebiz` | HomeBiz_Type included in output |

Output columns are **not hardcoded**. They are driven by `APP_CONFIG` rows, so new entitlements and fields can be added by DE without app code changes — only a config update and, if the schema changes, a new app version release.

---

## Streamlit Views

The app has six views accessible from a left-side navigation bar. All views run entirely within the customer's Snowflake account.

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

### View 2 — Setup Wizard

**Purpose:** One-time post-install onboarding. Guides the customer from a fresh install to a fully connected and verified app in approximately 5 minutes.

See **[Customer Onboarding Workflow](#customer-onboarding-workflow)** for the full 8-screen flow. The wizard is re-accessible from the Configuration view if credentials need to be updated.

---

### View 3 — Run Encrypt

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

> **Note from DE (2026-04-20):** These validation checks are in scope for v1. Timestamp age limit of 52 weeks aligns with DE's build retention window.

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
| HomeBiz_Type | *(future — de-scoped from v1)* | — |

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

### View 4 — Run Decrypt

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
| HomeBiz_Type | *(future — de-scoped from v1)* | — |

**On completion:**
- Result summary: rows in, rows decoded, rows written, runtime
- Links to output table and Job History

---

### View 5 — Job History

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

### View 6 — Configuration

**Purpose:** Manage license credentials, view current entitlements, and review the output column registry.

**License & Credentials**
- License key: shown masked (`1569-****-****-****`), with "Update" button that re-triggers the Enter Key screen
- Client name and expiration date (read-only, from LocID Central)
- API key: shown masked, used for usage stats reporting only
- **Refresh from LocID Central** button — manually re-fetches secrets and entitlements

**Current Entitlements**

```
✓ allow_encrypt    ✓ allow_decrypt
✓ allow_tx         ✓ allow_stable
✓ allow_geo_context ✗ allow_homebiz (not provisioned)
```

**Output Column Registry**

| Column Name | Operation | Requires Entitlement | Active |
|------------|-----------|---------------------|--------|
| TX_CLOC | Encrypt | allow_tx | ✓ |
| STABLE_CLOC | Both | allow_stable | ✓ |
| locid_country | Both | allow_geo_context | ✓ |
| … | … | … | … |

Read-only for customers. Updated by DE via app version releases when new fields are added.

**Advanced**
- "Re-run Setup Wizard" link — for re-registering credentials or troubleshooting connectivity

---

## Security & Data Boundary

- All customer data remains in the customer's Snowflake account at all times.
- Digital Envoy's LocID data lake is shared as read-only objects — no customer rows are written to DE's account.
- License key stored as a Snowflake `SECRET`, referenced by the External Access Integration — not visible in query results or logs.
- Cryptographic keys (AES) fetched at runtime from LocID Central, passed as UDF parameters, never persisted in tables.
- Masking policy on `APP_CONFIG` for sensitive configuration rows.

---

## Role Setup for App Package & App Deployment

Using `ACCOUNTADMIN` for day-to-day deployment is a common concern in enterprise environments. The custom roles below minimize privilege scope while covering everything needed to build, publish, and install the LocID Native App.

### Provider Account — `LOCID_APP_ADMIN`

Used by Digital Envoy's engineering or ops team to manage the Application Package, stage contents, and Marketplace listing.

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
-- Publish and manage the Snowflake Marketplace listing
GRANT MANAGE LISTING ON ACCOUNT TO ROLE LOCID_APP_ADMIN;
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

After installation, the app's `setup.sql` creates all internal objects (schemas, tables, UDFs, stored procedures) within the app container — no additional consumer-side grants are required for those.

### Notes

- The one-time `GRANT ... TO ROLE` steps must be executed by `ACCOUNTADMIN`. This is unavoidable, but it is a **one-time setup only** — all routine operations use the custom role thereafter.
- The app's onboarding wizard (Screen E — Review Privileges) checks required grants and surfaces the remediation SQL to the installer if any are missing.
- If the customer's environment uses a standard role hierarchy (e.g. `SYSADMIN` → custom roles), grant `LOCID_APP_INSTALLER` to `SYSADMIN` for hierarchy compliance:
  ```sql
  GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
  ```
- For Marketplace installs, `CREATE APPLICATION` on a custom role is the supported least-privilege path. `ACCOUNTADMIN` is not required for the install itself once the grant is in place.

---

## Performance Considerations

- **Clustering** on `LOCID_BUILDS`: `(build_dt)` — aligns with the date-range filter on `LOCID_BUILD_DATES`.
- **Clustering** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the IPv4 equi-join.
- **Search Optimization Service** candidate on the IPv4 exploded table for equality predicate on `ip_address`.
- IPv6 temp tables: materialized as transient tables within the job transaction to avoid recompute.
- Warehouse sizing recommendation: Medium or Large for large batch jobs given the multi-pass IPv6 matching.

---

## Roadmap: Python Package for Vectorized UDFs

### Background

The current implementation uses Scala UDFs backed by the `encode-lib` JAR. Each UDF is a scalar function — Snowflake calls it once per row within a SQL query. Snowflake's MPP engine distributes rows across warehouse nodes in parallel, which is already efficient. However, within each node the per-row call overhead accumulates:

- Key derivation (`Base64.decode` + `SecretKeySpec`) runs per row (partially mitigated in v1.1 via JVM-level caching)
- Object allocation (`BaseLocIdEncryption`, `EncScheme0`) runs per row
- JVM call dispatch overhead applies to every row

For workloads in the tens or hundreds of millions of rows, this per-row overhead becomes measurable wall-clock time.

There is also an ongoing practical concern: the JAR must be compiled to match Snowflake's supported JVM target. This has already caused one integration delay (Java 17 vs. Java 11 — see prior discussion). Each new Snowflake runtime version requires a JAR recompile and re-bundle.

### Snowflake Python Vectorized UDFs

Snowflake supports **vectorized Python UDFs** (`LANGUAGE PYTHON` with `@vectorized`). Instead of receiving one scalar value per call, the function receives a `pandas.Series` containing a **batch of rows** (typically thousands at a time) and returns a `pandas.Series`. This eliminates per-row dispatch overhead and allows the encoding logic to operate on the full batch using efficient array operations.

```
Scalar UDF (current):      Python vectorized UDF (target):
  call(row_1) → result         call(Series[row_1, row_2, ... row_N]) 
  call(row_2) → result           → Series[result_1, ... result_N]
  ...
  call(row_N) → result
  (N function calls)           (1 function call per batch)
```

Benchmark context (Snowflake engineering guidance): Python vectorized UDFs typically show **5–10× throughput improvement** over equivalent scalar Python UDFs for string transformation workloads. The improvement is most pronounced at larger warehouse sizes and larger batch sizes.

### What We Are Asking DE to Provide

Python source implementing the same encoding operations currently provided by `encode-lib`. **A pip package is not required** — plain `.py` files are sufficient. Snowflake Python UDFs support `IMPORTS = ('@stage/locid.py')` to load staged source files directly, the same way the JAR is staged today.

**Delivery options (any of these works):**

| Option | What DE provides | How it's used in the UDF |
|--------|-----------------|--------------------------|
| **Source files** *(simplest)* | One or more `.py` files | `IMPORTS = ('@APP_SCHEMA.APP_STAGE/src/lib/locid.py')` |
| **Wheel file** | A `.whl` built from the source | `IMPORTS = ('@APP_SCHEMA.APP_STAGE/src/lib/locid-x.y.z-py3-none-any.whl')` |
| **pip package** | Published to Anaconda or private PyPI | `PACKAGES = ('locid-python==x.y.z')` |
| **Scala/Java source** | Share the relevant encoding source files | We port the logic to Python on our side |

**Required API surface** — five functions matching the JAR's operations:

| Current (JAR — Scala) | Target (Python) |
|-----------------------|----------------|
| `BaseLocIdEncryption.encrypt(locId, key)` | `locid.base_encrypt(loc_id: str, key: str) -> str` |
| `BaseLocIdEncryption.decrypt(ciphertext, key)` | `locid.base_decrypt(ciphertext: str, key: str) -> str` |
| `TxCloc` + `EncScheme0.encode(...)` | `locid.txcloc_encrypt(encrypted_locid, base_key, scheme_key, ts, client_id) -> str` |
| `EncScheme0.decode(txCloc)` | `locid.txcloc_decrypt(tx_cloc: str, scheme_key: str) -> dict` |
| `StableCloc.encode(...)` | `locid.stable_cloc(encrypted_locid, base_key, ns_guid, client_id, enc_client_id, tier) -> str` |

### What the Vectorized UDF Would Look Like

```sql
-- LOCID_TXCLOC_DECRYPT — vectorized Python example (source file delivery)
CREATE OR REPLACE FUNCTION APP_SCHEMA.LOCID_TXCLOC_DECRYPT(
    TX_CLOC    VARCHAR,
    SCHEME_KEY VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
IMPORTS = ('@APP_SCHEMA.APP_STAGE/src/lib/locid.py')   -- DE-provided source file
HANDLER = 'decrypt_batch'
AS $$
import pandas as pd
import locid  # sourced from the staged locid.py

# _scheme_cache: key string → EncScheme0 object; persists across batches in the same worker
_scheme_cache = {}

@vectorized(input=pd.DataFrame)
def decrypt_batch(df: pd.DataFrame) -> pd.Series:
    scheme_key = df.iloc[0, 1]  # constant for all rows in this query
    if scheme_key not in _scheme_cache:
        _scheme_cache[scheme_key] = locid.EncScheme0(scheme_key)
    scheme = _scheme_cache[scheme_key]
    return df.iloc[:, 0].apply(lambda tx: scheme.decode_json(tx))
$$;
```

No changes are required to the stored procedures (`encrypt.sql`, `decrypt.sql`) — they call the UDFs via SQL and are unaffected by the language change.

### Additional Benefits of Moving to Python

| Concern | JAR (current) | Python (target) |
|---------|--------------|-----------------|
| JVM version compatibility | Must compile to match Snowflake's supported JVM target; caused one integration delay | No JVM dependency — runs on CPython 3.11 |
| Distribution | Bundle `.jar` in app stage; re-bundle on JAR changes | Stage `.py` file(s) alongside other app sources — same process already in place |
| Testing | Requires Snowflake sandbox to validate | Standard `pytest` on any developer machine |
| Customer inspection | Opaque binary | Python source — auditable if DE prefers |

### Request to DE

1. **Provide Python source** implementing the five encoding operations listed above — plain `.py` file(s) are sufficient. A pip package or `.whl` is welcome but not required.
2. **Alternatively**, share the relevant Scala/Java encoding source (the crypto and encoding classes from `encode-lib`) and we will handle the Python port on our side.
3. **Version alignment**: The Python implementation should be kept in sync with `encode-lib` releases so encode/decode results remain byte-compatible across both paths.

This is a **v2 roadmap item** — the current JAR-based implementation is fully functional and in use. We raise it now so DE can plan accordingly and so we have a clear upgrade path as customer data volumes grow.

> **Note:** If DE shares Scala/Java source for us to port, the Python implementation must be validated to produce byte-identical output to `encode-lib` (same ciphertext, same TX_CLOC encoding, same STABLE_CLOC UUIDs). A cross-compatibility test — running both the Scala UDFs and the Python UDFs against the same input and asserting identical output — is required before the Python path can be used in production.

---

## Usage Telemetry

After each job run, the app reports usage statistics to LocID Central:

```json
POST /api/0/location_id/stats
Header: de-access-token: <api_key>

[{
  "identifier": "<license_key>",
  "source":     "snowflake-native-app",
  "timestamp":  <epoch_ms>,
  "data_type":  "usage_metrics",
  "data": {
    "metric_key":       "encrypt_usage",
    "dimensions":       { "api_key": "<api_key>", "hit": 1, "tier": 0 },
    "metric_value":     <rows_processed>,
    "metric_datatype":  "Long"
  }
}]
```

> **Pending from DE:** The example above shows `encrypt_usage` only. DE needs to confirm the complete telemetry contract before implementation:
> - All `metric_key` values they want reported (e.g. `encrypt_usage`, `decrypt_usage`, and any others)
> - The full `dimensions` schema for each metric key — field names, types, and semantics of `hit` and `tier`

Job metadata (rows_in, rows_out, runtime_s, success flag) is also written to `APP_SCHEMA.JOB_LOG` for the customer's own visibility.

---

## Delivery Roadmap

| Milestone | Deliverable |
|-----------|-------------|
| **1 — Foundation** | Provider DB DDL (build tables, clustering, exploded IPv4 table) |
| | Native App package scaffold (`manifest.yml`, `setup.sql`, directory structure) |
| | External Access Integration (network rule + EAI for `central.locid.com`) |
| **2 — Core Engine** | Scala UDFs (encrypt, decrypt, stable CLOC) registered via bundled JAR |
| | APP_CONFIG table + entitlement logic (dynamic output column registry) |
| | LocID Central integration (fetch/cache secrets, report usage stats) |
| **3 — Processing** | Encrypt stored procedure (IPv4 + IPv6 matching → UDF → output table) |
| | Decrypt stored procedure (TX_CLOC decode → STABLE_CLOC + geo context) |
| **4 — UI** | Streamlit onboarding wizard (8-screen setup flow) |
| | Streamlit main views (Home, Run Encrypt, Run Decrypt, History, Config) |
| **5 — Polish** | Performance tuning (clustering keys, Search Optimization Service evaluation) |
| | End-to-end testing (encrypt/decrypt round-trip, IPv4 + IPv6, entitlement gates) |
