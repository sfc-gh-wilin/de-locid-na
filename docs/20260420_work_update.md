# LocID Native App — Work Update
**Date:** 2026-04-20  
**Project:** LocID — Snowflake Native App

## 7 Sections

1. Architecture & Documentation — what was designed and documented
2. Provider Database — DDL and UDFs, including the JAR compatibility resolution
3. Native App Package — procs, Streamlit UI, EAI, input validation
4. Deployment Roles — the two custom roles (safe to share — shows good security posture)
5. Sandbox Testing Framework — test data and test suites
6. Sandbox Deployment Guide — the step-by-step doc
7. Open Items — things still pending, including the 8.8.8.8 data item that's on LocID to confirm

### Sending Over

Hi Alyssa, here are the items I am currently on:
1. Architecture & Documentation — modified and updated with more content
2. Provider Database — DDL and UDFs with Jar file
3. Native App Package — procs, Streamlit UI, EAI, input validation
4. Deployment Roles — the two custom roles (provider / consumer)
5. Sandbox Testing Framework — test data and test suites

---

## Architecture & Documentation

- Drafted full Native App architecture covering app structure, IP matching strategy (IPv4 equi-join, IPv6 cascading range join), Streamlit views, customer onboarding workflow, entitlement model, and usage telemetry.
- Published two architecture documents: `README.md` (high-level overview) and `docs/20260413_Architecture_v1.md` (detailed technical spec).
- Addressed LocID feedback on IP matching strategy, data visibility, and input validation (IP format + timestamp age checks).

---

## Provider Database (DDL & UDFs)

- Created all provider-side DDL scripts: `LOCID_BUILD_DATES`, `LOCID_BUILDS`, `LOCID_BUILDS_IPV4_EXPLODED` with proper clustering keys.
- Implemented 5 Scala 2.13 / Java 17 UDFs wrapping the `encode-lib` JAR:
  - `LOCID_BASE_ENCRYPT` / `LOCID_BASE_DECRYPT`
  - `LOCID_TXCLOC_ENCRYPT` / `LOCID_TXCLOC_DECRYPT`
  - `LOCID_STABLE_CLOC`
- Resolved JAR compatibility issue (Java 11 → Scala 2.13 inline handlers; no new wrapper class required from LocID).

---

## Native App Package

- Structured the Native App package (`na_app_pkg/`): `manifest.yml`, `setup.sql`, stored procedures, and Streamlit UI.
- Implemented `LOCID_ENCRYPT` stored procedure (IPv4 equi-join + IPv6 range join, entitlement check, TX_CLOC + STABLE_CLOC generation, job logging, telemetry POST).
- Implemented `LOCID_DECRYPT` stored procedure (TX_CLOC decode, STABLE_CLOC generation, job logging).
- Built 5-page Streamlit UI: Setup Wizard, Run Encrypt, Run Decrypt, Job History, Configuration.
- Added External Access Integration (`LOCID_CENTRAL_EAI`) for `central.locid.com:443`.
- Input validation in Run Encrypt: IP format check, timestamp age advisory (52-week window).

---

## Deployment Roles

- Defined two least-privilege custom roles as an alternative to ACCOUNTADMIN:
  - `LOCID_APP_ADMIN` — provider side: manages Application Package, stage, versions, Marketplace listing.
  - `LOCID_APP_INSTALLER` — consumer side: installs and manages the Native App instance.
- Both roles documented in architecture docs and implemented in `db/dev/provider/00_roles.sql`.

---

## Sandbox Testing Framework

- Created test data loader (`01_load_test_data.sql`) from real client CSVs with explicit column remapping for `LOCID_BUILDS`.
- Created synthetic data generator (`00_generate_test_data.sql`) — no real client CSV files needed for sandbox testing; generates 100-row deterministic IP dataset using Snowflake `GENERATOR()`.
- Created consumer simulation table (`02_customer_input_sample.sql`): `LOCID_DEV.CONSUMER_TEST.NA_TEST_INPUT` with non-standard column names to exercise the app's column mapping UI.
- Created UDF round-trip test suite (`03_udf_test.sql`): BASE_ENCRYPT/DECRYPT, TXCLOC_ENCRYPT/DECRYPT, STABLE_CLOC.
- Created cross-compatibility test (`04_cross_compat_test.sql`): verifies UDF output matches LocID production API using known values.

---

## Sandbox Deployment Guide

- Published step-by-step sandbox guide (`docs/20260420_NativeApp_Test_Steps.md`) covering:
  - Phase 0: Role setup
  - Phase 1: Provider database setup
  - Phase 2: Test data load (Option A — generated, Option B — CSV)
  - Phase 3: App package creation, file upload, version, install
  - Phases 4–8: UDF tests, Setup Wizard walkthrough, Encrypt/Decrypt job testing, cross-compat
  - Appendix: cleanup and re-run procedures
- All commands use Snow CLI (`snow -c wl_sandbox`); no SnowSQL dependency.

---

## Open Items

- `8.8.8.8` in sandbox `LOCID_BUILDS` — required for cross-compat Test 1 (LocID to confirm V6 data availability).
- Stored procedure procs (`LOCID_ENCRYPT`, `LOCID_DECRYPT`) — implementation complete; end-to-end test pending JAR staged and app installed.
- Production key derivation — `06_udfs.sql` uses production-mode Base64 key derivation; cross-compat test requires production keys from LocID Central (`central.locid.com`).


