# LocID Native App — Consumer UAT Test Plan

**Date:** 2026-05-13  
**Version:** 1.0  
**Environment:** Cross-account (LocID Provider → Consumer install)

---

## Accounts

| Role | Account | Notes |
|------|---------|-------|
| Provider (LocID) | `JZAEQUY-QOC14949` | Owns `LOCID_PKG` |
| Consumer | `JZAEQUY-LOCID_CUST_ACCT_1` | Installs `LOCID_APP` |

---

## Prerequisites

| # | Requirement | Status |
|---|-------------|--------|
| 1 | Consumer deployment completed per `docs/20260511_LocID_Consumer_Steps.md` | ☐ |
| 2 | Snowpark-optimized warehouse available (Medium or larger) | ☐ |
| 3 | Test input table `LOCID_TEST.INPUT.SAMPLE_DATA` populated (≥ 10 rows) | ☐ |
| 4 | Role `LOCID_APP_INSTALLER` granted to tester's user | ☐ |
| 5 | Valid LocID license key available | ☐ |

---

## Test Cases

### TC-01 — App Installation & Permissions

| Field | Detail |
|-------|--------|
| **Objective** | Verify the app installs correctly and required permissions are granted |
| **Preconditions** | Provider has published listing; consumer has `LOCID_APP_INSTALLER` role |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 1.1 | Navigate to **Data Products → Apps** in Snowsight | `LOCID_APP` appears in list | ☐ |
| 1.2 | Check app status | Status = **Ready** | ☐ |
| 1.3 | Run: `DESCRIBE APPLICATION LOCID_APP;` | Returns version `v1_0`, patch ≥ 0, `upgrade_state = CURRENT` | ☐ |
| 1.4 | Verify external access was approved | Access to `central.locid.com` approved during install (Required Permissions prompt) | ☐ |

---

### TC-02 — Setup Wizard

| Field | Detail |
|-------|--------|
| **Objective** | Complete the setup wizard end-to-end and verify APP_CONFIG is populated |
| **Preconditions** | App installed, first launch (onboarding not yet complete) |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 2.1 | Open app → Setup Wizard screen A | "Welcome to LocID for Snowflake" displayed | ☐ |
| 2.2 | Click **Get Started** | Advances to screen B ("Have a license key?") | ☐ |
| 2.3 | Select **Yes, I have a license key** | Advances to screen C (Contact Sales not shown) | ☐ |
| 2.4 | Enter valid license key → click **Fetch License** | License validated, advances to screen D (Review License) | ☐ |
| 2.5 | Click **Continue** on Review License | Advances to screen E (Review Privileges) | ☐ |
| 2.6 | Approve required permissions | Advances to screen F (Create App Objects) | ☐ |
| 2.7 | Click **Create App Objects** | Objects created, advances to screen H (Select API Key) | ☐ |
| 2.8 | Select active API key → click **Confirm** | Advances to screen I (Setup Complete) | ☐ |
| 2.9 | Run: `SELECT config_key FROM LOCID_APP.APP_SCHEMA.APP_CONFIG ORDER BY config_key;` | Keys present: `api_key`, `api_key_id`, `cached_license`, `client_id`, `license_id_ref`, `namespace_guid`, `onboarding_complete` | ☐ |

---

### TC-03 — License & Entitlement Validation

| Field | Detail |
|-------|--------|
| **Objective** | Confirm license fetch populates entitlements and gating works |
| **Preconditions** | Setup wizard completed |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 3.1 | Open **Configuration** page | License section shows masked `license_id_ref` and `api_key_hint` | ☐ |
| 3.2 | Check "Current Entitlements" section | Badges displayed for entitled features (e.g., `allow_encrypt`, `allow_decrypt`) | ☐ |
| 3.3 | Open **Run Encrypt** with valid entitlement | Page loads without entitlement-block error | ☐ |

---

### TC-04 — Input Table Binding

| Field | Detail |
|-------|--------|
| **Objective** | Verify consumer can bind input tables via UI and SQL |
| **Preconditions** | Test table `LOCID_TEST.INPUT.SAMPLE_DATA` exists with data |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 4.1 | Open app → **⚙ Settings → Permissions** | Reference bindings UI displayed | ☐ |
| 4.2 | Bind **Input Table for Encrypt** to `LOCID_TEST.INPUT.SAMPLE_DATA` | Binding saved, table name shown | ☐ |
| 4.3 | Open **Run Encrypt** → Step 1 | Input table auto-populated with bound FQN | ☐ |
| 4.4 | Alternatively, bind via SQL: | Binding confirmed |  |
| | ```sql | | |
| | CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK( | | |
| |     'ENCRYPT_INPUT_TABLE', 'ADD', | | |
| |     SYSTEM$REFERENCE('TABLE', 'LOCID_TEST.INPUT.SAMPLE_DATA', 'PERSISTENT', 'SELECT') | | |
| | ); | | |
| | ``` | | ☐ |

---

### TC-05 — Encrypt Job (Happy Path)

| Field | Detail |
|-------|--------|
| **Objective** | Run a full Encrypt job and verify output |
| **Preconditions** | Input table bound, entitlement active, warehouse available |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 5.1 | Open **Run Encrypt** → Step 1 | Input table shown | ☐ |
| 5.2 | Step 2 — Map columns: ID = `ROW_ID`, IP = `IP_ADDR`, Timestamp = `EVENT_TS`, Format = `timestamp` | Columns mapped, validation passes | ☐ |
| 5.3 | Step 3 — Select all entitled output columns | Checkboxes shown for entitled columns | ☐ |
| 5.4 | Step 4 — Review & click **Run Job** | Job submits, progress indicator shown | ☐ |
| 5.5 | Wait for completion | Job finishes with status SUCCESS | ☐ |
| 5.6 | Run: `SHOW TABLES LIKE 'LOCID_ENCRYPT_OUTPUT_%' IN SCHEMA LOCID_APP.APP_SCHEMA;` | New output table exists with current timestamp suffix | ☐ |
| 5.7 | Run: `SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;` | Rows returned with expected columns (ROW_ID + selected output cols) | ☐ |

---

### TC-06 — Encrypt Input Validation

| Field | Detail |
|-------|--------|
| **Objective** | Verify advisory validation messages for edge-case input data |
| **Preconditions** | Input table bound |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 6.1 | Map columns with valid data (all timestamps within 52 weeks) | Green success: "Timestamp range looks good" | ☐ |
| 6.2 | Use input with NULL IP values | Warning: "X NULL IP value(s) — will be skipped" | ☐ |
| 6.3 | Use input with unparseable IP values | Warning: "X unparseable IP value(s) — will be skipped" | ☐ |
| 6.4 | Use input with timestamps > 52 weeks old | Warning: "X row(s) have timestamps older than 52 weeks" | ☐ |
| 6.5 | Use input with NULL timestamps | Warning: "X NULL timestamp value(s) — will be skipped" | ☐ |
| 6.6 | Confirm IPv4/IPv6 mix detection | Info message: "IP types (sample 1,000): IPv4: N · IPv6: N" | ☐ |

---

### TC-07 — Decrypt Job (Happy Path)

| Field | Detail |
|-------|--------|
| **Objective** | Run a full Decrypt job using Encrypt output |
| **Preconditions** | Encrypt job completed successfully with output containing TX_CLOC values |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 7.1 | Bind decrypt input to the Encrypt output table: | Binding saved | |
| | ```sql | | |
| | CALL LOCID_APP.APP_SCHEMA.REGISTER_SINGLE_CALLBACK( | | |
| |     'DECRYPT_INPUT_TABLE', 'ADD', | | |
| |     SYSTEM$REFERENCE('TABLE', 'LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS>', 'PERSISTENT', 'SELECT') | | |
| | ); | | |
| | ``` | | ☐ |
| 7.2 | Open **Run Decrypt** → Map columns: ID = `ROW_ID`, TX_CLOC = `TX_CLOC` | Columns mapped | ☐ |
| 7.3 | Click **Run Job** | Job submits | ☐ |
| 7.4 | Wait for completion | Job finishes with status SUCCESS | ☐ |
| 7.5 | Run: `SELECT * FROM LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS> LIMIT 10;` | Rows returned with ROW_ID + STABLE_CLOC + geo context columns | ☐ |

---

### TC-08 — STABLE_CLOC Consistency

| Field | Detail |
|-------|--------|
| **Objective** | Verify STABLE_CLOC from Encrypt matches STABLE_CLOC from Decrypt |
| **Preconditions** | Both Encrypt and Decrypt jobs completed on same dataset |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 8.1 | Run consistency check: | All rows show `PASS` | |
| | ```sql | | |
| | SELECT | | |
| |     e.row_id, | | |
| |     e.stable_cloc AS from_encrypt, | | |
| |     d.stable_cloc AS from_decrypt, | | |
| |     IFF(e.stable_cloc = d.stable_cloc, 'PASS', 'FAIL') AS consistent | | |
| | FROM LOCID_APP.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS> e | | |
| | JOIN LOCID_APP.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS> d | | |
| |     ON e.row_id = d.row_id | | |
| | WHERE e.stable_cloc IS NOT NULL; | | |
| | ``` | | ☐ |
| 8.2 | Confirm zero FAIL rows | `COUNT(*) WHERE consistent = 'FAIL'` = 0 | ☐ |

---

### TC-09 — Job History

| Field | Detail |
|-------|--------|
| **Objective** | Verify job history displays all jobs with correct metadata |
| **Preconditions** | At least one Encrypt and one Decrypt job completed |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 9.1 | Open **Job History** page | Table displays with recent jobs | ☐ |
| 9.2 | Verify both Encrypt and Decrypt jobs appear | At least 1 ENCRYPT + 1 DECRYPT row visible | ☐ |
| 9.3 | Filter by Operation = `ENCRYPT` | Only Encrypt jobs shown | ☐ |
| 9.4 | Filter by Status = `SUCCESS` | Only successful jobs shown | ☐ |
| 9.5 | Filter by date range (today) | Only today's jobs shown | ☐ |
| 9.6 | Expand a job row | Detail section shows run parameters | ☐ |
| 9.7 | Click CSV export | CSV file downloads with job data | ☐ |
| 9.8 | Run SQL verification: | Same data as UI | |
| | ```sql | | |
| | SELECT * FROM LOCID_APP.APP_SCHEMA.JOB_LOG ORDER BY run_at DESC; | | |
| | ``` | | ☐ |

---

### TC-10 — Configuration Page

| Field | Detail |
|-------|--------|
| **Objective** | Verify configuration page displays correct info and settings work |
| **Preconditions** | Setup wizard completed |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 10.1 | Open **Configuration** page | Page loads without errors | ☐ |
| 10.2 | Check "License & Credentials" section | `license_id_ref` shown (masked), `api_key_hint` shown (masked) | ☐ |
| 10.3 | Check "Current Entitlements" section | Entitlement badges displayed | ☐ |
| 10.4 | Check "Output Column Registry" section | Read-only table of available output columns shown | ☐ |
| 10.5 | Modify "Log Retention" to 30 days | Setting saved, confirmation shown | ☐ |
| 10.6 | Change "Log Level" to DEBUG | Setting saved | ☐ |
| 10.7 | Reset "Log Level" back to INFO | Setting saved | ☐ |
| 10.8 | Verify "Advanced" section shows re-run wizard option | Button/link present | ☐ |

---

### TC-11 — SQL Guide / Headless Execution

| Field | Detail |
|-------|--------|
| **Objective** | Verify Encrypt and Decrypt can be run via SQL stored procedures |
| **Preconditions** | Input tables bound, entitlements active |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 11.1 | Open **SQL Guide** page in the app | SQL examples displayed with correct app database name | ☐ |
| 11.2 | Run Encrypt via stored procedure using the documented SQL | Job completes, output table created | ☐ |
| 11.3 | Run Decrypt via stored procedure using the documented SQL | Job completes, output table created | ☐ |
| 11.4 | Verify both jobs appear in Job History | New entries visible | ☐ |

---

### TC-12 — Error Handling

| Field | Detail |
|-------|--------|
| **Objective** | Verify the app handles error conditions gracefully |
| **Preconditions** | App installed and configured |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 12.1 | Setup Wizard: enter invalid license key → **Fetch License** | Error message displayed, wizard does not advance | ☐ |
| 12.2 | Run Encrypt without binding an input table | Error: unable to access the input table / prompt to bind via Settings | ☐ |
| 12.3 | Run Encrypt with a table the role cannot SELECT | Permission error displayed | ☐ |
| 12.4 | Run Encrypt without `allow_encrypt` entitlement | Blocked: "Your license does not include the Encrypt entitlement" | ☐ |
| 12.5 | Run Decrypt without `allow_decrypt` entitlement | Blocked: similar entitlement error | ☐ |
| 12.6 | Map wrong column types (e.g., VARCHAR for timestamp) | Validation warning or job fails gracefully with clear error | ☐ |

---

### TC-13 — Version Upgrade

| Field | Detail |
|-------|--------|
| **Objective** | Verify consumer app upgrades correctly when provider pushes a patch |
| **Preconditions** | App installed at current version; provider deploys new patch |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 13.1 | Provider pushes new patch (updates release directive) | No action required on consumer | ☐ |
| 13.2 | Wait for auto-upgrade (or run `ALTER APPLICATION LOCID_APP UPGRADE;`) | Upgrade completes without error | ☐ |
| 13.3 | Run: `DESCRIBE APPLICATION LOCID_APP;` | New patch number shown, `upgrade_state = CURRENT` | ☐ |
| 13.4 | Open app in Snowsight | App loads normally, all pages accessible | ☐ |
| 13.5 | Run a new Encrypt job | Job succeeds — no regression | ☐ |

---

### TC-14 — Cleanup & Output Management

| Field | Detail |
|-------|--------|
| **Objective** | Verify cleanup procedures and output table management |
| **Preconditions** | Multiple Encrypt/Decrypt output tables exist |

| Step | Action | Expected Result | Pass/Fail |
|------|--------|-----------------|-----------|
| 14.1 | List output tables: | Tables listed | |
| | ```sql | | |
| | SHOW TABLES LIKE 'LOCID_%_OUTPUT_%' IN SCHEMA LOCID_APP.APP_SCHEMA; | | |
| | ``` | | ☐ |
| 14.2 | Purge with default retention: | Only tables older than default retention removed | |
| | ```sql | | |
| | CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(NULL); | | |
| | ``` | | ☐ |
| 14.3 | Purge with custom retention (30 days): | Only tables > 30 days old removed | |
| | ```sql | | |
| | CALL LOCID_APP.APP_SCHEMA.LOCID_PURGE_OUTPUTS(30); | | |
| | ``` | | ☐ |
| 14.4 | Full cleanup — drop app: | App removed | |
| | ```sql | | |
| | DROP APPLICATION IF EXISTS LOCID_APP CASCADE; | | |
| | ``` | | ☐ |
| 14.5 | Full cleanup — drop test data: | Test database removed | |
| | ```sql | | |
| | DROP DATABASE IF EXISTS LOCID_TEST; | | |
| | ``` | | ☐ |
| 14.6 | Full cleanup — drop role (ACCOUNTADMIN): | Role removed | |
| | ```sql | | |
| | USE ROLE ACCOUNTADMIN; | | |
| | DROP ROLE IF EXISTS LOCID_APP_INSTALLER; | | |
| | ``` | | ☐ |
| 14.7 | Verify no orphaned objects remain | No LOCID-prefixed databases, apps, or roles in account | ☐ |

---

## Summary & Sign-Off

| Test Case | Result | Notes |
|-----------|--------|-------|
| TC-01 — App Installation & Permissions | ☐ Pass / ☐ Fail | |
| TC-02 — Setup Wizard | ☐ Pass / ☐ Fail | |
| TC-03 — License & Entitlement Validation | ☐ Pass / ☐ Fail | |
| TC-04 — Input Table Binding | ☐ Pass / ☐ Fail | |
| TC-05 — Encrypt Job (Happy Path) | ☐ Pass / ☐ Fail | |
| TC-06 — Encrypt Input Validation | ☐ Pass / ☐ Fail | |
| TC-07 — Decrypt Job (Happy Path) | ☐ Pass / ☐ Fail | |
| TC-08 — STABLE_CLOC Consistency | ☐ Pass / ☐ Fail | |
| TC-09 — Job History | ☐ Pass / ☐ Fail | |
| TC-10 — Configuration Page | ☐ Pass / ☐ Fail | |
| TC-11 — SQL Guide / Headless Execution | ☐ Pass / ☐ Fail | |
| TC-12 — Error Handling | ☐ Pass / ☐ Fail | |
| TC-13 — Version Upgrade | ☐ Pass / ☐ Fail | |
| TC-14 — Cleanup & Output Management | ☐ Pass / ☐ Fail | |

**Overall Result:** ☐ Pass / ☐ Fail

| Field | Value |
|-------|-------|
| Tester | |
| Date | |
| App Version | |
| Notes | |
