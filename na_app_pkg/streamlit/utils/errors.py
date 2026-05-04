"""
streamlit/utils/errors.py
LocID Native App — Friendly error display helper

Usage:
    from utils.errors import show_error

    show_error("Job failed unexpectedly.", detail=e)
    show_error("License validation failed.", detail=e)
    show_error("Simple message with no detail.")
"""

from typing import Optional

import streamlit as st


def show_error(summary: str, detail: Optional[object] = None, icon: str = "❌") -> None:
    """Display a user-friendly error message with an optional expandable detail panel.

    Args:
        summary: Short, human-readable description shown prominently.
        detail:  Full error or traceback (exception or string). Hidden in an
                 expander so power users can inspect it without overwhelming
                 everyone else.
        icon:    Streamlit icon string (default "❌").
    """
    st.error(summary, icon=icon)
    if detail is not None:
        with st.expander("Error details"):
            st.code(str(detail), language=None)
