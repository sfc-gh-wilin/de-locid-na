# LocID Snowflake Native App — Architecture

**Provider:** LocID  
**Purpose:** Batch LocID enrichment for Snowflake customers — appends TX_CLOC and STABLE_CLOC identifiers to customer IP + timestamp data, entirely within the customer's Snowflake account.

---

## What This App Does

Customers who use LocID today call cloud or on-premise APIs to enrich their data with location identifiers. This Native App extends that capability into Snowflake as a batch workflow:

1. Customer provides a table with `(unique_id, ip_address, timestamp)` rows.
2. The app matches each IP + timestamp against LocID's weekly LocID data lake.
3. For each matched row, Python vectorized UDFs generate encrypted identifiers (TX_CLOC, STABLE_CLOC) and optional geo context.
4. Results are written to a customer-specified output table — all within the customer's account.
5. Usage statistics are reported back to LocID Central over HTTPS.

Two operations are supported:

| Operation | Input | Output |
|-----------|-------|--------|
| **Encrypt** | `unique_id`, `ip_address`, `timestamp` | `TX_CLOC`, `STABLE_CLOC`, geo context |
| **Decrypt** | `unique_id`, `tx_cloc` | `STABLE_CLOC`, geo context |

---

## Works Needed

| # | Work Item | Notes |
|---|-----------|-------|
| 1 | Native App package scaffolding | `manifest.yml`, `setup.sql`, directory structure |
| 2 | External Access Integration (EAI) | Outbound HTTPS to `central.locid.com` |
| 3 | Python vectorized UDF | Wrap `mb-locid-encoding` WHL; functions: encrypt, decrypt, stable CLOC |
| 4 | Config table design | Dynamic entitlements and output column registry |
| 5 | LocID Central integration | Fetch license/secrets/entitlements, cache, report stats |
| 6 | Encrypt stored procedure | IP matching (IPv4 + IPv6) + UDF call → output table |
| 7 | Decrypt stored procedure | TX_CLOC decode → STABLE_CLOC + context → output table |
| 8 | Streamlit onboarding wizard | 9-screen setup flow (see below) |
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
| **2 — Core Engine** | 4    | Python UDF | WHL registered, encrypt/decrypt/stable functions |
| | 5    | APP_CONFIG table + entitlement logic | Dynamic output column registry |
| | 6    | LocID Central integration | Fetch/cache secrets, report stats |
| | 7    | Usage telemetry | POST stats to LocID Central post-job |
| **3 — Processing** | 8    | Encrypt stored procedure | IPv4 + IPv6 matching + UDF → output table |
| | 9    | Decrypt stored procedure | TX_CLOC decode → STABLE_CLOC + context |
| **4 — UI** | 10   | Streamlit onboarding wizard | 9-screen setup flow |
| | 11   | Streamlit main views | Home, Run, History, Config |
| **5 — Polish** | 12   | Performance tuning | Clustering keys, SOS evaluation |
| | 13   | End-to-end testing | Encrypt/decrypt round-trip, IPv4 + IPv6, entitlement gates |

---

## How to Design

### App Package Structure

```
na_app_pkg/
├── manifest.yml                  # App manifest (privileges, references, default_streamlit)
├── setup.sql                     # Setup script (schemas, objects, grants)
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
    ├── pages/
    │   ├── 01_Setup_Wizard.py
    │   ├── 02_Run_Encrypt.py
    │   ├── 03_Run_Decrypt.py
    │   ├── 04_Job_History.py
    │   └── 05_Configuration.py
    └── utils/
        ├── locid_central.py      # LocID Central client — delegates HTTP to LOCID_FETCH_LICENSE stored procedure (Streamlit cannot make direct HTTP calls in Native Apps)
        ├── entitlements.py       # Entitlement check helpers
        └── logger.py             # App logging utilities
```

### Snowflake Object Layout (Provider Side)

LocID maintains these tables in their Snowflake account, shared to the Native App:

```
LOCID.STAGING.LOCID_BUILDS                  -- IP ranges, encrypted_locid, geo context
LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED    -- Exploded IPv4 table (equi-join)
LOCID.STAGING.LOCID_BUILD_DATES             -- Weekly build date reference
```

Updated weekly via an Airflow DAG on LocID's side. The Native App accesses these as shared objects — no customer data is written to the provider's account.

### Snowflake Object Layout (App Side — installed in customer account)

```
-- APP_SCHEMA (non-versioned): tables, stage, network rule, procedures, Streamlit
APP_SCHEMA.APP_CONFIG                       -- License key, cached secrets, entitlements, output column registry
APP_SCHEMA.JOB_LOG                          -- Job run history (job_id, run_dt, rows_in, rows_out, runtime_s, status)
APP_SCHEMA.APP_LOGS                         -- Diagnostic log table (log_id UUID, level, message, created_at)
APP_SCHEMA.APP_STAGE                        -- Internal stage: WHL, UDF SQL, proc SQL
APP_SCHEMA.LOCID_CENTRAL_RULE               -- Network rule (allowlist: central.locid.com:443)
APP_SCHEMA.LOCID_CENTRAL_EAI                -- External Access Integration (created at install time)
LOCID_CENTRAL_EAI_SPEC                      -- App specification (consumer must approve before EAI is usable; see Setup Wizard Screen E)
APP_SCHEMA.HTTP_PING()                      -- Python UDF to verify EAI connectivity during setup
APP_SCHEMA.LOCID_FETCH_LICENSE(VARCHAR)     -- Python stored procedure — fetches/caches license from LocID Central via EAI; called by Streamlit via session.call()
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

---

## Python Vectorized UDF Design

The `mb-locid-encoding` WHL (Python 3.11, pure Python) is bundled in the app stage. All six Python UDFs are registered under the `APP_CODE` versioned schema (`CREATE OR ALTER VERSIONED SCHEMA APP_CODE`) — Snowflake Native Apps require a versioned schema for any UDF that specifies `IMPORTS`. Each UDF uses `LANGUAGE PYTHON RUNTIME_VERSION = '3.11'` with a `@vectorized` handler and `IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')`.

> **Note:** The WHL is staged via `snow app deploy` (same deployment path as the previous JAR). A sys.path hack in each UDF handler promotes the `.whl` file for Python import resolution. This has negligible performance impact (~10–50 μs one-time per worker process).

> **Status (2026-05-05):** All 6 UDFs migrated from Scala scalar to Python vectorized. Benchmark confirms 5.7× throughput improvement over Scala at 50M rows.

Key functions:

| UDF | Inputs | Output | Notes |
|-----|--------|--------|-------|
| `LOCID_BASE_ENCRYPT` | `locid`, `base_locid_key` | `encrypted_locid` | AES-encrypts plain base LocID for storage |
| `LOCID_BASE_DECRYPT` | `encrypted_locid`, `base_locid_key` | `locid` | Decrypts stored base LocID to plain form |
| `LOCID_TXCLOC_ENCRYPT` | `encrypted_locid`, `base_locid_key`, `scheme_key`, `timestamp`, `client_id` | `tx_cloc` | Decrypts base LocID, re-encrypts as TX_CLOC |
| `LOCID_TXCLOC_DECRYPT` | `tx_cloc`, `scheme_key` | `VARIANT` (locid, timestamp, enc_client_id) | Decodes TX_CLOC → base LocID + metadata |
| `LOCID_STABLE_CLOC` | `encrypted_locid`, `base_locid_key`, `namespace_guid`, `dec_client_id`, `enc_client_id`, `tier` | `stable_cloc` | Produces stable UUID-format CLOC from stored encrypted LocID |
| `LOCID_STABLE_CLOC_FROM_PLAIN` | `locid`, `base_locid_key`, `namespace_guid`, `dec_client_id`, `enc_client_id`, `tier` | `stable_cloc` | As above, accepts plain (unencrypted) base LocID |

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

In production, the key material comes from LocID Central:
- `base_locid_secret` → `secret.replaceAll("~","=")` → `Base64.getUrlDecoder().decode()` → `SecretKeySpec` for `BaseLocIdEncryption`
- `scheme_secret` → same decode → `SecretKeySpec` for `EncScheme0`

Confirmed per `developer-integration-guide.md` (2026-04-15). All UDF `toKey()` handlers in `06_udfs.sql` and `locid_udf.sql` use this production derivation.

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

**Key data model points:**
- `access[]` is an array — one entry per API key. Each carries its own `namespace_guid`, `provider_id`, and per-key entitlements. Only entries with `"status": "ACTIVE"` are valid for job execution.
- `secrets` are license-level — `base_locid_secret` and `scheme_secret` are shared across all API keys under the same license. These are Base64-URL encoded (with `~` as alternate padding).
- The customer selects which API key to use during onboarding. The selected `api_key_id`, `namespace_guid`, and `provider_id` are stored in `APP_CONFIG` and used for all STABLE_CLOC calculations and stats reporting.

**Usage stats endpoint:**

```
POST https://central.locid.com/api/0/location_id/stats
  Header: de-access-token: <selected_api_key>
  Body:   [{ identifier, source, timestamp, data_type, data: { metric_key, dimensions, metric_value } }]
```

**Caching and refresh strategy:**
- On app launch: check `license_last_verified_at` in `APP_CONFIG`. If older than 24 hours (or not set), re-fetch from LocID Central and update `APP_CONFIG`.
- On job run: use cached values. If cache is missing → abort (secrets required).
- If refresh fails: use cached values, log warning.
- Sensitive values are stored as Snowflake `GENERIC_STRING` SECRETs — not in APP_CONFIG rows. `APP_CONFIG` holds only masked hints (`license_id_ref` = first 4 chars + `-****`; `api_key_hint` = first 8 chars). The cached license payload (`cached_license`) is stripped of cryptographic secrets before storage.

---

## Customer Onboarding Workflow

Multi-screen Streamlit wizard, runs once post-install.

```
[Welcome]
    └── [Have a LocID license key?]
            ├── No  → [Contact LocID Sales] → END (no forward navigation)
            └── Yes → [Approve Network Access (EAI spec — ACCOUNTADMIN action)]
                        → [Enter License Key + Validate against LocID Central]
                            → [Create App Objects]
                                → [Test EAI Connectivity]
                                    → [Select API Key]
                                        → [Setup Complete]
```

### Screen Details

| Screen | Purpose | Key Actions |
|--------|---------|-------------|
| **A. Welcome** | Intro | "Get started" CTA |
| **B. Have a key?** | Gate | Yes/No radio |
| **C. Contact Sales** | Dead end (no key) | Show LocID contact info, close wizard |
| **E. Approve Network Access** | EAI spec approval (runs before D) | Shows `SHOW SPECIFICATIONS` + `ALTER APPLICATION APPROVE SPECIFICATION` SQL for ACCOUNTADMIN; also `GRANT USAGE ON INTEGRATION`; **must be completed before license validation** |
| **D. Enter License Key** | Validate license | Masked input; calls `APP_SCHEMA.LOCID_FETCH_LICENSE` stored procedure (requires EAI spec approved at Screen E); caches full license payload in `APP_CONFIG` |
| **F. Create App Objects** | Bootstrap check | Verifies APP_CONFIG, JOB_LOG, APP_LOGS, HTTP_PING UDF |
| **G. Test Connectivity** | Validate EAI | Calls `APP_SCHEMA.HTTP_PING()` — HEAD request to `central.locid.com` |
| **H. Select API Key** | API key picker | List ACTIVE keys from `access[]` using `api_key_hint` (first 8 chars); user selects which to use; calls `APP_SCHEMA.LOCID_SET_API_KEY` to write full key to `LOCID_API_KEY` SECRET and scrub raw values from cache; `api_key_id`, `namespace_guid`, `client_id` stored in APP_CONFIG |
| **I. Success** | Done | Summary checklist, link to docs, "Launch App" |

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
         │       Resolve selected API key from APP_CONFIG:
         │       namespace_guid, provider_id, client_id → used for STABLE_CLOC
         │
         ├─ 2. Call LOCID_UDF per row
         │       tx_cloc → decrypt → base LocID + embedded geo_context
          │       → STABLE_CLOC, geo fields
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

Key optimisations vs. reference POC (important for big-data performance):
- `PARSE_IP` / `ip_hex` computed once per row (not 6×)
- `LOCID_BUILDS` scanned once (not 6×), pre-filtered to relevant build dates
- Prefix filter applied **before** the range join on the builds side (not after)
- Single accumulator anti-join per pass (O(1)) vs. growing exclusion chain (O(passes))

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
| `allow_geo_context` | Geo context fields included in output |
| *(future — de-scoped from v1)* `allow_homebiz` | HomeBiz_Type included in output |

Output columns are **not hardcoded**. They are driven by `APP_CONFIG` rows, so new entitlements/fields can be added by LocID without app code changes — only a config table update and a new app version release if schema changes.

### APP_CONFIG Table Design

```sql
APP_CONFIG (
    config_key        VARCHAR,   -- see key rows below
    config_value      VARCHAR,   -- masked hints for sensitive values; full secrets in Snowflake SECRETs
    last_refreshed_at TIMESTAMP,
    is_active         BOOLEAN
)

-- System config rows (populated at onboarding and refreshed daily):
--   'license_id_ref'           → masked hint: first 4 chars + '-****'
--                                full key stored in APP_SCHEMA.LOCID_LICENSE_KEY (GENERIC_STRING SECRET)
--   'api_key_hint'             → first 8 chars of selected API key
--                                full key stored in APP_SCHEMA.LOCID_API_KEY (GENERIC_STRING SECRET)
--   'api_key_id'               → integer ID of selected API key  (access[].api_key_id)
--   'namespace_guid'           → namespace GUID of selected key  (access[].namespace_guid)
--   'provider_id'              → provider ID of selected key     (access[].provider_id)
--   'client_id'                → customer client ID              (license.client_id)
--   'scheme_version'           → crypto scheme version           (secrets.scheme_version)
--   'license_last_verified_at' → ISO timestamp of last successful LocID Central fetch
--   'cached_license'           → stripped license JSON (no secrets field; api_key replaced by api_key_hint)
--   'log_retention_days'       → number of days to retain JOB_LOG / APP_LOGS rows (default: 30)

-- Snowflake SECRET objects (written only by stored procs; not accessible via SELECT):
--   APP_SCHEMA.LOCID_LICENSE_KEY   — full LocID license key
--   APP_SCHEMA.LOCID_API_KEY       — selected API bearer token
--   APP_SCHEMA.LOCID_BASE_SECRET   — base_locid_secret AES key
--   APP_SCHEMA.LOCID_SCHEME_SECRET — scheme_secret AES key

-- Entitlement/output column registry rows:
-- config_key = 'output_col.<name>'
-- config_value = JSON: { "operation": "encrypt|decrypt|both", "requires_entitlement": "allow_geo_context" }
```

This allows the stored procedure to dynamically build the SELECT list and gate columns by entitlement without changing code.

---

## Streamlit Views

The app has seven views accessible from a left-side navigation bar. All views run entirely within the customer's Snowflake account — no data leaves their environment.

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

See **[Customer Onboarding Workflow](#customer-onboarding-workflow)** for the full 9-screen flow (Welcome → License Key → Privileges → App Objects → EAI Test → Select API Key → Done). The wizard is re-accessible from the Configuration view if credentials need to be updated.

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
- **"Run Input Validation"** button runs advisory checks after columns are mapped:

  | Check | Scope | Behaviour |
  |-------|-------|-----------|
  | IP format | Sample 1,000 rows | Badge shows IPv4 / IPv6 / Mixed; warns on unparseable or NULL values |
  | Timestamp range | Full table | Warns if any values are older than 52 weeks (will not match any build) |
  | NULL timestamps | Full table | Informational count — NULLs are skipped during matching |

  Validation is advisory — warnings are shown but the job can always proceed.

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
  | Country / Country Code | `allow_geo_context` | ✓ |
  | Region / Region Code | `allow_geo_context` | ✓ |
  | City / City Code | `allow_geo_context` | ✓ |
  | Postal Code | `allow_geo_context` | ✓ |
  | HomeBiz_Type | *(future — de-scoped from v1)* | — |

- Columns the customer is not entitled to are shown greyed out with a tooltip explaining why

**Step 5 — Review & Run**
- Summary card: input table, row count, output table, selected columns, warehouse
- Warehouse selector: dropdown of warehouses the customer has access to
- **Run Job** button

**During execution:**
- Live progress bar with status messages (e.g. "Matching IP records…", "Generating LocIDs…", "Writing output…")
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
  | Country / Country Code | `allow_geo_context` | ✓ |
  | Region / Region Code | `allow_geo_context` | ✓ |
  | City / City Code | `allow_geo_context` | ✓ |
  | Postal Code | `allow_geo_context` | ✓ |
  | HomeBiz_Type | *(future — de-scoped from v1)* | — |

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

### View 6 — SQL Guide

**Purpose:** Reference guide for consumers who want to run Encrypt and Decrypt jobs via SQL stored procedure calls instead of the Streamlit UI. All jobs submitted via SQL are tracked in Job History the same way as UI jobs.

**Sections:**

- **Role note** — shows `GRANT APPLICATION ROLE <app>.APP_ADMIN TO ROLE <your_role>` with the live app name pre-filled
- **Step 1** — `GRANT SELECT ON TABLE ... TO APPLICATION ...` for the input table
- **Step 2** — Reference binding via Snowsight UI tab (screenshots) and SQL tab (`CALL register_single_callback(...)`)
- **Step 3** — `CALL LOCID_ENCRYPT(...)` with expandable parameter reference
- **Step 4** — `CALL LOCID_DECRYPT(...)` with expandable parameter reference
- **Step 5** — Query `APP_SCHEMA.JOB_LOG` to monitor job status
- **Scheduling example** — Snowflake Task snippet for automated daily encrypt jobs

---

### View 7 — Configuration

**Purpose:** Manage license credentials, view current entitlements, and review the output column registry.

**Sections:**

**License & Credentials**
- License key: shown masked (`1569-****-****-****`), with "Update" button that re-triggers the Enter Key screen
- Client name and expiration date (read-only, from LocID Central)
- Last verified: timestamp of last successful LocID Central fetch (`license_last_verified_at`)
- **Refresh from LocID Central** button — manually re-fetches secrets and entitlements; daily auto-refresh also runs at app launch

**API Key Selection**
- Table of all `access[]` entries from the last LocID Central fetch, with columns: API Key (masked), API Key ID, Provider ID, Namespace GUID, Status, and a "Use this key" radio selector:

  | API Key | Key ID | Provider ID | Namespace GUID | Status | Use |
  |---------|--------|-------------|----------------|--------|-----|
  | `2c7c****` | 4 | 2844 | `fb71a5a0-…` | ACTIVE | ◉ |
  | `dbf4****` | 3 | 2844 | `044a471b-…` | INACTIVE | — |
  | … | … | … | … | … | — |

- Only ACTIVE entries are selectable. Changing the selected API key updates `APP_CONFIG` (`api_key`, `api_key_id`, `namespace_guid`, `provider_id`) and takes effect on the next job run.
- **Note:** each API key has its own `namespace_guid` — switching keys changes the STABLE_CLOC output for new jobs.

**Current Entitlements**
- Read-only badge list reflecting the live `access[]` record from LocID Central:

  ```
  ✓ allow_encrypt    ✓ allow_decrypt
  ✓ allow_tx         ✓ allow_stable
  ✓ allow_geo_context ✗ allow_homebiz (not provisioned)
  ```

**Output Column Registry**
- Table view of all rows in `APP_CONFIG` where `config_key = 'output_col.*'`:

  | Column Name | Operation | Requires Entitlement | Active |
  |------------|-----------|---------------------|--------|
  | TX_CLOC | Encrypt | allow_tx | ✓ |
  | STABLE_CLOC | Both | allow_stable | ✓ |
  | locid_country | Both | allow_geo_context | ✓ |
  | … | … | … | … |

- Read-only for customers; updated by LocID via app version releases when new fields are added

**Advanced**
- "Re-run Setup Wizard" link — for re-registering credentials or troubleshooting EAI connectivity

**Log Retention**
- Number input (1–365 days) for how long `JOB_LOG` and `APP_LOGS` rows are kept (default: 30 days)
- Saved to `APP_CONFIG` key `log_retention_days`; applied opportunistically at the start of each job via `LOCID_PURGE_LOGS()`
- **Purge Now** button — runs `CALL APP_SCHEMA.LOCID_PURGE_LOGS()` immediately and shows rows deleted

---

## Performance Considerations

- **Clustering keys** on `LOCID_BUILDS`: `(build_dt)` — aligns with the date-range filter on `LOCID_BUILD_DATES`.
- **Clustering keys** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the equi-join.
- **Search Optimization Service (SOS)** candidate on IPv4 exploded table for equality predicate on `ip_address`.
- IPv6 temp tables: consider materializing as transient tables within the job transaction to avoid recompute.
- Warehouse sizing recommendation: M or L for large batch jobs given the multi-pass IPv6 matching.

---

## Roadmap: Python Package for Vectorized UDFs

### Background

The current implementation uses Python vectorized UDFs backed by the `mb-locid-encoding` WHL. Each UDF uses `@vectorized` batch dispatch — Snowflake delivers batches of ~4,000 rows per call, reducing Python/SQL boundary crossings by ~1000×. Within each batch, cipher objects are cached at module scope and reused across all rows in the same worker process.

The previous implementation used Scala scalar UDFs backed by the `encode-lib` JAR. The migration to Python vectorized UDFs delivered a **5.7× throughput improvement** at 50M rows (benchmarked 2026-05-05). Additional benefits: no JVM cold-start latency, no JAR recompile on Snowflake runtime updates, standard `pytest` for local testing.

### Snowflake Python Vectorized UDFs

Snowflake supports **vectorized Python UDFs** (`LANGUAGE PYTHON` with `@vectorized`). Instead of receiving one scalar value per call, the function receives a `pandas.Series` containing a **batch of rows** (typically thousands at a time) and returns a `pandas.Series`. This eliminates per-row dispatch overhead and allows the encoding logic to operate on the full batch using efficient array operations.

```
Scalar UDF (current):      Python vectorized UDF (target):
  call(row_1) → result         call(Series[row_1, row_2, ... row_N]) → Series[result_1, ... result_N]
  call(row_2) → result
  ...
  call(row_N) → result
  (N function calls)           (1 function call per batch)
```

Benchmark context (Snowflake engineering guidance): Python vectorized UDFs typically show **5–10× throughput improvement** over equivalent scalar Python UDFs for string transformation workloads. The improvement is most pronounced at larger warehouse sizes and larger batch sizes. Our measured result: **5.7× improvement** (Python vectorized WHL vs Scala scalar at 50M rows).

### Performance Estimates

Snowflake auto-tunes the vectorized batch size to approximately **1,000–8,192 rows per batch** per worker node. The throughput gain for this specific workload comes from two sources:

- **Fewer dispatch crossings** — the Python–SQL boundary is crossed `ceil(N / batch_size)` times instead of `N` times.
- **Amortised key setup** — `scheme_key` and `base_locid_key` are constants per query. A vectorized handler initialises cipher objects once per batch (or once per worker via `_scheme_cache`) instead of once per row.

| Row count    | Expected improvement vs. current scalar Scala UDFs         |
|--------------|------------------------------------------------------------|
| < 1M         | Marginal — IP matching SQL dominates runtime               |
| 1M – 10M     | 3–5× UDF throughput improvement likely                     |
| 10M – 100M   | 5–10× UDF throughput improvement expected                  |
| > 100M       | 5–10× or more — key-setup amortisation most impactful      |

> These estimates apply to the **UDF execution phase** only. The IP matching phase (Steps 3–4 of the stored procedure) is pure Snowflake SQL, already fully parallelised, and is unaffected by the UDF language change.

**Benchmark results — Medium Snowpark-optimized WH, 50M rows, CTAS forced materialization (2026-05-05)**

| Approach | UDF | Avg Elapsed (s) | Throughput (krows/s) | Speedup vs A | Notes |
|----------|-----|:---------------:|:--------------------:|:------------:|-------|
| A — Scala scalar (JAR) | `LOCID_BASE_ENCRYPT` | ~145 | ~373 | 1.0× | AES-128 ECB via encode-lib; warm JVM |
| B — Python scalar proxy | `PROXY_SCALAR` | ~23 | ~2,152 | 6.3× | SHA-256 per row |
| C — Python vectorized proxy | `PROXY_VECTORIZED` | ~20 | ~2,480 | 7.2× | numpy BLAS polynomial hash; no Python loop |
| D — Python vectorized (WHL) | `PROXY_WHL` | ~25 | ~2,040 | 5.7× | `StableCloc.encode()` SHA-1 UUID5 via production WHL |

> **Interpretation:** D (production WHL) is **5.7× faster** than A (Scala scalar, warm JVM) at 50M rows. All Python approaches (B, C, D) cluster in the 20–26s range — the `@vectorized` batch dispatch effectively eliminates the Python/SQL boundary overhead.

> **Cold JVM:** Run 1 shows A at 209s (first call in session — JVM init + JAR load). Warm steady-state A averages ~113s. Both `LOCID_ENCRYPT` and `LOCID_DECRYPT` handle cold-start automatically via a single-row warmup call before the production query.

### Warehouse Sizing Recommendations

For production Encrypt/Decrypt jobs:

- **< 10M rows** — Small or Medium standard warehouse
- **10M – 100M rows** — Medium Snowpark-optimized warehouse recommended
- **100M – 1B rows** — Large or X-Large Snowpark-optimized warehouse
- **> 1B rows** — X-Large or larger; consider partitioning input into batches

> Snowpark-optimized warehouses allocate more memory per node for Python UDF execution,
> reducing spill-to-disk and improving throughput for the vectorized batch handlers.

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

No changes were required to the stored procedures (`encrypt.sql`, `decrypt.sql`) — they call the UDFs via SQL and are unaffected by the language change.

### Additional Benefits of Moving to Python

| Concern | JAR (current) | Python (target) |
|---------|--------------|-----------------|
| JVM version compatibility | Must compile to match Snowflake's supported JVM target; caused one integration delay | No JVM dependency — runs on CPython 3.11 |
| Distribution | Bundle `.jar` in app stage; re-bundle on JAR changes | Stage `.py` file(s) alongside other app sources — same process already in place |
| Testing | Requires Snowflake sandbox to validate | Standard `pytest` on any developer machine |
| Customer inspection | Opaque binary | Python source — auditable if LocID prefers |

### Request to LocID

1. **Provide Python source** implementing the five encoding operations listed above — plain `.py` file(s) are sufficient. A pip package or `.whl` is welcome but not required.
2. **Alternatively**, share the relevant Scala/Java encoding source (the crypto and encoding classes from `encode-lib`) and we will handle the Python port on our side.
3. **Version alignment**: The Python implementation should be kept in sync with `encode-lib` releases so encode/decode results remain byte-compatible across both paths.

### Status

This is a **v2 roadmap item** — the current JAR-based implementation is fully functional and in use. Added to Open Items for tracking.

> **Note:** If LocID shares Scala/Java source for us to port, the Python implementation must be validated to produce byte-identical output to `encode-lib` (same ciphertext, same TX_CLOC encoding, same STABLE_CLOC UUIDs). A cross-compatibility test — running both the Scala UDFs and the Python UDFs against the same input and asserting identical output — is required before the Python path can be used in production.

---

## Security & Data Boundary

- All customer data remains in the customer's Snowflake account at all times.
- LocID's data is shared as read-only objects; no customer rows are written to LocID's account.
- All sensitive credentials are stored as Snowflake `GENERIC_STRING` SECRET objects — never in plain `APP_CONFIG` rows or query results:
  - `APP_SCHEMA.LOCID_LICENSE_KEY` — full LocID license key
  - `APP_SCHEMA.LOCID_API_KEY` — selected API bearer token
  - `APP_SCHEMA.LOCID_BASE_SECRET` — `base_locid_secret` AES key
  - `APP_SCHEMA.LOCID_SCHEME_SECRET` — `scheme_secret` AES key
- `APP_CONFIG` stores only masked hints: `license_id_ref` (first 4 chars + `-****`) and `api_key_hint` (first 8 chars).
- All SECRET writes are routed through stored procedures (`EXECUTE AS OWNER`) — `GRANT WRITE ON SECRET TO APPLICATION ROLE` is not supported; OWNER context is required.
- The cached license payload (`cached_license`) is stripped before storage: the `secrets` field is removed and `api_key` values are replaced with `api_key_hint` entries.
- Masking policy on `APP_CONFIG.config_value` for sensitive rows.

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

`snow app deploy` syncs local files to the stage. `snow app version create` bundles the stage snapshot as a named version — required because `APP_CODE` is a versioned schema and Scala UDFs with JAR `IMPORTS` must live in a versioned schema. `snow app run --version` installs or upgrades the app using the named version (not dev-mode).

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

> **Pending from LocID:** The example above shows `encrypt_usage` only. LocID needs to confirm the complete telemetry contract before implementation:
> - All `metric_key` values they want reported (e.g. `encrypt_usage`, `decrypt_usage`, and any others)
> - The full `dimensions` schema for each metric key — field names, types, and semantics of `hit` and `tier`

Job metadata (rows_in, rows_out, runtime_s, success flag) is also written to `APP_SCHEMA.JOB_LOG` for the customer's own visibility.

---

## Open Items / Pending from LocID

| Item | Status |
|------|--------|
| encode-lib JAR — switching to Scala UDF | ✓ Resolved 2026-04-15. JAR delivered: `encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar` (Scala 2.13 / Java 17). Approach changed from `LANGUAGE JAVA` + SnowflakeHandler wrapper to `LANGUAGE SCALA RUNTIME_VERSION = '2.13'` with inline handlers. Dev UDFs (`db/dev/provider/06_udfs.sql`) and native app UDFs (`na_app_pkg/src/udfs/locid_udf.sql`) both updated. |
| AES key derivation (test vs. production) | ✓ Resolved 2026-04-15/16. Production derivation confirmed: `secret.replaceAll("~","=")` → `Base64.getUrlDecoder().decode()` → AES key bytes. All `toKey()` handlers in `06_udfs.sql` and `locid_udf.sql` updated to production mode. Cross-compatibility test: `08_cross_compat_test.sql`. |
| IPv6 matching SQL | ✓ Implemented (2026-04-20). Optimised 6-pass cascading hex-prefix range join implemented in `na_app_pkg/src/procs/encrypt.sql`. Key optimisations vs. reference POC: ip_hex pre-computed once (not 6×), LOCID_BUILDS scanned once (date-filtered pre-materialisation), prefix filter applied before range join, single accumulator anti-join per pass. |
| HomeBiz_Type entitlement details | De-scoped from v1 (2026-04-16). No solid spec yet. Retained as a future entitlement flag (`allow_homebiz`); will be scoped and implemented in a subsequent version. |
| Additional FC50 columns / new entitlements | Pending LocID R&D spike outcome |
| Telemetry payload examples from existing real-time services | David to provide |
| Reference Docker container for encrypt/decrypt validation | David to investigate |
| V6 data confirmation in sandbox account | David to chase down |
| Multiple API keys per license key | ✓ Spec'd (2026-04-16). `access[]` array confirmed via live API: each entry has its own `api_key`, `api_key_id`, `namespace_guid`, `provider_id`, `status`, and per-key entitlements. `secrets` are license-level (shared). Architecture updated: APP_CONFIG now stores selected key fields; onboarding wizard (Screen H) presents ACTIVE API keys for selection; View 7 Configuration provides a key-switcher table. |
| Consumer/provider deployment role | ✓ Resolved. Custom roles defined — see [Role Setup for App Package & App Deployment](#role-setup-for-app-package--app-deployment). Provider: `LOCID_APP_ADMIN` with `CREATE APPLICATION PACKAGE`, `CREATE DATABASE`, `CREATE SHARE`, `CREATE LISTING`. Consumer: `LOCID_APP_INSTALLER` with `CREATE APPLICATION`, `CREATE DATABASE`. One-time grants require `ACCOUNTADMIN`; all routine operations use the custom role. |
| UAT test account strategy | Separate Snowflake accounts required for UAT to surface multi-account permission issues. Coordinate with Alyssa for throwaway account creation and Snowflake credits. William's sandbox available as fallback. |
| Key status / expiry handling | License keys in LocID Central have status and expiry date fields. Implement configurable handling — surface warnings when key is nearing expiry or inactive; optionally gate job execution if key is expired. |
| Step-by-step deployment guides | Provide guides for deploying the native app to multiple environments (dev, UAT, prod), including config changes required per environment. |
| Python package for vectorized UDFs | **v2 roadmap item.** Request LocID to publish `locid-python` (pip-installable) implementing the five encoding operations in `encode-lib`. Enables `LANGUAGE PYTHON @vectorized` UDFs — 5–10× throughput improvement for large batches; also eliminates JVM version compatibility concerns. Distribution can be private (`.whl`, private PyPI, or Snowflake Anaconda channel). No stored procedure changes required. See [Roadmap: Python Package for Vectorized UDFs](#roadmap-python-package-for-vectorized-udfs). |
| SQL-only workflow for consumers | ✓ Implemented (2026-04-28). SQL Guide view (View 6) added to Streamlit app — step-by-step instructions for running `LOCID_ENCRYPT` / `LOCID_DECRYPT` via SQL with live app name. Jobs submitted via SQL are tracked in Job History identically to UI jobs. |
| Log retention for JOB_LOG / APP_LOGS | ✓ Implemented (2026-04-28). `LOCID_PURGE_LOGS()` stored procedure reads `log_retention_days` from APP_CONFIG (default 30 days) and deletes old rows. Called opportunistically at the start of each job and available on-demand via the Log Retention section in Configuration (View 7). |


