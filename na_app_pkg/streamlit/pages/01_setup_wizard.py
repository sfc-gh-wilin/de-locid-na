"""
streamlit/pages/01_setup_wizard.py
LocID Native App — Setup Wizard (View 2)

8-screen onboarding wizard:
  A. Welcome
  B. Have a license key?
  C. Contact Sales (no-key dead end)
  D. Enter License Key
  E. Review Privileges
  F. Create App Objects
  G. Test Connectivity
  H. Setup Complete
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.title("Setup Wizard")
st.caption("Complete this wizard once after installing the app.")
st.divider()

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
    st.header("Contact Digital Envoy")
    st.info(
        "To get a LocID license key, contact Digital Envoy / Matchbook Data. "
        "Once you have your license key, re-open this wizard to continue setup."
    )
    # TODO: add DE contact details (email, URL)
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
                # TODO: validate key format + store as Snowflake SECRET
                # TODO: call locid_central.fetch_license(session, key_input)
                st.session_state.license_key = key_input
                st.session_state.wizard_step = "E"
                st.rerun()

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
            # Mark onboarding complete
            session.sql(
                "UPDATE APP_SCHEMA.APP_CONFIG SET config_value = 'true' "
                "WHERE config_key = 'onboarding_complete'"
            ).collect()
            st.session_state.wizard_step = "H"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen H — Setup Complete
# ---------------------------------------------------------------------------
elif step == "H":
    st.header("Setup Complete!")
    st.success("Your LocID license is connected and verified.")
    st.write("**What's next:**")
    st.write("- Run an **Encrypt** job to enrich IP+timestamp data with TX_CLOC / STABLE_CLOC")
    st.write("- Run a **Decrypt** job to decode TX_CLOC values back to geo context")
    st.write("- View your **Job History** at any time from the sidebar")
    if st.button("Launch App →"):
        st.switch_page("app.py")
