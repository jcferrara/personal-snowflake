"""CLI entrypoint: pull Plaid transaction/investment data into RAW.PLAID.

Usage:
    python -m plaid_extract.main                               # every item, every table
    python -m plaid_extract.main --only accounts,transactions
    python -m plaid_extract.main --since 2024-01-01             # override investment_transactions' date watermark

Every landed table is (NATURAL_KEY, RAW_DATA, EXTRACTED_AT, SOURCE_METHOD) and
upserts MERGE on NATURAL_KEY, so re-running is safe and idempotent. Each
linked item (institution) and table is wrapped independently, so one item's
failure never blocks another item, or another table for the same item.
"""
from __future__ import annotations

import argparse
import logging
import sys
from datetime import date

from dotenv import load_dotenv

from . import collectors, items as items_mod, snowflake_writer, state
from .plaid_client import ItemLoginRequiredError, get_client

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("plaid_extract")

ALL_NAMES = ["accounts", "transactions", "investment_transactions", "holdings"]


def run_accounts(conn, client, item) -> None:
    _, rows = collectors.accounts(client, item)[0]
    n = snowflake_writer.upsert(conn, "ACCOUNTS", rows)
    log.info("item=%s ACCOUNTS: upserted %d rows", item.item_id, n)


def run_transactions(conn, client, item) -> None:
    cursor = state.get_cursor(conn, "transactions", item.item_id)
    table_rows, next_cursor = collectors.transactions_sync(client, item, cursor)
    _, rows = table_rows[0]
    n = snowflake_writer.upsert(conn, "TRANSACTIONS", rows)
    state.advance_cursor(conn, "transactions", item.item_id, next_cursor)
    log.info("item=%s TRANSACTIONS: upserted %d rows, cursor advanced", item.item_id, n)


def run_investment_transactions(conn, client, item, since: date | None) -> None:
    start = since or state.get_date_watermark(conn, "investment_transactions", item.item_id)
    end = date.today()
    for table, rows in collectors.investment_transactions(client, item, start, end):
        n = snowflake_writer.upsert(conn, table, rows)
        log.info("item=%s %s: upserted %d rows (window %s..%s)", item.item_id, table, n, start, end)
    state.advance_date_watermark(conn, "investment_transactions", item.item_id, end)


def run_holdings(conn, client, item) -> None:
    for table, rows in collectors.holdings(client, item):
        n = snowflake_writer.upsert(conn, table, rows)
        log.info("item=%s %s: upserted %d rows", item.item_id, table, n)


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
        help="ISO date (YYYY-MM-DD) overriding investment_transactions' date watermark for this run",
    )
    args = parser.parse_args()

    names = {n.strip() for n in args.only.split(",")} if args.only else set(ALL_NAMES)
    unknown = names - set(ALL_NAMES)
    if unknown:
        parser.error(f"unknown table(s): {', '.join(sorted(unknown))}")
    since = date.fromisoformat(args.since) if args.since else None

    client = get_client()
    plaid_items = items_mod.load_items()
    conn = snowflake_writer.connect()
    had_failure = False
    try:
        for item in plaid_items:
            log.info("=== item=%s (%s) ===", item.item_id, item.nickname)
            for name in ALL_NAMES:
                if name not in names:
                    continue
                try:
                    if name == "accounts":
                        run_accounts(conn, client, item)
                    elif name == "transactions":
                        run_transactions(conn, client, item)
                    elif name == "investment_transactions":
                        run_investment_transactions(conn, client, item, since)
                    elif name == "holdings":
                        run_holdings(conn, client, item)
                except ItemLoginRequiredError:
                    log.error(
                        "item=%s (%s): ITEM_LOGIN_REQUIRED — needs interactive Plaid Link "
                        "'update mode', which can't run in CI. Re-link locally with "
                        "`python -m plaid_extract.link_item` and refresh PLAID_ACCESS_TOKENS. "
                        "Skipping this item for the rest of the run.",
                        item.item_id, item.nickname,
                    )
                    had_failure = True
                    break  # no point trying this item's other tables once login is required
                except Exception:
                    log.exception("item=%s %s: failed, continuing", item.item_id, name)
                    had_failure = True
    finally:
        conn.close()

    if had_failure:
        sys.exit(1)


if __name__ == "__main__":
    main()
