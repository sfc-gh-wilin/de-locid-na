"""
streamlit/utils/logger.py
LocID Native App — Application logger

Writes structured entries to APP_SCHEMA.APP_LOGS.
All functions are non-blocking — a logging failure never raises or surfaces
to the user.

Usage:
    from utils import logger
    logger.info(session,  "02_run_encrypt.run_job",  "Job started")
    logger.error(session, "02_run_encrypt.run_job",  "Job failed", exc=e)
"""

import traceback
from typing import Optional

import snowflake.snowpark as snowpark

_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "TRACE"}

_INSERT_SQL = (
    "INSERT INTO APP_SCHEMA.APP_LOGS "
    "(level, source, logged_at, session_id, message, traceback) "
    "VALUES (?, ?, "
    "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, "
    "CURRENT_SESSION()::VARCHAR, ?, ?)"
)


def _log(
    session: snowpark.Session,
    level: str,
    source: str,
    message: str,
    exc: Optional[BaseException] = None,
) -> None:
    """Insert one log row into APP_SCHEMA.APP_LOGS. Never raises."""
    level = level.upper() if level.upper() in _LEVELS else "INFO"
    tb = (
        "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        if exc else None
    )
    try:
        session.sql(_INSERT_SQL, params=[level, source, message, tb]).collect()
    except Exception:
        pass  # logging must never fail the caller


def debug(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "DEBUG", source, message)


def info(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "INFO", source, message)


def warning(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "WARNING", source, message)


def error(
    session: snowpark.Session,
    source: str,
    message: str,
    exc: Optional[BaseException] = None,
) -> None:
    _log(session, "ERROR", source, message, exc)


def trace(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "TRACE", source, message)
