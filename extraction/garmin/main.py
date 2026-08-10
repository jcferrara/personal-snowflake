"""CLI entrypoint: incrementally pull Garmin data into RAW.GARMIN.

Usage:
    python -m garmin.main                  # run every collector
    python -m garmin.main --only stats,sleep,activities
"""
from __future__ import annotations

import argparse
import logging
from datetime import date, timedelta

from dotenv import load_dotenv

from . import activities, collectors, garmin_client, snowflake_writer, state

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("garmin")


def run_collector(conn, client, collector: collectors.Collector, since: date | None = None) -> None:
    watermark = since if since is not None else state.get_watermark(conn, collector.table)
    today = date.today()

    if collector.kind == "range":
        rows = collectors.fetch_range(client, collector, watermark, today)
    else:
        rows = []
        d = watermark
        while d <= today:
            rows.extend(collectors.fetch_daily(client, collector, d))
            d += timedelta(days=1)

    n = snowflake_writer.upsert(conn, collector.table, rows)
    log.info("%s: upserted %d rows (window %s..%s)", collector.table, n, watermark, today)
    state.advance_watermark(conn, collector.table, today)


def run_activities(conn, client) -> None:
    known_ids = snowflake_writer.existing_keys(conn, activities.TABLE)
    rows = activities.fetch_new_activities(client, known_ids)
    n = snowflake_writer.upsert(conn, activities.TABLE, rows)
    log.info("%s: upserted %d rows", activities.TABLE, n)


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated table names to run (default: all)")
    parser.add_argument(
        "--since",
        help="ISO date (YYYY-MM-DD) to backfill the daily/range collectors from, "
        "overriding their watermark for this run only (e.g. for an initial historical load)",
    )
    args = parser.parse_args()

    names = {n.strip().upper() for n in args.only.split(",")} if args.only else None
    since = date.fromisoformat(args.since) if args.since else None

    client = garmin_client.get_client()
    conn = snowflake_writer.connect()
    try:
        if names is None or activities.TABLE in names:
            run_activities(conn, client)
        for collector in collectors.ALL_COLLECTORS:
            if names is not None and collector.table not in names:
                continue
            run_collector(conn, client, collector, since=since)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
