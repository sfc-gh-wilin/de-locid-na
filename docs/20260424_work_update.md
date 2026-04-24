# LocID Native App — Work Update
**Date:** 2026-04-24
**Project:** LocID — Snowflake Native App

---

## Summary

Continued work on the Native App package and sandbox deployment guide. Today's focus was on the Native App Framework (NAF) compliance upgrade (manifest v2), EAI architecture refactor, and deployment tooling consolidation.

---

## 1. Manifest v2 Upgrade

- Upgraded `manifest.yml` from v1 to v2 format.
- Replaced static `external_access_integrations` block (provider-declared EAI) with a `privileges` declaration — the app now requests `CREATE EXTERNAL ACCESS INTEGRATION` from the consumer at install time.
- Added `references` block for consumer object binding: `INPUT_TABLE` (SELECT), `APP_WAREHOUSE` (USAGE). These are configured via the Setup Wizard and registered through a new callback procedure.

---

## 2. EAI Architecture Refactor

- Removed `07_deploy_jar.sql` (obsolete — JAR upload is now handled by `snow app deploy`).
- Added `07_eai_setup.sql`: standalone script to create `LOCID_CENTRAL_EAI` and its network rule at the account level for provider-side sandbox use.
- Updated `setup.sql` to create `LOCID_CENTRAL_EAI` inside the app package (consumer-side), driven by the `CREATE EXTERNAL ACCESS INTEGRATION` privilege declared in `manifest.yml`. Consumer approves at install time — no manual SQL required.
- Added `register_single_callback` stored procedure in `setup.sql` to handle `INPUT_TABLE` and `APP_WAREHOUSE` reference binding/removal.

---

## 3. Snow CLI Deployment (`snow app`)

- Updated `snowflake.yml` to define the app package, stage artifacts, and deployment targets for `snow app deploy` / `snow app run`.
- Deployment is now fully driven by `snow app deploy` from within `na_app_pkg/` — no manual stage uploads needed.
- JAR file (`encode-lib-*.jar`) is bundled via `src/lib/` directory; `snowflake.yml` includes it as a staged artifact.

---

## 4. Sandbox Deployment Guide Updates (`20260420_NativeApp_Test_Steps.md`)

- Updated Phase 3 to use `snow app deploy` / `snow app run` workflow (replacing prior manual stage-copy approach).
- Added Phase 3.1: pre-deployment step to copy the JAR into `na_app_pkg/src/lib/`.
- Added Phase 3.3: notes on consumer EAI approval at install time via Snowsight.
- Corrected `snow connection test` command to use `wl_sandbox_dcr`.
- Updated file reference table to include `07_eai_setup.sql`.

---

## 5. Test Data & UDF Tests

- Minor updates to `00_generate_test_data.sql` (added `$base_locid_secret` variable setup step for test data generation).
- Updated `01_load_test_data.sql` and `03_udf_test.sql` for consistency with current schema.

---

## Open Items (Carried Forward)

- `8.8.8.8` entry in `LOCID_BUILDS` — required for cross-compat Test 1; LocID to confirm V6 data availability.
- End-to-end Encrypt/Decrypt job test — pending JAR staged and `snow app run` install completion.
- Production key derivation — cross-compat test requires production keys from `central.locid.com`.
