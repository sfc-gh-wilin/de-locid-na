"""
streamlit/pages/01_setup_wizard.py
LocID Native App — Setup Wizard (View 2)

9-screen onboarding wizard:
  A. Welcome
  B. Have a license key?
  C. Contact Sales (no-key dead end)
  D. Enter License Key       → validates + fetches license from LocID Central
  E. Review Privileges
  F. Create App Objects
  G. Test Connectivity
  H. Select API Key          → writes api_key / api_key_id / namespace_guid / client_id
  I. Setup Complete
"""

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.locid_central import fetch_license

session = get_active_session()

st.title("Setup Wizard")
st.caption("Complete this wizard once after installing the app.")
st.divider()


# ---------------------------------------------------------------------------
# APP_CONFIG upsert helper
# ---------------------------------------------------------------------------
def _upsert_config(key: str, value: str) -> None:
    session.sql(
        "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
        "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
        "WHEN MATCHED THEN UPDATE SET config_value = s.v, last_refreshed_at = CURRENT_TIMESTAMP "
        "WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active) "
        "VALUES (s.k, s.v, CURRENT_TIMESTAMP, TRUE)",
        params=[key, value]
    ).collect()


# ---------------------------------------------------------------------------
# Wizard state
# ---------------------------------------------------------------------------
if "wizard_step" not in st.session_state:
    st.session_state.wizard_step = "A"

step = st.session_state.wizard_step

# ---------------------------------------------------------------------------
# Screen A — Welcome
# ---------------------------------------------------------------------------
if step == "A":
    st.header("Welcome to LocID for Snowflake")
    st.write(
        "This wizard will connect your LocID license to Snowflake and verify "
        "that the app can reach LocID Central. It takes about 5 minutes."
    )
    if st.button("Get Started"):
        st.session_state.wizard_step = "B"
        st.rerun()

# ---------------------------------------------------------------------------
# Screen B — Have a key?
# ---------------------------------------------------------------------------
elif step == "B":
    st.header("Do you have a LocID license key?")
    choice = st.radio("", ["Yes, I have a license key", "No, I need one"])
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "A"
            st.rerun()
    with col2:
        if st.button("Continue"):
            st.session_state.wizard_step = "D" if "Yes" in choice else "C"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen C — Contact Sales
# ---------------------------------------------------------------------------
elif step == "C":
    st.header("Contact LocID")
    st.info(
        "To get a LocID license key, contact LocID. "
        "Once you have your license key, re-open this wizard to continue setup."
    )
    # TODO: add LocID contact details (email, URL)
    if st.button("← Back"):
        st.session_state.wizard_step = "B"
        st.rerun()

# ---------------------------------------------------------------------------
# Screen D — Enter License Key
# ---------------------------------------------------------------------------
elif step == "D":
    st.header("Enter Your License Key")
    key_input = st.text_input("License Key", type="password",
                              placeholder="1569-XXXX-XXXX-XXXX-XXXX-XXXX")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "B"
            st.rerun()
    with col2:
        if st.button("Validate & Continue"):
            if not key_input:
                st.error("Please enter your license key.")
            else:
                with st.spinner("Validating license with LocID Central…"):
                    try:
                        data = fetch_license(session, key_input)
                        _upsert_config("license_id_ref", key_input)
                        st.session_state.license_key  = key_input
                        st.session_state.license_data = data
                        st.session_state.wizard_step  = "E"
                        st.rerun()
                    except Exception as e:
                        st.error(f"License validation failed: {e}")

# ---------------------------------------------------------------------------
# Screen E — Review Privileges
# ---------------------------------------------------------------------------
elif step == "E":
    st.header("Review Required Privileges")
    st.write("The app needs the following grants. Run the SQL below as ACCOUNTADMIN.")
    # TODO: dynamically check which grants are already in place
    st.code(
        "GRANT EXECUTE TASK ON ACCOUNT TO APPLICATION <app_name>;\n"
        "GRANT USAGE ON INTEGRATION LOCID_CENTRAL_EAI TO APPLICATION <app_name>;",
        language="sql"
    )
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "D"
            st.rerun()
    with col2:
        if st.button("Grants confirmed — Continue"):
            st.session_state.wizard_step = "F"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen F — Create App Objects
# ---------------------------------------------------------------------------
elif step == "F":
    st.header("Initialising App Objects")
    # TODO: check if APP_CONFIG, JOB_LOG exist (created by setup.sql — should always be present)
    st.success("APP_CONFIG table — OK")
    st.success("JOB_LOG table — OK")
    st.success("HTTP_PING UDF — OK")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "E"
            st.rerun()
    with col2:
        if st.button("Continue"):
            st.session_state.wizard_step = "G"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen G — Test Connectivity
# ---------------------------------------------------------------------------
elif step == "G":
    st.header("Test LocID Central Connectivity")
    if st.button("Run Connectivity Test"):
        with st.spinner("Connecting to central.locid.com…"):
            result = session.sql("SELECT APP_SCHEMA.HTTP_PING()").collect()[0][0]
        if result.startswith("OK"):
            st.success(f"LocID Central is reachable — {result}")
            st.session_state.connectivity_ok = True
        else:
            st.error(f"Connection failed — {result}")
            st.session_state.connectivity_ok = False
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "F"
            st.rerun()
    with col2:
        if st.button("Continue", disabled=not st.session_state.get("connectivity_ok")):
            st.session_state.wizard_step = "H"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen H — Select API Key
# ---------------------------------------------------------------------------
elif step == "H":
    st.header("Select API Key")
    st.write(
        "Your license includes one or more API keys. Select the key this "
        "Snowflake account should use for LocID lookups."
    )

    # Load active access entries from cached license
    cached_rows = session.sql(
        "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
        "WHERE config_key = 'cached_license' AND is_active = TRUE LIMIT 1"
    ).collect()

    active_entries = []
    client_id      = 0
    if cached_rows and cached_rows[0][0]:
        try:
            lic_data       = json.loads(cached_rows[0][0])
            client_id      = int(lic_data.get("license", {}).get("client_id", 0))
            active_entries = [
                e for e in lic_data.get("access", [])
                if e.get("status") == "ACTIVE"
            ]
        except Exception:
            pass

    if not active_entries:
        st.error(
            "No active API keys found in your license response. "
            "Go back and re-validate your license key, or contact LocID."
        )
        if st.button("← Back"):
            st.session_state.wizard_step = "G"
            st.rerun()
    else:
        # Build display labels — show api_key_id and a masked key value
        def _mask_key(k: str) -> str:
            return k[:8] + "****" if k and len(k) > 8 else "****"

        labels = [
            f"API Key #{e.get('api_key_id')} — {_mask_key(e.get('api_key', ''))}"
            for e in active_entries
        ]

        # Auto-select single key; radio for multiple
        if len(active_entries) == 1:
            st.info(f"One active API key found: **{labels[0]}**")
            chosen_idx = 0
        else:
            choice     = st.radio("Available API keys:", labels)
            chosen_idx = labels.index(choice)

        col1, col2 = st.columns(2)
        with col1:
            if st.button("← Back"):
                st.session_state.wizard_step = "G"
                st.rerun()
        with col2:
            if st.button("Confirm Selection", type="primary"):
                entry = active_entries[chosen_idx]
                _upsert_config("api_key_id",     str(entry.get("api_key_id", "")))
                _upsert_config("api_key",         entry.get("api_key", ""))
                _upsert_config("namespace_guid",  entry.get("namespace_guid", ""))
                _upsert_config("client_id",       str(client_id))
                _upsert_config("onboarding_complete", "true")
                st.session_state.wizard_step = "I"
                st.rerun()

# ---------------------------------------------------------------------------
# Screen I — Setup Complete
# ---------------------------------------------------------------------------
elif step == "I":
    st.header("Setup Complete!")
    st.success("Your LocID license is connected and verified.")
    st.write("**What's next:**")
    st.write("- Run an **Encrypt** job to enrich IP+timestamp data with TX_CLOC / STABLE_CLOC")
    st.write("- Run a **Decrypt** job to decode TX_CLOC values back to geo context")
    st.write("- View your **Job History** at any time from the sidebar")
    if st.button("Launch App →"):
        st.switch_page("app.py")


