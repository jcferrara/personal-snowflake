"""CLI entrypoint: pull an ESPN fantasy football league into RAW.FANTASY_FOOTBALL.

Usage:
    python -m fantasy_football.main                     # current season, weeks 1..current
    python -m fantasy_football.main --backfill          # every season since ESPN_FIRST_SEASON
    python -m fantasy_football.main --seasons 2020 2021
    python -m fantasy_football.main --only draft,transactions
    python -m fantasy_football.main --weeks 1-6         # override the matchup week range

Every landed table is (NATURAL_KEY, RAW_DATA, EXTRACTED_AT, SOURCE_METHOD) and
upserts MERGE on NATURAL_KEY, so re-running is safe and idempotent. A season's
own collectors keep going if one of them fails.
"""
from __future__ import annotations

import argparse
import logging
from datetime import date

from dotenv import load_dotenv

from . import collectors, snowflake_writer
from .espn_client import ESPNConfig, fetch, season_range

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("fantasy_football")

# Collector -> callable. Season collectors run once per season; week collectors
# run once per week in the season's range; snapshot collectors are forward-only
# (current season / current week only) and never part of a backfill.
SEASON_COLLECTORS = {
    "league_settings": collectors.league_settings,
    "draft": collectors.draft,
}
WEEK_COLLECTORS = {
    "matchups": collectors.matchups,
    "transactions": collectors.transactions,  # mTransactions2 is per-scoring-period
}
SNAPSHOT_COLLECTORS = {
    "free_agents": collectors.free_agents,
}
ALL_NAMES = list(SEASON_COLLECTORS) + list(WEEK_COLLECTORS) + list(SNAPSHOT_COLLECTORS)

# Modern ESPN seasons run 18 scoring periods (regular season + playoffs);
# older seasons top out at 17. Weeks past the season's end just return empty.
MAX_WEEK = 18


def _write(conn, table_rows) -> None:
    for table, rows in table_rows:
        n = snowflake_writer.upsert(conn, table, rows)
        log.info("%s: upserted %d rows", table, n)


def _week_bounds(config: ESPNConfig, season: int, current_year: int) -> tuple[int, int, int | None]:
    """(first_week, last_week, current_week) for a season.

    current_week is None for a completed (past) season.
    """
    data = fetch(season, ["mSettings"], config=config)
    status = data.get("status") or {}
    if season >= current_year:
        current_week = (
            data.get("scoringPeriodId") or status.get("latestScoringPeriod") or 1
        )
        return 1, current_week, current_week
    last = status.get("finalScoringPeriod") or MAX_WEEK
    return 1, min(last, MAX_WEEK), None


def _parse_weeks(spec: str | None) -> tuple[int, int] | None:
    if not spec:
        return None
    lo, _, hi = spec.partition("-")
    return int(lo), int(hi or lo)


def run_season(conn, config, season, names, week_override, current_year) -> None:
    log.info("=== season %s ===", season)

    for name, fn in SEASON_COLLECTORS.items():
        if name in names:
            try:
                _write(conn, fn(config, season))
            except Exception:
                log.exception("season=%s %s: failed, continuing", season, name)

    if not names & (set(WEEK_COLLECTORS) | set(SNAPSHOT_COLLECTORS)):
        return

    first, last, current_week = _week_bounds(config, season, current_year)
    if week_override:
        first, last = week_override

    for week in range(first, last + 1):
        for name, fn in WEEK_COLLECTORS.items():
            if name in names:
                try:
                    _write(conn, fn(config, season, week))
                except Exception:
                    log.exception("season=%s week=%s %s: skipped", season, week, name)

    # Snapshots: current season only, and only the current (in-progress) week.
    if current_week is not None:
        for name, fn in SNAPSHOT_COLLECTORS.items():
            if name in names:
                try:
                    _write(conn, fn(config, season, current_week))
                except Exception:
                    log.exception("season=%s %s: skipped", season, name)


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--seasons", type=int, nargs="+", help="specific seasons (default: current season)"
    )
    parser.add_argument(
        "--backfill", action="store_true", help="every season since ESPN_FIRST_SEASON"
    )
    parser.add_argument(
        "--only", help="comma-separated collector names (default: all): " + ", ".join(ALL_NAMES)
    )
    parser.add_argument(
        "--weeks", help="matchup week range, e.g. '1-6' or '3' (default: 1..current/final)"
    )
    args = parser.parse_args()

    config = ESPNConfig()
    current_year = date.today().year

    if args.backfill:
        seasons = list(season_range(config))
    elif args.seasons:
        seasons = args.seasons
    else:
        seasons = [current_year]

    names = {n.strip() for n in args.only.split(",")} if args.only else set(ALL_NAMES)
    unknown = names - set(ALL_NAMES)
    if unknown:
        parser.error(f"unknown collector(s): {', '.join(sorted(unknown))}")

    week_override = _parse_weeks(args.weeks)

    conn = snowflake_writer.connect()
    try:
        for season in seasons:
            season_names = set(names)
            if season < current_year:
                season_names.discard("free_agents")  # can't backfill a free-agent pool
            run_season(conn, config, season, season_names, week_override, current_year)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
