# LocID Native App — Sandbox Deployment and Test Guide
**Date:** 2026-04-20  
**Version:** 1.0  
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
| Test data | `db/dev/provider_tests/01_load_test_data.sql`, `02_customer_input_sample.sql` |
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

cd /Users/wilin/Docs/LocalProjects/GitHub/de-locid-na

# Verify connection
snow connection test -c wl_sandbox_dcr
```

---

## Phase 0 — Role Setup (one-time, ACCOUNTADMIN)

Create the two custom deployment roles. This only needs to run once per Snowflake account.

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/00_roles.sql"
```

Before running, open `db/dev/provider/00_roles.sql` and replace the two placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_WAREHOUSE>` | Your actual warehouse name (e.g. `DEV_WH`) |
| `<username>` | Your Snowflake username |

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
```

> **Note:** Step 1.6 requires the JAR to be on `LOCID_STAGE` first. The JAR is uploaded in Phase 3 (app deployment). Skip 1.6 for now if deploying the app before testing UDFs directly; come back after Phase 3.

---

## Phase 2 — Load Test Data

Choose **one** option. Both produce the same table structure; the difference is the data source.

| Option | File | Use when |
|--------|------|----------|
| **A — Generated (recommended for sandbox)** | `00_generate_test_data.sql` | You want synthetic data — no real client CSV files required |
| **B — CSV load** | `01_load_test_data.sql` | You have the real client CSV files in `Coco/db/` |

---

### Option A — Synthetic generated data (no CSV files)

Requires Phase 1 Steps 1.1–1.6 (UDFs must exist) and your `base_locid_secret` from the LocID Central license response.

1. Open `db/dev/provider_tests/00_generate_test_data.sql`, set `$base_locid_secret` at the top, then run:
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
| `CUSTOMER_TEST_INPUT` | 100 |
| `CONSUMER_TEST.NA_TEST_INPUT` | 100 |

Generated IP space: `10.0.0.1` – `10.9.9.1` (100 /24 subnets, one host each).  
Customer event timestamps: `2025-01-10 08:00:00` + 10-minute increments (all match the `2025-01-08` build range).

When running the Encrypt job in the app (Phase 6), select timestamp format **datetime** (not epoch_ms).

---

### Option B — CSV load (real client data)

> The CSV files in `Coco/db/` contain real client data. Use Option A for general sandbox testing.

#### B.1 Upload CSV files to stage (Snow CLI, from repository root)

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

> The stage is created by `01_load_test_data.sql`. If it does not yet exist, run that file first up to the `LIST` command, then return here to upload.

#### B.2 Load provider tables

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/01_load_test_data.sql"
```

Expected row counts:

| Table | Rows |
|-------|------|
| `LOCID_BUILD_DATES` | 60 |
| `LOCID_BUILDS` | 10,000 |
| `LOCID_BUILDS_IPV4_EXPLODED` | 10,000 |
| `CUSTOMER_TEST_INPUT` | 100 |

#### B.3 Create consumer test input

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/02_customer_input_sample.sql"
```

This creates `LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT` (100 rows) — the simulated consumer input table used when testing the app's Encrypt workflow.

---

## Phase 3 — Deploy Native App

This phase uses Snow CLI with `na_app_pkg/snowflake.yml` to deploy the app package and install the app.  
All `snow app` commands must be run from inside `na_app_pkg/` (or pass `--project-definition na_app_pkg/snowflake.yml` from the repo root).

**Role convention for this phase:**

| Command type | How role is set |
|---|---|
| `snow app deploy / version / run` | Automatically from `meta.role` in `snowflake.yml` — no `--role` flag needed |
| `snow sql -f <file>` | `USE ROLE` at the top of each SQL file |
| `snow sql -q <query>` / `snow stage` | Must pass `--role` explicitly |

---

### 3.1 Pre-requisite — copy encode-lib JAR into `src/lib/`

The JAR is not checked in to git. Copy it once before the first deploy:

Verify it is in place:

```bash
ls na_app_pkg/src/lib/
# encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
```

---

### 3.2 Deploy app package (Snow CLI)

`snow app deploy` creates `LOCID_DEV_PKG` (if missing) and uploads all artifacts defined in `snowflake.yml` to `@APP_SCHEMA.APP_STAGE`:

```bash
cd na_app_pkg
snow app deploy --connection wl_sandbox_dcr
```

Verify files were uploaded:

```bash
snow stage list-files @LOCID_DEV_PKG.APP_SCHEMA.APP_STAGE \
    --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
# Expected: setup.sql, manifest.yml, README.md, lib/encode-lib-*.jar,
#           src/udfs/locid_udf.sql, src/procs/encrypt.sql, src/procs/decrypt.sql,
#           streamlit/app.py, streamlit/pages/*.py, streamlit/utils/*.py
```

---

### 3.3 Share provider data into app package

Once `LOCID_DEV_PKG` exists (created by `snow app deploy` in 3.2), run the provider
data sharing script. This creates `LOCID_SHARE` inside the app package and exposes
`LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, and `LOCID_BUILD_DATES` as Secure Views
to all installed app instances.

`snowflake.yml` declares `meta.role: LOCID_APP_ADMIN` for the `pkg` entity, so
`snow app deploy` creates `LOCID_DEV_PKG` under that role. This script runs as the
same role and therefore has the OWNERSHIP needed for package operations.

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/08_share_to_pkg.sql"
```

Verify:

```bash
snow sql --connection wl_sandbox_dcr --role LOCID_APP_ADMIN \
    -q "SHOW VIEWS IN SCHEMA LOCID_DEV_PKG.LOCID_SHARE"
# Expected: 3 views — LOCID_BUILDS, LOCID_BUILDS_IPV4_EXPLODED, LOCID_BUILD_DATES
```

> **Re-run when needed:** If the provider source tables are recreated (e.g. after a
> fresh data load), re-run this file so the Secure Views and grants stay in sync.

---

### 3.4 Approve external access at install time

`setup.sql` creates `LOCID_CENTRAL_EAI` in the consumer account during installation
(using the `CREATE EXTERNAL ACCESS INTEGRATION` privilege declared in `manifest.yml`).
No manual SQL is needed.

When `snow app run` installs the app, Snowflake will prompt for approval of the
`CREATE EXTERNAL ACCESS INTEGRATION` privilege. In Snowsight, this appears as a
permission dialog during app configuration. Approve it to enable outbound HTTPS to
`central.locid.com`.

> **Note:** `db/dev/provider/07_eai_setup.sql` is only needed for the **dev provider**
> environment (running UDFs directly against `LOCID_DEV.STAGING`). It is not part of
> the Native App install flow.

---

### 3.5 Create app version

```bash
cd na_app_pkg
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr
```

`--force` overwrites any existing `v1_0` version. `--skip-git-check` suppresses the uncommitted-files warning.

---

### 3.6 Install the application

```bash
cd na_app_pkg
snow app run --version v1_0 --connection wl_sandbox_dcr
```

`snow app run` creates `LOCID_DEV_APP` if it does not exist, or upgrades it if it does.

---

### 3.7 Bind references

The app uses `references` for consumer objects declared in `manifest.yml`.
Output tables are created by the app in its own `APP_SCHEMA` — no consumer GRANT is needed
for output.

| Access | Method |
|---|---|
| Input table (SELECT) | Reference — bound via Streamlit wizard or SQL |
| Output tables | Auto-created in `APP_SCHEMA` (`LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS` / `LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS`) |
| Warehouse (USAGE) | Reference — bound via Streamlit wizard or SQL |

**Bind INPUT_TABLE and APP_WAREHOUSE references**

*Option A — Streamlit setup wizard (recommended):*
Open the app in Snowsight and follow the setup wizard. Each reference has a picker that lets the
consumer select the target object. Snowflake calls `APP_SCHEMA.register_single_callback`
automatically on each selection.

*Option B — SQL (dev / automation):*

Replace `<YOUR_WAREHOUSE>` with the warehouse the app should use for jobs:

```sql
USE ROLE LOCID_APP_INSTALLER;

-- Bind the input table (grants SELECT automatically via reference)
CALL LOCID_DEV_APP.APP_SCHEMA.register_single_callback(
    'INPUT_TABLE', 'ADD', 'LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT');

-- Bind the job warehouse (grants USAGE automatically via reference)
CALL LOCID_DEV_APP.APP_SCHEMA.register_single_callback(
    'APP_WAREHOUSE', 'ADD', '<YOUR_WAREHOUSE>');
```

To remove a binding (e.g. to switch to a different table or warehouse):

```sql
CALL LOCID_DEV_APP.APP_SCHEMA.register_single_callback('INPUT_TABLE',   'REMOVE', '');
CALL LOCID_DEV_APP.APP_SCHEMA.register_single_callback('APP_WAREHOUSE', 'REMOVE', '');
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

### 4.1 Upload JAR to provider stage (if not already done in Phase 1.5)

```bash
snow stage copy \
    "Coco/tmp/20260415/encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar" \
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
| **D — Review License** | Confirm the license details (expiration, client name) and click **Continue** |
| **E — Review Privileges** | Review required permissions and click **Grant Privileges** |
| **F — Create App Objects** | Click **Create App Objects** (creates `APP_CONFIG`, `JOB_LOG`, etc.) |
| **G — Test Connectivity** | Click **Test Connectivity** — should show a green success indicator |
| **H — Select API Key** | Choose the active API key entry and click **Confirm** |
| **I — Setup Complete** | Wizard complete — sidebar navigation is now active |

> **H** is the API key selection screen. It reads the `access[]` array from the cached license response and shows all `ACTIVE` entries. Select the appropriate key and confirm; this writes `api_key_id`, `api_key`, `namespace_guid`, and `client_id` to `APP_CONFIG`.

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
| Warehouse | `<YOUR_WAREHOUSE>` |

> Output table is auto-generated in `LOCID_DEV_APP.APP_SCHEMA` as
> `LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`. The name is returned in the job result.

### 6.2 Run input validation (Step 2)

Click **Run Input Validation**. Review the advisory results:

| Check | Expected |
|-------|----------|
| IPv4 count | Most rows (test data is IPv4-dominant) |
| Bad IP format | 0 |
| Null IPs | 0 |
| Stale timestamps | Some (test data from 2025 — advisory only, does not block the job) |

### 6.3 Run the job (Step 5)

Click **Run Job**. The proc call: `APP_SCHEMA.LOCID_ENCRYPT(...)`.

Expected output:
- Result panel shows `output_table`, rows matched, rows in, and runtime
- Output table created at `LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS`

### 6.4 Inspect output

Substitute the actual table name returned by the job:

```sql
-- Replace <YYYYMMDD_HHMMSS> with the timestamp from the job result
SELECT * FROM LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;

-- Compare against expected output (CUSTOMER_TEST_OUTPUT_2K)
SELECT
    a.row_id,
    a.tx_cloc IS NOT NULL                       AS has_tx_cloc,
    a.encrypted_locid = b.encrypted_locid       AS encrypted_locid_match,
    a.locid_country    = b.locid_country        AS country_match,
    a.locid_city       = b.locid_city           AS city_match
FROM LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> a
JOIN LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT_2K                        b ON a.row_id = b.id
ORDER BY a.row_id
LIMIT 20;
```

---

## Phase 7 — Test Decrypt

### 7.1 Configure the job

Open **Run Decrypt** from the sidebar.

| Field | Value |
|-------|-------|
| ID column | `ROW_ID` |
| TX_CLOC column | `TX_CLOC` |
| Warehouse | `<YOUR_WAREHOUSE>` |

> Input for decrypt is the Encrypt output table from the previous step
> (`LOCID_DEV_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS>`).
> Decrypt output is auto-generated as `LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS` in the same schema.

### 7.2 Run the job

Click **Run Job**. The proc call: `APP_SCHEMA.LOCID_DECRYPT(...)`.

### 7.3 Verify STABLE_CLOC consistency

The STABLE_CLOC from Decrypt should match the STABLE_CLOC from Encrypt for the same row.
Substitute the actual table names returned by each job:

```sql
-- Replace both <YYYYMMDD_HHMMSS> placeholders with the timestamps from each job result
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

> Test 1 requires `8.8.8.8` to be present in the sandbox `LOCID_BUILDS` table. If it returns NULL at step 1a, the sandbox data does not yet include this IP range. Test 2 (decrypt path from known tx_cloc) runs independently.

---

## Appendix A — Cleanup

To reset the sandbox environment:

```sql
-- Drop the installed app
DROP APPLICATION IF EXISTS LOCID_DEV_APP;

-- Drop the app package
DROP APPLICATION PACKAGE IF EXISTS LOCID_DEV_PKG;

-- Drop provider test tables and stage
DROP TABLE  IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;
DROP TABLE  IF EXISTS LOCID_DEV.STAGING.CUSTOMER_TEST_OUTPUT_2K;
DROP STAGE  IF EXISTS LOCID_DEV.STAGING.LOCID_TEST_DATA_STAGE;

-- Drop consumer test schema
DROP SCHEMA IF EXISTS LOCID_DEV.CONSUMER_TEST;
```

To preserve provider data but reset test tables only:

```sql
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED;
TRUNCATE TABLE LOCID_DEV.STAGING.LOCID_BUILD_DATES;
TRUNCATE TABLE LOCID_DEV.STAGING.CUSTOMER_TEST_INPUT;
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
