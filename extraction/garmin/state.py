"""Per-collector extraction watermarks, tracked in RAW.GARMIN._EXTRACT_STATE."""
from __future__ import annotations

from datetime import date, timedelta

import snowflake.connector

STATE_TABLE = "_EXTRACT_STATE"

DEFAULT_LOOKBACK_DAYS = 30
REFETCH_BUFFER_DAYS = 3


def _ensure_state_table(conn: snowflake.connector.SnowflakeConnection) -> None:
    conn.cursor().execute(
        f"""
        CREATE TABLE IF NOT EXISTS {STATE_TABLE} (
            COLLECTOR_NAME VARCHAR,
            LAST_EXTRACTED_DATE DATE,
            UPDATED_AT TIMESTAMP_NTZ
        )
        """
    )


def get_watermark(conn: snowflake.connector.SnowflakeConnection, collector_name: str) -> date:
    """Start date for this run's fetch window.

    Re-fetches a small buffer behind the last watermark to catch late-syncing
    metrics (e.g. sleep/HRV that finalize a day or two after the fact).
    """
    _ensure_state_table(conn)
    cur = conn.cursor()
    cur.execute(
        f"SELECT LAST_EXTRACTED_DATE FROM {STATE_TABLE} WHERE COLLECTOR_NAME = %s",
        (collector_name,),
    )
    row = cur.fetchone()
    if row and row[0]:
        return row[0] - timedelta(days=REFETCH_BUFFER_DAYS)
    return date.today() - timedelta(days=DEFAULT_LOOKBACK_DAYS)


def advance_watermark(conn: snowflake.connector.SnowflakeConnection, collector_name: str, through_date: date) -> None:
    conn.cursor().execute(
        f"""
        MERGE INTO {STATE_TABLE} t
        USING (SELECT %(name)s AS COLLECTOR_NAME, %(through)s AS LAST_EXTRACTED_DATE) s
        ON t.COLLECTOR_NAME = s.COLLECTOR_NAME
        WHEN MATCHED THEN UPDATE SET
            LAST_EXTRACTED_DATE = s.LAST_EXTRACTED_DATE, UPDATED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (COLLECTOR_NAME, LAST_EXTRACTED_DATE, UPDATED_AT)
        VALUES (s.COLLECTOR_NAME, s.LAST_EXTRACTED_DATE, CURRENT_TIMESTAMP())
        """,
        {"name": collector_name, "through": through_date},
    )
