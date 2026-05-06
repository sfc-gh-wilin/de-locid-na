# LocID Native App — Consumer Account Test Steps

**Date:** 2026-05-05  
**Version:** 1.0  
**Environment:** Cross-account (Provider listing → Consumer install)

---

## Accounts

| Role | Connection | Account |
|------|-----------|---------|
| Provider | `wl_sandbox_dcr` | `SFPSCOGS-WLIN_DCR_AWS_W2` |
| Consumer | `wl_sandbox` | `SFPSCOGS-WLIN_AWS_W2` |

---

## Phase 0 — Provider: Publish Listing (one-time)

> Run all commands in this phase from the **provider** connection (`wl_sandbox_dcr`).

### 0.1 Ensure the app package is deployed and versioned

```bash
cd na_app_pkg
snow app deploy --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

### 0.2 Enable external distribution and share to consumer account

For testing without a public Marketplace listing, share the package directly to the consumer account via a private listing.

**Step A — Set distribution to EXTERNAL:**

```sql
USE ROLE LOCID_APP_ADMIN;

ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    SET DISTRIBUTION = 'EXTERNAL';
```

**Step B — Add version to the default release channel:**

```sql
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    ADD VERSION v1_0;
```

**Step C — Wait for security scan approval:**

Snowflake runs an automated security scan on all versions released externally. Check scan status:

```sql
SHOW VERSIONS IN APPLICATION PACKAGE LOCID_DEV_PKG;
-- Look for review_status = 'APPROVED' on v1_0
-- If 'PENDING' — wait (typically < 1 hour, can take longer)
```

> **Note:** The scan must show `APPROVED` before you can set a release directive or attach the package to a listing. If the scan finds issues, check the scan report in Snowsight under the app package.

**Step D — Set the DEFAULT release directive:**

The private listing **requires** a default release directive on the DEFAULT release channel. Without this, attaching the package to a listing fails with:

> *"No default release directive is found for application package 'LOCID_DEV_PKG' when setting up a listing with the application package."*

```sql
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET DEFAULT RELEASE DIRECTIVE
    VERSION = v1_0
    PATCH = 0;
```

> Replace `PATCH = 0` with the latest approved patch number from `SHOW VERSIONS`.

Verify:

```sql
SHOW RELEASE DIRECTIVES IN APPLICATION PACKAGE LOCID_DEV_PKG;
-- Expected: a row with name=DEFAULT, target_type=DEFAULT, release_status=DEPLOYED
```

**Step D2 (optional) — Set a custom release directive for specific account targeting:**

Only needed if you want to pin a *different* version/patch to the consumer account than the default. For basic testing where the consumer should get the same version as the default directive, skip this step.

```sql
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    SET RELEASE DIRECTIVE CONSUMER_TEST_DIRECTIVE
    ACCOUNTS = (SFPSCOGS.WLIN_AWS_W2)
    VERSION = v1_0
    PATCH = 0;
```

> **Note:** A custom directive always takes precedence over the default for the specified accounts.

**Step E — Create a private listing (required for Snowsight visibility):**

A release directive alone does **not** make the app visible in the consumer's Snowsight UI. You must also create a private listing with the application package as its data content.

In Snowsight on the **provider** account:

1. Navigate to **Marketplace → Provider Studio**
2. Click **Create Listing**
3. Enter a name: `LocID for Snowflake`
4. Under "Who can discover the listing" → select **Only specified consumers**
5. Click **Add Data Product** → choose `LOCID_DEV_PKG`
6. In "Add consumer accounts" → add `SFPSCOGS.WLIN_AWS_W2`
7. Click **Publish**

> **Note:** Without a listing, the app will not appear in the consumer's Snowsight **Catalog → Apps** UI.

### 0.3 Verify listing is visible

In Snowsight on the consumer account, navigate to **Catalog → Apps** and confirm "LocID for Snowflake" appears in the available apps list.

---

## Phase 1 — Consumer: Role Setup (one-time, ACCOUNTADMIN)

> Run all commands from here onward from the **consumer** connection (`wl_sandbox`).

### 1.1 Create the installer role

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER;

-- Required privileges for Native App installation
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
GRANT CREATE DATABASE    ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;

-- Warehouse for running jobs
GRANT USAGE ON WAREHOUSE <your_warehouse> TO ROLE LOCID_APP_INSTALLER;

-- Assign to your user
GRANT ROLE LOCID_APP_INSTALLER TO USER <your_username>;

-- Optional: hierarchy compliance
GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
```

### 1.2 Verify the role

```bash
snow sql --connection wl_sandbox -q "SHOW ROLES LIKE 'LOCID_APP_INSTALLER'"
```

---

## Phase 2 — Consumer: Install the App

### 2.1 Install from listing

In Snowsight on the consumer account:

1. Navigate to **Catalog → Apps**
2. Find **LocID for Snowflake** (or the package name shared by the provider)
3. Click **Get**
4. Choose database name: `LOCID_APP` (or preferred name)
5. Review and approve the **Required Permissions**:
   - External access to `central.locid.com` (license validation + usage reporting)
6. Click **Activate**

### 2.2 Approve external access

External access (outbound HTTPS to `central.locid.com`) is approved during installation via the Snowsight permissions dialog in step 2.1 above. If prompted again on first app launch, approve via the in-app permissions screen.

### 2.3 Verify installation

In Snowsight, navigate to **Catalog → Apps**. Confirm `LOCID_APP` appears with status **Ready**.

---

## Phase 3 — Consumer: Setup Wizard

Open the app in Snowsight: **Catalog → Apps → LOCID_APP**

Walk through the Setup Wizard:

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **C — Enter License Key** | Enter your LocID license key and click **Fetch License** |
| **D — Review License** | Confirm license details and click **Continue** |
| **E — Review Privileges** | Approve network access (if not already done in 2.2) |
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

-- Simple test table (10 rows with known IPs)
CREATE OR REPLACE TABLE LOCID_TEST.INPUT.SAMPLE_DATA (
    ROW_ID      INTEGER,
    IP_ADDR     VARCHAR,
    EVENT_TS    TIMESTAMP_NTZ
) AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS row_id,
    '8.8.8.' || (SEQ4() % 10 + 1)::VARCHAR AS ip_addr,
    DATEADD('minute', SEQ4() * 10, '2025-06-01 08:00:00'::TIMESTAMP_NTZ) AS event_ts
FROM TABLE(GENERATOR(ROWCOUNT => 10));
```

### 4.2 Bind the input table reference

**Option A — Streamlit UI (recommended):**

Open the app → **Settings** (gear icon) → bind **Input Table for Encrypt** to `LOCID_TEST.INPUT.SAMPLE_DATA`.

**Option B — SQL:**

```sql
USE ROLE LOCID_APP_INSTALLER;

CALL LOCID_APP.APP_SCHEMA.LOCID_REGISTER_SINGLE_CALLBACK(
    'ENCRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_TEST.INPUT.SAMPLE_DATA', 'SESSION', 'SELECT')
);
```

---

## Phase 5 — Consumer: Test Encrypt

1. Open **Run Encrypt** from the sidebar
2. Map columns:
   - ID column: `ROW_ID`
   - IP column: `IP_ADDR`
   - Timestamp column: `EVENT_TS`
   - Timestamp format: `timestamp`
3. Select output columns (all entitled)
4. Click **Run Job**

**Expected:**
- Job completes successfully
- Output table created: `LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`
- `rows_matched` > 0 (depends on whether the IPs exist in LocID's data lake)

Inspect:

```sql
SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;
```

---

## Phase 6 — Consumer: Test Decrypt

1. Bind the decrypt input table to the Encrypt output table:

```sql
CALL LOCID_APP.APP_SCHEMA.LOCID_REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS>',
                     'SESSION', 'SELECT')
);
```

2. Open **Run Decrypt** from the sidebar
3. Map columns:
   - ID column: `ROW_ID`
   - TX_CLOC column: `TX_CLOC`
4. Click **Run Job**

**Expected:**
- Job completes successfully
- `STABLE_CLOC` values match between Encrypt output and Decrypt output

Verify:

```sql
SELECT
    e.row_id,
    e.stable_cloc AS from_encrypt,
    d.stable_cloc AS from_decrypt,
    IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS consistent
FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> e
JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS> d ON e.row_id = d.row_id
WHERE e.stable_cloc IS NOT NULL;
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

## Appendix B — Cleanup (Provider)

To revoke access from the consumer:

```sql
USE ROLE LOCID_APP_ADMIN;

-- Remove the release directive targeting the consumer account
ALTER APPLICATION PACKAGE LOCID_DEV_PKG
    MODIFY RELEASE CHANNEL DEFAULT
    UNSET RELEASE DIRECTIVE CONSUMER_TEST_DIRECTIVE;
```
