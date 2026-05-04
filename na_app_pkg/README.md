# LocID for Snowflake — Native App

**Version:** 1.0

Enrich your IP + timestamp data with LocID location identifiers — TX_CLOC and STABLE_CLOC — entirely within your Snowflake account. No data leaves your environment.

---

## What This App Does

**Encrypt** — Provide a table of `(unique_id, ip_address, timestamp)` and the app returns TX_CLOC, STABLE_CLOC, and geo context columns appended to each row.

**Decrypt** — Provide a table of `(unique_id, tx_cloc)` and the app returns STABLE_CLOC and geo context columns.

Results are written to a new table in your app database. All processing happens inside your Snowflake account using LocID's shared data lake.

---

## Prerequisites

- Snowflake account (Business Critical edition recommended for SECRET object support)
- A valid LocID license key
- ACCOUNTADMIN role **or** a dedicated installer role with `CREATE APPLICATION` and `CREATE DATABASE` privileges (see Installation Role below)

---

## Installation Role

You can install this app as ACCOUNTADMIN, or use a dedicated least-privilege role. Using a custom role is recommended for teams and production environments.

Run the following **once** as ACCOUNTADMIN to create the installer role:

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS LOCID_APP_INSTALLER;

GRANT CREATE APPLICATION ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
GRANT CREATE DATABASE    ON ACCOUNT TO ROLE LOCID_APP_INSTALLER;
GRANT USAGE ON WAREHOUSE <your_warehouse> TO ROLE LOCID_APP_INSTALLER;

GRANT ROLE LOCID_APP_INSTALLER TO USER <your_username>;
```

After this one-time setup, all installation and day-to-day operations use `LOCID_APP_INSTALLER` — ACCOUNTADMIN is not needed again. If your account uses a standard role hierarchy, you can also grant the installer role to `SYSADMIN`:

```sql
GRANT ROLE LOCID_APP_INSTALLER TO ROLE SYSADMIN;
```

---

## Installation

1. Find **LocID for Snowflake** in the Snowflake Marketplace and click **Get**.
2. Choose the database name for the app (e.g. `LOCID_APP`).
3. Review and approve the **Required Permissions** shown during installation. The app requests access to `central.locid.com` for license validation and usage reporting.
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

- `APP_SCHEMA.APP_CONFIG` — License metadata and entitlements
- `APP_SCHEMA.JOB_LOG` — Audit trail of all Encrypt and Decrypt jobs
- `APP_SCHEMA.LOCID_ENCRYPT(...)` — Stored procedure for batch Encrypt
- `APP_SCHEMA.LOCID_DECRYPT(...)` — Stored procedure for batch Decrypt

---

## Data Privacy

- **Your data never leaves your Snowflake account.** Input tables, output tables, and intermediate results are all within your account.
- LocID's data lake is shared as **read-only** — no rows from your data are written to LocID's account.
- Your LocID license key is stored as a Snowflake `SECRET` object — it is never exposed in query results, logs, or the app UI.
- The only outbound call is to `central.locid.com` for license validation and job-level usage metrics (row counts and runtime — no record-level data).

---

## Required Grants (post-installation)

Before running a job, bind your input table reference via the Snowsight **App Permissions** screen or SQL. The role used must own the table or have `SELECT WITH GRANT OPTION`:

The input table can be in any database in your account — it does not need to be in the app database.

---

## Support

Contact LocID for:
- License key issues or entitlement changes
- Questions about TX_CLOC / STABLE_CLOC output
- App version upgrades
