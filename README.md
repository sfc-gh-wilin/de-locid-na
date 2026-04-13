# LocID Snowflake Native App — Architecture

**Provider:** Digital Envoy / Matchbook Data  
**Purpose:** Batch LocID enrichment for Snowflake customers — appends TX_CLOC and STABLE_CLOC identifiers to customer IP + timestamp data, entirely within the customer's Snowflake account.

---

## What This App Does

Customers who use LocID today call cloud or on-premise APIs to enrich their data with location identifiers. This Native App extends that capability into Snowflake as a batch workflow:

1. Customer provides a table with `(unique_id, ip_address, timestamp)` rows.
2. The app matches each IP + timestamp against Digital Envoy's weekly LocID data lake.
3. For each matched row, the Scala UDF generates encrypted identifiers (TX_CLOC, STABLE_CLOC) and optional geo context.
4. Results are written to a customer-specified output table — all within the customer's account.
5. Usage statistics are reported back to LocID Central over HTTPS.

Two operations are supported:

| Operation | Input | Output |
|-----------|-------|--------|
| **Encrypt** | `unique_id`, `ip_address`, `timestamp` | `TX_CLOC`, `STABLE_CLOC`, geo context, `HomeBiz_Type` |
| **Decrypt** | `unique_id`, `tx_cloc` | `STABLE_CLOC`, geo context, `HomeBiz_Type` |

---

## Works Needed

| # | Work Item | Notes |
|---|-----------|-------|
| 1 | Native App package scaffolding | `manifest.yml`, `setup.sql`, directory structure |
| 2 | External Access Integration (EAI) | Outbound HTTPS to `central.locid.com` |
| 3 | Scala UDF | Wrap `encode-lib` JAR; functions: encrypt, decrypt, stable CLOC |
| 4 | Config table design | Dynamic entitlements and output column registry |
| 5 | LocID Central integration | Fetch license/secrets/entitlements, cache, report stats |
| 6 | Encrypt stored procedure | IP matching (IPv4 + IPv6) + UDF call → output table |
| 7 | Decrypt stored procedure | TX_CLOC decode → STABLE_CLOC + context → output table |
| 8 | Streamlit onboarding wizard | 8-screen setup flow (see below) |
| 9 | Streamlit main app views | Job submission, history, config |
| 10 | Performance tuning | Clustering keys / search optimization on provider build tables |
| 11 | Usage telemetry | POST stats to LocID Central after each job run |
| 12 | Testing | End-to-end encrypt/decrypt round-trip, IPv4 + IPv6, entitlement gates |

---

## Delivery Plan

Ordered phases from first artifact to production-ready app.

| Phase | Step | Work Item | Output |
|-------|------|-----------|--------|
| **1 — Foundation** | 1    | Provider DB DDL | `db/dev/provider/` |
| | 2    | Native App package scaffold | `na_app_pkg/` skeleton |
| | 3    | External Access Integration (EAI) | Network rule + EAI for `central.locid.com` |
| **2 — Core Engine** | 4    | Scala UDF | JAR registered, encrypt/decrypt/stable functions |
| | 5    | APP_CONFIG table + entitlement logic | Dynamic output column registry |
| | 6    | LocID Central integration | Fetch/cache secrets, report stats |
| | 7    | Usage telemetry | POST stats to LocID Central post-job |
| **3 — Processing** | 8    | Encrypt stored procedure | IPv4 + IPv6 matching + UDF → output table |
| | 9    | Decrypt stored procedure | TX_CLOC decode → STABLE_CLOC + context |
| **4 — UI** | 10   | Streamlit onboarding wizard | 8-screen setup flow |
| | 11   | Streamlit main views | Home, Run, History, Config |
| **5 — Polish** | 12   | Performance tuning | Clustering keys, SOS evaluation |
| | 13   | End-to-end testing | Encrypt/decrypt round-trip, IPv4 + IPv6, entitlement gates |

---

## How to Design

### App Package Structure

```
locid-native-app/
├── manifest.yml                  # App manifest (privileges, references)
├── setup.sql                     # Setup script (schemas, objects, grants)
├── scripts/
│   └── setup/
│       └── setup.sql
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

### Snowflake Object Layout (Provider Side)

Digital Envoy maintains these tables in their Snowflake account, shared to the Native App:

```
LOCID.STAGING.LOCID_BUILDS                  -- IP ranges, encrypted_locid, geo context
LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED    -- Exploded IPv4 table (equi-join)
LOCID.STAGING.LOCID_BUILD_DATES             -- Weekly build date reference
```

Updated weekly via an Airflow DAG on DE's side. The Native App accesses these as shared objects — no customer data is written to the provider's account.

### Snowflake Object Layout (App Side — installed in customer account)

```
APP_SCHEMA.APP_CONFIG          -- License key, cached secrets, entitlements, output column registry
APP_SCHEMA.JOB_LOG             -- Job run history (job_id, run_dt, rows_in, rows_out, runtime_s, status)
APP_SCHEMA.LOCID_ENCRYPT(...)  -- Encrypt stored procedure
APP_SCHEMA.LOCID_DECRYPT(...)  -- Decrypt stored procedure
APP_SCHEMA.LOCID_UDF(...)      -- Scala UDF (encrypt/decrypt via JAR)
APP_SCHEMA.HTTP_PING()         -- Python UDF to test EAI connectivity during setup
```

---

## Scala UDF Design

The `encode-lib` JAR is bundled in the app stage and registered as a Java/Scala UDF. Key functions:

| UDF | Inputs | Output | Notes |
|-----|--------|--------|-------|
| `locid_encrypt` | `encrypted_locid`, `timestamp`, `scheme_key`, `base_locid_key`, `client_id` | `tx_cloc` | Decrypts base LocID from build table, re-encrypts as TX_CLOC |
| `locid_stable` | `encrypted_locid`, `namespace_guid`, `client_id`, `tier` | `stable_cloc` | Produces stable UUID-format CLOC |
| `locid_decrypt` | `tx_cloc`, `scheme_key` | `VARIANT` (locid, timestamp, enc_client_id) | Decrypts TX_CLOC |

Crypto keys (`scheme_key`, `base_locid_key`) are retrieved from LocID Central at job start, passed into UDFs — never stored in plaintext in tables.

### TxCloc Constructor (confirmed from local JAR testing)

```scala
// 5-parameter form — GeoContext and optional stable ID are required
TxCloc(
  locationId  : String,         // base LocID
  timestamp   : Long,           // epoch seconds
  encClientId : Int,            // client_id from LocID Central access record
  geoContext  : GeoContext,     // GeoContext() for default/empty; populated fields if entitlement allows
  stableId    : Option[...]     // None for standard encrypt path
)
```

### Key Material Note

Local tests (`EncryptionTest.scala`, `EncryptionTestWithTS.scala`) derive the AES key by taking the **license key string's raw UTF-8 bytes padded to 32 bytes (AES-256)**. This is a test shortcut only.

In production, the key material must come from LocID Central:
- `base_locid_secret` → Base64-URL decode → `SecretKeySpec` for `BaseLocIdEncryption`
- `scheme_secret` → Base64-URL decode → `SecretKeySpec` for `EncScheme0`

The integration guide specifies these decode to **16 bytes (AES-128)**. The test files use 32 bytes. **Clarify with DE which key size the production JAR expects** before finalizing the UDF implementation.

---

## LocID Central Integration

```
GET  https://central.locid.com/api/0/location_id/license/{license_id}
  → license metadata, access[] (entitlements), secrets (AES-128 keys)

POST https://central.locid.com/api/0/location_id/stats
  Header: de-access-token: <api_key>
  Body:   [{ identifier, source, timestamp, data_type, data: { metric_key, dimensions, metric_value } }]
```

**Caching strategy** (implemented inside the stored procedure / Streamlit session):
- Fetch on first job run of the session.
- Refresh every 60 minutes in background.
- Cache expiry: 1 week.
- If initial fetch fails → abort job (secrets are required).
- If refresh fails → use cached values, log warning.

The license key is stored as a Snowflake `SECRET` (via the EAI), referenced by the app — never exposed in query results or UI.

---

## Customer Onboarding Workflow

Multi-screen Streamlit wizard, runs once post-install.

```
[Welcome]
    └── [Have a LocID license key?]
            ├── No  → [Contact LocID Sales] → END (no forward navigation)
            └── Yes → [Enter License Key (masked)]
                        → [Review & Request Privileges]
                            → [Create Shared App Objects]
                                → [Test EAI Connectivity]
                                    → [Setup Complete]
```

### Screen Details

| Screen | Purpose | Key Actions |
|--------|---------|-------------|
| **A. Welcome** | Intro | "Get started" CTA |
| **B. Have a key?** | Gate | Yes/No radio |
| **C. Contact Sales** | Dead end (no key) | Show DE contact info, close wizard |
| **D. Enter License Key** | Capture credential | Masked input, validate format, store as Snowflake SECRET |
| **E. Review Privileges** | Grant check | Check EAI, DB/schema grants; show SQL for ACCOUNTADMIN |
| **F. Create App Objects** | Bootstrap | Create APP_SHARED schema, APP_CONFIG, JOB_LOG, HTTP_PING UDF |
| **G. Test Connectivity** | Validate EAI | Call LocID Central license endpoint; show status + latency |
| **H. Success** | Done | Summary checklist, link to docs, "Launch App" |

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
         ├─ 2. IP Matching (see matching strategy below)
         │       → returns: unique_id, ip_address, timestamp,
         │                  encrypted_locid, tier, geo_context, build_dt
         │
         ├─ 3. Call LOCID_UDF per row
         │       encrypted_locid → decrypt base LocID → re-encrypt
         │       → TX_CLOC, STABLE_CLOC
         │
         ├─ 4. Apply entitlement filter on output columns
         │
         ├─ 5. INSERT INTO customer output table
         │
         └─ 6. POST usage stats to LocID Central
                (rows_in, rows_out, runtime_s, job_id, timestamp)
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
         │       tx_cloc → decrypt → base LocID + embedded geo_context
         │       → STABLE_CLOC, geo fields, HomeBiz_Type
         │
         ├─ 3. Apply entitlement filter on output columns
         │
         ├─ 4. INSERT INTO customer output table
         │
         └─ 5. POST usage stats to LocID Central
```

### IP Matching Strategy

**IPv4** — Exploded equi-join (most performant):
```
customer_input.ip_address = locid_builds_ipv4_exploded.ip_address
joined back to locid_builds on (build_dt, start_ip, end_ip)
```

**IPv6** — Cascading prefix range joins (6 passes):
```
Pass 1: hex prefix[0:12] match + range join  → temp_ipv6_prefix12
Pass 2: prefix[0:10], exclude prefix12 hits  → temp_ipv6_prefix10
Pass 3: prefix[0:8],  exclude above          → temp_ipv6_prefix8
Pass 4: prefix[0:6],  exclude above          → temp_ipv6_prefix6
Pass 5: prefix[0:4],  exclude above          → temp_ipv6_prefix4
Pass 6: full range join on remaining rows    → temp_ipv6_remaining
UNION ALL all results
```

Both IPv4 and IPv6 results are filtered to `relevant_builds` (build dates whose range covers the input timestamp).

---

## Customer Entitlements

Entitlements are fetched from LocID Central per license key and cached in `APP_CONFIG`. They control:

| Entitlement Flag | Controls |
|-----------------|---------|
| `allow_encrypt` | Permission to run Encrypt jobs |
| `allow_decrypt` | Permission to run Decrypt jobs |
| `allow_tx` | TX_CLOC included in output |
| `allow_stable` | STABLE_CLOC included in output |
| `allow_geocontext` | Geo context fields included in output |
| *(future)* `allow_homebiz` | HomeBiz_Type included in output |

Output columns are **not hardcoded**. They are driven by `APP_CONFIG` rows, so new entitlements/fields can be added by DE without app code changes — only a config table update and a new app version release if schema changes.

### APP_CONFIG Table Design

```sql
APP_CONFIG (
    config_key        VARCHAR,   -- e.g. 'license_key', 'api_key', 'scheme_version'
    config_value      VARCHAR,   -- encrypted or plaintext depending on sensitivity
    last_refreshed_at TIMESTAMP,
    is_active         BOOLEAN
)

-- Entitlement/output column registry rows:
-- config_key = 'output_col.<name>'
-- config_value = JSON: { "operation": "encrypt|decrypt|both", "requires_entitlement": "allow_geocontext" }
```

This allows the stored procedure to dynamically build the SELECT list and gate columns by entitlement without changing code.

---

## Streamlit Views

The app has six views accessible from a left-side navigation bar. All views run entirely within the customer's Snowflake account — no data leaves their environment.

---

### View 1 — Home

**Purpose:** Status dashboard. The first thing a customer sees when they open the app.

**Layout:**

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
- **Setup banner** — shown only if onboarding wizard has not been completed; prompts the customer to finish setup before running jobs

---

### View 2 — Setup Wizard

**Purpose:** One-time post-install onboarding. Guides the customer from a fresh install to a fully connected and verified app in ~5 minutes.

See **[Customer Onboarding Workflow](#customer-onboarding-workflow)** for the full 8-screen flow (Welcome → License Key → Privileges → App Objects → EAI Test → Done). The wizard is re-accessible from the Configuration view if credentials need to be updated.

---

### View 3 — Run Encrypt

**Purpose:** Submit a batch Encrypt job — match customer IP + timestamp data against the LocID data lake and produce TX_CLOC / STABLE_CLOC output.

**Workflow (5 steps, shown as a top stepper):**

```
[1. Input]  [2. Map Columns]  [3. Output]  [4. Options]  [5. Review & Run]
```

**Step 1 — Select Input Table**
- Dropdown: all tables/views the app has been granted access to in the customer's account
- Preview: row count + first 5 rows shown inline after selection
- IP version hint: app auto-detects whether the table contains IPv4, IPv6, or mixed addresses (shown as info badge)

**Step 2 — Map Columns**
- The app reads the selected table's schema and presents a mapping widget:

  | Required Field | Map to Column |
  |---------------|---------------|
  | Unique Row ID | `[dropdown]` |
  | IP Address    | `[dropdown]` |
  | Timestamp     | `[dropdown]` |

- Column dropdowns are pre-filled with best-guess matches (e.g. a column named `ip` auto-selects for IP Address)
- Timestamp format selector: epoch seconds, epoch milliseconds, or TIMESTAMP string

**Step 3 — Configure Output**
- Radio: *Create new table* or *Overwrite existing table*
- Text input: output table name (e.g. `MY_DB.MY_SCHEMA.LOCID_RESULTS`)
- If overwrite: confirmation prompt

**Step 4 — Select Output Columns**
- Checkboxes for each available output field, gated by entitlement:

  | Column | Entitlement Required | Default |
  |--------|---------------------|---------|
  | TX_CLOC | `allow_tx` | ✓ |
  | STABLE_CLOC | `allow_stable` | ✓ |
  | Country / Country Code | `allow_geocontext` | ✓ |
  | Region / Region Code | `allow_geocontext` | ✓ |
  | City / City Code | `allow_geocontext` | ✓ |
  | Postal Code | `allow_geocontext` | ✓ |
  | HomeBiz_Type | *(future entitlement)* | — |

- Columns the customer is not entitled to are shown greyed out with a tooltip explaining why

**Step 5 — Review & Run**
- Summary card: input table, row count, output table, selected columns, warehouse
- Warehouse selector: dropdown of warehouses the customer has access to
- **Run Job** button

**During execution:**
- Live progress bar with status messages (e.g. "Matching IPv4 records…", "Calling LocID UDF…", "Writing output…")
- Cancel button available during run

**On completion:**
- Result summary: rows in, rows matched, rows written, unmatched count, runtime
- Link: "View output table" (opens Snowflake worksheet) and "View in Job History"

---

### View 4 — Run Decrypt

**Purpose:** Submit a batch Decrypt job — decode TX_CLOC values back to STABLE_CLOC and optional geo context.

**Workflow (same 5-step stepper as Encrypt):**

**Step 1 — Select Input Table**
- Same table selector as Encrypt
- Preview with row count + first 5 rows

**Step 2 — Map Columns**

  | Required Field | Map to Column |
  |---------------|---------------|
  | Unique Row ID | `[dropdown]` |
  | TX_CLOC       | `[dropdown]` |

**Step 3 — Configure Output**
- Same as Encrypt: new table or overwrite

**Step 4 — Select Output Columns**

  | Column | Entitlement Required | Default |
  |--------|---------------------|---------|
  | STABLE_CLOC | `allow_stable` | ✓ |
  | Country / Country Code | `allow_geocontext` | ✓ |
  | Region / Region Code | `allow_geocontext` | ✓ |
  | City / City Code | `allow_geocontext` | ✓ |
  | Postal Code | `allow_geocontext` | ✓ |
  | HomeBiz_Type | *(future entitlement)* | — |

**Step 5 — Review & Run**
- Same summary + warehouse selector + Run Job button as Encrypt

**On completion:**
- Result summary: rows in, rows decoded, rows written, runtime
- Link to output table and Job History

---

### View 5 — Job History

**Purpose:** Full audit log of all Encrypt and Decrypt jobs run through the app.

**Layout:**

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
- Runtime breakdown (matching, UDF, write)
- Error message with guidance if status is FAIL
- Output column list used for the job

**Actions:**
- Filter by: Operation (Encrypt / Decrypt), Status (Success / Failed), Date range
- Re-run: button to pre-fill Run Encrypt / Run Decrypt with the same settings as a previous job
- Download: export job log as CSV

---

### View 6 — Configuration

**Purpose:** Manage license credentials, view current entitlements, and review the output column registry.

**Sections:**

**License & Credentials**
- License key: shown masked (`1569-****-****-****`), with "Update" button that re-triggers the Enter Key screen
- Client name and expiration date (read-only, from LocID Central)
- API key: shown masked, used for stats reporting only
- **Refresh from LocID Central** button — manually re-fetches secrets and entitlements; shows last refreshed timestamp

**Current Entitlements**
- Read-only badge list reflecting the live `access[]` record from LocID Central:

  ```
  ✓ allow_encrypt    ✓ allow_decrypt
  ✓ allow_tx         ✓ allow_stable
  ✓ allow_geocontext ✗ allow_homebiz (not provisioned)
  ```

**Output Column Registry**
- Table view of all rows in `APP_CONFIG` where `config_key = 'output_col.*'`:

  | Column Name | Operation | Requires Entitlement | Active |
  |------------|-----------|---------------------|--------|
  | TX_CLOC | Encrypt | allow_tx | ✓ |
  | STABLE_CLOC | Both | allow_stable | ✓ |
  | locid_country | Both | allow_geocontext | ✓ |
  | … | … | … | … |

- Read-only for customers; updated by DE via app version releases when new fields are added

**Advanced**
- "Re-run Setup Wizard" link — for re-registering credentials or troubleshooting EAI connectivity

---

## Performance Considerations

- **Clustering keys** on `LOCID_BUILDS`: `(build_dt)` — aligns with the date-range filter on `LOCID_BUILD_DATES`.
- **Clustering keys** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the equi-join.
- **Search Optimization Service (SOS)** candidate on IPv4 exploded table for equality predicate on `ip_address`.
- IPv6 temp tables: consider materializing as transient tables within the job transaction to avoid recompute.
- Warehouse sizing recommendation: M or L for large batch jobs given the multi-pass IPv6 matching.

---

## Security & Data Boundary

- All customer data remains in the customer's Snowflake account at all times.
- Digital Envoy's LocID data is shared as read-only objects; no customer rows are written to DE's account.
- License key stored as a Snowflake `SECRET`, referenced by EAI — not visible in query results or logs.
- Crypto keys (AES-128) fetched at runtime from LocID Central, passed as UDF parameters, never persisted in tables.
- Masking policy on `APP_CONFIG.config_value` for sensitive rows.

---

## Usage Telemetry

After each job run, the stored procedure calls LocID Central stats endpoint:

```json
POST /api/0/location_id/stats
Header: de-access-token: <api_key from entitlements>

[{
  "identifier": "<license_key>",
  "source":     "snowflake-native-app",
  "timestamp":  <epoch_ms>,
  "data_type":  "usage_metrics",
  "data": {
    "metric_key": "encrypt_usage",
    "dimensions": { "api_key": "<api_key>", "hit": 1, "tier": 0 },
    "metric_value": <rows_processed>,
    "metric_datatype": "Long"
  }
}]
```

Job metadata (rows_in, rows_out, runtime_s, success flag) is also written to `APP_SCHEMA.JOB_LOG` for the customer's own visibility.

---

## Open Items / Pending from DE

| Item | Status |
|------|--------|
| IPv6 matching SQL | Available — full 6-pass prefix range join logic is in `Coco/tmp/20260331/example_sql_for_snowflake_locid_matching.sql`. Confirm with Ryan this POC SQL represents the final approach before productionizing. |
| HomeBiz_Type entitlement details | Pending product iteration (Ash/David) |
| Additional FC50 columns / new entitlements | Pending DE R&D spike outcome |
| Telemetry payload examples from existing real-time services | David to provide |
| Reference Docker container for encrypt/decrypt validation | David to investigate |
| V6 data confirmation in sandbox account | David to chase down |
