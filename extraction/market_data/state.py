"""Per-ticker price watermarks, derived from RAW.MARKET_DATA.DAILY_PRICES itself.

Unlike garmin/plaid_extract, there's no _EXTRACT_STATE table: the landed rows
already say how far each ticker has been loaded, and deriving it means a
ticker newly added to the universe (no rows yet) automatically gets a full
backfill while existing tickers stay incremental.
"""
from __future__ import annotations

from datetime import date, timedelta

import snowflake.connector

DEFAULT_START = date(2000, 1, 1)  # backfill floor for tickers with no landed history
REFETCH_BUFFER_DAYS = 5  # Yahoo occasionally revises the last few sessions' bars

_TABLE_NOT_FOUND = 2003


def last_price_dates(conn: snowflake.connector.SnowflakeConnection) -> dict[str, date]:
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT RAW_DATA:ticker::STRING, MAX(RAW_DATA:date::DATE)
            FROM DAILY_PRICES
            GROUP BY 1
            """
        )
    except snowflake.connector.errors.ProgrammingError as e:
        if e.errno == _TABLE_NOT_FOUND:  # first run: nothing landed yet
            return {}
        raise
    return dict(cur.fetchall())


def start_date(last_date: date | None) -> date:
    if last_date is None:
        return DEFAULT_START
    return last_date - timedelta(days=REFETCH_BUFFER_DAYS)
