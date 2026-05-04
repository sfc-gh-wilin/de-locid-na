"""
streamlit/views/sql_guide.py
LocID Native App — SQL Guide (View 6)

Step-by-step guide for running Encrypt and Decrypt jobs via SQL stored
procedures, for consumers who need to call the procedures from pipelines,
scheduled tasks, or notebooks instead of the Streamlit UI.
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

# ---------------------------------------------------------------------------
# App name helper (used to make the SQL examples concrete)
# ---------------------------------------------------------------------------
try:
    _app_name = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
except Exception:
    _app_name = "<app_database>"

st.title(":material/terminal: SQL Guide")
st.caption(
    "Run Encrypt and Decrypt jobs from SQL, Snowflake Tasks, or notebooks "
    "— without using the Streamlit UI."
)

# ---------------------------------------------------------------------------
# Role note
# ---------------------------------------------------------------------------
st.info(
    "**Required role:** Use the role that installed this app (e.g. `LOCID_APP_INSTALLER`). "
    "That role already has the `APP_ADMIN` application role granted automatically at install time.",
    icon="ℹ️",
)

st.divider()

# ---------------------------------------------------------------------------
# Step 1 — Bind the input tables
# ---------------------------------------------------------------------------
st.subheader("Step 1 — Bind the input tables")

tab_ui, tab_sql = st.tabs(["Snowsight UI (recommended)", "SQL (alternative)"])

with tab_ui:
    st.markdown(
        "1. In Snowsight, go to **Catalog → Apps → LocID for Snowflake**.\n"
        "2. Click the **Settings** (gear) icon in the top-right corner.\n"
        "3. Under **Object access privileges**, bind:\n"
        "   - **Input Table for Encrypt** → select your encrypt input table\n"
        "   - **Input Table for Decrypt** → select your decrypt input table\n"
        "4. Click **Save**.\n\n"
        "> If the permissions page appeared when the app was first launched, "
        "these bindings may already be set."
    )

with tab_sql:
    st.markdown(
        "When binding via SQL, you must first grant the app SELECT access on "
        "your input table(s). Run as the role that **owns** the table (or has "
        "`SELECT WITH GRANT OPTION`):"
    )
    st.code(
        f"-- For Encrypt jobs:\n"
        f"GRANT SELECT ON TABLE <your_db>.<your_schema>.<encrypt_input_table>\n"
        f"    TO APPLICATION {_app_name};\n\n"
        f"-- For Decrypt jobs:\n"
        f"GRANT SELECT ON TABLE <your_db>.<your_schema>.<decrypt_input_table>\n"
        f"    TO APPLICATION {_app_name};",
        language="sql",
    )
    st.markdown("Then bind each reference by calling the app's registration procedure:")
    st.code(
        f"-- Bind Encrypt input table:\n"
        f"CALL {_app_name}.APP_SCHEMA.register_single_callback(\n"
        f"    'ENCRYPT_INPUT_TABLE', 'ADD',\n"
        f"    '<your_db>.<your_schema>.<encrypt_input_table>'\n"
        f");\n\n"
        f"-- Bind Decrypt input table:\n"
        f"CALL {_app_name}.APP_SCHEMA.register_single_callback(\n"
        f"    'DECRYPT_INPUT_TABLE', 'ADD',\n"
        f"    '<your_db>.<your_schema>.<decrypt_input_table>'\n"
        f");",
        language="sql",
    )
    st.caption(
        "To unbind a reference, call `register_single_callback` with "
        "`'REMOVE'` instead of `'ADD'`."
    )

st.divider()

# ---------------------------------------------------------------------------
# Step 2 — Run Encrypt
# ---------------------------------------------------------------------------
st.subheader("Step 2 — Run an Encrypt job")
st.markdown(
    "Call `LOCID_ENCRYPT` with your column names and timestamp format. "
    "The procedure reads from the bound `ENCRYPT_INPUT_TABLE` reference."
)

with st.expander("Parameter reference", expanded=False):
    st.markdown(
        "| Parameter | Type | Description |\n"
        "|-----------|------|-------------|\n"
        "| `ID_COL` | VARCHAR | Column name for unique row identifier |\n"
        "| `IP_COL` | VARCHAR | Column name for the IP address |\n"
        "| `TS_COL` | VARCHAR | Column name for the timestamp |\n"
        "| `TS_FORMAT` | VARCHAR | `'epoch_sec'`, `'epoch_ms'`, or `'timestamp'` |\n"
        "| `OUTPUT_COLS` | ARRAY | Columns to include in output — see valid values below. "
        "Empty array `ARRAY_CONSTRUCT()` returns all entitled columns. |"
    )
    st.caption(
        "Use `'epoch_sec'` for Unix timestamps in seconds, `'epoch_ms'` for "
        "milliseconds, or `'timestamp'` for a `TIMESTAMP_NTZ` column."
    )
    st.markdown("**Valid `OUTPUT_COLS` values (Encrypt):**")
    st.code(
        "ARRAY_CONSTRUCT(\n"
        "    'tx_cloc',            -- TX_CLOC identifier  (requires allow_tx)\n"
        "    'stable_cloc',        -- STABLE_CLOC UUID    (requires allow_stable)\n"
        "    'locid_country',      -- Country name        (requires allow_geo_context)\n"
        "    'locid_country_code', -- ISO country code    (requires allow_geo_context)\n"
        "    'locid_region',       -- Region / state name (requires allow_geo_context)\n"
        "    'locid_region_code',  -- Region code         (requires allow_geo_context)\n"
        "    'locid_city',         -- City name           (requires allow_geo_context)\n"
        "    'locid_city_code',    -- City code           (requires allow_geo_context)\n"
        "    'locid_postal_code'   -- Postal / ZIP code   (requires allow_geo_context)\n"
        ")",
        language="sql",
    )
    st.caption(
        "Columns your license is not entitled to are silently excluded even if listed. "
        "Unrecognised column names are ignored."
    )

st.code(
    f"-- All entitled columns (recommended default):\n"
    f"CALL {_app_name}.APP_SCHEMA.LOCID_ENCRYPT(\n"
    f"    'MY_ID',           -- ID_COL:     your unique row identifier column\n"
    f"    'IP_ADDRESS',      -- IP_COL:     your IP address column\n"
    f"    'EVENT_TS',        -- TS_COL:     your timestamp column\n"
    f"    'epoch_sec',       -- TS_FORMAT:  epoch_sec | epoch_ms | timestamp\n"
    f"    ARRAY_CONSTRUCT()  -- OUTPUT_COLS: empty = all entitled columns\n"
    f");\n\n"
    f"-- Specific columns only (e.g. TX_CLOC + country):\n"
    f"CALL {_app_name}.APP_SCHEMA.LOCID_ENCRYPT(\n"
    f"    'MY_ID', 'IP_ADDRESS', 'EVENT_TS', 'epoch_sec',\n"
    f"    ARRAY_CONSTRUCT('tx_cloc', 'locid_country', 'locid_country_code')\n"
    f");",
    language="sql",
)

st.markdown("**Read the results:**")
st.code(
    "-- The procedure returns a VARIANT with job metadata:\n"
    "-- job_id, status, output_table, rows_in, rows_matched, runtime_s\n\n"
    "-- To query the output, use the output_table value from the result:\n"
    f"SELECT * FROM {_app_name}.APP_SCHEMA.LOCID_ENCRYPT_OUTPUT_<YYYYMMDD_HHMMSS>;\n\n"
    "-- Or capture the output table name dynamically:\n"
    "DECLARE\n"
    "    result VARIANT;\n"
    "    out_table VARCHAR;\n"
    "BEGIN\n"
    f"    CALL {_app_name}.APP_SCHEMA.LOCID_ENCRYPT(\n"
    "        'MY_ID', 'IP_ADDRESS', 'EVENT_TS', 'epoch_sec', ARRAY_CONSTRUCT()\n"
    "    ) INTO :result;\n"
    "    out_table := result:output_table::VARCHAR;\n"
    "    EXECUTE IMMEDIATE 'SELECT * FROM ' || :out_table;\n"
    "END;",
    language="sql",
)

st.divider()

# ---------------------------------------------------------------------------
# Step 3 — Run Decrypt
# ---------------------------------------------------------------------------
st.subheader("Step 3 — Run a Decrypt job")
st.markdown(
    "Call `LOCID_DECRYPT` with your column names. "
    "The procedure reads from the bound `DECRYPT_INPUT_TABLE` reference."
)

with st.expander("Parameter reference", expanded=False):
    st.markdown(
        "| Parameter | Type | Description |\n"
        "|-----------|------|-------------|\n"
        "| `ID_COL` | VARCHAR | Column name for unique row identifier |\n"
        "| `TXCLOC_COL` | VARCHAR | Column name for the TX_CLOC values |\n"
        "| `OUTPUT_COLS` | ARRAY | Columns to include in output — see valid values below. "
        "Empty array `ARRAY_CONSTRUCT()` returns all entitled columns. |"
    )
    st.markdown("**Valid `OUTPUT_COLS` values (Decrypt):**")
    st.code(
        "ARRAY_CONSTRUCT(\n"
        "    'stable_cloc'         -- STABLE_CLOC UUID (requires allow_stable)\n"
        "    -- Geo context columns are not available in v1 of the Decrypt path\n"
        ")",
        language="sql",
    )
    st.caption(
        "Columns your license is not entitled to are silently excluded even if listed. "
        "Unrecognised column names are ignored."
    )

st.code(
    f"-- All entitled columns (recommended default):\n"
    f"CALL {_app_name}.APP_SCHEMA.LOCID_DECRYPT(\n"
    f"    'MY_ID',           -- ID_COL:      your unique row identifier column\n"
    f"    'TX_CLOC',         -- TXCLOC_COL:  your TX_CLOC column\n"
    f"    ARRAY_CONSTRUCT()  -- OUTPUT_COLS: empty = all entitled columns\n"
    f");\n\n"
    f"-- STABLE_CLOC only:\n"
    f"CALL {_app_name}.APP_SCHEMA.LOCID_DECRYPT(\n"
    f"    'MY_ID', 'TX_CLOC',\n"
    f"    ARRAY_CONSTRUCT('stable_cloc')\n"
    f");",
    language="sql",
)

st.markdown("**Read the results:**")
st.code(
    "-- The procedure returns a VARIANT with job metadata:\n"
    "-- job_id, status, output_table, rows_in, rows_matched, rows_out, runtime_s\n\n"
    f"SELECT * FROM {_app_name}.APP_SCHEMA.LOCID_DECRYPT_OUTPUT_<YYYYMMDD_HHMMSS>;",
    language="sql",
)

st.divider()

# ---------------------------------------------------------------------------
# Step 4 — Check job history
# ---------------------------------------------------------------------------
st.subheader("Step 4 — Check job history")
st.markdown(
    "All job runs are recorded in the `JOB_LOG` table. "
    "Use it to audit results or find the output table name from a previous run:"
)
st.code(
    f"SELECT\n"
    f"    job_id,\n"
    f"    operation,\n"
    f"    run_dt,\n"
    f"    rows_in,\n"
    f"    rows_matched,\n"
    f"    rows_out,\n"
    f"    runtime_s,\n"
    f"    status,\n"
    f"    output_table\n"
    f"FROM {_app_name}.APP_SCHEMA.JOB_LOG\n"
    f"ORDER BY run_dt DESC\n"
    f"LIMIT 20;",
    language="sql",
)

st.divider()

# ---------------------------------------------------------------------------
# Using in a Snowflake Task (automation)
# ---------------------------------------------------------------------------
st.subheader("Using in a Snowflake Task (automation)")
st.markdown(
    "To schedule Encrypt jobs to run automatically, wrap the `CALL` in a "
    "Snowflake Task. Create the task in your own database (not the app database):"
)
st.code(
    "CREATE OR REPLACE TASK MY_DB.MY_SCHEMA.LOCID_ENCRYPT_DAILY\n"
    "    WAREHOUSE = <your_warehouse>\n"
    "    SCHEDULE  = 'USING CRON 0 2 * * * UTC'  -- daily at 02:00 UTC\n"
    "AS\n"
    f"    CALL {_app_name}.APP_SCHEMA.LOCID_ENCRYPT(\n"
    "        'MY_ID', 'IP_ADDRESS', 'EVENT_TS', 'epoch_sec', ARRAY_CONSTRUCT()\n"
    "    );\n\n"
    "-- Activate the task:\n"
    "ALTER TASK MY_DB.MY_SCHEMA.LOCID_ENCRYPT_DAILY RESUME;",
    language="sql",
)
st.caption(
    "The role owning the task must have been granted "
    f"`APPLICATION ROLE {_app_name}.APP_ADMIN`."
)
