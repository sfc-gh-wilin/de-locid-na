# LocID for Snowflake — Native App

**Provider:** LocID  
**Version:** 1.0

Enrich your IP + timestamp data with LocID location identifiers — TX_CLOC and STABLE_CLOC — entirely within your Snowflake account. No data leaves your environment.

---

## What This App Does

| Operation | You Provide | App Returns |
|-----------|-------------|-------------|
| **Encrypt** | Table of `(unique_id, ip_address, timestamp)` | TX_CLOC, STABLE_CLOC, geo context |
| **Decrypt** | Table of `(unique_id, tx_cloc)` | STABLE_CLOC, geo context |

Results are written to a table you specify. All processing happens inside your Snowflake account using LocID's shared LocID data lake.

---

## Prerequisites

- Snowflake account (Business Critical edition recommended for SECRET object support)
- A valid LocID license key from LocID
- ACCOUNTADMIN role (required to approve permissions during installation)
- A warehouse the app can use to run enrichment jobs

---

## Installation

1. Find **LocID for Snowflake** in the Snowflake Marketplace and click **Get**.
2. Choose the database name for the app (e.g. `LOCID_APP`).
3. Review and approve the **Required Permissions** shown during installation:

   | Permission | Why |
   |-----------|-----|
   | External access to `central.locid.com` | Required for license validation and usage reporting |

4. Click **Activate**.

---

## First-Time Setup

After installation, open the app and complete the **Setup Wizard**:

```
Welcome → Have a license key? → Enter License Key
  → Review Privileges → Create App Objects
    → Test Connectivity → Setup Complete
```

The wizard takes approximately 5 minutes and only needs to be run once.  
It can be re-accessed from the **Configuration** view if you need to update your credentials.

---

## Running Your First Job

### Encrypt (IP + timestamp → TX_CLOC / STABLE_CLOC)

1. Open **Run Encrypt** from the sidebar.
2. Select your input table (must contain `ip_address` and `timestamp` columns).
3. Map your columns and choose an output table.
4. Select the output columns you are entitled to.
5. Click **Run Job**.

### Decrypt (TX_CLOC → STABLE_CLOC + geo context)

1. Open **Run Decrypt** from the sidebar.
2. Select your input table (must contain a `tx_cloc` column).
3. Map your columns and choose an output table.
4. Click **Run Job**.

---

## App Objects Created at Install

The following objects are created in your app database:

| Object | Type | Purpose |
|--------|------|---------|
| `APP_SCHEMA.APP_CONFIG` | Table | License metadata, entitlements, output column registry |
| `APP_SCHEMA.JOB_LOG` | Table | Full audit trail of all Encrypt and Decrypt jobs |
| `APP_SCHEMA.HTTP_PING()` | UDF | Connectivity test used by the Setup Wizard |
| `APP_SCHEMA.LOCID_ENCRYPT(...)` | Stored Procedure | Batch Encrypt workflow |
| `APP_SCHEMA.LOCID_DECRYPT(...)` | Stored Procedure | Batch Decrypt workflow |

---

## Data Privacy

- **Your data never leaves your Snowflake account.** Input tables, output tables, and intermediate results are all within your account.
- LocID's data lake is shared as **read-only** — no rows from your data are written to LocID's account.
- Your LocID license key is stored as a Snowflake `SECRET` object — it is never exposed in query results, logs, or the app UI.
- The only outbound call is to `central.locid.com` for license validation and job-level usage metrics (row counts and runtime — no record-level data).

---

## Required Grants (post-installation)

After installing the app, grant the app SELECT access to any table you want to use as input:

```sql
GRANT SELECT ON TABLE <your_db>.<your_schema>.<your_table>
    TO APPLICATION <app_name>;
```

Grant the app USAGE on the warehouse you want it to use:

```sql
GRANT USAGE ON WAREHOUSE <your_warehouse>
    TO APPLICATION <app_name>;
```

---

## Support

Contact LocID for:
- License key issues or entitlement changes
- Questions about TX_CLOC / STABLE_CLOC output
- App version upgrades

---

## Package Structure (for reference)

```
na_app_pkg/
├── manifest.yml              # App manifest: privileges, EAI, artifacts
├── setup.sql                 # Setup script: schemas, tables, UDF, network rule
├── src/
│   ├── udfs/
│   │   └── locid_udf.sql     # Scala UDFs wrapping encode-lib JAR
│   ├── procs/
│   │   ├── encrypt.sql       # Encrypt stored procedure
│   │   └── decrypt.sql       # Decrypt stored procedure
│   └── lib/
│       └── encode-lib-*.jar  # Bundled Scala JAR
└── streamlit/
    ├── app.py                # Home dashboard
    ├── pages/
    │   ├── 01_setup_wizard.py
    │   ├── 02_run_encrypt.py
    │   ├── 03_run_decrypt.py
    │   ├── 04_job_history.py
    │   └── 05_configuration.py
    └── utils/
        ├── locid_central.py  # LocID Central API client
        └── entitlements.py   # Entitlement helpers
```


