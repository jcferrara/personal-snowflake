"""Per-item extraction watermarks/cursors, tracked in RAW.PLAID._EXTRACT_STATE.

TRANSACTIONS uses the SYNC_CURSOR column (an opaque cursor from
/transactions/sync); INVESTMENT_TRANSACTIONS uses LAST_EXTRACTED_DATE (a date
watermark, since that endpoint paginates by date range rather than cursor).
Each collector only touches its own column; the other stays NULL for that
row. Keyed per (COLLECTOR_NAME, ITEM_ID) since each linked Item has its own
independent sync state — unlike garmin/state.py, which only has one source.
"""
from __future__ import annotations

from datetime import date, timedelta

import snowflake.connector

STATE_TABLE = "_EXTRACT_STATE"

DEFAULT_LOOKBACK_DAYS = 730  # ~2 years of investment transaction history on first run
REFETCH_BUFFER_DAYS = 5  # investment transactions can settle later than the trade date


def _ensure_state_table(conn: snowflake.connector.SnowflakeConnection) -> None:
    conn.cursor().execute(
        f"""
        CREATE TABLE IF NOT EXISTS {STATE_TABLE} (
            COLLECTOR_NAME VARCHAR,
            ITEM_ID VARCHAR,
            SYNC_CURSOR VARCHAR,
            LAST_EXTRACTED_DATE DATE,
            UPDATED_AT TIMESTAMP_NTZ
        )
        """
    )


def get_cursor(conn: snowflake.connector.SnowflakeConnection, collector_name: str, item_id: str) -> str | None:
    _ensure_state_table(conn)
    cur = conn.cursor()
    cur.execute(
        f"SELECT SYNC_CURSOR FROM {STATE_TABLE} WHERE COLLECTOR_NAME = %s AND ITEM_ID = %s",
        (collector_name, item_id),
    )
    row = cur.fetchone()
    return row[0] if row else None


def advance_cursor(
    conn: snowflake.connector.SnowflakeConnection, collector_name: str, item_id: str, cursor: str
) -> None:
    conn.cursor().execute(
        f"""
        MERGE INTO {STATE_TABLE} t
        USING (SELECT %(name)s AS COLLECTOR_NAME, %(item_id)s AS ITEM_ID, %(cursor)s AS SYNC_CURSOR) s
        ON t.COLLECTOR_NAME = s.COLLECTOR_NAME AND t.ITEM_ID = s.ITEM_ID
        WHEN MATCHED THEN UPDATE SET
            SYNC_CURSOR = s.SYNC_CURSOR, UPDATED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (COLLECTOR_NAME, ITEM_ID, SYNC_CURSOR, UPDATED_AT)
        VALUES (s.COLLECTOR_NAME, s.ITEM_ID, s.SYNC_CURSOR, CURRENT_TIMESTAMP())
        """,
        {"name": collector_name, "item_id": item_id, "cursor": cursor},
    )


def get_date_watermark(conn: snowflake.connector.SnowflakeConnection, collector_name: str, item_id: str) -> date:
    """Start date for this run's fetch window, with a re-fetch buffer behind
    the last watermark to catch late-settling investment transactions."""
    _ensure_state_table(conn)
    cur = conn.cursor()
    cur.execute(
        f"SELECT LAST_EXTRACTED_DATE FROM {STATE_TABLE} WHERE COLLECTOR_NAME = %s AND ITEM_ID = %s",
        (collector_name, item_id),
    )
    row = cur.fetchone()
    if row and row[0]:
        return row[0] - timedelta(days=REFETCH_BUFFER_DAYS)
    return date.today() - timedelta(days=DEFAULT_LOOKBACK_DAYS)


def advance_date_watermark(
    conn: snowflake.connector.SnowflakeConnection, collector_name: str, item_id: str, through_date: date
) -> None:
    conn.cursor().execute(
        f"""
        MERGE INTO {STATE_TABLE} t
        USING (SELECT %(name)s AS COLLECTOR_NAME, %(item_id)s AS ITEM_ID, %(through)s AS LAST_EXTRACTED_DATE) s
        ON t.COLLECTOR_NAME = s.COLLECTOR_NAME AND t.ITEM_ID = s.ITEM_ID
        WHEN MATCHED THEN UPDATE SET
            LAST_EXTRACTED_DATE = s.LAST_EXTRACTED_DATE, UPDATED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (COLLECTOR_NAME, ITEM_ID, LAST_EXTRACTED_DATE, UPDATED_AT)
        VALUES (s.COLLECTOR_NAME, s.ITEM_ID, s.LAST_EXTRACTED_DATE, CURRENT_TIMESTAMP())
        """,
        {"name": collector_name, "item_id": item_id, "through": through_date},
    )
