# LocID Native App — Sandbox Deployment and Test Steps

**Date:** 2026-05-05  
**Version:** 2.0  
**Environment:** Sandbox (single-account, provider + consumer in same Snowflake account)

---

## Overview

This guide walks through deploying the LocID Native App from scratch in a sandbox account and verifying all major functions. The sandbox environment collapses the provider and consumer into one account for convenience.

**File references used in this guide:**

| Phase | Files |
|-------|-------|
| Role setup | `db/dev/provider/00_roles.sql` |
| Provider setup | `db/dev/provider/01_setup.sql` → `06_udfs.sql` |
| EAI setup | `db/dev/provider/07_eai_setup.sql` |
| Provider data sharing | `db/dev/provider/08_share_to_pkg.sql` |
| Test data | `db/dev/provider_tests/00_generate_test_data.sql`, `02_customer_input_sample.sql` |
| UDF tests | `db/dev/provider_tests/03_udf_test.sql` |
| Cross-compat | `db/dev/provider_tests/04_cross_compat_test.sql` |

---

## Prerequisites

### Tools

| Tool | Purpose |
|------|---------|
| Snow CLI (`snow`) | Run SQL files, upload files to stage, manage app deployment |
| Snowsight (browser) | Run ad-hoc SQL, use the Streamlit app |

### Snowflake roles

Two custom roles are used throughout this guide — created once by `ACCOUNTADMIN` in Phase 0:

| Role | Used for |
|------|---------|
| `LOCID_APP_ADMIN` | Provider side — manages the Application Package, stage, versions, and Marketplace listing |
| `LOCID_APP_INSTALLER` | Consumer side — installs and manages the Native App instance |

> In the sandbox, both roles live in the same account. In production, `LOCID_APP_ADMIN` belongs on the provider account and `LOCID_APP_INSTALLER` on the consumer account.

### Repository

All SQL paths below are relative to the repository root. Run Snow CLI from the repository root directory.

```bash
brew update && brew upgrade snowflake-cli

cd <repository-root>

# Verify connection
snow connection test -c wl_sandbox_dcr
```

---

## Phase 0 — Role Setup (one-time, ACCOUNTADMIN)

Create the two custom deployment roles. This only needs to run once per Snowflake account.

Before running, open `db/dev/provider/00_roles.sql` and replace the two placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_WAREHOUSE>` | Your actual warehouse name (e.g. `DEV_WH`) |
| `<username>` | Your Snowflake username |

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/00_roles.sql"
```

After running, verify both roles exist:

```bash
snow sql --connection wl_sandbox_dcr -q "SHOW ROLES LIKE 'LOCID_APP_%'"
```

Expected output: two rows — `LOCID_APP_ADMIN` and `LOCID_APP_INSTALLER`.

---

## Phase 1 — Provider Setup

Run the following scripts in order using Snow CLI. Each is idempotent (`CREATE IF NOT EXISTS` / `CREATE OR REPLACE`).

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/01_setup.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/02_locid_build_dates.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/03_locid_builds.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/04_locid_builds_ipv4_exploded.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/05_stage_setup.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/06_udfs.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/07_eai_setup.sql"
```

> **Note:** Step 06 requires the JAR to be on `LOCID_STAGE` first. The JAR is uploaded in Phase 3 (app deployment). Skip 06 for now if deploying the app before testing UDFs directly; come back after Phase 3.

---

## Phase 2 — Load Test Data

Choose **one** option. Both produce the same table structure; the difference is the data source.

| Option | File | Use when |
|--------|------|----------|
| **A — Generated (recommended for sandbox)** | `00_generate_test_data.sql` | You want synthetic data — no real client CSV files required |
| **B — CSV load** | `01_load_test_data.sql` | You have the real client CSV files |

---

### Option A — Synthetic generated data (no CSV files)

Requires Phase 1 Steps 01–06 (UDFs must exist) and your `base_locid_secret` from the LocID Central license response.

Retrieve secrets from:

```
GET https://central.locid.com/api/0/location_id/license/<your-license-id>
```

The response JSON contains:

```json
{
  "secrets": {
    "base_locid_secret": "<Base64-URL string, ~ as padding>",
    "scheme_secret":     "<Base64-URL string, ~ as padding>"
  }
}
```

Open `db/dev/provider_tests/00_generate_test_data.sql`, set `$base_locid_secret`, then run:

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/00_generate_test_data.sql"
```

This file is self-contained — it creates `LOCID_DEV.CONSUMER_TEST` schema and `NA_TEST_INPUT` table automatically.

Expected row counts:

| Table | Rows |
|-------|------|
| `LOCID_BUILD_DATES` | 5 |
| `LOCID_BUILDS` | 100 |
| `LOCID_BUILDS_IPV4_EXPLODED` | 100 |
| `CONSUMER_TEST.NA_TEST_INPUT` | 100 |

Generated IP space: `10.0.0.1` – `10.9.9.1` (100 /24 subnets, one host each).  
When running the Encrypt job in the app (Phase 6), select timestamp format **datetime** (not epoch_ms).

---

### Option B — CSV load (real client data)

#### B.1 Upload CSV files to stage

```bash
snow stage copy Coco/db/LOCID_BUILDS.csv \
    @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE --overwrite --connection wl_sandbox_dcr

snow stage copy Coco/db/LOCID_BUILDS_IPV4_EXPLODED.csv \
    @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE --overwrite --connection wl_sandbox_dcr

snow stage copy Coco/db/LOCID_BUILD_DATES.csv \
    @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE --overwrite --connection wl_sandbox_dcr

snow stage copy Coco/db/CUSTOMER_TEST_INPUT.csv \
    @LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE --overwrite --connection wl_sandbox_dcr
```

#### B.2 Load provider tables

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/01_load_test_data.sql"
```

#### B.3 Create consumer test input

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/02_customer_input_sample.sql"
```

This creates `LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT` (100 rows).

---

## Phase 3 — Deploy Native App

This phase uses Snow CLI with `na_app_pkg/snowflake.yml` to deploy the app package and install the app.  
All `snow app` commands must be run from inside `na_app_pkg/`.

**Role convention for this phase:**

| Command type | How role is set |
|---|---|
| `snow app deploy / version / run` | Automatically from `meta.role` in `snowflake.yml` — no `--role` flag needed |
| `snow sql -f <file>` | `USE ROLE` at the top of each SQL file |
| `snow sql -q <query>` / `snow stage` | Must pass `--role` explicitly |

---

### 3.1 Pre-requisite — mb-locid-encoding WHL in `src/lib/`

The WHL is not checked in to git. Place it once before the first deploy:

```bash
ls na_app_pkg/src/lib/
# mb_locid_encoding-0.0.0-py3-none-any.whl
```

---

### 3.2 Deploy app package (Snow CLI)

`snow app deploy` creates `LOCID_DEV_PKG` (if missing) and uploads all artifacts defined in `snowflake.yml` to `@APP_SCHEMA.APP_STAGE`:

```bash
cd na_app_pkg
snow app deploy --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

Verify files were uploaded:

```bash
snow stage list-files @LOCID_DEV_PKG.APP_SCHEMA.APP_STAGE \
    --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

---

### 3.3 Share provider data into app package

Once `LOCID_DEV_PKG` exists, run the provider data sharing script. This creates `LOCID_SHARE` inside the app package and exposes `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, and `LOCID_BUILD_DATES` as Secure Views.

```bash
cd <repository-root>
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/08_share_to_pkg.sql"
```

Verify:

```bash
snow sql --connection wl_sandbox_dcr --role LOCID_APP_ADMIN \
    -q "SHOW VIEWS IN SCHEMA LOCID_DEV_PKG.LOCID_SHARE"
# Expected: 3 views — LOCID_BUILDS, LOCID_BUILDS_IPV4_EXPLODED, LOCID_BUILD_DATES
```

> **Re-run when needed:** If the provider source tables are recreated, re-run this file so the Secure Views and grants stay in sync.

---

### 3.4 Approve external access at install time

`setup.sql` creates `LOCID_CENTRAL_EAI` in the consumer account during installation (using the `CREATE EXTERNAL ACCESS INTEGRATION` privilege declared in `manifest.yml`). No manual SQL is needed.

When `snow app run` installs the app, Snowflake will prompt for approval. In Snowsight, this appears as a permission dialog during app configuration. Approve it to enable outbound HTTPS to `central.locid.com`.

> **Note:** `db/dev/provider/07_eai_setup.sql` is only needed for the **dev provider** environment (running UDFs directly against `LOCID_DEV.STAGING`). It is not part of the Native App install flow.

---

### 3.5 Create app version

```bash
cd na_app_pkg
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

`--force` overwrites any existing `v1_0` version. `--skip-git-check` suppresses the uncommitted-files warning.

---

### 3.6 Install the application

```bash
cd na_app_pkg
snow app run --version v1_0 --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

`snow app run` creates `LOCID_DEV_APP` if it does not exist, or upgrades it if it does.

---

### 3.7 Bind references

Two references must be bound before the app can run jobs: `ENCRYPT_INPUT_TABLE` and `DECRYPT_INPUT_TABLE`.

**Option A — Streamlit Setup Wizard (recommended)**

Open the app in Snowsight → navigate to **Setup Wizard**. The wizard walks through each reference step-by-step with inline instructions.

**Option B — SQL (Snowsight worksheet)**

```sql
-- 1. Bind the encrypt input table
CALL LOCID_DEV_APP.APP_SCHEMA.LOCID_REGISTER_SINGLE_CALLBACK(
    'ENCRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT',
                     'SESSION', 'SELECT')
);

-- 2. Bind the decrypt input table (can reuse the same table or a different one)
CALL LOCID_DEV_APP.APP_SCHEMA.LOCID_REGISTER_SINGLE_CALLBACK(
    'DECRYPT_INPUT_TABLE', 'ADD',
    SYSTEM$REFERENCE('TABLE', 'LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT',
                     'SESSION', 'SELECT')
);
```

Verify:

```sql
SELECT * FROM LOCID_DEV_APP.APP_SCHEMA.APP_CONFIG
WHERE config_key LIKE 'ref.%';
-- Expected: 2 rows with non-null config_value
```

---

### Re-deploying after code changes

After editing any file in `na_app_pkg/`:

```bash
cd na_app_pkg

# 1. Upload changed files
snow app deploy --connection wl_sandbox_dcr

# 2. Add a new patch to the existing version
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr

# 3. Upgrade the running app
snow app run --version v1_0 --connection wl_sandbox_dcr
```

---

## Phase 4 — UDF Tests (direct, outside the app)

These tests validate the UDFs in `LOCID_DEV.STAGING` independently of the app.

### 4.1 Upload JAR to provider stage (if not already done in Phase 1)

```bash
snow stage copy \
    "na_app_pkg/src/lib/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar" \
    @LOCID_DEV.STAGING.LOCID_STAGE --overwrite --connection wl_sandbox_dcr

snow stage list-files @LOCID_DEV.STAGING.LOCID_STAGE --connection wl_sandbox_dcr
```

### 4.2 Run UDF round-trip tests

Run `db/dev/provider_tests/03_udf_test.sql` step by step.

Before running, set the secrets (from the LocID Central license response — not the License Key):

```sql
SET base_locid_secret = 'REPLACE_WITH_YOUR_BASE_LOCID_SECRET';
SET scheme_secret     = 'REPLACE_WITH_YOUR_SCHEME_SECRET';
```

Expected results:

| Test | Assertion | Expected |
|------|-----------|----------|
| Test 1 | `test_base_encrypt_decrypt` | `PASS` |
| Test 2+3 | `test_2_3_txcloc_roundtrip` | `PASS` |
| Test 4 | `test_4_stable_cloc` | `PASS` (non-null UUID) |

---

## Phase 5 — App Setup Wizard

Open the app in Snowsight: **Data Products → Apps → LOCID_DEV_APP**.

Walk through the Setup Wizard screens:

| Screen | Action |
|--------|--------|
| **A — Welcome** | Click **Get Started** |
| **B — License key?** | Select **Yes, I have a license key** |
| **C — Enter License Key** | Enter your LocID license key and click **Fetch License** |
| **D — Review License** | Confirm the license details and click **Continue** |
| **E — Review Privileges** | Review required permissions and click **Grant Privileges** |
| **F — Create App Objects** | Click **Create App Objects** (creates `APP_CONFIG`, `JOB_LOG`, etc.) |
| **G — Test Connectivity** | Click **Test Connectivity** — should show a green success indicator |
| **H — Select API Key** | Choose the active API key entry and click **Confirm** |
| **I — Setup Complete** | Wizard complete — sidebar navigation is now active |

After the wizard, verify `APP_CONFIG` is populated:

```sql
SELECT config_key, config_value, last_refreshed_at
FROM LOCID_DEV_APP.APP_SCHEMA.APP_CONFIG
ORDER BY config_key;
```

Expected keys: `api_key`, `api_key_id`, `cached_license`, `client_id`, `license_id_ref`, `namespace_guid`, `onboarding_complete`.

---

## Phase 6 — Test Encrypt

### 6.1 Configure the job

Open **Run Encrypt** from the sidebar.

| Field | Value |
|-------|-------|
| Input table | `LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT` |
| ID column | `ROW_ID` |
| IP column | `IP_ADDR` |
| Timestamp column | `EVENT_TS` |
| Timestamp format | `epoch_ms` or `datetime` (match actual format in test data) |

> Output table is auto-generated in `LOCID_DEV_APP.APP_SCHEMA` as `LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`.

### 6.2 Run input validation (Step 2)

Click **Run Input Validation**. Review the advisory results:

| Check | Expected |
|-------|----------|
| IPv4 count | Most rows (test data is IPv4-dominant) |
| Bad IP format | 0 |
| Null IPs | 0 |
| Stale timestamps | Some (advisory only, does not block the job) |

### 6.3 Run the job

Click **Run Job**. The proc call: `APP_SCHEMA.LOCID_ENCRYPT(...)`.

Expected output:
- Result panel shows `output_table`, rows matched, rows in, and runtime
- Output table created at `LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`

### 6.4 Inspect output

```sql
-- Replace <YYYYMMDD_HHMMSS> with the timestamp from the job result
SELECT * FROM LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;
```

---

## Phase 7 — Test Decrypt

### 7.1 Configure the job

Open **Run Decrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| TX_CLOC column | `TX_CLOC` |

> Input for decrypt is the Encrypt output table from the previous step.
> Decrypt output is auto-generated as `LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS` in the same schema.

### 7.2 Run the job

Click **Run Job**. The proc call: `APP_SCHEMA.LOCID_DECRYPT(...)`.

### 7.3 Verify STABLE_CLOC consistency

The STABLE_CLOC from Decrypt should match the STABLE_CLOC from Encrypt for the same row:

```sql
SELECT
    e.row_id,
    e.stable_cloc  AS stable_from_encrypt,
    d.stable_cloc  AS stable_from_decrypt,
    IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS stable_cloc_consistent
FROM LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> e
JOIN LOCID_DEV_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS> d ON e.row_id = d.row_id
WHERE e.stable_cloc IS NOT NULL
LIMIT 20;
-- All rows should show PASS
```

---

## Phase 8 — Cross-Compatibility Test

This test verifies UDF output is cross-compatible with the LocID production API using known values from LocID.

Before running, confirm:
1. UDFs are recreated with **production key derivation** (see header of `04_cross_compat_test.sql`)
2. Production keys are populated in the session variables

Run `db/dev/provider_tests/04_cross_compat_test.sql` step by step.

Expected final summary:

| Column | Expected |
|--------|----------|
| `test_1_encrypt_path` | `PASS` |
| `test_2_decrypt_path` | `PASS` |

> Test 1 requires `8.8.8.8` to be present in the sandbox `LOCID_BUILDS` table. If it returns NULL, the sandbox data does not yet include this IP range. Test 2 (decrypt path from known tx_cloc) runs independently.

---

## Appendix A — Cleanup

To reset the sandbox environment:

```sql
-- Drop the installed app (including LOCID_CENTRAL_EAI)
DROP APPLICATION IF EXISTS LOCID_DEV_APP CASCADE;

-- Drop the app package
DROP APPLICATION PACKAGE IF EXISTS LOCID_DEV_PKG;

-- Drop provider test tables and stage
DROP TABLE  IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;
DROP TABLE  IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT_2K;
DROP STAGE  IF EXISTS LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE;

-- Drop consumer test schema
DROP SCHEMA IF EXISTS LOCID_DEV.CONSUMER_TEST;
```

---

## Appendix B — Re-running Test Data

**Option A (synthetic data):** Re-run the single self-contained file:

```
db/dev/provider_tests/00_generate_test_data.sql
```

**Option B (CSV load):** Re-run in order:

```
db/dev/provider_tests/01_load_test_data.sql
db/dev/provider_tests/02_customer_input_sample.sql
```

All scripts truncate before loading and are idempotent.

---

## Appendix C — Job History

All Encrypt and Decrypt job runs are logged in `APP_SCHEMA.JOB_LOG` inside the app:

```sql
SELECT *
FROM LOCID_DEV_APP.APP_SCHEMA.JOB_LOG
ORDER BY started_at DESC;
```
