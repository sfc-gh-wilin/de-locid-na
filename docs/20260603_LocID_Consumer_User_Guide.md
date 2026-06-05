# LocID for Snowflake — Consumer User Guide

**Date:** 2026-06-03  
**Version:** 1.0

---

## Overview

This guide covers everything a consumer needs to install, configure, and use the LocID Native App. The app is distributed via a private Snowflake Marketplace listing and installs directly into your Snowflake account — all processing happens within your own environment.

**What the app does:**

- **Encrypt** — matches IP addresses and timestamps in your input table against LocID's data lake, returning TX_CLOC identifiers and optional geo context (country, region, city, postal code)
- **Decrypt** — resolves TX_CLOC values back to STABLE_CLOC identifiers and geo context
- **SQL Guide** — documents how to call Encrypt and Decrypt from SQL

---

## Prerequisites

Before starting, confirm the following:

| # | Requirement |
|---|-------------|
| 1 | You have received a private listing invitation from LocID |
| 2 | You have `ACCOUNTADMIN` access on your Snowflake account |
| 3 | You have a valid LocID license key |
| 4 | A Snowpark-optimized warehouse is available (Medium or larger recommended) |

---

## Section 1 — Account & Role Setup

> Run these commands once per account as `ACCOUNTADMIN`.

### 1.1 Create a dedicated warehouse (recommended)

For best performance, use a Snowpark-optimized warehouse:

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE WAREHOUSE LOCID_WH
    WAREHOUSE_SIZE = 'LARGE'
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 3
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE;
```

**Sizing guide:**

| Row count | Recommended size |
|-----------|-----------------|
| < 1M rows | Medium Snowpark-optimized |
| 1M – 10M rows | Medium or Large Snowpark-optimized |
| 10M+ rows | Large+ Snowpark-optimized |

> If you already have a Snowpark-optimized warehouse, you can use it instead.

### 1.2 Create the installer role

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER;

-- Required privileges for Native App installation
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
GRANT CREATE DATABASE    ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;

-- Grant warehouse access to the role
GRANT USAGE ON WAREHOUSE LOCID_WH TO ROLE LOCID_APP_INSTALLER;

-- Assign to your user
GRANT ROLE LOCID_APP_INSTALLER TO USER <your_username>;

-- Optional: hierarchy compliance
GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
```

---

## Section 2 — Install the App

### 2.1 Install from the listing

1. Switch to the `LOCID_APP_INSTALLER` role (bottom-left role selector in Snowsight)
2. Navigate to **Apps**
3. Find **LocID for Snowflake** under "Recently Shared with You" or use search
4. Click **Get**
5. Expand **Options** → change the **Application name** to `LOCID_APP`
6. Click **Get** to install

> You must use the `LOCID_APP_INSTALLER` role when installing. This role owns the application and has the required `CREATE APPLICATION` privilege.

### 2.2 Approve network access

The app requires outbound access to the LocID Central API for license validation and usage reporting.

1. Navigate to **Apps → LOCID_APP**
2. Click **Settings** (gear icon) → **Configurations**
3. Next to *LocID Central API Access*, click **…** → **Approve**

### 2.3 Grant warehouse to the application

The Streamlit UI runs under the application's own context and needs explicit warehouse access:

```sql
USE ROLE LOCID_APP_INSTALLER;

GRANT USAGE ON WAREHOUSE LOCID_WH TO APPLICATION LOCID_APP;
```

> **Why two grants?**
> - `TO ROLE LOCID_APP_INSTALLER` — allows the role to call stored procedures and run SQL
> - `TO APPLICATION LOCID_APP` — allows the Streamlit UI (which runs as the application object) to use the warehouse

### 2.4 Verify installation

Navigate to **Apps** and confirm `LOCID_APP` appears.

> **Known issue — two `LOCID_APP` entries in the Apps list**
>
> Snowsight may display two rows named `LOCID_APP`. The second entry is the Streamlit app embedded inside the Native App — it is not a separate installation.
>
> | Entry | Installed from | Owner Role | Action |
> |-------|---------------|------------|--------|
> | **Correct** | `LOCID_PKG` | `LOCID_APP_INSTALLER` | Open and use this one |
> | Ignore | `LOCID_APP.APP_SCHEMA.LOCID_APP` | *(none)* | Do not open |
>
> Always use the entry whose **Owner Role** shows `LOCID_APP_INSTALLER`. This is a known Snowflake platform bug.

---

## Section 3 — Setup Wizard

Open the app: **Apps → LOCID_APP**

The Setup Wizard runs on first launch. Walk through each screen:

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **E — Approve Network Access** | If not already approved in Section 2.2 — approve the LocID Central API connection, then click **Approved — Continue** |
| **D — Enter License Key** | Enter your LocID license key and click **Fetch License** |
| **F — Review License** | Confirm license details and click **Continue** |
| **G — Create App Objects** | Click **Create App Objects** |
| **H — Select API Key** | Choose the active API key and click **Confirm** |
| **I — Setup Complete** | Done — the sidebar navigation is now active |

---

## Section 4 — Prepare Your Input Data

### 4.1 Input table requirements

Your input table must contain at minimum:

| Column | Type | Description |
|--------|------|-------------|
| ID column | Any | Unique row identifier |
| IP column | VARCHAR | IPv4 or IPv6 address string |
| Timestamp column | TIMESTAMP_NTZ, BIGINT (epoch_sec or epoch_ms), or FLOAT | Event timestamp |

### 4.2 Create a test input table

```sql
USE ROLE LOCID_APP_INSTALLER;

CREATE DATABASE IF NOT EXISTS LOCID_TEST;
CREATE SCHEMA IF NOT EXISTS LOCID_TEST.INPUT;

CREATE OR REPLACE TABLE LOCID_TEST.INPUT.SAMPLE_DATA (
    row_id   VARCHAR       NOT NULL,
    ip_addr  VARCHAR       NOT NULL,
    event_ts TIMESTAMP_NTZ NOT NULL
);
```

For a quick smoke test (10 rows):

```sql
INSERT INTO LOCID_TEST.INPUT.SAMPLE_DATA
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4())::VARCHAR AS row_id,
    '8.8.8.' || (SEQ4() % 10 + 1)::VARCHAR AS ip_addr,
    DATEADD('minute', SEQ4() * 10, '2025-06-01 08:00:00'::TIMESTAMP_NTZ) AS event_ts
FROM TABLE(GENERATOR(ROWCOUNT => 10));
```

> Use real traffic IPs for meaningful match results. Fabricated IPs may not exist in LocID's data lake.

### 4.3 Bind the input table

**Option A — Streamlit UI (recommended):**

Open the app → click the **Permissions** tab → find **Input Table for Encrypt** → click **Add** → bind to your table.

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

GRANT SELECT ON TABLE LOCID_TEST.INPUT.SAMPLE_DATA TO APPLICATION LOCID_APP;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'ENCRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_TEST.INPUT.SAMPLE_DATA', 'PERSISTENT', 'SELECT')
);
```

---

## Section 5 — Running Encrypt Jobs

### 5.1 Via the Streamlit UI

Open **Run Encrypt** from the sidebar and follow the 4-step wizard:

| Step | Action |
|------|--------|
| **1 — Input Table** | Confirm the bound input table |
| **2 — Map Columns** | Select your ID, IP, and Timestamp columns; choose timestamp format (`timestamp`, `epoch_sec`, or `epoch_ms`) |
| **3 — Output Columns** | Select which output columns to include (only entitled columns are shown) |
| **4 — Review & Run** | Confirm settings and click **Run Job** |

**Column mapping options:**

| Field | Description |
|-------|-------------|
| ID column | Your unique row identifier |
| IP column | IPv4 or IPv6 address column |
| Timestamp column | Event timestamp column |
| Timestamp format | `timestamp` for TIMESTAMP_NTZ; `epoch_sec` for Unix seconds; `epoch_ms` for Unix milliseconds |
| Convert ID to VARCHAR | When checked, casts the ID column to VARCHAR in output (integer-valued floats are cleaned, e.g. `12345.0` → `'12345'`; genuine decimals are preserved) |

**Input validation — the app will warn you if:**
- NULL IP values are present (will be skipped)
- Unparseable IP values are present (will be skipped)
- Timestamps older than 52 weeks are present
- NULL timestamps are present (will be skipped)
- Duplicate row IDs are detected

### 5.2 Check results

After the job completes, find the output table name in Job History or via SQL:

```sql
SHOW TABLES LIKE 'LOCID_ENCRYPT_OUTPUT_%' IN SCHEMA LOCID_APP.APP_SCHEMA;
```

Query the output:

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> LIMIT 10;
```

**Output columns (subject to entitlement):**

| Column | Description |
|--------|-------------|
| `tx_cloc` | TX_CLOC identifier — use as input to Decrypt |
| `stable_cloc` | STABLE_CLOC UUID — persistent cross-session identifier |
| `locid_country` | Country name |
| `locid_country_code` | ISO country code |
| `locid_region` | Region / state name |
| `locid_region_code` | Region code |
| `locid_city` | City name |
| `locid_city_code` | City code |
| `locid_postal_code` | Postal / ZIP code |

---

## Section 6 — Running Decrypt Jobs

### 6.1 Bind the decrypt input table

The Decrypt input table must contain a TX_CLOC column (typically the output of a prior Encrypt job).

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX>',
                     'PERSISTENT', 'SELECT')
);
```

### 6.2 Via the Streamlit UI

Open **Run Decrypt** from the sidebar:

1. Confirm the bound input table
2. Map your ID column and TX_CLOC column
3. Select output columns
4. Click **Run Job**

### 6.3 Check results

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> LIMIT 10;
```

### 6.4 Verify STABLE_CLOC consistency

If you ran both Encrypt and Decrypt on the same dataset, STABLE_CLOC should match between the two outputs:

```sql
SELECT
    e.row_id,
    e.stable_cloc AS from_encrypt,
    d.stable_cloc AS from_decrypt,
    IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS consistent
FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> e
JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> d
    ON e.row_id = d.row_id
WHERE e.stable_cloc IS NOT NULL;
-- All rows should show PASS
```

---

## Section 7 — Running Jobs via SQL

The **SQL Guide** page in the app documents how to call Encrypt and Decrypt directly from SQL — useful for pipelines or notebooks.

### Encrypt via SQL

```sql
-- All entitled columns, preserve original ID type:
CALL LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT(
    'MY_ID',           -- ID_COL
    'IP_ADDRESS',      -- IP_COL
    'EVENT_TS',        -- TS_COL
    'epoch_sec',       -- TS_FORMAT: epoch_sec | epoch_ms | timestamp
    ARRAY_CONSTRUCT()  -- OUTPUT_COLS: empty = all entitled
    -- ID_TO_VARCHAR defaults to FALSE
);

-- Cast ID to VARCHAR and select specific columns:
CALL LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT(
    'MY_ID', 'IP_ADDRESS', 'EVENT_TS', 'epoch_sec',
    ARRAY_CONSTRUCT('tx_cloc', 'locid_country', 'locid_country_code'),
    TRUE   -- ID_TO_VARCHAR
);
```

The procedure returns a VARIANT with: `job_id`, `status`, `output_table`, `rows_in`, `rows_matched`, `runtime_s`.

### Decrypt via SQL

```sql
-- All entitled columns:
CALL LOCID_APP.APP_SCHEMA.LOCID_DECRYPT(
    'MY_ID',           -- ID_COL
    'TX_CLOC',         -- TXCLOC_COL
    ARRAY_CONSTRUCT()  -- OUTPUT_COLS: empty = all entitled
);
```


---

## Section 8 — Job History

Open **Job History** from the sidebar to view all past Encrypt and Decrypt runs.

The table shows: job ID, operation, status, rows in, rows matched, rows out, runtime, output table name, and run timestamp.

**Filter options:** Operation, Status, date range.

**Via SQL:**

```sql
SELECT
    job_id,
    operation,
    run_dt,
    rows_in,
    rows_matched,
    rows_out,
    runtime_s,
    status,
    output_table
FROM LOCID_APP.APP_SCHEMA.JOB_LOG
ORDER BY run_dt DESC
LIMIT 20;
```

---

## Section 9 — Configuration

Open **Configuration** from the sidebar to review and manage app settings.

| Section | Contents |
|---------|----------|
| **License & Credentials** | Masked `license_id_ref` and `api_key_hint` |
| **Current Entitlements** | Badges for each entitled feature |
| **Output Column Registry** | Read-only table of all available output columns |
| **Log Retention** | Days to retain job log entries (default: 90) |
| **Log Level** | INFO (default) or DEBUG |
| **Advanced** | Re-run Setup Wizard option |

---

## Section 10 — Managing Output Tables

Each Encrypt and Decrypt job creates a new permanent table in `APP_SCHEMA`. Table names follow the pattern `LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX` — unique per job, including jobs started within the same second.

Over time these accumulate. To manage them:

```sql
-- List all output tables
SHOW TABLES LIKE 'LOCID_%_OUTPUT_%' IN SCHEMA LOCID_APP.APP_SCHEMA;

-- Purge tables older than 90 days (default retention)
CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(NULL);

-- Purge tables older than 30 days
CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(30);
```

---

## Section 11 — Upgrading the App

When LocID releases a new version, your app will be automatically upgraded. To check the current installed version:

```sql
DESCRIBE APPLICATION LOCID_APP;
-- Look for: version, patch, upgrade_state = COMPLETE
```

To manually trigger an upgrade:

```sql
ALTER APPLICATION LOCID_APP UPGRADE;
```

---

## Appendix A — Cleanup

To fully remove the app and test data from your account:

```sql
USE ROLE LOCID_APP_INSTALLER;

-- Drop the app
DROP APPLICATION IF EXISTS LOCID_APP CASCADE;

-- Drop test data
DROP DATABASE IF EXISTS LOCID_TEST;
```

```sql
USE ROLE ACCOUNTADMIN;

-- Drop the installer role (only if fully decommissioning)
DROP ROLE IF EXISTS LOCID_APP_INSTALLER;
```

---

## Appendix B — Troubleshooting

### "No warehouse found for the Streamlit object"

```sql
GRANT USAGE ON WAREHOUSE <your_warehouse> TO APPLICATION LOCID_APP;
```

Then re-open the app. See [Section 2.3](#23-grant-warehouse-to-the-application).

### "Exceeded maximum number of inbound queries allowed for this instance: 298"

This is a transient Streamlit-in-Snowflake throttling error caused by rapid page refreshes.

1. Close the browser tab completely
2. Wait 60 seconds for the query queue to drain
3. Re-open the app

No configuration changes are needed.

### "Schema 'LOCID_APP.LOCID_SHARE' does not exist or not authorized"

The provider's shared data lake is not accessible. This is a provider-side issue — contact LocID support.

### Invalid license key error during Setup Wizard

Verify the key is entered exactly as provided (no leading/trailing spaces). If the error persists, contact LocID support with your account identifier.

### Run Encrypt fails with permission error

Ensure the app has SELECT access on your input table:

```sql
GRANT SELECT ON TABLE <your_db>.<your_schema>.<your_table> TO APPLICATION LOCID_APP;
```

Then re-bind the table reference.

### `rows_matched = 0` on every job

- Confirm your IP column contains real routable IPs (not internal/private ranges)
- Confirm your timestamps fall within the past 52 weeks
- Verify the warehouse is Snowpark-optimized (standard warehouses are not supported)

---

## Known Issues

### KI-01 — Two `LOCID_APP` entries in Snowsight Apps list

Snowsight displays two rows named `LOCID_APP` on **Apps**. The second is the Streamlit app embedded inside the Native App — it is not a separate installation.

| Entry | Installed from | Owner Role | Action |
|-------|---------------|------------|--------|
| **Correct** | `LOCID_PKG` | `LOCID_APP_INSTALLER` | ✓ Use this one |
| Ignore | `LOCID_APP.APP_SCHEMA.LOCID_APP` | *(none)* | ✗ Do not open |

Always select the entry with Owner Role `LOCID_APP_INSTALLER`. This is a known Snowflake platform bug with no consumer-side workaround.
