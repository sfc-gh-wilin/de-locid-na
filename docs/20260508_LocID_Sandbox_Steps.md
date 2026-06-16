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

> **Why do I see two "LOCID_APP" tiles in My Apps?**
>
> Snowsight's "My Apps" page aggregates all Streamlit apps in the account — including Streamlits embedded inside Native Apps. This produces two tiles with the same name:
>
> | Tile | "Installed from" label | Owner Role | What it is |
> |---|---|---|---|
> | Tile 1 | `LOCID_PKG` | `LOCID_APP_INSTALLER` | The **Native App** — use this one |
> | Tile 2 | `LOCID_APP.APP_SCHEMA.LOCID_APP` | *(none)* | The internal **Streamlit object** surfaced directly |
>
> Always open the app via **Tile 1** (owner role `LOCID_APP_INSTALLER`, source `LOCID_PKG`). This routes through the Native App container with proper permissions. Tile 2 opens the same Streamlit directly, bypassing the app context — it may appear to work but lacks the correct role bindings. This is a Snowsight display quirk in sandbox only; real Marketplace consumers see one tile in their own account.

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
- Output table created: `LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS_JOBSFX`
- `rows_matched > 0`

Inspect:

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> LIMIT 10;
```

---

## Phase 7 — Test Decrypt

### 7.1 Bind the decrypt input table

Bind the Encrypt output table as input for Decrypt:

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX>',
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
FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> e
JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS_JOBSFX> d ON e.row_id = d.row_id
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

> **Why Prod and Dev apps cannot coexist in the same account**
>
> When a Native App installs, it claims ownership of its External Access Integration (EAI) — the object that grants the app network access to the LocID Central API. EAI names are **account-level singletons**: they are not scoped to a package or app instance.
>
> Both `LOCID_APP` and `LOCID_APP_DEV` require an EAI pointing to the external endpoint. Because both apps run in the same sandbox account, they compete for the same EAI name and ownership. Snowflake does not allow two installed apps to simultaneously own or share the same EAI.
>
> This constraint is **sandbox-only**. In a real Marketplace deployment each consumer installs the app in their own account, so there is never a conflict. To eliminate the drop cycle entirely, use a dedicated second Snowflake account for DEV consumer testing (see [Release DEV App to a DEV Consumer Account](#release-dev-app-to-a-dev-consumer-account) below).

> **"Can each package just use its own EAI with a different name?"**
>
> In principle yes — two EAIs with different names (`LOCID_CENTRAL_EAI` and `LOCID_CENTRAL_EAI_DEV`) would not conflict. In practice it does not work cleanly here because the EAI name is hardcoded inside every proc and function definition in `setup.sql`:
>
> ```sql
> EXTERNAL_ACCESS_INTEGRATIONS = (LOCID_CENTRAL_EAI)
> ```
>
> To give `LOCID_APP_DEV` its own EAI, `setup_dev.sql` would have to re-create every proc after prod setup runs — just to swap the name. That duplicates all proc DDL and creates ongoing maintenance overhead any time a new proc is added. The drop cycle is simpler and the problem is sandbox-only. The clean long-term fix is a **dedicated second Snowflake account for DEV**, which requires no code changes and mirrors real consumer behavior exactly.

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

### Release DEV App to a DEV Consumer Account

Use this to let a specific consumer account (e.g. a UAT partner) test against the DEV endpoint.

> **Provider steps** in this section are performed on the **provider** account. Consumer steps are performed on the **DEV consumer** account.

---

#### Provider Step 1 — Ensure DEV package is deployed and versioned

Verify the version was created:

```sql
USE ROLE LOCID_APP_ADMIN;
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG_DEV;
-- Expected at this point: review_status = 'NOT_REVIEWED'
-- This is correct immediately after version create, before the package has
-- DISTRIBUTION = 'EXTERNAL' set. The security scan is triggered in Step 2
-- when ADD VERSION is run on an EXTERNAL package — see wait note there.
```

Enable external distribution so the package can be shared to accounts outside the provider's organization:

```sql
USE ROLE LOCID_APP_ADMIN;

ALTER APPLICATION PACKAGE LOCID_PKG_DEV
    SET DISTRIBUTION = 'EXTERNAL';
```

> **Required** even for private listings shared to a single consumer account. Without this the package defaults to `INTERNAL` distribution — the consumer account will not see the listing if it is in a different Snowflake organization.

#### Provider Step 2 — Add version to release channel and wait for approval

```sql
USE ROLE LOCID_APP_ADMIN;

-- Add the version to the DEFAULT release channel.
-- On an EXTERNAL package this triggers the Snowflake automated security scan.
ALTER APPLICATION PACKAGE LOCID_PKG_DEV
    MODIFY RELEASE CHANNEL DEFAULT
    ADD VERSION v1_0;
```

Wait for the security scan to complete (typically < 1 hour):

```sql
USE ROLE LOCID_APP_ADMIN;
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG_DEV;
-- Wait until review_status = 'APPROVED' on v1_0 before proceeding.
-- If still 'PENDING' — wait and re-run this query.
-- Setting the release directive before APPROVED fails with:
--   "Version 'V1_0', patch 0 has not yet been approved to release to accounts outside of this organization"
```

Once approved, set the release directive:

```sql
USE ROLE LOCID_APP_ADMIN;

ALTER APPLICATION PACKAGE LOCID_PKG_DEV
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = 0;
```

> Replace `PATCH = 0` with the latest patch number from `SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG_DEV`.

#### Provider Step 3 — Create a private listing in Snowsight

In Snowsight on the **provider** account:

1. Navigate to **Marketplace → Provider Studio**
2. Click **+ Listing**
3. Enter the listing name: `LocID for Snowflake - DEV`
4. Under "Who can discover this listing?" → select **Only specified consumers**
5. Click **Add Data Product** → choose `LOCID_PKG_DEV`
6. Select `Free` for **Pricing**
7. In **Consumer Accounts** → add the DEV consumer's org.account (e.g. `JZAEQUY.DEV_CONSUMER_ACCT`)
8. Add a **Description** (e.g. "DEV build for pre-production testing")
9. Click **Publish**

Verify the listing is visible to the DEV consumer:

In Snowsight on the **DEV consumer** account, navigate to **Catalog → Apps** and confirm `LocID for Snowflake - DEV` appears under "Recently Shared with You".

---

#### DEV Consumer Step 1 — Drop PROD app (if installed)

> **Required.** `LOCID_APP` (prod) and `LOCID_APP_DEV` share the same account-level EAI name `LOCID_CENTRAL_EAI`. Both cannot be installed at the same time in the same account.

```sql
USE ROLE LOCID_APP_INSTALLER;
DROP APPLICATION IF EXISTS LOCID_APP CASCADE;
```

#### DEV Consumer Step 2 — Install from listing

In Snowsight on the **DEV consumer** account:

1. **Switch to the `LOCID_APP_INSTALLER` role** (bottom-left role selector)
2. Navigate to **Catalog → Apps**
3. Find **LocID for Snowflake - DEV** (under "Recently Shared with You" or use search)
4. Click **Get**
5. Expand **Options** → change the **Application name** field to `LOCID_APP_DEV`
6. Click **Get** to install

#### DEV Consumer Step 3 — Approve network access

**Option A — Snowsight UI:**

1. Navigate to **Catalog → Apps → LOCID_APP_DEV**
2. Click **Settings** (gear icon) → **Configurations**
3. Next to *LocID Central API Access*, click **…** → **Approve**

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

-- 1. Find the current sequence number:
SHOW SPECIFICATIONS IN APPLICATION LOCID_APP_DEV;

-- 2. Approve (replace N with SEQUENCE_NUMBER from above, usually 1):
ALTER APPLICATION LOCID_APP_DEV
    APPROVE SPECIFICATION LOCID_CENTRAL_EAI_SPEC SEQUENCE_NUMBER = N;

-- 3. Grant usage on the integration:
GRANT USAGE ON INTEGRATION LOCID_CENTRAL_EAI TO APPLICATION LOCID_APP_DEV;
```

#### DEV Consumer Step 4 — Grant warehouse

```sql
USE ROLE LOCID_APP_INSTALLER;

GRANT USAGE ON WAREHOUSE <your_warehouse> TO APPLICATION LOCID_APP_DEV;
```

#### DEV Consumer Step 5 — Setup Wizard

Open the app: **Catalog → Apps → LOCID_APP_DEV**

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **E — Approve Network Access** | Approve the connection to `central.matchbookdata-dev.com` and click **Approved — Continue** |
| **C — Enter License Key** | Enter the **DEV environment** license key and click **Fetch License** |
| **D — Review License** | Confirm license details and click **Continue** |
| **F — Create App Objects** | Click **Create App Objects** |
| **H — Select API Key** | Choose the active API key and click **Confirm** |
| **I — Setup Complete** | Done — sidebar navigation is now active |

> **Note:** A DEV-environment license key is required. The prod license key will be rejected by `central.matchbookdata-dev.com` with HTTP 401.

#### DEV Consumer — Restore PROD App after testing

```sql
USE ROLE LOCID_APP_INSTALLER;

-- 1. Drop DEV app (releases EAI ownership)
DROP APPLICATION IF EXISTS LOCID_APP_DEV CASCADE;

-- 2. Reinstall PROD app from the Marketplace listing
```

In Snowsight: **Catalog → Apps → LocID for Snowflake → Get → Application name: LOCID_APP → Get**

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

---

## Appendix D — Updating the mb-locid-encoding WHL

The `mb_locid_encoding` WHL is the Python encoding library used by all LocID UDFs. It is **not committed to git** and must be placed manually in `na_app_pkg/src/lib/` before each deploy. When a new version is provided by the Matchbook team, follow these steps.

### D.1 — Determine if the filename changed

The current WHL filename is hardcoded in the UDF definitions:

```
na_app_pkg/src/udfs/locid_udf.sql   (6 IMPORTS clauses)
```

Check the new WHL filename:

```bash
ls na_app_pkg/src/lib/
# e.g. mb_locid_encoding-1.2.0-py3-none-any.whl
```

- **Same filename** (e.g., still `mb_locid_encoding-0.0.0-py3-none-any.whl`) → skip to [D.3](#d3--deploy).
- **New filename** (version number changed) → continue to D.2.

### D.2 — Update hardcoded filename references (if version changed)

Update all 6 `IMPORTS` clauses in `na_app_pkg/src/udfs/locid_udf.sql`:

```bash
# Verify current references
grep -n "IMPORTS" na_app_pkg/src/udfs/locid_udf.sql

# Replace old version with new version (adjust version strings as needed)
sed -i '' \
  "s|mb_locid_encoding-0\.0\.0-py3-none-any\.whl|mb_locid_encoding-1.2.0-py3-none-any.whl|g" \
  na_app_pkg/src/udfs/locid_udf.sql

# Confirm all 6 occurrences updated
grep -n "IMPORTS" na_app_pkg/src/udfs/locid_udf.sql
```

Also update the comment lines in `na_app_pkg/setup.sql` (lines referencing the WHL filename) and `na_app_pkg/src/udfs/locid_udf.sql` (top-of-file comment) to keep documentation consistent.

> **Note:** The `snowflake.yml` artifact mapping uses `src: src/lib/` (directory-level), so it automatically picks up any `.whl` file placed there — no change needed in `snowflake.yml`.

### D.3 — Replace the WHL file

```bash
# Remove old WHL
rm na_app_pkg/src/lib/mb_locid_encoding-*.whl

# Copy new WHL into place
cp /path/to/new/mb_locid_encoding-1.2.0-py3-none-any.whl na_app_pkg/src/lib/

# Confirm
ls na_app_pkg/src/lib/
```

### D.4 — Deploy

```bash
cd na_app_pkg
snow app deploy --connection locid
```

Snow CLI uploads the new WHL to `@LOCID_PKG.APP_SCHEMA.APP_STAGE/lib/` and re-runs `setup.sql`, which recreates all UDFs with the updated `IMPORTS` path.

Verify the new WHL is on stage:

```bash
snow stage list-files @LOCID_PKG.APP_SCHEMA.APP_STAGE/lib \
    --connection locid --role LOCID_APP_ADMIN
```

### D.5 — Create a new app patch (required for consumer accounts)

Because UDF `IMPORTS` clauses changed, consumers on existing installs will not see the update until a new patch is released and installed.

```sql
-- Create a new patch on the current version
USE ROLE LOCID_APP_ADMIN;
ALTER APPLICATION PACKAGE LOCID_PKG
    ADD PATCH FOR VERSION V1_0
    USING '@LOCID_PKG.APP_SCHEMA.APP_STAGE';

-- Confirm the new patch number
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_PKG;
```

Then follow the standard release steps (Provider Steps 1–2 in the "Release DEV App to a DEV Consumer Account" section) to push the patch to the release channel.

> **Note:** If only the WHL binary changed but the filename stayed the same (same version string), Snow CLI still re-uploads the file on `snow app deploy`. No new patch is strictly required for the stage file to update, but creating a patch is still recommended so consumers on managed upgrades receive the update automatically.

### D.6 — Smoke test

After install/upgrade on a test account, run a quick UDF validation:

```sql
USE ROLE LOCID_APP_INSTALLER;

-- Confirm UDF resolves without import errors
SELECT LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_IPV4('192.168.1.1', 'test-key');
```

A non-NULL or expected-format result confirms the new WHL is loaded correctly.
