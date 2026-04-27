"""
streamlit/app.py
LocID Native App — Navigation Controller

Entry point: configures layout, logo, and page routing.
All page content lives in views/.
"""
import streamlit as st

st.set_page_config(page_title="LocID for Snowflake", layout="wide")
st.logo("logo.svg")

pg = st.navigation({
    " ": [
        st.Page("views/home.py",          title="Home",          icon="📊", default=True),
    ],
    "Setup": [
        st.Page("views/setup_wizard.py",  title="Setup Wizard",  icon="✨"),
    ],
    "Jobs": [
        st.Page("views/run_encrypt.py",   title="Run Encrypt",   icon="🔒"),
        st.Page("views/run_decrypt.py",   title="Run Decrypt",   icon="🔓"),
        st.Page("views/job_history.py",   title="Job History",   icon="🕐"),
    ],
    "Settings": [
        st.Page("views/configuration.py", title="Configuration", icon="⚙️"),
    ],
})
pg.run()
