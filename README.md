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
| **2 — Core Engine** | 4    | Python UDF | WHL registered, encrypt/decrypt/stable functions |
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
    ├── Home.py                   # Main Streamlit entry point (st.navigation)
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

### Snowflake Object Layout (Provider Side)

LocID maintains these tables in their Snowflake account, shared to the Native App:

```
LOCID.STAGING.LOCID_BUILDS                  -- IP ranges, encrypted_locid, geo context
LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED    -- Exploded IPv4 lookup (equi-join, one row per IP)
LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED    -- Exploded IPv6 /56 prefix lookup (equi-join, one row per /56 per range ≤ /48; 71.4B rows)
LOCID.STAGING.LOCID_BUILD_DATES             -- Weekly build date reference
```

Updated weekly via an Airflow DAG on LocID's side. The Native App accesses these as shared objects — no customer data is written to the provider's account.

### Snowflake Object Layout (App Side — installed in customer account)

```
-- APP_SCHEMA (non-versioned): tables, stage, network rule, procedures, Streamlit
APP_SCHEMA.APP_CONFIG                       -- Masked credential hints, entitlements, output column registry; full secrets in GENERIC_STRING SECRET objects
APP_SCHEMA.JOB_LOG                          -- Job run history (job_id, operation, run_dt, rows_in, rows_matched, rows_out, runtime_s, status[STARTED|SUCCESS|FAILED], error_msg, input_table, output_table, warehouse, output_cols)
APP_SCHEMA.APP_LOGS                         -- Diagnostic log table (log_id UUID, level, source, logged_at, session_id, message, traceback)
APP_SCHEMA.APP_STAGE                        -- Internal stage: WHL, UDF SQL, proc SQL
APP_SCHEMA.LOCID_CENTRAL_RULE               -- Network rule (allowlist: central.locid.com:443)
APP_SCHEMA.LOCID_CENTRAL_EAI                -- External Access Integration (created at install time)
LOCID_CENTRAL_EAI_SPEC                      -- App specification (consumer must approve before EAI is usable; see Setup Wizard Screen E)
APP_SCHEMA.HTTP_PING()                      -- Python UDF to verify EAI connectivity during setup
APP_SCHEMA.LOCID_FETCH_LICENSE(VARCHAR)     -- Python stored procedure — fetches/caches license from LocID Central via EAI; called by Streamlit via session.call()
APP_SCHEMA.LOCID_SET_API_KEY(INTEGER, VARCHAR) -- Python stored procedure — writes selected API key to LOCID_API_KEY SECRET; stores api_key_hint in APP_CONFIG
APP_SCHEMA.register_single_callback(...)    -- Callback proc for input table references
APP_SCHEMA.LOCID_ENCRYPT(...)               -- Encrypt stored procedure (uses EAI for stats reporting)
APP_SCHEMA.LOCID_DECRYPT(...)               -- Decrypt stored procedure (uses EAI for stats reporting)
APP_SCHEMA.LOCID_PURGE_LOGS()              -- Purge JOB_LOG / APP_LOGS rows older than log_retention_days
APP_SCHEMA.LOCID_PURGE_OUTPUTS(INTEGER)   -- Drop output tables older than output_retention_days (default: 90)
APP_SCHEMA.LOCID_APP                        -- Streamlit application object

-- APP_CODE (versioned schema): Python vectorized UDFs — required by Snowflake for UDFs with WHL IMPORTS
-- All crypto-using UDFs declare EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI) and
-- SECRETS = ('alias' = APP_SCHEMA.LOCID_*_SECRET). Keys are read inside the handler via
-- _snowflake.get_generic_secret_string('alias') — never passed as SQL parameters.
APP_CODE.LOCID_BASE_ENCRYPT(LOC_ID)                                                     -- Encrypt raw base LocID (AES-GCM) → URL-safe base64; key from LOCID_BASE_SECRET
APP_CODE.LOCID_BASE_DECRYPT(ENCRYPTED_LOC_ID)                                           -- Decrypt base64 ciphertext → raw base LocID; key from LOCID_BASE_SECRET
APP_CODE.LOCID_TXCLOC_ENCRYPT(TX_CLOC_JSON)                                             -- JSON (flat geo fields) → TX_CLOC; key from LOCID_SCHEME_SECRET
APP_CODE.LOCID_TXCLOC_DECRYPT(TX_CLOC)                                                  -- Decode TX_CLOC → VARCHAR JSON: {base_loc_id, timestamp, enc_client_id, geo...}; key from LOCID_SCHEME_SECRET
APP_CODE.LOCID_STABLE_CLOC(ENCRYPTED_LOCID, NAMESPACE_GUID, CLIENT_ID, ENC_CLIENT_ID, TIER) -- Generate STABLE_CLOC from encrypted base LocID; key from LOCID_BASE_SECRET
APP_CODE.LOCID_STABLE_CLOC_FROM_PLAIN(BASE_LOC_ID, NAMESPACE_GUID, DEC_CLIENT_ID, ENC_CLIENT_ID, TIER)     -- Generate STABLE_CLOC from plain base LocID (decrypt path; no key — pure SHA-1/UUID5)
```

---

## Python Vectorized UDF Design

The `mb-locid-encoding` WHL (Python 3.11, pure Python) is bundled in the app stage. All six Python UDFs are registered under the `APP_CODE` versioned schema (`CREATE OR ALTER VERSIONED SCHEMA APP_CODE`) — Snowflake Native Apps require a versioned schema for any UDF that specifies `IMPORTS`. Each UDF uses `LANGUAGE PYTHON RUNTIME_VERSION = '3.11'` with a `@vectorized` handler and `IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')`.

> **Note — `sys.path` wheel-loading snippet is required:** Since `snow snowpark package upload` cannot be used for consumer app deployment, the `.whl` is staged via `IMPORTS = ('/lib/mb_locid_encoding-0.0.0-py3-none-any.whl')`. When Snowflake imports a `.whl` file this way, it places it on the filesystem but does **not** automatically unpack it onto `sys.path`. The snippet in each UDF handler manually adds the `.whl` to `sys.path` so that `from locid import ...` resolves correctly. This is the standard pattern for consuming `.whl` files delivered via `IMPORTS` in Snowflake Python UDFs. Performance impact is negligible (~10–50 μs one-time per worker process).

> **Status (2026-05-05):** All 6 UDFs migrated from Scala scalar to Python vectorized. Benchmark confirms 5.7× throughput improvement over Scala at 50M rows.

Key functions:

| UDF | Inputs | Output | Notes |
|-----|--------|--------|-------|
| `LOCID_BASE_ENCRYPT` | `loc_id` | `encrypted_locid` (VARCHAR) | AES-encrypts plain base LocID; key from LOCID_BASE_SECRET |
| `LOCID_BASE_DECRYPT` | `encrypted_loc_id` | `locid` (VARCHAR) | Decrypts stored base LocID; key from LOCID_BASE_SECRET |
| `LOCID_TXCLOC_ENCRYPT` | `tx_cloc_json` | `tx_cloc` (VARCHAR) | JSON → TX_CLOC; key from LOCID_SCHEME_SECRET |
| `LOCID_TXCLOC_DECRYPT` | `tx_cloc` | VARCHAR (JSON: {base_loc_id, timestamp, enc_client_id, geo...}) | Decodes TX_CLOC → base LocID + metadata + geo; key from LOCID_SCHEME_SECRET |
| `LOCID_STABLE_CLOC` | `encrypted_locid`, `namespace_guid`, `client_id`, `enc_client_id`, `tier` | `stable_cloc` (VARCHAR) | Produces stable UUID-format CLOC; key from LOCID_BASE_SECRET |
| `LOCID_STABLE_CLOC_FROM_PLAIN` | `base_loc_id`, `namespace_guid`, `dec_client_id`, `enc_client_id`, `tier` | `stable_cloc` (VARCHAR) | As above, accepts plain base LocID (decrypt path; no key — pure SHA-1/UUID5) |

Crypto keys are stored in Snowflake `GENERIC_STRING` SECRET objects (`LOCID_BASE_SECRET`, `LOCID_SCHEME_SECRET`) and read by UDFs via their `SECRETS` clause + `_snowflake.get_generic_secret_string()`. Keys are **never** passed as SQL parameters or exposed in query history.

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
- On app launch: check `cached_license.last_refreshed_at` in `APP_CONFIG`. If older than 24 hours (or not set), auto-refresh from LocID Central.
- On job run: use cached values. If cache is missing → abort (secrets required).
- If auto-refresh fails: cached values remain usable, error is logged.
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
| **H. Select API Key** | API key picker | List ACTIVE keys from `access[]` using `api_key_hint` (first 8 chars); user selects which to use; calls `APP_SCHEMA.LOCID_SET_API_KEY` to write full key to `LOCID_API_KEY` SECRET and `namespace_guid` to `LOCID_NAMESPACE_GUID` SECRET; `api_key_id`, `client_id` stored in APP_CONFIG |
| **I. Success** | Done | Summary checklist, link to docs, "Launch App" |

---

## Customer Data Workflow

### Encrypt (IP → LocID)

```
Customer Input Table (via reference binding)
  (unique_id, ip_address, timestamp)
         │
         ▼
  LOCID_ENCRYPT(ID_COL, IP_COL, TS_COL, TS_FORMAT, OUTPUT_COLS, ID_TO_VARCHAR)
         │
         ├─ 0. INSERT STARTED row into JOB_LOG (visible immediately in Job History)
         │
         ├─ 1. Entitlement check — verify allow_encrypt + requested output columns
         │
          ├─ 2. Fetch license context from APP_CONFIG (client_id); namespace_guid from SECRET
          │       Crypto secrets are bound directly to UDFs via SECRETS clauses —
          │       never read into proc variables or embedded in SQL.
         │
         ├─ 3. IP Matching (see matching strategy below)
         │       → unique_id, encrypted_locid, tier, geo_context, build_dt
         │
         ├─ 4. Call UDFs per matched row:
         │       LOCID_TXCLOC_ENCRYPT → TX_CLOC
         │         (geo context fields from the IP match — country, region, city,
         │          postal_code, country_code, region_code, city_code — are included
         │          in the TX_CLOC JSON payload so they are recoverable at decrypt time)
         │       LOCID_STABLE_CLOC → STABLE_CLOC
         │
         ├─ 5. Apply entitlement filter on output columns
         │
         ├─ 6. CREATE TABLE APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX
         │      (auto-generated: UTC timestamp + 12-char job ID; SELECT granted to APP_ADMIN/APP_VIEWER)
         │
         ├─ 8. UPDATE JOB_LOG (STARTED→SUCCESS) + opportunistic LOCID_PURGE_LOGS
         │
         └─ 9. POST usage stats to LocID Central (via EAI)
              If stats POST fails → JOB_LOG updated to FAILED (data still in output table)
```

**On failure:** APP_LOGS receives an ERROR entry. JOB_LOG is updated to FAILED with the error message. Usage stats are posted to LocID Central with partial data (whatever rows were counted/matched before the failure).  
**On user cancel:** The STARTED row remains — visible in Job History as an incomplete job.

### Decrypt (TX_CLOC → STABLE_CLOC)

```
Customer Input Table (via reference binding)
  (unique_id, tx_cloc)
         │
         ▼
  LOCID_DECRYPT(ID_COL, TXCLOC_COL, OUTPUT_COLS)
         │
         ├─ 0. INSERT STARTED row into JOB_LOG (visible immediately in Job History)
         │
         ├─ 1. Entitlement check — verify allow_decrypt + requested output columns
         │
          ├─ 2. Fetch license context from APP_CONFIG (client_id); namespace_guid from SECRET
          │       Crypto secrets are bound directly to UDFs via SECRETS clauses.
         │
         ├─ 3. Call UDFs per row:
         │       LOCID_TXCLOC_DECRYPT → base_loc_id + metadata + geo context (JSON)
         │         (geo fields are recovered from the TX_CLOC payload if they were
         │          included at encrypt time; extracted via PARSE_JSON)
         │       LOCID_STABLE_CLOC_FROM_PLAIN → STABLE_CLOC
         │
         ├─ 4. Apply entitlement filter on output columns
         │
         ├─ 5. CREATE TABLE APP_SCHEMA.LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX
         │      (auto-generated: UTC timestamp + 12-char job ID; SELECT granted to APP_ADMIN/APP_VIEWER)
         │
         ├─ 7. UPDATE JOB_LOG (STARTED→SUCCESS) + opportunistic LOCID_PURGE_LOGS
         │
         └─ 8. POST usage stats to LocID Central (via EAI)
              If stats POST fails → JOB_LOG updated to FAILED (data still in output table)
```

**On failure:** APP_LOGS receives an ERROR entry. JOB_LOG is updated to FAILED with the error message. Usage stats are posted to LocID Central with partial data (whatever rows were counted/matched before the failure).  
**On user cancel:** The STARTED row remains — visible in Job History as an incomplete job.

### IP Matching Strategy

**IPv4** — Exploded equi-join (most performant):
```
customer_input.ip_address = locid_builds_ipv4_exploded.ip_address
joined back to locid_builds on (build_dt, start_ip, end_ip)
```

**IPv6** — 2-stage equi-join via `LOCID_BUILDS_IPV6_EXPLODED` + BETWEEN fallback:
```
Stage 1 (~99%+ of inputs):
  equi-join on SUBSTR(ip_hex, 1, 14) = PREFIX_56    → hash join, ~30 candidates per IP
  BETWEEN filter on start/end_ip_int_hex             → exact range match
  join back to LOCID_BUILDS on (build_dt, start_ip, end_ip)  → retrieve geo context
  QUALIFY ROW_NUMBER() OVER (PARTITION BY _id ORDER BY build_dt DESC) = 1

Stage 2 (fallback for unmatched IDs — wide ranges > /48 only, ~31K source rows):
  LEFT JOIN anti-join on Stage 1 results (matched._id IS NULL)
  BETWEEN range join against LOCID_BUILDS wide ranges directly
  QUALIFY ROW_NUMBER() OVER (PARTITION BY _id ORDER BY build_dt DESC) = 1
```

Key performance characteristics:
- Stage 1 hash equi-join on `PREFIX_56` reduces candidates per input IP from ~269K → ~30
- `LOCID_BUILDS_IPV6_EXPLODED` clustered on `(PREFIX_56, BUILD_DT)` — micro-partition pruning on prefix + date
- Stage 2 scans only ~31K wide-range build rows — negligible overhead for the remaining inputs
- `PARSE_IP` / `ip_hex` computed once per input row (shared by both stages)

Both IPv4 and IPv6 results are combined into a single matched table before UDF execution.

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
--   (staleness tracked via cached_license.last_refreshed_at column, not a separate config key)
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

### View 2 — Run Encrypt

**Purpose:** Submit a batch Encrypt job — match customer IP + timestamp data against the LocID data lake and produce TX_CLOC / STABLE_CLOC output.

**Workflow (4 steps, shown as a top stepper):**

**Step 1 — Select Input Table**
- Input table is bound via Native App reference binding (`ENCRYPT_INPUT_TABLE`)
- Preview: row count + first 5 rows shown after binding
- Warehouse sizing tip shown as info box

**Step 2 — Map Columns**
- The app reads the selected table's schema and presents a mapping widget:

  | Required Field | Map to Column |
  |---------------|---------------|
  | Unique Row ID | `[dropdown]` |
  | IP Address    | `[dropdown]` |
  | Timestamp     | `[dropdown]` |

- Column dropdowns are pre-filled with best-guess matches (e.g. a column named `ip` auto-selects for IP Address)
- Timestamp format selector: epoch seconds, epoch milliseconds, or TIMESTAMP string
- **"Run Format Validation"** and **"Run ID Unique Check"** buttons run advisory checks after columns are mapped. A sample size selector (1K–5M rows or full table; default 100K) controls the scope for all checks:

  | Check | Scope | Behaviour |
  |-------|-------|-----------|
  | IP format | Configurable sample (default 100K rows) | Shows IPv4 / IPv6 / Mixed counts; warns on unparseable or NULL values |
  | Timestamp range | Configurable sample (default 100K rows) | Warns if any values are older than the earliest LocID build date (dynamic from provider data) |
  | ID uniqueness | Configurable sample (default 100K rows) | Warns if duplicate ID values found — procedure deduplicates to one result per unique ID |

  All checks are advisory — warnings are shown but the job can always proceed.

**Step 3 — Select Output Columns**
- Checkboxes for each available output field, gated by entitlement:

  | Column | Entitlement Required | Default |
  |--------|---------------------|---------|
  | TX_CLOC | `allow_tx` | ✓ |
  | STABLE_CLOC | `allow_stable` | ✓ |
  | Country / Country Code | `allow_geo_context` | ✓ |
  | Region / Region Code | `allow_geo_context` | ✓ |
  | City / City Code | `allow_geo_context` | ✓ |
  | Postal Code | `allow_geo_context` | ✓ |

- Columns the customer is not entitled to are shown greyed out with a tooltip explaining why

**Step 4 — Review & Run**
- Summary card: input table, mapped columns, selected output columns
- **Warehouse confirmation:** Shows the active warehouse name (or a generic reminder to confirm the warehouse in the top-right corner of Snowsight)
- **How to abort a running job:** Expandable section with instructions (navigate away from app, or cancel via Monitoring → Query History in Snowsight)
- **Run Job** button

**During execution:**
- `st.status()` panel with start time (UTC) and running animation
- Elapsed time shown on completion/failure

**On completion:**
- Result summary: rows in, rows matched, rows written, unmatched count, runtime, elapsed time
- Output table name displayed (auto-generated in APP_SCHEMA)

**Table binding note:**
- If no table is bound, a "Can't find your table in the picker?" expander explains that Snowsight cannot browse the app's own database and provides the SQL workaround via `REGISTER_SINGLE_CALLBACK`

---

### View 3 — Run Decrypt

**Purpose:** Submit a batch Decrypt job — decode TX_CLOC values back to STABLE_CLOC.

**Workflow (same 4-step stepper as Encrypt):**

**Step 1 — Select Input Table**
- Input table is bound via Native App reference binding (`DECRYPT_INPUT_TABLE`)
- Preview with row count + first 5 rows

**Step 2 — Map Columns**

  | Required Field | Map to Column |
  |---------------|---------------|
  | Unique Row ID | `[dropdown]` |
  | TX_CLOC       | `[dropdown]` |

**Step 3 — Select Output Columns**

  | Column | Entitlement Required | Default |
  |--------|---------------------|---------|
  | STABLE_CLOC | `allow_stable` | ✓ |
  | Country / Country Code | `allow_geo_context` | ✓ (if included at encrypt time) |
  | Region / Region Code | `allow_geo_context` | ✓ (if included at encrypt time) |
  | City / City Code | `allow_geo_context` | ✓ (if included at encrypt time) |
  | Postal Code | `allow_geo_context` | ✓ (if included at encrypt time) |

> **Note:** Geo context columns are recovered from the TX_CLOC payload. They are only available if the TX_CLOC was produced by the LocID Encrypt procedure (which embeds geo fields from the IP match). TX_CLOCs produced without geo context will return NULL for these columns.

**Step 4 — Review & Run**
- Same layout as Encrypt: warehouse confirmation, abort instructions, Run Job button
- `st.status()` panel with start time (UTC) and elapsed time on completion

**On completion:**
- Result summary: rows in, rows decoded, rows written, runtime, elapsed time
- Output table name displayed (auto-generated in APP_SCHEMA)

---

### View 4 — Job History

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
│ job_0039 │ Encrypt   │ 2026-04-04   │ —      │ —      │ ⏳ STRT │
└──────────┴───────────┴──────────────┴────────┴────────┴────────┘
```

**Job statuses:**
- **SUCCESS** — Job completed normally
- **FAILED** — Job hit an error (error message shown in detail)
- **STARTED** — Job was started but never completed — likely cancelled by the user from Snowsight or terminated by a session timeout

**Expandable row detail (click any row):**
- Input table, output table, warehouse used
- Runtime breakdown (matching, UDF, write)
- Error message with guidance if status is FAIL
- Warning for STARTED jobs: "This job was started but never completed"
- Output column list used for the job

**Actions:**
- Filter by: Operation (Encrypt / Decrypt), Status (Success / Failed / Started), Date range
- Re-run: button to pre-fill Run Encrypt / Run Decrypt with the same settings as a previous job
- Download: export job log as CSV

---

### View 5 — SQL Guide

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

### View 6 — Configuration

**Purpose:** Manage license credentials, view current entitlements, and review the output column registry.

**Sections:**

**License & Credentials**
- License key: shown masked (`1569-****-****-****`), with "Update" button that re-triggers the Enter Key screen
- Client name and expiration date (read-only, from LocID Central)
- Last verified: timestamp of last successful LocID Central fetch (`cached_license.last_refreshed_at`)
- **Refresh from LocID Central** button — manually re-fetches secrets and entitlements; auto-refresh also runs on app launch if cache is >24h stale

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

### View 7 — Setup Wizard

**Purpose:** One-time post-install onboarding. Guides the customer from a fresh install to a fully connected and verified app in ~5 minutes.

See **[Customer Onboarding Workflow](#customer-onboarding-workflow)** for the full 8-screen flow (Welcome → License Key → Privileges → App Objects → Select API Key → Done). The wizard is re-accessible from the Configuration view if credentials need to be updated.

---

## Managing Output Tables

Each Encrypt and Decrypt job creates a new permanent table in `APP_SCHEMA`:

```
LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX
LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX
```

Where `YYYYMMDD_HHMMSS` is the UTC timestamp at job start and `JOBSFX` is the first 12 uppercase hex characters of the job UUID (e.g., `LOCID_ENCRYPT_OUTPUT_20260601_143022_A4D2C1F07E3B`).

Over time, frequent job runs can produce many output tables. The app provides a built-in purge procedure to help consumers manage this.

### Role Required

All output table management requires the **`APP_ADMIN`** application role:

```sql
GRANT APPLICATION ROLE <app_name>.APP_ADMIN TO ROLE <your_role>;
```

### Listing Output Tables

```sql
SHOW TABLES LIKE 'LOCID_%_OUTPUT_%' IN SCHEMA <app_name>.APP_SCHEMA;
```

### Automatic Purge by Retention

Call `LOCID_PURGE_OUTPUTS` to drop output tables older than a retention threshold:

```sql
-- Use the configured retention (default: 90 days, stored in APP_CONFIG key 'output_retention_days')
CALL <app_name>.APP_SCHEMA.LOCID_PURGE_OUTPUTS(NULL);

-- Or specify a custom retention (e.g., drop tables older than 30 days)
CALL <app_name>.APP_SCHEMA.LOCID_PURGE_OUTPUTS(30);
```

Returns a summary:

```json
{
  "tables_dropped": ["LOCID_ENCRYPT_OUTPUT_20260401_120000_A4D2C1F07E3B", ...],
  "count": 5,
  "retention_days": 30,
  "cutoff_date": "2026-04-08 13:37:00"
}
```

### Configuring Default Retention

The default retention period is stored in `APP_CONFIG`:

```sql
-- View current setting
SELECT config_value FROM <app_name>.APP_SCHEMA.APP_CONFIG
WHERE config_key = 'output_retention_days';

-- Update (e.g., keep output tables for 60 days)
UPDATE <app_name>.APP_SCHEMA.APP_CONFIG
SET config_value = '60'
WHERE config_key = 'output_retention_days';
```

---

## Performance Considerations

### Provider Table Requirements

The stored procedures depend on specific column types and clustering keys on the provider tables. If these are missing, jobs will either fail silently (IPv6 returns 0 matches) or run indefinitely (full table scans).

**Strategy:** At 58B+ and 253B+ rows, copying tables is impractical. Instead:
1. Secure Views in the app package cast `VARIANT→VARCHAR` inline at query time (zero storage cost)
2. Clustering keys are added to the source tables for micro-partition pruning

> **Setup script:** `db/locid/provider/01_optimize_tables.sql` adds clustering keys. The Secure Views in `04_share_to_pkg.sql` handle the `VARIANT→VARCHAR` cast inline.

### General Performance Notes

- **Clustering keys** on `LOCID_BUILDS`: `(build_dt, start_ip_int_hex)` — compound key enables micro-partition pruning on the date filter and the Stage 2 BETWEEN fallback for wide IPv6 ranges.
- **Clustering keys** on `LOCID_BUILDS_IPV4_EXPLODED`: `(ip_address, build_dt)` — supports the IPv4 equi-join.
- **Clustering keys** on `LOCID_BUILDS_IPV6_EXPLODED`: `(PREFIX_56, BUILD_DT)` — supports the Stage 1 IPv6 equi-join. Adding start/end hex columns is not beneficial: ~30 candidates per prefix is trivial in memory.
- **Search Optimization Service (SOS)** candidate on IPv4 exploded table for equality predicate on `ip_address`.
- **IPv6 exploded-table equi-join:** `LOCID_BUILDS_IPV6_EXPLODED` (71.4B rows) has one row per /56 prefix per build range ≤ /48. Stage 1 hash equi-join on `PREFIX_56` reduces candidates from ~269K → ~30 per input IP vs. the previous 6-pass range join approach.
- **IPv6 network blocks** (e.g., `2806:108E:E:D03A::`) are fully supported. `PARSE_IP` expands `::` notation; the resulting hex matches via Stage 1 equi-join, identical to full device addresses.
- **Invalid timestamps:** Rows with unparseable timestamps are gracefully skipped using `TRY_CAST`. For `epoch_sec`/`epoch_ms`, the column is cast to `BIGINT`. For `timestamp` format, a zero-row type probe at job start determines whether to use `TRY_CAST AS TIMESTAMP_NTZ` (VARCHAR column) or `DATE_PART(epoch_second, col)` directly (native TIMESTAMP column). Skipped rows appear in `rows_skipped_invalid_ts`.
- **ID column output:** The output table preserves the original ID column type by default. Set `ID_TO_VARCHAR=TRUE` to cast to VARCHAR — numeric IDs with decimal representation (e.g. `12345.0`) are stripped to integer string (`12345`) via `COALESCE(TRY_CAST AS NUMBER(38,0)::VARCHAR, TO_VARCHAR(id))`.
- **Session timeout:** Streamlit sleep timer is set to 30 minutes (`config.toml`). For jobs exceeding 30 min, users should run via SQL worksheet (see SQL Guide page) — SQL worksheets have no session timeout.
- Warehouse sizing recommendation: M or L Snowpark-optimized for large batch jobs.

---

## Python Vectorized UDFs (Implemented)

### Background

The current implementation uses Python vectorized UDFs backed by the `mb-locid-encoding` WHL. Each UDF uses `@vectorized` batch dispatch — Snowflake delivers batches of ~4,000 rows per call, reducing Python/SQL boundary crossings by ~1000×. Within each batch, cipher objects are cached at module scope and reused across all rows in the same worker process.

The previous implementation used Scala scalar UDFs backed by the `encode-lib` JAR. The migration to Python vectorized UDFs delivered a **5.7× throughput improvement** at 50M rows (benchmarked 2026-05-05). Additional benefits: no JVM cold-start latency, no JAR recompile on Snowflake runtime updates, standard `pytest` for local testing.

### Snowflake Python Vectorized UDFs

Snowflake supports **vectorized Python UDFs** (`LANGUAGE PYTHON` with `@vectorized`). Instead of receiving one scalar value per call, the function receives a `pandas.Series` containing a **batch of rows** (typically thousands at a time) and returns a `pandas.Series`. This eliminates per-row dispatch overhead and allows the encoding logic to operate on the full batch using efficient array operations.

```
Scalar UDF (previous):     Python vectorized UDF (current):
  call(row_1) → result         call(Series[row_1, row_2, ... row_N]) → Series[result_1, ... result_N]
  call(row_2) → result
  ...
  call(row_N) → result
  (N function calls)           (1 function call per batch)
```

Benchmark context (Snowflake engineering guidance): Python vectorized UDFs typically show **5–10× throughput improvement** over equivalent scalar Python UDFs for string transformation workloads. The improvement is most pronounced at larger warehouse sizes and larger batch sizes. Our measured result: **5.7× improvement** (Python vectorized WHL vs Scala scalar at 50M rows).

### Performance Results

Snowflake auto-tunes the vectorized batch size to approximately **1,000–8,192 rows per batch** per worker node. The throughput gain for this specific workload comes from two sources:

- **Fewer dispatch crossings** — the Python–SQL boundary is crossed `ceil(N / batch_size)` times instead of `N` times.
- **Amortised key setup** — Crypto keys are read from Snowflake SECRETs once per worker process and cached as a module-scope `_KEY_SERIES`. The cipher object is initialised once per worker (not once per row or per batch).

| Row count    | Measured/expected improvement vs. Scala scalar UDFs        |
|--------------|------------------------------------------------------------|
| < 1M         | Marginal — IP matching SQL dominates runtime               |
| 1M – 10M     | 3–5× UDF throughput improvement                            |
| 10M – 100M   | 5–10× UDF throughput improvement                           |
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

> **Note on JVM cold-start (historical):** The Scala path showed a 209s first-run penalty (JVM init + JAR load) before settling to ~113s steady-state. This concern is eliminated with the Python path — Python UDFs have no equivalent cold-start overhead.

### Warehouse Sizing Recommendations

For production Encrypt/Decrypt jobs:

- **< 1M rows** — Medium Snowpark-optimized warehouse
- **1M – 10M rows** — Medium or Large Snowpark-optimized warehouse
- **10M – 100M rows** — Large Snowpark-optimized warehouse
- **100M – 1B rows** — X-Large Snowpark-optimized warehouse
- **> 1B rows** — X-Large or larger; consider partitioning input into batches

> The IP matching phase (SQL joins against the LocID data lake) dominates runtime at all row
> counts. Snowpark-optimized warehouses improve both Python UDF execution and join parallelism.
> IPv6-dominant workloads run ~40% slower than IPv4-dominant due to multi-pass CIDR range
> comparison vs the IPv4 exploded equi-join.

#### Multi-Cluster Warehouses (Concurrent Jobs)

Multi-cluster warehouses (scale-out) add additional clusters to handle **concurrent** encrypt/decrypt jobs. They do **not** speed up a single job — for that, increase warehouse size (scale-up).

| Scenario | Recommendation |
|----------|---------------|
| Single user, one job at a time | Single-cluster (default) — multi-cluster adds no benefit |
| 2+ concurrent jobs (multiple users or scheduled + manual) | Set `MAX_CLUSTER_COUNT = 2–3` with `SCALING_POLICY = 'STANDARD'` |

**Recommended warehouse DDL:**

```sql
CREATE OR REPLACE WAREHOUSE LOCID_WH
    WAREHOUSE_SIZE = 'LARGE'
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 3
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE;
```

#### Compute Pools (Not Applicable)

Snowflake Compute Pools (SPCS) are for long-running container services and Streamlit container runtimes. They **cannot** accelerate the LocID encrypt/decrypt stored procedures, which execute as SQL queries on virtual warehouses. Compute Pools are not relevant for this workload.

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

### Benefits of Python over JAR

| Concern | JAR (previous) | Python (current) |
|---------|--------------|-----------------|
| JVM version compatibility | Must compile to match Snowflake's supported JVM target; caused one integration delay | No JVM dependency — runs on CPython 3.11 |
| Distribution | Bundle `.jar` in app stage; re-bundle on JAR changes | Stage `.py` file(s) alongside other app sources — same process already in place |
| Testing | Requires Snowflake sandbox to validate | Standard `pytest` on any developer machine |
| Customer inspection | Opaque binary | Python source — auditable if LocID prefers |

### ~~Request to LocID~~ (Completed)

> **Fulfilled:** LocID delivered `mb_locid_encoding-0.0.0-py3-none-any.whl`. Python vectorized UDFs are deployed and benchmarked at 5.7× improvement over the Scala scalar path. No further action needed.

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

**Post-install: Grant warehouse to the application:**

```sql
USE ROLE LOCID_APP_INSTALLER;
GRANT USAGE ON WAREHOUSE <customer_warehouse> TO APPLICATION LOCID_APP;
```

> **Why both grants?** The role grant allows the installer to call stored procedures. The application grant allows the Streamlit UI (which runs as the application object with owner's rights) to use the warehouse.

After installation, the app's `setup.sql` creates all internal objects (schemas, tables, UDFs, stored procedures) within the app container. One additional post-install step is required: the consumer must approve the `LOCID_CENTRAL_EAI_SPEC` app specification so the EAI can make outbound HTTPS calls. The Setup Wizard (Screen E) provides the exact SQL.

### Application Roles (APP_ADMIN / APP_VIEWER)

The app defines two **Application Roles** inside the installed app. These are *not* account-level roles — they are internal permission boundaries within the app that consumers grant to their own account roles.

**Automatic grant on install:** When you install the app via Snowsight, Snowflake automatically grants `APP_ADMIN` to the role that performed the installation (e.g., `LOCID_APP_INSTALLER`). No manual grant is needed.

**Privilege comparison:**

| Capability | APP_ADMIN | APP_VIEWER |
|-----------|-----------|------------|
| Open Streamlit app | ✓ | ✓ |
| View job history (`JOB_LOG`) | ✓ | ✓ |
| View app logs (`APP_LOGS`) | ✓ | ✓ |
| Read app configuration (`APP_CONFIG`) | ✓ | ✓ |
| Query output tables | ✓ | ✓ |
| Run Encrypt / Decrypt jobs | ✓ | — |
| Manage configuration (update `APP_CONFIG`) | ✓ | — |
| Purge logs / output tables | ✓ | — |
| Fetch license / set API key | ✓ | — |

**When to use APP_VIEWER:** Use `APP_VIEWER` when you want analysts or downstream consumers to read job results and history without being able to trigger new jobs (which consume API quota and warehouse credits).

```sql
-- Grant APP_VIEWER to a read-only analyst role
GRANT APPLICATION ROLE <app_name>.APP_VIEWER TO ROLE DATA_ANALYST;
```

`APP_VIEWER` is optional — if all users who access the app should be able to run jobs, `APP_ADMIN` (auto-granted to the installer role) is sufficient.

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

### Cross-Region & Cross-Cloud Distribution

When consumers need to install the app in a region or cloud different from the provider's account, Snowflake's **Cross-Cloud Auto-Fulfillment** handles replication automatically via a Secure Share Area (SSA).

| Scenario | Mechanism | Example |
|----------|-----------|---------|
| Same region | Direct install from application package | Provider: `aws_us_west_2` → Consumer: `aws_us_west_2` |
| Different region, same cloud | Auto-fulfillment via Listing | Provider: `aws_us_west_2` → Consumer: `aws_us_east_1` |
| Different cloud and region | Auto-fulfillment via Listing | Provider: `aws_us_west_2` → Consumer: `azure_eastus2` |

> **Key point:** Cross-region/cross-cloud distribution requires a **Listing** (private or marketplace). Direct `CREATE APPLICATION FROM APPLICATION PACKAGE` only works within the same region.

**Provider: Set up for cross-region distribution**

```sql
-- 1. Set distribution to EXTERNAL (triggers automated security scan)
USE ROLE LOCID_APP_ADMIN;
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    SET DISTRIBUTION = 'EXTERNAL';

-- 2. Enable auto-refresh on release directive changes (so consumers get updates automatically)
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    SET LISTING_AUTO_REFRESH = 'ON';
```

Then create a **Private Listing** in Snowsight:

1. Navigate to **Marketplace → Provider Studio → Create Listing**
2. Select **"Only specified consumers"** (private listing)
3. Attach the application package `LOCID_DEV_PKG`
4. Add the consumer's account identifier (e.g., `ORG_NAME.ACCOUNT_NAME`)
5. If the consumer is in a different region, Snowsight automatically detects this and enables auto-fulfillment
6. Configure refresh frequency (recommended: trigger-based or daily)
7. Publish the listing

**Consumer: Install from a different region/cloud**

1. Navigate to **Snowsight → Marketplace → Shared With Me** (or search if marketplace listing)
2. Click **Get** on the LocID listing
3. Follow normal installation flow — Snowflake handles replication transparently

**Costs & Considerations:**

- Cross-region auto-fulfillment incurs **data transfer** and **replication credits**
- Initial replication may take time depending on the size of shared databases (`LOCID_BUILDS`, etc.)
- Provider can monitor replication via `SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_REFRESH_DAILY`
- ORGADMIN must first delegate auto-fulfillment privileges: `SELECT SYSTEM$ENABLE_GLOBAL_DATA_SHARING_FOR_ACCOUNT('<provider_account>')`

**Cost Model (Provider pays):**

The **provider** bears all auto-fulfillment costs. Consumers pay nothing extra beyond their normal compute.

| Cost Component | Trigger | Scaling |
|----------------|---------|---------|
| Replication credits | Initial sync + each data refresh | Per distinct target region |
| Data transfer (egress) | Cross-region/cross-cloud bytes moved | Per distinct target region × data size |
| SSA storage | Data stored in each Secure Share Area | Per distinct target region |

> **Key:** Snowflake creates **one SSA per region**, not per consumer. 10 consumers in the same region share one SSA — cost does not increase with consumer count within a region. Cost scales with the **number of distinct consumer regions**.

**Cost control strategies:**

- Use **trigger-based refresh** (`SYSTEM$TRIGGER_LISTING_REFRESH`) instead of interval-based — only replicate when a new version/patch is released
- Limit listing availability to specific regions (marketplace listings allow region selection)
- For LocID's weekly build-table updates + app patches, recommend trigger-based refresh tied to the Airflow DAG completion

---

## Usage Telemetry

After each job run — whether it succeeds or fails — the stored procedure posts usage statistics to LocID Central. The telemetry contract is defined in the [Telemetry Catalog Addendum](Tmp/tmp/20260505/locid-central-telemetry-catalog-native-app-addendum.md).

**Stats POST failure** is not silent: if the POST to Central fails, the job's `JOB_LOG` status is updated to `FAILED` with a message that identifies the output table (so the consumer knows their data was processed). The failure is also written to `APP_LOGS` as `ERROR`.

**Failed jobs** also post stats: if the job itself throws an exception, `_post_stats` is called from the error handler using whatever partial counters were accumulated (rows counted, rows matched, partial phase timings). This gives Central visibility into both good and bad job outcomes.

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
| `batch-hits.encrypt` | Counter | api_key, client_id, tier, job_id | Rows matched at each tier. Emitted only when non-zero. |
| `batch-hits.decrypt` | Counter | api_key, client_id, tier, job_id | Rows matched at each tier. Emitted only when non-zero. |
| `batch-runtime.encrypt` | Timer | api_key, client_id, job_id, stage | Per-phase timing (match, udf, write, total). Always emitted (even with 0 counts). |
| `batch-runtime.decrypt` | Timer | api_key, client_id, job_id, stage | Per-phase timing (match, udf, write, total). Always emitted. |
| `batch-outcomes.encrypt` | Counter | api_key, client_id, outcome, job_id | Row classification: `matched` (always emitted), `unmatched` / `invalid` / `error` (emitted when non-zero). |
| `batch-outcomes.decrypt` | Counter | api_key, client_id, outcome, job_id | Row classification: same outcome values. |

#### `batch-outcomes` outcome values

| `outcome` | Meaning | When emitted |
|-----------|---------|--------------|
| `matched` | Row joined FC50 build successfully; a CLOC was produced | Always (even if 0) |
| `unmatched` | No FC50 hit — IP not in coverage, or timestamp outside any build window | When > 0 |
| `invalid` | Row rejected for bad input — IP failed format validation or timestamp unparseable | When > 0 |
| `error` | Row hit a UDF exception or SP-level failure; or all unprocessed rows on a failed job | When > 0 |

**Integrity invariant:** `matched + unmatched + invalid + error == JOB_LOG.rows_in`

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

One flush per job: on the **success path**, immediately after JOB_LOG is written to `SUCCESS`. On the **failure path**, immediately after JOB_LOG is written to `FAILED` — using whatever partial counters were accumulated before the exception.

Each Counter value represents that job's totals (delta semantics — not cumulative since process start).

### Integrity Invariants (success path)

- `matched + unmatched + invalid + error == JOB_LOG.rows_in`
- `sum(batch-hits.{op} across all tiers) == batch-outcomes.{op} where outcome='matched'`

Job metadata (rows_in, rows_out, runtime_s, status) is also written to `APP_SCHEMA.JOB_LOG` for the consumer's own visibility.

---

## Open Items / Pending from LocID

| Item | Status |
|------|--------|
| encode-lib JAR — switching to Scala UDF | ✓ Resolved 2026-04-15. JAR delivered: `encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar` (Scala 2.13 / Java 17). Approach changed from `LANGUAGE JAVA` + SnowflakeHandler wrapper to `LANGUAGE SCALA RUNTIME_VERSION = '2.13'` with inline handlers. Dev UDFs (`db/dev/provider/06_udfs.sql`) updated. **Superseded** by Python vectorized UDFs (2026-05-05) — see below. |
| AES key derivation (test vs. production) | ✓ Resolved 2026-04-15/16. Production derivation confirmed: `secret.replaceAll("~","=")` → `Base64.getUrlDecoder().decode()` → AES key bytes. Dev Scala UDFs (`db/dev/provider/06_udfs.sql`) retain this pattern for benchmark reference. Production UDFs now read keys from Snowflake SECRETs — no key derivation in SQL. |
| Secret-backed UDFs (crypto key leak fix) | ✓ Completed (2026-05-17). All 5 crypto-using UDFs in `na_app_pkg/src/udfs/locid_udf.sql` now use `SECRETS` + `EXTERNAL_ACCESS_INTEGRATIONS` — keys never appear in query history. Encrypt/Decrypt procs no longer embed keys in SQL. Performance validated: zero per-row overhead (secret read once per worker process, cached at module scope). |
| IPv6 matching SQL | ✓ Implemented (2026-04-20). Optimised 6-pass cascading hex-prefix range join implemented in `na_app_pkg/src/procs/encrypt.sql`. Key optimisations vs. reference POC: ip_hex pre-computed once (not 6×), LOCID_BUILDS scanned once (date-filtered pre-materialisation), prefix filter applied before range join, single accumulator anti-join per pass. |
| HomeBiz_Type entitlement details | De-scoped from v1 (2026-04-16). No solid spec yet. Retained as a future entitlement flag (`allow_homebiz`); will be scoped and implemented in a subsequent version. |
| Additional FC50 columns / new entitlements | Pending LocID R&D spike outcome |
| Telemetry payload examples from existing real-time services | ✓ Resolved (2026-05-06). Full telemetry contract confirmed — see [Telemetry Catalog Addendum](Tmp/tmp/20260505/locid-central-telemetry-catalog-native-app-addendum.md). 6 batch metric keys (hits, runtime, outcomes × encrypt/decrypt) with Counter and Timer datatypes. |
| Reference Docker container for encrypt/decrypt validation | David to investigate |
| V6 data confirmation in sandbox account | David to chase down |
| Multiple API keys per license key | ✓ Spec'd (2026-04-16). `access[]` array confirmed via live API: each entry has its own `api_key`, `api_key_id`, `namespace_guid`, `provider_id`, `status`, and per-key entitlements. `secrets` are license-level (shared). Architecture updated: APP_CONFIG now stores selected key fields; onboarding wizard (Screen H) presents ACTIVE API keys for selection; View 6 Configuration provides a key-switcher table. |
| Consumer/provider deployment role | ✓ Resolved. Custom roles defined — see [Role Setup for App Package & App Deployment](#role-setup-for-app-package--app-deployment). Provider: `LOCID_APP_ADMIN` with `CREATE APPLICATION PACKAGE`, `CREATE DATABASE`, `CREATE SHARE`, `CREATE LISTING`. Consumer: `LOCID_APP_INSTALLER` with `CREATE APPLICATION`, `CREATE DATABASE`. One-time grants require `ACCOUNTADMIN`; all routine operations use the custom role. |
| UAT test account strategy | Separate Snowflake accounts required for UAT to surface multi-account permission issues. Coordinate with Alyssa for throwaway account creation and Snowflake credits. William's sandbox available as fallback. |
| Key status / expiry handling | License keys in LocID Central have status and expiry date fields. Implement configurable handling — surface warnings when key is nearing expiry or inactive; optionally gate job execution if key is expired. |
| Step-by-step deployment guides | Provide guides for deploying the native app to multiple environments (dev, UAT, prod), including config changes required per environment. |
| Python package for vectorized UDFs | ✓ Completed (2026-05-05). LocID delivered `mb_locid_encoding-0.0.0-py3-none-any.whl`. All UDFs migrated to Python vectorized — benchmarked at 5.7× throughput vs Scala scalar at 50M rows. See [Roadmap: Python Package for Vectorized UDFs](#roadmap-python-package-for-vectorized-udfs). |
| SQL-only workflow for consumers | ✓ Implemented (2026-04-28). SQL Guide view (View 5) added to Streamlit app — step-by-step instructions for running `LOCID_ENCRYPT` / `LOCID_DECRYPT` via SQL with live app name. Jobs submitted via SQL are tracked in Job History identically to UI jobs. |
| Log retention for JOB_LOG / APP_LOGS | ✓ Implemented (2026-04-28). `LOCID_PURGE_LOGS()` stored procedure reads `log_retention_days` from APP_CONFIG (default 30 days) and deletes old rows. Called opportunistically at the start of each job and available on-demand via the Log Retention section in Configuration (View 6). |
| Decrypt `location_id` field bug | ✓ Fixed (2026-05-19). Decrypt STABLE_CLOC was referencing `_decoded:location_id` (non-existent) instead of `_decoded:base_loc_id`. All decrypted rows now produce correct STABLE_CLOC values. |
| Invalid timestamp handling | ✓ Fixed (2026-05-19). Encrypt now uses `TRY_TO_*` functions for timestamp parsing. Rows with invalid timestamps are skipped gracefully instead of failing the entire job. Result includes `rows_skipped_invalid_ts` count. |
| Failed job tracking in Job History | ✓ Fixed (2026-05-20). Job procedures now INSERT a STARTED row at the beginning, then UPDATE to SUCCESS/FAILED on completion. Jobs cancelled via Snowsight or terminated by session timeout remain as STARTED in Job History — all started jobs are now visible. |
| IPv6 performance — prefix semi-join | ✓ Optimised (2026-05-20). 3-tier prefix semi-join pre-filter: (1) 16-char prefix for narrow blocks, (2) 12-char prefix for medium-width blocks, (3) wide blocks unconditionally. Reduces working set from ~700M to <5M rows for most inputs. |
