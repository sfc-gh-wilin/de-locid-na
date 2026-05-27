# LocID Native App — Deployment Steps (LocID Account)

**Date:** 2026-05-08  
**Version:** 1.0  
**Environment:** LocID's Snowflake account (single-account sandbox — provider + consumer in same account)

---

## Overview

This guide walks through deploying the LocID Native App on LocID's own Snowflake account and verifying all major functions. The provider data tables already exist — no data loading is required.

**Key identifiers:**

| Object | Name |
|--------|------|
| Application Package | `LOCID_PKG` |
| Installed Application | `LOCID_APP` |
| Provider Database | `LOCID` (existing — do not modify) |
| Provider Tables | `LOCID.STAGING.LOCID_BUILDS`, `LOCID.STAGING.LOCID_BUILDS_IPV4_EXPLODED`, `LOCID.STAGING.LOCID_BUILD_DATES` |
| Snow CLI connection | `locid` |
| Warehouse | `SNOWPARK_OPT_M_WH` |
| Username | `WLIN` |

**File references used in this guide:**

| Phase | Files |
|-------|-------|
| Key access setup | (manual — see below) |
| Role setup | `db/locid/provider/00_roles.sql` |
| Add clustering keys | `db/locid/provider/01_optimize_tables.sql` |
| Create IPv6 exploded table | `db/locid/provider/02_ipv6_exploded_table.sql` |
| Grant access | `db/locid/provider/03_grant_access.sql` |
| Share to app package | `db/locid/provider/04_share_to_pkg.sql` |

---

## Prerequisites

### Tools

| Tool | Purpose | Minimum Version |
|------|---------|-----------------|
| Snow CLI (`snow`) | Run SQL files, upload files to stage, manage app deployment | **3.17+** (older versions like 3.1 have incompatibilities with `manifest_version: 2` and release channels) |
| Snowsight (browser) | Run ad-hoc SQL, use the Streamlit app | — |
| OpenSSL | Generate key pair for JWT authentication | — |

> **Important:** Run `snow --version` to check. If below 3.17, upgrade via `pip install snowflake-cli --upgrade` or `pipx upgrade snowflake-cli`. Many errors in sections 3.6–3.7 (release channels, debug mode) are resolved by upgrading Snow CLI.

---

## Phase 0 — Account Key Access

Generate an RSA key pair for Snow CLI JWT authentication:

```bash
openssl genrsa -out snowflake_key.pem 2048
openssl rsa -in snowflake_key.pem -pubout -out snowflake_key.pub
openssl pkcs8 -topk8 -inform PEM -outform PEM -in snowflake_key.pem -out snowflake_key.p8 -nocrypt
```

Register the public key with your Snowflake user:

```sql
SELECT CURRENT_USER();
ALTER USER WLIN SET RSA_PUBLIC_KEY='<paste contents of snowflake_key.pub, without header/footer lines>';
```

---

## Phase 1 — Snow CLI Connection Setup

Add the connection to `~/.snowflake/connections.toml`:

```toml
[locid]
account = "JZAEQUY-QOC14949"
user = "WLIN"
private_key_file = "/your/path/snowflake_key.p8"
authenticator = "SNOWFLAKE_JWT"
role = "ACCOUNTADMIN"
```

Test the connection:

```bash
snow connection test -c locid
```

---

## Phase 2 — Create Warehouse (one-time, ACCOUNTADMIN)

The LocID encrypt/decrypt procedures require a **Snowpark-optimized** warehouse. Create one if it does not already exist:

```sql
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS SNOWPARK_OPT_M_WH
    WAREHOUSE_SIZE = 'MEDIUM'
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 3
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE;
```

| Row Count | Recommended Size |
|-----------|-----------------|
| < 1M rows | Medium Snowpark-optimized |
| 1M–10M rows | Medium/Large Snowpark-optimized |
| 10M+ rows | Large+ Snowpark-optimized |

> **Note:** For concurrent jobs, set `MAX_CLUSTER_COUNT = 2–3` (multi-cluster). Adjust `WAREHOUSE_SIZE` based on your input row counts.

---

## Phase 3 — Role Setup (one-time, ACCOUNTADMIN)

Create the two custom deployment roles. This only needs to run once.

The file `db/locid/provider/00_roles.sql` is pre-configured with:
- Warehouse: `SNOWPARK_OPT_M_WH`
- Username: `WLIN`

```bash
snow sql --connection locid -f "db/locid/provider/00_roles.sql"
```

Verify both roles exist:

```bash
snow sql --connection locid -q "SHOW ROLES LIKE 'LOCID_APP_%'"
```

Expected: two rows — `LOCID_APP_ADMIN` and `LOCID_APP_INSTALLER`.

---

## Phase 4 — Deploy Native App

### 4.1 Pre-requisite — mb-locid-encoding WHL in `src/lib/`

The WHL is not checked in to git. Place it once before the first deploy:

```bash
ls na_app_pkg/src/lib/
# Expected: mb_locid_encoding-0.0.0-py3-none-any.whl
```

### 4.2 Deploy app package (Snow CLI)

`snow app deploy` creates `LOCID_PKG` (if missing) and uploads all artifacts to `@APP_SCHEMA.APP_STAGE`:

```bash
cd na_app_pkg
snow app deploy --connection locid
```

> **Note:** The role is set automatically from `meta.role: LOCID_APP_ADMIN` in `snowflake.yml`.

Verify files were uploaded:

```bash
snow stage list-files @LOCID_PKG.APP_SCHEMA.APP_STAGE \
    --connection locid --role LOCID_APP_ADMIN
```

### 4.3 Add clustering keys to provider tables (one-time)

LocID's source tables in `LOCID.STAGING` lack clustering keys. Without clustering, full table scans on 58B+ rows make the encrypt procedure run indefinitely.

```bash
cd <repository-root>
snow sql --connection locid -f "db/locid/provider/01_optimize_tables.sql"
```

This adds clustering keys: `LOCID_BUILDS(build_dt, start_ip_int_hex)`, `LOCID_BUILDS_IPV4_EXPLODED(ip_address, build_dt)`.

> **Note:** This is a metadata-only operation. Snowflake's Automatic Clustering reclusters in the background — queries improve progressively as it completes.

### 4.4 Create IPv6 exploded table (one-time)

The IPv6 encrypt procedure uses a pre-exploded `/56` prefix lookup table to convert a slow BETWEEN range join into a fast equi-join. This table must exist before the Secure Views in the app package are created.

```bash
cd <repository-root>
snow sql --connection locid -f "db/locid/provider/02_ipv6_exploded_table.sql"
```

> **Note:** The CREATE TABLE statement is idempotent (`IF NOT EXISTS`). The INSERT statements are date-scoped — edit the `BUILD_DT` value before running for each build date you want to include.

### 4.5 Grant access

The Secure Views in the app package reference `LOCID.STAGING` tables directly. The `LOCID_APP_ADMIN` role (which owns the package) must have SELECT on those tables, otherwise the installed app fails with "Failure during expansion of view: Error in secure object".

```bash
cd <repository-root>
snow sql --connection locid -f "db/locid/provider/03_grant_access.sql"
```

This also grants `LOCID_APP_INSTALLER` read access to the POC test input tables for reference binding.

### 4.6 Share provider data into app package

Once `LOCID_PKG` exists, run the provider data sharing script. This creates `LOCID_SHARE` inside the app package and exposes the four provider tables as Secure Views.

```bash
cd <repository-root>
snow sql --connection locid -f "db/locid/provider/04_share_to_pkg.sql"
```

Verify:

```bash
snow sql --connection locid --role LOCID_APP_ADMIN \
    -q "SHOW VIEWS IN SCHEMA LOCID_PKG.LOCID_SHARE"
# Expected: 4 views — LOCID_BUILDS, LOCID_BUILDS_IPV4_EXPLODED, LOCID_BUILDS_IPV6_EXPLODED, LOCID_BUILD_DATES
```

> **Re-run when needed:** If the provider source tables are recreated, re-run this file so the Secure Views and grants stay in sync.

### 4.7 Create app version

```bash
cd na_app_pkg
snow app version create v1_0 --force --skip-git-check --connection locid
```

`--force` overwrites any existing `v1_0` version. `--skip-git-check` suppresses the uncommitted-files warning.

### 4.8 Install the application

```bash
cd na_app_pkg
snow app run --version v1_0 --connection locid
```

`snow app run` creates `LOCID_APP` if it does not exist, or upgrades it if it does.

<https://app.snowflake.com/us-east-1/mrc41853/#/apps/application/LOCID_APP>

> **Note:** During installation, Snowflake will prompt for approval of the External Access Integration (`LOCID_CENTRAL_EAI`) for outbound HTTPS to `central.locid.com`. Approve it.

---

## Phase 5 — App Setup Wizard

Open the app in Snowsight: **Data Products → Apps → LOCID_APP**.

Walk through the Setup Wizard screens:

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **C — Enter License Key** | Enter your LocID license key and click **Fetch License** |
| **D — Review License** | Confirm the license details and click **Continue** |
| **E — Review Privileges** | Review required permissions and click **Grant Privileges** |
| **F — Create App Objects** | Click **Create App Objects** |
| **H — Select API Key** | Choose the active API key entry and click **Confirm** |
| **I — Setup Complete** | Wizard complete — sidebar navigation is now active |

After the wizard, verify `APP_CONFIG` is populated:

```sql
SELECT config_key, config_value, last_refreshed_at
FROM LOCID_APP.APP_SCHEMA.APP_CONFIG
ORDER BY config_key;
```

Expected keys: `api_key`, `api_key_id`, `cached_license`, `client_id`, `license_id_ref`, `namespace_guid`, `onboarding_complete`.

---

## Phase 6 — Test Encrypt

Test input tables already exist in the `LOCID` database:

| Table | Rows | IP Type |
|-------|------|---------|
| `LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4` | 1M | IPv4 |
| `LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV6` | 1M | IPv6 |

### 6.1 Bind the input table

**Option A — Streamlit UI (recommended):**

Open the app → **Settings** (gear icon) → bind **Input Table for Encrypt** to `LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4`.

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

GRANT SELECT ON TABLE LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4 TO APPLICATION LOCID_APP;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'ENCRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV4', 'PERSISTENT', 'SELECT')
);
```

> To test IPv6 instead, replace with `LOCID.POC.CUSTOMER_TEST_INPUT_1M_IPV6`.

### 6.2 Run the Encrypt job

Open **Run Encrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| IP column | `IP_ADDR` |
| Timestamp column | `EVENT_TS` |
| Timestamp format | `timestamp` |

Click **Run Job**.

**Expected:**
- Job completes successfully (status = `SUCCESS` in Job History)
- Output table created: `LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`
- `rows_matched > 0`

Inspect:

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;
```

---

## Phase 7 — Test Decrypt

### 7.1 Bind the decrypt input table

Bind the Encrypt output table as input for Decrypt:

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS>',
                     'PERSISTENT', 'SELECT')
);
```

### 7.2 Run the Decrypt job

Open **Run Decrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| TX_CLOC column | `TX_CLOC` |

Click **Run Job**.

### 7.3 Verify STABLE_CLOC consistency

```sql
SELECT
    e.row_id,
    e.stable_cloc AS stable_from_encrypt,
    d.stable_cloc AS stable_from_decrypt,
    IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS stable_cloc_consistent
FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> e
JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS> d ON e.row_id = d.row_id
WHERE e.stable_cloc IS NOT NULL
LIMIT 20;
-- All rows should show PASS
```

---

## Phase 8 — Verify Job History

```sql
SELECT *
FROM LOCID_APP.APP_SCHEMA.JOB_LOG
ORDER BY run_at DESC;
-- Expected: 2 rows (1 Encrypt + 1 Decrypt), both status = SUCCESS
```

---

## Re-deploying After Code Changes

After editing any file in `na_app_pkg/`:

```bash
cd na_app_pkg

# 1. Upload changed files
snow app deploy --connection locid

# 2. Add a new patch to the existing version
snow app version create v1_0 --force --skip-git-check --connection locid

# 3. Upgrade the running app (provider account test)
snow app run --version v1_0 --connection locid
```

> **Note:** You may see the warning `The connection host (xxx.snowflakecomputing.com) was missing or not in the expected format`. This is a Snow CLI message about the connection URL format — it does not affect deployment. Safe to ignore.

After verifying the update works on the provider account, push it to consumers:

```sql
USE ROLE LOCID_APP_ADMIN;

-- Check current versions/patches to find the latest patch number:
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG;

-- Set the release directive to the new patch:
ALTER APPLICATION PACKAGE LOCID_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = <new_patch_number>;
```

> **Note:** Replace `<new_patch_number>` with the latest patch number from `SHOW VERSIONS` above. Consumers on the DEFAULT channel will automatically pick up the new patch on their next app refresh.

---

## Dev Environment Deployment

The REST endpoint is stored in the `LOCID_CENTRAL_URL` Snowflake SECRET inside the app — not visible to consumers via SQL. The production app (`LOCID_PKG` / `LOCID_APP`) contains **no DEV-switching proc** and is never published to Marketplace with dev capabilities.

Dev testing uses a separate `LOCID_PKG_DEV` / `LOCID_APP_DEV` package, deployed via `deploy_dev.sh`. The DEV app is always in dev mode from the moment it installs — `setup_dev.sql` configures the dev endpoint, network rule, and EAI spec at install time.

> **Why a separate package?**  
> Objects inside a Native App can only be modified by procs running inside the app's own context. Direct DDL from outside (even as the app owner) fails with "Insufficient privileges". Keeping the DEV configuration in a separate package means Marketplace consumers never receive it.

### Deploy DEV package

```bash
cd na_app_pkg
./deploy_dev.sh --connection locid
# Expected: drops LOCID_APP, deploys LOCID_APP_DEV already in DEV mode
```

The DEV app is configured at install time — no proc call needed. `setup_dev.sql` sets the dev endpoint URL, network rule, and EAI spec automatically during `snow app run`.

> **One-time step after deploy:** Approve the updated spec in Snowsight:  
> **LOCID_APP_DEV → Settings → Connections → LocID Central API Access → Approve**

The script drops `LOCID_APP` before deploying — `LOCID_APP` and `LOCID_APP_DEV` cannot coexist in the same account (shared account-level EAI). This is sandbox-only; Marketplace consumers each have their own account.

To reinstall the prod app after dev testing, drop `LOCID_APP_DEV` first (same EAI ownership conflict applies in reverse):

```bash
# 1. Drop DEV app
snow sql --connection locid --role LOCID_APP_INSTALLER \
    -q "DROP APPLICATION IF EXISTS LOCID_APP_DEV CASCADE"

# 2. Reinstall prod app
cd na_app_pkg
snow app run --version v1_0 --connection locid
```

### DEV package cleanup

```sql
USE ROLE LOCID_APP_INSTALLER;
DROP APPLICATION IF EXISTS LOCID_APP_DEV CASCADE;

USE ROLE LOCID_APP_ADMIN;
DROP APPLICATION PACKAGE IF EXISTS LOCID_PKG_DEV;
```

---

## Appendix A — Cleanup

```sql
USE ROLE LOCID_APP_INSTALLER;

-- Drop the installed app (including LOCID_CENTRAL_EAI)
DROP APPLICATION IF EXISTS LOCID_APP CASCADE;
```

```sql
USE ROLE LOCID_APP_ADMIN;

-- Drop the app package (only if fully decommissioning)
DROP APPLICATION PACKAGE IF EXISTS LOCID_PKG;
```

```sql
USE ROLE ACCOUNTADMIN;

-- Drop roles (only if fully decommissioning)
DROP ROLE IF EXISTS LOCID_APP_INSTALLER;
DROP ROLE IF EXISTS LOCID_APP_ADMIN;
```

---

## Appendix B — Managing Output Tables

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

## Appendix C — Job History

All Encrypt and Decrypt job runs are logged in `APP_SCHEMA.JOB_LOG` inside the app:

```sql
SELECT *
FROM LOCID_APP.APP_SCHEMA.JOB_LOG
ORDER BY run_at DESC;
```
