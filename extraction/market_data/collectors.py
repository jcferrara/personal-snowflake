"""Collectors: turn the universe and yfinance downloads into landed rows.

Each returns rows shaped {natural_key, raw_data, source_method} for
snowflake_writer.upsert.

Price semantics (from Yahoo, via yf.download(auto_adjust=False)):
  - `close` is adjusted for splits but NOT dividends. Yahoo applies split
    adjustments retroactively, which is why main.py refetches a ticker's full
    history whenever a split lands in its incremental window.
  - `adj_close` also folds in dividends, and Yahoo rewrites it on every
    ex-dividend date. Rows outside the refetch window are not rewritten, so
    historical adj_close is only "as of when that row was extracted" — compute
    total return in dbt from `close` + `dividends` instead.
  - `dividends` is the per-share cash amount on the ex-date; `stock_splits` is
    the split ratio (e.g. 4.0 for 4-for-1) on the split date, 0 otherwise.
"""
from __future__ import annotations

import logging
import math
from datetime import date, datetime, timedelta, timezone
from typing import Any

import pandas as pd
import yfinance as yf

log = logging.getLogger("market_data")

PRICE_COLUMNS = {
    "Open": "open",
    "High": "high",
    "Low": "low",
    "Close": "close",
    "Adj Close": "adj_close",
    "Volume": "volume",
    "Dividends": "dividends",
    "Stock Splits": "stock_splits",
}


def tickers(universe: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    snapshot_date = datetime.now(timezone.utc).date().isoformat()
    return [
        {
            "natural_key": ticker,
            "raw_data": {**attrs, "universe_snapshot_date": snapshot_date},
            "source_method": "universe_build",
        }
        for ticker, attrs in sorted(universe.items())
    ]


def _clean(value: Any) -> Any:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return None
    return float(value)


def _download(symbols: list[str], start: date, end: date, threads: bool) -> pd.DataFrame:
    """Long-format frame (Date, Ticker, Open, ..., Stock Splits) with empty rows dropped."""
    df = yf.download(
        symbols,
        start=start.isoformat(),
        # yfinance's `end` is exclusive
        end=(end + timedelta(days=1)).isoformat(),
        auto_adjust=False,
        actions=True,
        group_by="ticker",
        threads=threads,
        progress=False,
    )
    if df.empty:
        return df
    long = df.stack(level=0, future_stack=True).reset_index()
    return long.dropna(subset=["Close"])


def daily_prices(symbols: list[str], start: date, end: date) -> tuple[list[dict[str, Any]], list[str]]:
    """Daily OHLCV + dividends/splits for one batch of `symbols` over [start, end].
    main.py chunks the universe into CHUNK_SIZE batches so a multi-decade
    backfill never holds every ticker's rows in memory.

    Returns (rows, missing): `missing` are tickers that returned no data even
    after a retry — usually delisted or not on Yahoo, occasionally a transient
    Yahoo failure that the next run's refetch window will pick up.
    """
    frame = _download(symbols, start, end, threads=True)
    got = set(frame["Ticker"]) if not frame.empty else set()

    # yfinance's threaded mode intermittently fails individual tickers (e.g.
    # "database is locked" on its shared sqlite tz cache), so retry the
    # empties once, single-threaded.
    retry = [s for s in symbols if s not in got]
    if retry:
        retried = _download(retry, start, end, threads=False)
        if not retried.empty:
            frame = pd.concat([frame, retried], ignore_index=True) if not frame.empty else retried
            got |= set(retried["Ticker"])
    missing = [s for s in symbols if s not in got]

    rows = []
    for rec in frame.to_dict("records"):
        day = rec["Date"].date().isoformat()
        raw = {"ticker": rec["Ticker"], "date": day}
        raw.update({dst: _clean(rec.get(src)) for src, dst in PRICE_COLUMNS.items()})
        rows.append(
            {
                "natural_key": f"{rec['Ticker']}-{day}",
                "raw_data": raw,
                "source_method": "yfinance_download",
            }
        )
    return rows, missing
