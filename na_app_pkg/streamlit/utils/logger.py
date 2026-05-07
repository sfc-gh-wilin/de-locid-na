"""
streamlit/utils/logger.py
LocID Native App — Application logger

Writes structured entries to APP_SCHEMA.APP_LOGS.
All functions are non-blocking — a logging failure never raises or surfaces
to the user.

Log level threshold is read from APP_CONFIG (config_key='log_level').
Messages below the configured threshold are silently discarded.
Severity order: DEBUG < PERF/TELEMETRY < INFO < WARNING < ERROR

Usage:
    from utils import logger
    logger.info(session,  "02_run_encrypt.run_job",  "Job started")
    logger.error(session, "02_run_encrypt.run_job",  "Job failed", exc=e)
"""

import time
import traceback
from typing import Optional

import snowflake.snowpark as snowpark

_LEVELS = {"DEBUG", "PERF", "TELEMETRY", "INFO", "WARNING", "ERROR"}

# Severity ranking — higher number = more severe
_SEVERITY = {
    "DEBUG":     0,
    "PERF":      1,
    "TELEMETRY": 1,
    "INFO":      2,
    "WARNING":   3,
    "ERROR":     4,
}

_INSERT_SQL = (
    "INSERT INTO APP_SCHEMA.APP_LOGS "
    "(level, source, logged_at, session_id, message, traceback) "
    "VALUES (?, ?, "
    "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, "
    "CURRENT_SESSION()::VARCHAR, ?, ?)"
)

# ---------------------------------------------------------------------------
# Cached log-level threshold — re-read from APP_CONFIG at most every 60s
# ---------------------------------------------------------------------------
_cached_threshold: int = _SEVERITY["INFO"]  # default
_cache_ts: float = 0.0
_CACHE_TTL: float = 60.0  # seconds


def _get_threshold(session: snowpark.Session) -> int:
    """Return the numeric severity threshold from APP_CONFIG (cached 60s)."""
    global _cached_threshold, _cache_ts
    now = time.time()
    if now - _cache_ts < _CACHE_TTL:
        return _cached_threshold
    try:
        rows = session.sql(
            "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
            "WHERE config_key = 'log_level' AND is_active = TRUE LIMIT 1"
        ).collect()
        if rows and rows[0][0]:
            val = rows[0][0].upper().strip()
            if val == "PERF/TELEMETRY":
                _cached_threshold = _SEVERITY["PERF"]
            else:
                _cached_threshold = _SEVERITY.get(val, _SEVERITY["INFO"])
        else:
            _cached_threshold = _SEVERITY["INFO"]
    except Exception:
        _cached_threshold = _SEVERITY["INFO"]
    _cache_ts = now
    return _cached_threshold


def _log(
    session: snowpark.Session,
    level: str,
    source: str,
    message: str,
    exc: Optional[BaseException] = None,
) -> None:
    """Insert one log row into APP_SCHEMA.APP_LOGS. Never raises."""
    level = level.upper() if level.upper() in _LEVELS else "INFO"
    # Gate on configured threshold
    if _SEVERITY.get(level, 2) < _get_threshold(session):
        return
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


def perf(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "PERF", source, message)


def telemetry(session: snowpark.Session, source: str, message: str) -> None:
    _log(session, "TELEMETRY", source, message)

