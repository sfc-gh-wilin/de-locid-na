# LocID Snowflake Native App — Architecture

**Version:** 1.0  
**Provider:** Digital Envoy / Matchbook Data  
**Prepared by:** Snowflake Solutions Architecture

---

## Overview

The LocID Native App brings Digital Envoy's location identity enrichment capabilities natively into a customer's Snowflake account. Customers who today call cloud or on-premise APIs to enrich data with LocID identifiers can now run the same enrichment as a batch workflow — entirely within their own Snowflake environment, with no data leaving their account.

**Two operations are supported:**

| Operation | Customer Provides | App Returns |
|-----------|-------------------|-------------|
| **Encrypt** | Table of `(unique_id, ip_address, timestamp)` | `TX_CLOC`, `STABLE_CLOC`, geo context, `HomeBiz_Type` |
| **Decrypt** | Table of `(unique_id, tx_cloc)` | `STABLE_CLOC`, geo context, `HomeBiz_Type` |

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
│       └── encode-lib-*.jar      # Bundled Scala JAR (stage artifact)
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

The `encode-lib` JAR is bundled in the app stage and registered as Snowflake Scala UDFs. Key functions:

| UDF | Inputs | Output |
|-----|--------|--------|
| `locid_encrypt` | `encrypted_locid`, `timestamp`, `scheme_key`, `base_locid_key`, `client_id` | `tx_cloc` |
| `locid_stable` | `encrypted_locid`, `namespace_guid`, `client_id`, `tier` | `stable_cloc` (UUID) |
| `locid_decrypt` | `tx_cloc`, `scheme_key` | `location_id`, `timestamp`, `enc_client_id` |

Cryptographic keys are retrieved from LocID Central at job start and passed directly into UDF calls — never stored in plaintext in any table.

### IP Matching Strategy

**IPv4** — Exploded equi-join for maximum performance:
```
customer_input.ip_address = locid_builds_ipv4_exploded.ip_address
joined back to locid_builds on (build_dt, start_ip, end_ip)
```

**IPv6** — Cascading 6-pass hex-prefix range join:
```
Pass 1: hex prefix[0:12] match + range join
Pass 2: prefix[0:10], excluding Pass 1 hits
  ...
Pass 6: full range join on remaining rows
UNION ALL all results
```

Both strategies filter to relevant build dates covering the input timestamp.

---

## LocID Central Integration

```
GET  https://central.locid.com/api/0/location_id/license/{license_id}
  → license metadata, entitlements (access[]), cryptographic secrets

POST https://central.locid.com/api/0/location_id/stats
  → usage metrics after each job run (rows processed, runtime, job_id)
```

**Caching strategy:**
- Secrets and entitlements are fetched on first job run and refreshed every 60 minutes.
- Cache expiry: 1 week.
- If the initial fetch fails, the job is aborted — secrets are required.
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
| **H. Success** | Summary checklist and "Launch App" button |

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
         │
         ├─ 2. Call LOCID_UDF per row
         │       tx_cloc → decrypt → base LocID + embedded geo context
         │       → STABLE_CLOC, geo fields, HomeBiz_Type
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
| `allow_geocontext` | Geo context fields included in output |
| *(future)* `allow_homebiz` | HomeBiz_Type included in output |

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

**Step 3 — Configure Output**
- Radio: *Create new table* or *Overwrite existing table*
- Text input: output table name (e.g. `MY_DB.MY_SCHEMA.LOCID_RESULTS`)
- Confirmation prompt if overwriting

**Step 4 — Select Output Columns**

| Column | Entitlement Required | Default |
|--------|---------------------|---------|
| TX_CLOC | `allow_tx` | ✓ |
| STABLE_CLOC | `allow_stable` | ✓ |
| Country / Country Code | `allow_geocontext` | ✓ |
| Region / Region Code | `allow_geocontext` | ✓ |
| City / City Code | `allow_geocontext` | ✓ |
| Postal Code | `allow_geocontext` | ✓ |
| HomeBiz_Type | *(future)* | — |

Columns the customer is not entitled to are shown greyed out with a tooltip explaining why.

**Step 5 — Review & Run**
- Summary card: input table, row count, output table, selected columns, warehouse
- Warehouse selector: dropdown of warehouses the customer has access to
- **Run Job** button

**During execution:**
- Live progress bar with status messages (e.g. "Matching IPv4 records…", "Calling LocID UDF…", "Writing output…")
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
| Country / Country Code | `allow_geocontext` | ✓ |
| Region / Region Code | `allow_geocontext` | ✓ |
| City / City Code | `allow_geocontext` | ✓ |
| Postal Code | `allow_geocontext` | ✓ |
| HomeBiz_Type | *(future)* | — |

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
✓ allow_geocontext ✗ allow_homebiz (not provisioned)
```

**Output Column Registry**

| Column Name | Operation | Requires Entitlement | Active |
|------------|-----------|---------------------|--------|
| TX_CLOC | Encrypt | allow_tx | ✓ |
| STABLE_CLOC | Both | allow_stable | ✓ |
| locid_country | Both | allow_geocontext | ✓ |
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

## Performance Considerations

- **Clustering** on `LOCID_BUILDS`: `(build_dt)` — aligns with the date-range filter on `LOCID_BUILD_DATES`.
- **Clustering** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the IPv4 equi-join.
- **Search Optimization Service** candidate on the IPv4 exploded table for equality predicate on `ip_address`.
- IPv6 temp tables: materialized as transient tables within the job transaction to avoid recompute.
- Warehouse sizing recommendation: Medium or Large for large batch jobs given the multi-pass IPv6 matching.

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
