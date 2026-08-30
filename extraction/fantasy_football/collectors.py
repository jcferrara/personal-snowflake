"""ESPN fantasy views -> RAW.FANTASY_FOOTBALL row builders.

One collector per data domain. Each takes an ``ESPNConfig`` plus the season
(and, where ESPN scopes the endpoint that way, a week) and returns a list of
``(table, rows)`` pairs, where every row is the
``{natural_key, raw_data, source_method}`` dict ``snowflake_writer.upsert``
expects. Payloads land close to ESPN's raw JSON — one row per team, matchup,
pick, transaction, or player — and get flattened later in dbt staging models.

``natural_key`` always encodes the grain (season, plus week / id where
relevant) since every domain shares the four-column landing shape and upserts
MERGE on that key. ``source_method`` records the ESPN view(s) the row came from.
"""
from __future__ import annotations

import json
import logging
from typing import Any

from .espn_client import ESPNConfig, fetch

log = logging.getLogger("fantasy_football")

TableRows = tuple[str, list[dict[str, Any]]]


def _row(natural_key: str, payload: Any, source_method: str) -> dict[str, Any]:
    return {"natural_key": natural_key, "raw_data": payload, "source_method": source_method}


def league_settings(config: ESPNConfig, season: int) -> list[TableRows]:
    """LEAGUE_SETTINGS (1 row/season) + TEAMS + MEMBERS, from one fetch.

    LEAGUE_SETTINGS keeps the top-level league/status/settings block; the
    per-team and per-member arrays land one row each, essentially as returned.
    """
    views = ["mSettings", "mTeam"]
    data = fetch(season, views, config=config)
    src = ",".join(views)

    settings_payload = {
        "id": data.get("id"),
        "seasonId": data.get("seasonId", season),
        "scoringPeriodId": data.get("scoringPeriodId"),
        "status": data.get("status"),
        "settings": data.get("settings"),
    }
    return [
        ("LEAGUE_SETTINGS", [_row(str(season), settings_payload, src)]),
        ("TEAMS", [_row(f"{season}-{t.get('id')}", t, src) for t in data.get("teams", [])]),
        ("MEMBERS", [_row(f"{season}-{m.get('id')}", m, src) for m in data.get("members", [])]),
    ]


def draft(config: ESPNConfig, season: int) -> list[TableRows]:
    """DRAFT_PICKS — one row per pick, raw ESPN pick dict."""
    data = fetch(season, ["mDraftDetail"], config=config)
    picks = data.get("draftDetail", {}).get("picks", []) or []
    rows = [
        _row(f"{season}-{p.get('overallPickNumber', i + 1)}", p, "mDraftDetail")
        for i, p in enumerate(picks)
    ]
    return [("DRAFT_PICKS", rows)]


def transactions(config: ESPNConfig, season: int, week: int) -> list[TableRows]:
    """TRANSACTIONS — one row per add/drop/trade/waiver, for a single week.

    ``mTransactions2`` is a per-scoring-period endpoint: with no
    ``scoringPeriodId`` it returns *no* ``transactions`` key at all, so this is
    a week-scoped collector (main.py loops it over the season like matchups).
    Rows key on ``{season}-{transaction_id}`` — ESPN's transaction ids are
    globally unique, so the per-week MERGE naturally dedupes any overlap.
    """
    data = fetch(
        season,
        ["mTransactions2"],
        extra_params={"scoringPeriodId": week},
        config=config,
    )
    txns = data.get("transactions", []) or []
    rows = [
        _row(f"{season}-{tx.get('id', f'{week}-{i}')}", tx, "mTransactions2")
        for i, tx in enumerate(txns)
    ]
    return [("TRANSACTIONS", rows)]


def matchups(config: ESPNConfig, season: int, week: int) -> list[TableRows]:
    """MATCHUPS — one row per matchup for a single scoring period (week).

    Payload is ESPN's raw ``schedule`` entry, including the nested per-player
    boxscore roster for both sides, rather than pre-parsed score fields.
    """
    data = fetch(
        season,
        ["mMatchupScore", "mBoxscore"],
        extra_params={"scoringPeriodId": week},
        config=config,
    )
    schedule = data.get("schedule", []) or []
    week_matchups = [m for m in schedule if m.get("matchupPeriodId") == week] or schedule
    rows = [
        _row(f"{season}-{week}-{m.get('id', i)}", m, "mMatchupScore,mBoxscore")
        for i, m in enumerate(week_matchups)
    ]
    return [("MATCHUPS", rows)]


def free_agents(config: ESPNConfig, season: int, week: int, limit: int = 3000) -> list[TableRows]:
    """FREE_AGENTS — a point-in-time snapshot of the unrostered player pool.

    Forward-only: ESPN doesn't expose historical free-agent pools, so this is
    never backfilled, only collected going forward. Over-fetches the player pool
    (``x-fantasy-filter`` header raises ESPN's default result cap) and filters
    client-side on ``onTeamId`` (0 / missing == unrostered), which is steadier
    than ESPN's undocumented ``filterStatus`` syntax.
    """
    # ESPN rejects a bare `limit` ("Limit request must be accompanied by a sort"),
    # so pair it with a percent-owned sort — descending, so the truncation (if
    # `limit` ever bites) drops the least-relevant deep waiver names, not the
    # ones anyone would pick up.
    espn_filter = {
        "players": {
            "limit": limit,
            "sortPercOwned": {"sortAsc": False, "sortPriority": 1},
        }
    }
    headers = {"x-fantasy-filter": json.dumps(espn_filter)}
    data = fetch(
        season,
        ["kona_player_info"],
        extra_params={"scoringPeriodId": week},
        headers=headers,
        config=config,
    )
    players = data.get("players", []) or []
    pool = [p for p in players if not p.get("onTeamId")]
    rows = [
        _row(f"{season}-{week}-{p.get('id', i)}", p, "kona_player_info")
        for i, p in enumerate(pool)
    ]
    log.info("free_agents: %d unrostered of %d players fetched", len(pool), len(players))
    return [("FREE_AGENTS", rows)]
