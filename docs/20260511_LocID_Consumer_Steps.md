# LocID Native App — Consumer Deployment Steps

**Date:** 2026-05-11  
**Version:** 1.0  
**Environment:** Cross-account (LocID Provider → Consumer install)

---

## Overview

This guide walks a consumer through installing, configuring, and testing the LocID Native App distributed from LocID's provider account via a private Snowflake Marketplace listing.

**Accounts:**

| Role | Account                     | Notes |
|------|-----------------------------|-------|
| Provider (LocID) | `JZAEQUY-QOC14949` | Owns `LOCID_PKG` |
| Consumer | `JZAEQUY-LOCID_CUST_ACCT_1` | Installs `LOCID_APP` |

> **For other consumers:** Replace the consumer account identifier with your own.

---

## Phase 0 — Provider: Publish Listing (one-time)

> These steps are performed by LocID on the **provider** account. Consumer can skip to Phase 1.

### 0.1 Ensure the app package is deployed and versioned

```bash
cd na_app_pkg
snow app deploy --connection locid
snow app version create v1_0 --force --skip-git-check --connection locid
```

### 0.2 Enable external distribution

```sql
USE ROLE LOCID_APP_ADMIN;

ALTER APPLICATION PACKAGE LOCID_PKG
    SET DISTRIBUTION = 'EXTERNAL';
```

### 0.3 Add version to the default release channel

```sql
ALTER APPLICATION PACKAGE LOCID_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    ADD VERSION v1_0;
```

### 0.4 Wait for security scan approval

```sql
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG;
-- Look for review_status = 'APPROVED' on v1_0
-- If 'PENDING' — wait (typically < 1 hour)
```

### 0.5 Set the default release directive

```sql
ALTER APPLICATION PACKAGE LOCID_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = 0;
```

> Replace `PATCH = 0` with the latest approved patch number from `SHOW VERSIONS`.

Verify:

```sql
SHOW RELEASE DIRECTIVES IN APPLICATION PACKAGE LOCID_PKG;
-- Expected: a row with name=DEFAULT, target_type=DEFAULT, release_status=DEPLOYED
```

### 0.6 Create a private listing

In Snowsight on the **provider** account:

1. Navigate to **Marketplace → Provider Studio**
2. Click **Create Listing**
3. Enter a name: `LocID for Snowflake`
4. Under "Who can discover the listing" → select **Only specified consumers**
5. Click **Add Data Product** → choose `LOCID_PKG`
6. Select `Free` for **Access**
7. In "Add consumer accounts" → add the consumer's org.account (e.g., `JZAEQUY.LOCID_CUST_ACCT_1`)
8. Add **Description**
8. Click **Publish**

### 0.7 Verify listing is visible

In Snowsight on the consumer account, navigate to **Catalog → Apps** and confirm "LocID for Snowflake" appears.

---

## Phase 1 — Consumer: Role Setup (one-time, ACCOUNTADMIN)

> All commands from here onward run on the **consumer** account.

### 1.1 Create the installer role

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER;

-- Required privileges for Native App installation
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
GRANT CREATE DATABASE    ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;

-- Warehouse for running jobs (Snowpark-optimized recommended)
GRANT USAGE ON WAREHOUSE <your_warehouse> TO ROLE LOCID_APP_INSTALLER;

-- Assign to your user
GRANT ROLE LOCID_APP_INSTALLER TO USER <your_username>;

-- Optional: hierarchy compliance
GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
```

### 1.2 Create a dedicated warehouse (recommended)

For best performance, use a **Snowpark-optimized** warehouse:

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

-- Grant usage to the installer role
GRANT USAGE ON WAREHOUSE LOCID_WH TO ROLE LOCID_APP_INSTALLER;
```

| Row Count | Recommended Size |
|-----------|-----------------|
| < 1M rows | Medium Snowpark-optimized |
| 1M–10M rows | Medium/Large Snowpark-optimized |
| 10M+ rows | Large+ Snowpark-optimized |

> **Note:** If you already have a Snowpark-optimized warehouse, you can use it instead — just grant usage to the `LOCID_APP_INSTALLER` role (see 1.1 above).

### 1.3 Verify the role

```sql
SHOW ROLES LIKE 'LOCID_APP_INSTALLER';
```

---

## Phase 2 — Consumer: Install the App

### 2.1 Install from listing

In Snowsight on the consumer account:

1. **Switch to the `LOCID_APP_INSTALLER` role** (bottom-left role selector in Snowsight)
2. Navigate to **Catalog → Apps**
3. Find **LocID for Snowflake** (under "Recently Shared with You" or use search)
4. Click **Get**
5. Expand **Options** at the bottom of the dialog → click the **Application name** field and change it to `LOCID_APP`
6. Click **Get** to install

> **Important:** You must use the `LOCID_APP_INSTALLER` role when installing. This role owns the application and has the required `CREATE APPLICATION` privilege.

### 2.2 Approve network access

After installation, grant the app permission to connect to LocID Central (`central.locid.com`) for license validation and usage reporting:

**Option A — Snowsight UI:**

1. Navigate to **Catalog → Apps**
2. Click the app name (**LocID for Snowflake** or **LOCID_APP**)
3. Click **Settings** (gear icon) → **Configurations**
4. Next to *LocID Central API Access*, click **…** → **Approve**

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

-- 1. Find the current sequence number:
SHOW SPECIFICATIONS IN APPLICATION LOCID_APP;

-- 2. Approve (replace N with SEQUENCE_NUMBER from above, usually 1):
ALTER APPLICATION LOCID_APP
    APPROVE SPECIFICATION LOCID_CENTRAL_EAI_SPEC SEQUENCE_NUMBER = N;

-- 3. Grant USAGE on the integration:
GRANT USAGE ON INTEGRATION LOCID_CENTRAL_EAI TO APPLICATION LOCID_APP;
```

### 2.3 Grant warehouse to the application

The Streamlit UI runs under the application's own context. Grant warehouse usage to the application so it can power the Streamlit interface:

```sql
USE ROLE LOCID_APP_INSTALLER;

-- If using the recommended warehouse from section 1.2:
GRANT USAGE ON WAREHOUSE LOCID_WH TO APPLICATION LOCID_APP;

-- Or if using an existing warehouse:
-- GRANT USAGE ON WAREHOUSE <your_warehouse> TO APPLICATION LOCID_APP;
```

> **Why both grants?**
> - `GRANT USAGE ON WAREHOUSE ... TO ROLE LOCID_APP_INSTALLER` — allows the role to call stored procedures (Encrypt/Decrypt) and run SQL against the app.
> - `GRANT USAGE ON WAREHOUSE ... TO APPLICATION LOCID_APP` — allows the Streamlit UI (which runs as the application object with owner's rights) to use the warehouse.

### 2.4 Verify installation

In Snowsight, navigate to **Catalog → Apps**. Confirm `LOCID_APP` appears with status **NEW**.

> **Known issue — two `LOCID_APP` entries visible in the Apps list**
>
> Snowsight currently displays the embedded Streamlit app (located inside the Native App at `LOCID_APP.APP_SCHEMA.LOCID_APP`) as a separate entry alongside the installed Native App.
>
> | Entry | Installed from | Owner Role | Action |
> |-------|---------------|------------|--------|
> | **Correct** | `LOCID_PKG` | `LOCID_APP_INSTALLER` | Use this one |
> | Ignore | `LOCID_APP.APP_SCHEMA.LOCID_APP` | *(none)* | Do not open |
>
> Always open the entry whose **Owner Role** column shows `LOCID_APP_INSTALLER`. This is a known Snowflake platform bug and will be resolved in a future Snowflake release.

---

## Phase 3 — Consumer: Setup Wizard

Open the app in Snowsight: **Catalog → Apps → LOCID_APP**

Walk through the Setup Wizard:

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **E — Approve Network Access** | If not already approved in Phase 2.2 — approve the connection to `central.locid.com` and click **Approved — Continue** |
| **C — Enter License Key** | Enter your LocID license key and click **Fetch License** |
| **D — Review License** | Confirm license details and click **Continue** |
| **F — Create App Objects** | Click **Create App Objects** |
| **H — Select API Key** | Choose the active API key and click **Confirm** |
| **I — Setup Complete** | Done — sidebar navigation is now active |

Verify `APP_CONFIG`:

```sql
SELECT config_key, config_value, last_refreshed_at
FROM LOCID_APP.APP_SCHEMA.APP_CONFIG
ORDER BY config_key;
```

Expected keys: `api_key`, `api_key_id`, `cached_license`, `client_id`, `license_id_ref`, `namespace_guid`, `onboarding_complete`.

---

## Phase 4 — Consumer: Prepare Test Data

### 4.1 Create a test input table

```sql
USE ROLE LOCID_APP_INSTALLER;

CREATE DATABASE IF NOT EXISTS LOCID_TEST;
CREATE SCHEMA IF NOT EXISTS LOCID_TEST.INPUT;

CREATE OR REPLACE TABLE LOCID_TEST.INPUT.SAMPLE_DATA (
    row_id      VARCHAR        NOT NULL,
    ip_addr     VARCHAR        NOT NULL,
    event_ts    TIMESTAMP_NTZ  NOT NULL
);
```

Populate with your own data, or use a simple smoke test:

```sql
-- Smoke test (10 rows — verifies job execution, may produce 0 matches)
INSERT INTO LOCID_TEST.INPUT.SAMPLE_DATA
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4())::VARCHAR AS row_id,
    '8.8.8.' || (SEQ4() % 10 + 1)::VARCHAR AS ip_addr,
    DATEADD('minute', SEQ4() * 10, '2025-06-01 08:00:00'::TIMESTAMP_NTZ) AS event_ts
FROM TABLE(GENERATOR(ROWCOUNT => 10));
```

> **Note:** Fabricated IPs (like `8.8.8.x`) may not exist in LocID's data lake. Use real traffic IPs for meaningful match results.

### 4.2 Bind the input table reference

**Option A — Streamlit UI (recommended):**

Open the app → click the **Permissions** tab → find **Input Table for Encrypt** → click **Add** (or the edit icon) → bind to `LOCID_TEST.INPUT.SAMPLE_DATA`.

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'ENCRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_TEST.INPUT.SAMPLE_DATA', 'PERSISTENT', 'SELECT')
);
```

---

## Phase 5 — Consumer: Test Encrypt

### 5.1 Run the Encrypt job

Open **Run Encrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| IP column | `IP_ADDR` |
| Timestamp column | `EVENT_TS` |
| Timestamp format | `timestamp` |

Select output columns (all entitled) and click **Run Job**.

### 5.2 Verify results

**Expected:**
- Job completes successfully (status = `SUCCESS` in Job History)
- Output table created: `LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX`

Inspect:

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> LIMIT 10;
```

### 5.3 Warehouse recommendation

| Row count | Recommended warehouse |
|-----------|----------------------|
| < 1M rows | Medium Snowpark-optimized |
| 1M – 10M rows | Medium or Large Snowpark-optimized |
| 10M+ rows | Large+ Snowpark-optimized |

> The IP matching phase dominates runtime. Snowpark-optimized warehouses improve both UDF execution and join parallelism.

---

## Phase 6 — Consumer: Test Decrypt

### 6.1 Bind the decrypt input table

Bind the Encrypt output table as input for Decrypt:

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX>',
                     'PERSISTENT', 'SELECT')
);
```

### 6.2 Run the Decrypt job

Open **Run Decrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| TX_CLOC column | `TX_CLOC` |

Click **Run Job**.

### 6.3 Verify STABLE_CLOC consistency

```sql
SELECT
    e.row_id,
    e.stable_cloc AS from_encrypt,
    d.stable_cloc AS from_decrypt,
    IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS consistent
FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> e
JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> d ON e.row_id = d.row_id
WHERE e.stable_cloc IS NOT NULL
LIMIT 20;
-- All rows should show PASS
```

---

## Phase 7 — Consumer: Verify Job History

```sql
SELECT *
FROM LOCID_APP.APP_SCHEMA.JOB_LOG
ORDER BY run_at DESC;
-- Expected: 2 rows (1 Encrypt + 1 Decrypt), both status = SUCCESS
```

---

## Appendix A — Cleanup (Consumer)

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

## Appendix B — Version & Patch Updates

### Provider: Deploy a new patch

```bash
cd na_app_pkg
snow app deploy --connection locid
snow app version create v1_0 --force --skip-git-check --connection locid
```

### Provider: Push update to consumers

```sql
USE ROLE LOCID_APP_ADMIN;

ALTER APPLICATION PACKAGE LOCID_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = <new_patch_number>;
```

> Snowflake queues all installed consumer apps for automatic upgrade. This typically completes within minutes.

### Consumer: Check installed version

In Snowsight, navigate to **Catalog → Apps → LOCID_APP** — the version and patch are shown in the app details.

Or via SQL:

```sql
DESCRIBE APPLICATION LOCID_APP;
-- Look for: version, patch, upgrade_state
```

### Consumer: Manually trigger an upgrade

```sql
ALTER APPLICATION LOCID_APP UPGRADE;
```

---

## Appendix C — Managing Output Tables

Each Encrypt/Decrypt job creates a new output table. To manage accumulation:

```sql
-- List all output tables
SHOW TABLES LIKE 'LOCID_%_OUTPUT_%' IN SCHEMA LOCID_APP.APP_SCHEMA;

-- Purge output tables older than 90 days (default retention)
CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(NULL);

-- Or specify custom retention (e.g., 30 days)
CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(30);
```

---

## Appendix D — Troubleshooting

### "No warehouse found for the Streamlit object"

Run:

```sql
GRANT USAGE ON WAREHOUSE <your_warehouse> TO APPLICATION LOCID_APP;
```

Then re-open the app. See [Phase 2.3](#23-grant-warehouse-to-the-application) for details.

### "Exceeded maximum number of inbound queries allowed for this instance: 298"

This is a transient Streamlit-in-Snowflake throttling error. It occurs when too many queries are queued on a single app instance — typically caused by rapid page refreshes during troubleshooting.

**Resolution:**
1. Close the browser tab completely
2. Wait 60 seconds for the query queue to drain
3. Re-open the app

This is not a configuration issue — no code or grant changes are needed.

### "Schema 'LOCID_APP.LOCID_SHARE' does not exist or not authorized"

The provider's shared data lake is not accessible. This is a provider-side deployment issue — contact LocID support to verify the data share is properly linked to your app version.
