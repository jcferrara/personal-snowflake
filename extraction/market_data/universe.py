"""Build the ticker universe: S&P 500 constituents + curated ETFs/indices + Plaid holdings.

Each source returns {yahoo_ticker: attributes}; build_universe() merges them
into one entry per ticker, recording every list the ticker came from in
`universes` (e.g. SPY is both a curated ETF and a holding). Tickers are
normalized to Yahoo's symbology ("BRK.B" → "BRK-B") since that's what
yfinance needs; the original symbol is kept as `source_symbol`.
"""
from __future__ import annotations

import csv
import io
import json
import logging
from pathlib import Path
from typing import Any

import pandas as pd
import requests
import snowflake.connector

log = logging.getLogger("market_data")

SP500_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
# Wikipedia rejects requests' default User-Agent with a 403.
HTTP_HEADERS = {"User-Agent": "personal-snowflake-market-data-extractor/1.0"}
CURATED_TICKERS_PATH = Path(__file__).with_name("curated_tickers.csv")


def to_yahoo_ticker(symbol: str) -> str:
    return symbol.strip().upper().replace(".", "-")


def sp500() -> dict[str, dict[str, Any]]:
    """Current S&P 500 constituents from Wikipedia's maintained list."""
    resp = requests.get(SP500_URL, headers=HTTP_HEADERS, timeout=30)
    resp.raise_for_status()
    table = pd.read_html(io.StringIO(resp.text), attrs={"id": "constituents"})[0]
    out = {}
    for row in table.to_dict("records"):
        out[to_yahoo_ticker(row["Symbol"])] = {
            "source_symbol": row["Symbol"],
            "name": row["Security"],
            "gics_sector": row["GICS Sector"],
            "gics_sub_industry": row["GICS Sub-Industry"],
            "sp500_date_added": row["Date added"],
            "cik": str(row["CIK"]),
        }
    # Sanity floor: a parse that silently returns a partial table should fail
    # loudly rather than shrink the universe.
    if len(out) < 450:
        raise ValueError(f"S&P 500 table parsed only {len(out)} rows; page layout may have changed")
    return out


def curated() -> dict[str, dict[str, Any]]:
    """Hand-maintained ETFs and benchmark indices (curated_tickers.csv)."""
    with CURATED_TICKERS_PATH.open(newline="") as f:
        return {
            to_yahoo_ticker(row["ticker"]): {
                "source_symbol": row["ticker"],
                "name": row["name"],
                "curated_category": row["category"],
                "curated_subcategory": row["subcategory"],
            }
            for row in csv.DictReader(f)
        }


def holdings(conn: snowflake.connector.SnowflakeConnection) -> dict[str, dict[str, Any]]:
    """Every non-cash security with a ticker that Plaid has ever reported — current
    holdings plus anything traded — so sold positions keep a price history too."""
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            NATURAL_KEY,
            RAW_DATA:ticker_symbol::STRING,
            RAW_DATA:name::STRING,
            RAW_DATA:type::STRING
        FROM RAW.PLAID.SECURITIES
        WHERE RAW_DATA:ticker_symbol::STRING IS NOT NULL
          AND COALESCE(RAW_DATA:is_cash_equivalent::BOOLEAN, FALSE) = FALSE
          AND COALESCE(RAW_DATA:type::STRING, '') <> 'cash'
        """
    )
    out: dict[str, dict[str, Any]] = {}
    for security_id, symbol, name, security_type in cur.fetchall():
        entry = out.setdefault(
            to_yahoo_ticker(symbol),
            {"source_symbol": symbol, "name": name, "plaid_security_type": security_type,
             "plaid_security_ids": []},
        )
        entry["plaid_security_ids"].append(security_id)
    return out


def previous_sp500(conn: snowflake.connector.SnowflakeConnection) -> dict[str, dict[str, Any]]:
    """S&P 500 rows from the last successful run, used when Wikipedia is unreachable."""
    cur = conn.cursor()
    cur.execute(
        """
        SELECT NATURAL_KEY, RAW_DATA
        FROM TICKERS
        WHERE ARRAY_CONTAINS('sp500'::VARIANT, RAW_DATA:universes)
        """
    )
    out = {}
    for ticker, raw in cur.fetchall():
        data = json.loads(raw)
        out[ticker] = {
            k: data.get(k)
            for k in ("source_symbol", "name", "gics_sector", "gics_sub_industry", "sp500_date_added", "cik")
        }
    return out


def build_universe(
    conn: snowflake.connector.SnowflakeConnection,
) -> tuple[dict[str, dict[str, Any]], bool]:
    """Merge every source into {ticker: attributes}. Returns (universe, had_failure);
    a failed source is logged and skipped (S&P 500 falls back to the last run's
    list) so one flaky source never blocks price extraction for the rest."""
    had_failure = False
    sources: dict[str, dict[str, dict[str, Any]]] = {}

    try:
        sources["sp500"] = sp500()
    except Exception:
        log.exception("S&P 500 list fetch failed; falling back to the previously landed list")
        had_failure = True
        try:
            sources["sp500"] = previous_sp500(conn)
        except Exception:
            log.exception("no previously landed S&P 500 list to fall back to")

    sources["curated"] = curated()

    try:
        sources["holding"] = holdings(conn)
    except Exception:
        log.exception("Plaid holdings lookup failed; continuing without holdings")
        had_failure = True

    universe: dict[str, dict[str, Any]] = {}
    for source_name, entries in sources.items():
        for ticker, attrs in entries.items():
            entry = universe.setdefault(ticker, {"ticker": ticker, "universes": []})
            entry["universes"].append(source_name)
            # First source wins for shared keys (name, source_symbol): S&P 500 /
            # curated names are cleaner than Plaid's "Trust - Fund" strings.
            for k, v in attrs.items():
                entry.setdefault(k, v)

    for source_name, entries in sources.items():
        log.info("universe source %s: %d tickers", source_name, len(entries))
    log.info("universe total: %d distinct tickers", len(universe))
    return universe, had_failure
