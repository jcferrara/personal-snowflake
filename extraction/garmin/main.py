"""CLI entrypoint: incrementally pull Garmin data into RAW.GARMIN.

Usage:
    python -m garmin.main                  # run every collector
    python -m garmin.main --only stats,sleep,activities
"""
from __future__ import annotations

import argparse
import logging
import time
from datetime import date, timedelta

from dotenv import load_dotenv

from . import activities, activity_details, collectors, garmin_client, snowflake_writer, state

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("garmin")

ACTIVITY_DETAILS_BATCH_SIZE = 20
ACTIVITY_DETAILS_REQUEST_DELAY_SECONDS = 0.5


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


def run_activity_details(conn, client) -> None:
    all_activity_ids = snowflake_writer.existing_keys(conn, activities.TABLE)
    known_detail_ids = snowflake_writer.existing_keys(conn, activity_details.TABLE)
    missing_ids = sorted(all_activity_ids - known_detail_ids)
    log.info("%s: %d activities missing details", activity_details.TABLE, len(missing_ids))

    total = 0
    batch: list[dict] = []
    for i, activity_id in enumerate(missing_ids, start=1):
        try:
            row = activity_details.fetch_activity_detail(client, activity_id)
        except Exception:
            log.exception(
                "%s: failed to fetch details for activity %s, skipping",
                activity_details.TABLE,
                activity_id,
            )
        else:
            if row:
                batch.append(row)

        if batch and (len(batch) >= ACTIVITY_DETAILS_BATCH_SIZE or i == len(missing_ids)):
            total += snowflake_writer.upsert(conn, activity_details.TABLE, batch)
            log.info("%s: upserted %d/%d", activity_details.TABLE, total, len(missing_ids))
            batch = []

        time.sleep(ACTIVITY_DETAILS_REQUEST_DELAY_SECONDS)

    log.info("%s: done, upserted %d rows total", activity_details.TABLE, total)


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
        if names is None or activity_details.TABLE in names:
            run_activity_details(conn, client)
        for collector in collectors.ALL_COLLECTORS:
            if names is not None and collector.table not in names:
                continue
            run_collector(conn, client, collector, since=since)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
