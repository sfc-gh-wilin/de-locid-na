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

| View | Purpose |
|------|---------|
| **Home** | App status, license info, last job summary |
| **Setup Wizard** | Post-install onboarding (see above) |
| **Run Encrypt** | Select input table, map columns (id, ip, timestamp), select output table, run |
| **Run Decrypt** | Select input table, map columns (id, tx_cloc), select output table, run |
| **Job History** | Table of past runs: job_id, operation, rows_in, rows_out, runtime, status |
| **Configuration** | View/update license key, refresh entitlements, view output column registry |

**Column Mapping UX (Run views):**  
Customer selects their input table from a dropdown. The app reads column names and presents a mapping widget so the customer can assign which column is `ip_address`, which is `timestamp`, etc. This handles arbitrary customer table schemas without hardcoding.

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
