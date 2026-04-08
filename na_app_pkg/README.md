# Native App Package

This folder will contain the Snowflake Native App package artifacts (Delivery Plan Phase 1, Step 2).

## Planned Structure

```
na_app_pkg/
├── manifest.yml              # App manifest: privileges, references, artifacts
├── setup.sql                 # Setup script: schemas, objects, grants
├── scripts/
│   └── setup/
│       └── setup.sql
├── src/
│   ├── procs/
│   │   ├── encrypt.sql       # Encrypt stored procedure
│   │   └── decrypt.sql       # Decrypt stored procedure
│   ├── udfs/
│   │   └── locid_udf.sql     # Scala UDF definitions wrapping encode-lib JAR
│   └── lib/
│       └── encode-lib-*.jar  # Bundled Scala JAR (stage artifact)
└── streamlit/
    ├── app.py                # Main Streamlit entry point
    ├── pages/
    │   ├── 01_setup_wizard.py
    │   ├── 02_run_encrypt.py
    │   ├── 03_run_decrypt.py
    │   ├── 04_job_history.py
    │   └── 05_configuration.py
    └── utils/
        ├── locid_central.py  # LocID Central API calls (via EAI)
        └── entitlements.py   # Entitlement check helpers
```
