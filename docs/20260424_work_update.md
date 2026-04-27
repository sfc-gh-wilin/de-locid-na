# LocID Native App — Work Update
**Project:** LocID — Snowflake Native App
**Last updated:** 2026-04-24

## Sending Over

1. Architecture & Documentations
    - In progress: continue to make adjustments
2. Provider Database (DDL & UDFs) 
    - Completed
3. Native App Package Works
    - In progress: continue development
4. Manifest v2 Upgrade
    - Completed
5. EAI Architecture Refactor
    - In progress: need more tests
6. Snow CLI Deployment
    - Completed
7. Deployment Roles and Guide
    - In progress: need more tests
8. Testing Framework
    - In progress: need more development tests

---

## All Work Done to Date

### 1. Architecture & Documentation

- Drafted full Native App architecture covering app structure, IP matching strategy (IPv4 equi-join, IPv6 cascading range join), Streamlit views, customer onboarding workflow, entitlement model, and usage telemetry.
- Published two architecture documents: `README.md` (high-level overview) and `docs/20260413_Architecture_v1.md` (detailed technical spec), later superseded by `docs/20260422_Architecture_v2.md`.
- Addressed LocID feedback on IP matching strategy, data visibility, and input validation (IP format + timestamp age checks).

---

### 2. Provider Database (DDL & UDFs)

- Created all provider-side DDL scripts: `LOCID_BUILD_DATES`, `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED` with proper clustering keys.
- Implemented 5 Scala 2.13 / Java 17 UDFs wrapping the `encode-lib` JAR:
  - `LOCID_BASE_ENCRYPT` / `LOCID_BASE_DECRYPT`
  - `LOCID_TXCLOC_ENCRYPT` / `LOCID_TXCLOC_DECRYPT`
  - `LOCID_STABLE_CLOC`
- Resolved JAR compatibility issue (Java 11 → Scala 2.13 inline handlers; no new wrapper class required from LocID).

---

### 3. Native App Package

- Structured the Native App package (`na_app_pkg/`): `manifest.yml`, `setup.sql`, stored procedures, and Streamlit UI.
- Implemented `LOCID_ENCRYPT` stored procedure (IPv4 equi-join + IPv6 range join, entitlement check, TX_CLOC + STABLE_CLOC generation, job logging, telemetry POST).
- Implemented `LOCID_DECRYPT` stored procedure (TX_CLOC decode, STABLE_CLOC generation, job logging).
- Built 5-page Streamlit UI: Setup Wizard, Run Encrypt, Run Decrypt, Job History, Configuration.
- Added External Access Integration (`LOCID_CENTRAL_EAI`) for `central.locid.com:443`.
- Input validation in Run Encrypt: IP format check, timestamp age advisory (52-week window).

---

### 4. Manifest v2 Upgrade *(2026-04-24)*

- Upgraded `manifest.yml` from v1 to v2 format.
- Replaced static `external_access_integrations` block (provider-declared EAI) with a `privileges` declaration — the app now requests `CREATE EXTERNAL ACCESS INTEGRATION` from the consumer at install time.
- Added `references` block for consumer object binding: `INPUT_TABLE` (SELECT), `APP_WAREHOUSE` (USAGE), configured via the Setup Wizard and a new callback procedure.

---

### 5. EAI Architecture Refactor *(2026-04-24)*

- Removed `07_deploy_jar.sql` (obsolete — JAR upload now handled by `snow app deploy`).
- Added `07_eai_setup.sql`: standalone script to create `LOCID_CENTRAL_EAI` and its network rule at the account level for provider-side sandbox use.
- Updated `setup.sql` to create `LOCID_CENTRAL_EAI` inside the app package (consumer-side) at install time. Consumer approves via Snowsight — no manual SQL required.
- Added `register_single_callback` stored procedure in `setup.sql` to handle `INPUT_TABLE` and `APP_WAREHOUSE` reference binding/removal.

---

### 6. Snow CLI Deployment (`snow app`) *(2026-04-24)*

- Updated `snowflake.yml` to define the app package, stage artifacts, and deployment targets for `snow app deploy` / `snow app run`.
- Deployment is now fully driven by `snow app deploy` from `na_app_pkg/` — no manual stage uploads needed.
- JAR file (`encode-lib-*.jar`) is bundled via `src/lib/`; included as a staged artifact in `snowflake.yml`.

---

### 7. Provider Data Sharing — Secure Views into App Package *(2026-04-24)*

- Identified missing piece: `encrypt.sql` was hardcoded to reference `LOCID_DEV.STAGING` directly — a path that does not exist on any consumer account.
- Created `db/dev/provider/08_share_to_pkg.sql`: provider-side script that shares the three LocID data tables into the Application Package via Secure Views:
  - Creates `LOCID_SHARE` schema inside `LOCID_DEV_PKG`
  - Creates Secure Views: `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED`, `LOCID_BUILD_DATES`
  - Grants `REFERENCE_USAGE ON DATABASE LOCID_DEV` to the package share
  - Grants `SELECT` on each view to the package share (visible to all installed app instances)
- Consumer accounts cannot query the Secure Views directly — the Native App Framework enforces access to app procedures only.
- Updated `encrypt.sql`: changed `_PROVIDER_SCHEMA` from `'LOCID_DEV.STAGING'` to `'LOCID_SHARE'` (one-line fix) so the procedure reads through the shared schema at runtime.
- Updated sandbox deployment guide: added Phase 3.3 (run `08_share_to_pkg.sql` after `snow app deploy`); renumbered old 3.3–3.6 to 3.4–3.7.

---

### 8. Deployment Roles

- Defined two least-privilege custom roles as an alternative to ACCOUNTADMIN:
  - `LOCID_APP_ADMIN` — provider side: manages Application Package, stage, versions, Marketplace listing.
  - `LOCID_APP_INSTALLER` — consumer side: installs and manages the Native App instance.
- Both roles documented in architecture docs and implemented in `db/dev/provider/00_roles.sql`.

---

### 9. Sandbox Testing Framework

- Created test data loader (`01_load_test_data.sql`) from real client CSVs with explicit column remapping for `LOCID_BUILDS`.
- Created synthetic data generator (`00_generate_test_data.sql`) — generates 100-row deterministic IP dataset using Snowflake `GENERATOR()`; no real CSV files needed.
- Created consumer simulation table (`02_customer_input_sample.sql`): `LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT` with non-standard column names to exercise the app's column mapping UI.
- Created UDF round-trip test suite (`03_udf_test.sql`): BASE_ENCRYPT/DECRYPT, TXCLOC_ENCRYPT/DECRYPT, STABLE_CLOC.
- Created cross-compatibility test (`04_cross_compat_test.sql`): verifies UDF output matches LocID production API using known values.

---

### 10. Sandbox Deployment Guide (`docs/20260420_NativeApp_Test_Steps.md`)

- Published step-by-step sandbox guide covering:
  - Phase 0: Role setup
  - Phase 1: Provider database setup
  - Phase 2: Test data load (Option A — generated, Option B — CSV)
  - Phase 3: App package creation, file upload, version, install
  - Phases 4–8: UDF tests, Setup Wizard walkthrough, Encrypt/Decrypt job testing, cross-compat
  - Appendix: cleanup and re-run procedures
- Updated Phase 3 *(2026-04-24)*: now uses `snow app deploy` / `snow app run` workflow; added Phase 3.3 (provider data sharing via `08_share_to_pkg.sql`), JAR pre-copy step, and EAI approval notes.
- All commands use Snow CLI (`snow -c wl_sandbox_dcr`); no SnowSQL dependency.

---

## Open Items

- `8.8.8.8` in sandbox `LOCID_BUILDS` — required for cross-compat Test 1; LocID to confirm V6 data availability.
- End-to-end Encrypt/Decrypt job test — pending JAR staged and `snow app run` install completion.
- Production key derivation — cross-compat test requires production keys from `central.locid.com`.
