"""
streamlit/Home.py
LocID Native App — navigation entry point

Sets page config and logo, then defines the multi-page app via st.navigation().
All view content lives in streamlit/views/.
Requires Streamlit 1.36+ (bundled via environment.yml: streamlit=1.42.0).
"""

import streamlit as st

st.set_page_config(page_title="LocID for Snowflake", layout="wide")
st.logo("logo.svg")

pg = st.navigation([
    st.Page("views/home.py",          title="Home",          icon=":material/home:"),
    st.Page("views/setup_wizard.py",  title="Setup Wizard",  icon=":material/settings:"),
    st.Page("views/run_encrypt.py",   title="Run Encrypt",   icon=":material/lock:"),
    st.Page("views/run_decrypt.py",   title="Run Decrypt",   icon=":material/lock_open:"),
    st.Page("views/job_history.py",   title="Job History",   icon=":material/history:"),
    st.Page("views/configuration.py", title="Configuration", icon=":material/tune:"),
])
pg.run()
