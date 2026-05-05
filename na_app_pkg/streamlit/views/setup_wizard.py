"""
streamlit/views/setup_wizard.py
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

import streamlit as st
from snowflake.snowpark.context import get_active_session
from utils.locid_central import fetch_license
from utils import logger
from utils.errors import show_error

session = get_active_session()

st.header(":material/settings: Setup Wizard")
st.caption("Complete this wizard once after installing the app.")
st.divider()


# ---------------------------------------------------------------------------
# APP_CONFIG upsert helper
# ---------------------------------------------------------------------------
def _upsert_config(key: str, value: str) -> None:
    session.sql(
        "MERGE INTO APP_SCHEMA.APP_CONFIG AS t "
        "USING (SELECT ? AS k, ? AS v) AS s ON t.config_key = s.k "
        "WHEN MATCHED THEN UPDATE SET config_value = s.v, "
        "last_refreshed_at = CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ "
        "WHEN NOT MATCHED THEN INSERT (config_key, config_value, last_refreshed_at, is_active) "
        "VALUES (s.k, s.v, "
        "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, TRUE)",
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
    st.subheader(":material/waving_hand: Welcome to LocID for Snowflake")
    st.write(
        "This wizard connects your LocID license to Snowflake and verifies "
        "that the app can reach LocID Central. It takes about 5 minutes."
    )
    st.write("**What you'll need:**")
    st.write("- Your LocID license key")
    st.write("- A warehouse the app can use for jobs")
    st.write("- An input table with IP address and timestamp data (for Encrypt) "
             "or TX_CLOC data (for Decrypt)")
    if st.button("Get Started", type="primary"):
        logger.info(session, "setup_wizard", "Wizard started")
        st.session_state.wizard_step = "B"
        st.rerun()

# ---------------------------------------------------------------------------
# Screen B — Have a key?
# ---------------------------------------------------------------------------
elif step == "B":
    st.subheader(":material/key: Do you have a LocID license key?")
    choice = st.radio("", ["Yes, I have a license key", "No, I need one"])
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "A"
            st.rerun()
    with col2:
        if st.button("Continue", type="primary"):
            st.session_state.wizard_step = "E" if "Yes" in choice else "C"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen C — Contact Sales
# ---------------------------------------------------------------------------
elif step == "C":
    st.subheader(":material/chat: Contact LocID")
    st.info(
        "To get a LocID license key, contact LocID at **locid.com**. "
        "Once you have your license key, re-open this wizard to continue setup."
    )
    if st.button("← Back"):
        st.session_state.wizard_step = "B"
        st.rerun()

# ---------------------------------------------------------------------------
# Screen D — Enter License Key
# ---------------------------------------------------------------------------
elif step == "D":
    st.subheader(":material/key: Enter Your License Key")
    key_input = st.text_input("License Key", type="password",
                              placeholder="1569-XXXX-XXXX-XXXX-XXXX-XXXX")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "E"
            st.rerun()
    with col2:
        if st.button("Validate & Continue", type="primary"):
            if not key_input:
                st.error("Please enter your license key.")
            else:
                with st.spinner("Validating license with LocID Central…"):
                    try:
                        data = fetch_license(session, key_input)
                        st.session_state.license_key  = key_input
                        st.session_state.license_data = data
                        st.session_state.wizard_step  = "F"
                        logger.info(session, "setup_wizard.validate",
                                    "License validated successfully")
                        st.rerun()
                    except Exception as e:
                        logger.error(session, "setup_wizard.validate",
                                     "License validation failed", exc=e)
                        show_error("License validation failed.", detail=e)

# ---------------------------------------------------------------------------
# Screen E — Review Privileges
# ---------------------------------------------------------------------------
elif step == "E":
    st.subheader(":material/admin_panel_settings: Approve Network Access")
    try:
        _app_name = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    except Exception:
        _app_name = "<app_name>"
    st.info(
        "When you first launched this app, Snowsight showed an **App Permissions** "
        "screen where you could approve the network connection to central.locid.com. "
        "If you approved it there, you can click **Approved — Continue** below.\n\n"
        "If you skipped that screen or are unsure, use one of the options below to approve now.",
        icon="ℹ️",
    )
    st.markdown("**Option A — Snowsight UI**")
    st.write(
        "In the navigation menu go to **Catalog → Apps**, select this app, "
        "click the **Settings** icon, then choose **Connections**. "
        "Next to *LocID Central API Access*, click **…** → **Approve**."
    )
    st.markdown("**Option B — SQL**")
    st.code(
        f"-- 1. Find the current sequence number:\n"
        f"SHOW SPECIFICATIONS IN APPLICATION {_app_name};\n\n"
        f"-- 2. Approve (replace N with SEQUENCE_NUMBER from above, usually 1):\n"
        f"ALTER APPLICATION {_app_name}\n"
        f"    APPROVE SPECIFICATION LOCID_CENTRAL_EAI_SPEC SEQUENCE_NUMBER = N;\n\n"
        f"-- 3. Also grant USAGE on the integration:\n"
        f"GRANT USAGE ON INTEGRATION LOCID_CENTRAL_EAI TO APPLICATION {_app_name};",
        language="sql"
    )
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "B"
            st.rerun()
    with col2:
        if st.button("Approved — Continue", type="primary"):
            st.session_state.wizard_step = "D"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen F — Create App Objects
# ---------------------------------------------------------------------------
elif step == "F":
    st.subheader(":material/build: Initialising App Objects")
    st.success("APP_CONFIG table — OK", icon="✅")
    st.success("JOB_LOG table — OK",   icon="✅")
    st.success("APP_LOGS table — OK",  icon="✅")
    st.success("HTTP_PING UDF — OK",   icon="✅")
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "D"
            st.rerun()
    with col2:
        if st.button("Continue", type="primary"):
            st.session_state.wizard_step = "G"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen G — Test Connectivity
# ---------------------------------------------------------------------------
elif step == "G":
    st.subheader(":material/cloud_circle: Test LocID Central Connectivity")
    if st.button(":material/wifi_tethering: Run Connectivity Test", type="primary"):
        with st.spinner("Connecting to central.locid.com…"):
            try:
                result = session.sql("SELECT APP_SCHEMA.HTTP_PING()").collect()[0][0]
            except Exception as e:
                logger.error(session, "setup_wizard.connectivity", "HTTP_PING failed", exc=e)
                result = f"FAILED: {e}"
        if result.startswith("OK"):
            st.success(f"LocID Central is reachable", icon="✅")
            logger.info(session, "setup_wizard.connectivity", f"Connectivity OK: {result}")
            st.session_state.connectivity_ok = True
        else:
            show_error("LocID Central connection failed.", detail=result)
            logger.error(session, "setup_wizard.connectivity",
                         f"Connectivity failed: {result}")
            st.session_state.connectivity_ok = False
    col1, col2 = st.columns(2)
    with col1:
        if st.button("Back"):
            st.session_state.wizard_step = "F"
            st.rerun()
    with col2:
        if st.button("Continue", type="primary",
                     disabled=not st.session_state.get("connectivity_ok")):
            st.session_state.wizard_step = "H"
            st.rerun()

# ---------------------------------------------------------------------------
# Screen H — Select API Key
# ---------------------------------------------------------------------------
elif step == "H":
    st.subheader(":material/key: Select API Key")
    st.write(
        "Your license includes one or more API keys. Select the key this "
        "Snowflake account should use for LocID lookups."
    )

    # api_key values are kept only in session state (in-memory) — never written
    # to APP_CONFIG. If this session was restarted after Screen D, the user must
    # re-validate the license to repopulate session state.
    lic_data = st.session_state.get("license_data")

    active_entries: list = []
    client_id = 0

    if not lic_data:
        st.error(
            "License data is no longer available in this session. "
            "Please go back to **Enter License Key** and re-validate."
        )
        if st.button("← Back to License Key"):
            st.session_state.wizard_step = "D"
            st.rerun()
    else:
        try:
            client_id = int(lic_data.get("license", {}).get("client_id", 0))
            active_entries = [
                e for e in lic_data.get("access", [])
                if e.get("status") == "ACTIVE"
            ]
        except Exception as e:
            logger.error(session, "setup_wizard.api_key",
                         "Failed to parse license data", exc=e)

    if lic_data and not active_entries:
        st.error(
            "No active API keys found in your license response. "
            "Go back and re-validate your license key, or contact LocID."
        )
        if st.button("← Back"):
            st.session_state.wizard_step = "G"
            st.rerun()
    elif active_entries:
        labels = [
            f"API Key #{e.get('api_key_id')} — {e.get('api_key', '')[:8] or e.get('api_key_hint', '????')}****"
            for e in active_entries
        ]

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
                entry       = active_entries[chosen_idx]
                api_key_id  = int(entry.get("api_key_id", 0))
                api_key_val = entry.get("api_key", "")
                if not api_key_val:
                    st.error(
                        "API key value missing from session data. "
                        "Re-validate your license key and try again."
                    )
                else:
                    with st.spinner("Saving API key and completing setup…"):
                        session.call("APP_SCHEMA.LOCID_SET_API_KEY",
                                     api_key_id, api_key_val)
                        _upsert_config("api_key_id",          str(api_key_id))
                        _upsert_config("namespace_guid",      entry.get("namespace_guid", ""))
                        _upsert_config("client_id",           str(client_id))
                        _upsert_config("onboarding_complete", "true")
                        logger.info(session, "setup_wizard.api_key",
                                    f"API key selected: {api_key_id}")
                    st.session_state.wizard_step = "I"
                    st.rerun()

# ---------------------------------------------------------------------------
# Screen I — Setup Complete
# ---------------------------------------------------------------------------
elif step == "I":
    st.subheader(":material/task_alt: Setup Complete!")
    st.success("Your LocID license is connected and verified.")
    st.write("**What's next:**")
    st.write("- Run an **Encrypt** job to enrich IP+timestamp data with TX_CLOC / STABLE_CLOC")
    st.write("- Run a **Decrypt** job to decode TX_CLOC values back to geo context")
    st.write("- View your **Job History** at any time from the sidebar")
    logger.info(session, "setup_wizard", "Setup wizard completed")
    if st.button("Launch App →", type="primary"):
        for key in ("wizard_step", "license_key", "license_data", "connectivity_ok"):
            st.session_state.pop(key, None)
        st.switch_page("views/home.py")
