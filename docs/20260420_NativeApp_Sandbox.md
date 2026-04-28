# LocID Native App — Sandbox

## Repository

```bash
brew update && brew upgrade snowflake-cli

cd /Users/wilin/Docs/LocalProjects/GitHub/de-locid-na

snow connection test -c wl_sandbox_dcr
```

## Phase 0 — Role Setup (one-time, ACCOUNTADMIN)

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/00_roles.sql"
```

```bash
snow sql --connection wl_sandbox_dcr -q "SHOW ROLES LIKE 'LOCID_APP_%'"
```

## Phase 1 — Provider Setup

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/01_setup.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/02_locid_build_dates.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/03_locid_builds.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/04_locid_builds_ipv4_exploded.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/05_stage_setup.sql"
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/06_udfs.sql"
```

## Phase 2 — Load Test Data

Set `$base_locid_secret` at the top, then run:

```bash
snow sql --connection wl_sandbox_dcr -f "db/dev/provider_tests/00_generate_test_data.sql"
```

## Phase 3 — Deploy Native App

### 3.1 Pre-requisite — copy encode-lib JAR into `src/lib/`

```bash
ls na_app_pkg/src/lib/
# encode-lib-2.1.5-feature-OLDE-275-scala-2.13-build-SNAPSHOT.jar
```

### 3.2 Deploy app package (Snow CLI)

```bash
cd na_app_pkg
snow app deploy --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

```bash
snow stage list-files @LOCID_DEV_PKG.APP_SCHEMA.APP_STAGE \
    --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
# Expected: setup.sql, manifest.yml, README.md, lib/encode-lib-*.jar,
#           src/udfs/locid_udf.sql, src/procs/encrypt.sql, src/procs/decrypt.sql,
#           streamlit/app.py, streamlit/pages/*.py, streamlit/utils/*.py
```

### 3.3 Share provider data into app package

```bash
cd /Users/wilin/Docs/LocalProjects/GitHub/de-locid-na
snow sql --connection wl_sandbox_dcr -f "db/dev/provider/08_share_to_pkg.sql"
```

```bash
snow sql --connection wl_sandbox_dcr --role LOCID_APP_ADMIN \
    -q "SHOW VIEWS IN SCHEMA LOCID_DEV_PKG.LOCID_SHARE"
# Expected: 3 views — LOCID_BUILDS, LOCID_BUILDS_IPV4_EXPLODED, LOCID_BUILD_DATES
```

### 3.4 Approve external access at install time

`setup.sql` creates `LOCID_CENTRAL_EAI` in the consumer account during installation
(using the `CREATE EXTERNAL ACCESS INTEGRATION` privilege declared in `manifest.yml`).
No manual SQL is needed.

When `snow app run` installs the app, Snowflake will prompt for approval of the
`CREATE EXTERNAL ACCESS INTEGRATION` privilege. In Snowsight, this appears as a
permission dialog during app configuration. Approve it to enable outbound HTTPS to
`central.locid.com`.

### 3.5 Create app version

```bash
cd na_app_pkg
snow app version create v1_0 --force --skip-git-check --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

### 3.6 Install the application

```bash
cd na_app_pkg
snow app run --version v1_0 --connection wl_sandbox_dcr --role LOCID_APP_ADMIN
```

### 3.7 Bind references

Streamlit setup wizard.

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
