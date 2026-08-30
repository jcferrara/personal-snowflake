"""Dump a few raw ESPN responses to local JSON so you can eyeball the real
shape for your league before trusting the collectors. ESPN's JSON has drifted
across seasons; the field access in collectors.py should match what you see here.

Writes sample_*.json into the current directory (git-ignored). Run it first,
against the season you're about to backfill — older seasons (pre-2018) use a
different URL shape and are the ones most likely to differ.

Usage:
    python -m fantasy_football.explore            # current season
    python -m fantasy_football.explore 2019       # a specific season
"""
from __future__ import annotations

import json
import sys
from datetime import date

from dotenv import load_dotenv


def main() -> None:
    load_dotenv()
    from .espn_client import ESPNConfig, fetch

    config = ESPNConfig()
    season = int(sys.argv[1]) if len(sys.argv) > 1 else date.today().year

    settings = fetch(season, ["mSettings", "mTeam"], config=config)
    week = settings.get("scoringPeriodId") or 1

    samples = {
        "sample_settings_teams.json": settings,
        "sample_boxscore.json": fetch(
            season, ["mMatchupScore", "mBoxscore"],
            extra_params={"scoringPeriodId": week}, config=config,
        ),
        "sample_draft.json": fetch(season, ["mDraftDetail"], config=config),
        "sample_transactions.json": fetch(season, ["mTransactions2"], config=config),
    }
    for filename, data in samples.items():
        with open(filename, "w") as f:
            json.dump(data, f, indent=2, default=str)
        print(f"wrote {filename}")
    print(f"season={season} current_week={week}")
    print("Compare these against collectors.py's field access before backfilling.")


if __name__ == "__main__":
    main()
