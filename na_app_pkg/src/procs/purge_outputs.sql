-- src/procs/purge_outputs.sql
-- LocID Native App — LOCID_PURGE_OUTPUTS Stored Procedure
--
-- Uploaded to @APP_SCHEMA.APP_STAGE/src/procs/ and executed from setup.sql via:
--   EXECUTE IMMEDIATE FROM '@APP_SCHEMA.APP_STAGE/src/procs/purge_outputs.sql';
--
-- Purpose:
--   Allows consumers to manage the accumulation of output tables created by
--   LOCID_ENCRYPT and LOCID_DECRYPT. Each job creates a new table named
--   LOCID_ENCRYPT_OUTPUT_YYYYMMDD_HHMMSS or LOCID_DECRYPT_OUTPUT_YYYYMMDD_HHMMSS.
--   Over time these can become numerous. This procedure drops output tables
--   older than a configurable retention threshold.
--
-- Parameters:
--   RETENTION_DAYS (INTEGER, optional) — tables older than this many days are dropped.
--       If NULL or 0, reads 'output_retention_days' from APP_CONFIG (default: 90).
--
-- Returns:
--   VARIANT — { "tables_dropped": [...], "count": N }
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP_SCHEMA.LOCID_PURGE_OUTPUTS(
    RETENTION_DAYS  INTEGER DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'purge_handler'
AS $$
import time
import re
from datetime import datetime, timedelta

import snowflake.snowpark as snowpark


def purge_handler(session, retention_days):
    try:
        # Resolve retention threshold
        if not retention_days or retention_days <= 0:
            rows = session.sql(
                "SELECT config_value FROM APP_SCHEMA.APP_CONFIG "
                "WHERE config_key = 'output_retention_days' AND is_active = TRUE LIMIT 1"
            ).collect()
            try:
                retention_days = int(rows[0][0]) if rows and rows[0][0] else 90
            except (TypeError, ValueError):
                retention_days = 90

        cutoff = datetime.utcnow() - timedelta(days=retention_days)

        # List all output tables in APP_SCHEMA
        tables = session.sql(
            "SHOW TABLES LIKE 'LOCID_%_OUTPUT_%' IN SCHEMA APP_SCHEMA"
        ).collect()

        # Parse table name → extract timestamp suffix
        pattern = re.compile(r'^LOCID_(?:ENCRYPT|DECRYPT)_OUTPUT_(\d{8}_\d{6})$')
        dropped = []

        for row in tables:
            tbl_name = row['name']
            m = pattern.match(tbl_name)
            if not m:
                continue
            try:
                tbl_ts = datetime.strptime(m.group(1), '%Y%m%d_%H%M%S')
            except ValueError:
                continue

            if tbl_ts < cutoff:
                session.sql(f'DROP TABLE IF EXISTS APP_SCHEMA."{tbl_name}"').collect()
                dropped.append(tbl_name)

        return {
            'tables_dropped': dropped,
            'count': len(dropped),
            'retention_days': retention_days,
            'cutoff_date': cutoff.strftime('%Y-%m-%d %H:%M:%S'),
        }

    except Exception as exc:
        try:
            session.sql(
                "INSERT INTO APP_SCHEMA.APP_LOGS (level, source, message) VALUES (?, ?, ?)",
                params=['ERROR', 'locid_purge_outputs.purge_handler', str(exc)]
            ).collect()
        except Exception:
            pass
        raise RuntimeError(f'LOCID_PURGE_OUTPUTS failed: {exc}') from exc
$$;

GRANT USAGE ON PROCEDURE APP_SCHEMA.LOCID_PURGE_OUTPUTS(INTEGER)
    TO APPLICATION ROLE APP_ADMIN;
