"""CLI entrypoint: pull daily market prices from Yahoo Finance into RAW.MARKET_DATA.

Usage:
    python -m market_data.main                                # rebuild the universe, then prices for all of it
    python -m market_data.main --only tickers                  # just refresh the universe
    python -m market_data.main --tickers SPY,QQQ --since 2024-01-01   # a subset, from a given date

Every landed table is (NATURAL_KEY, RAW_DATA, EXTRACTED_AT, SOURCE_METHOD) and
upserts MERGE on NATURAL_KEY, so re-running is safe and idempotent. Price
chunks are wrapped independently, so one failed Yahoo call never blocks the
rest of the universe.
"""
from __future__ import annotations

import argparse
import logging
import sys
import time
from collections import defaultdict
from datetime import date

from dotenv import load_dotenv

from . import collectors, snowflake_writer, state, universe as universe_mod

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("market_data")

ALL_NAMES = ["tickers", "daily_prices"]

CHUNK_SIZE = 100  # tickers per yf.download call
CHUNK_PAUSE_SECONDS = 2  # be polite between chunks to stay under Yahoo's throttling


def run_tickers(conn, universe) -> None:
    n = snowflake_writer.upsert(conn, "TICKERS", collectors.tickers(universe))
    log.info("TICKERS: upserted %d rows", n)


def fetch_prices(conn, symbols: list[str], start: date, end: date) -> tuple[list[dict], list[str], bool]:
    """Chunk `symbols`, download and upsert each chunk. Returns (price rows
    that carry a split event, tickers with no data, had_failure)."""
    splits: list[dict] = []
    missing: list[str] = []
    had_failure = False
    for i in range(0, len(symbols), CHUNK_SIZE):
        chunk = symbols[i : i + CHUNK_SIZE]
        try:
            rows, chunk_missing = collectors.daily_prices(chunk, start, end)
            n = snowflake_writer.upsert(conn, "DAILY_PRICES", rows)
            log.info(
                "DAILY_PRICES %s..%s tickers %d-%d of %d: upserted %d rows",
                start, end, i + 1, i + len(chunk), len(symbols), n,
            )
            missing.extend(chunk_missing)
            splits.extend(r["raw_data"] for r in rows if r["raw_data"]["stock_splits"])
        except Exception:
            log.exception("DAILY_PRICES chunk %d-%d (%s..%s) failed, continuing", i + 1, i + len(chunk), start, end)
            had_failure = True
        if i + CHUNK_SIZE < len(symbols):
            time.sleep(CHUNK_PAUSE_SECONDS)
    return splits, missing, had_failure


def run_daily_prices(conn, symbols: list[str], since: date | None) -> bool:
    end = date.today()
    last_dates = state.last_price_dates(conn)

    # Group tickers by fetch start so each group is one set of batched
    # downloads — in steady state that's a single group (everything is
    # caught up to the same day), plus one full-history group for any
    # ticker new to the universe.
    by_start: dict[date, list[str]] = defaultdict(list)
    for symbol in symbols:
        by_start[since or state.start_date(last_dates.get(symbol))].append(symbol)

    had_failure = False
    missing: list[str] = []
    split_tickers: set[str] = set()
    for start, group in sorted(by_start.items()):
        log.info("DAILY_PRICES: %d tickers from %s", len(group), start)
        splits, group_missing, failed = fetch_prices(conn, group, start, end)
        had_failure |= failed
        missing.extend(group_missing)
        if start > state.DEFAULT_START:
            split_tickers |= {s["ticker"] for s in splits}

    # Yahoo's close is split-adjusted retroactively, so rows landed before a
    # split are now on a different share basis. Refetch those tickers' full
    # history to restate them consistently.
    if split_tickers:
        log.info("DAILY_PRICES: split detected for %s; refetching full history", sorted(split_tickers))
        _, _, failed = fetch_prices(conn, sorted(split_tickers), state.DEFAULT_START, end)
        had_failure |= failed

    if missing:
        # Not a run failure: typically delisted tickers or ones Yahoo doesn't
        # carry (e.g. escrow/contingent-rights securities from Plaid).
        log.warning("DAILY_PRICES: no data for %d tickers: %s", len(missing), ", ".join(sorted(missing)))
    return had_failure


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--only", help="comma-separated table names to run (default: all): " + ", ".join(ALL_NAMES)
    )
    parser.add_argument(
        "--since",
        help="ISO date (YYYY-MM-DD) to fetch prices from for every selected ticker, overriding watermarks",
    )
    parser.add_argument(
        "--tickers",
        help="comma-separated Yahoo tickers to fetch prices for instead of the whole universe",
    )
    args = parser.parse_args()

    names = {n.strip() for n in args.only.split(",")} if args.only else set(ALL_NAMES)
    unknown = names - set(ALL_NAMES)
    if unknown:
        parser.error(f"unknown table(s): {', '.join(sorted(unknown))}")
    since = date.fromisoformat(args.since) if args.since else None

    conn = snowflake_writer.connect()
    had_failure = False
    try:
        universe, had_failure = universe_mod.build_universe(conn)
        if "tickers" in names:
            try:
                run_tickers(conn, universe)
            except Exception:
                log.exception("TICKERS: failed, continuing")
                had_failure = True
        if "daily_prices" in names:
            if args.tickers:
                symbols = sorted({universe_mod.to_yahoo_ticker(t) for t in args.tickers.split(",")})
            else:
                symbols = sorted(universe)
            had_failure |= run_daily_prices(conn, symbols, since)
    finally:
        conn.close()

    if had_failure:
        sys.exit(1)


if __name__ == "__main__":
    main()
