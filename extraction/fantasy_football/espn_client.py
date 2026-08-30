"""Direct HTTP client for ESPN's fantasy football v3 API.

ESPN doesn't publish or support this API — the shape here is the
community-reverse-engineered one, fetched with plain ``requests`` rather than a
third-party fantasy wrapper. Two things worth knowing:

1. The read host moved once already (April 2024, from ``fantasy.espn.com`` to
   ``lm-api-reads.fantasy.espn.com``). ``READ_HOST`` is the constant to change
   if requests start failing outright — a 401, by contrast, means the cookies.
2. Seasons from 2018 on live under ``/seasons/{year}/segments/0/leagues/{id}``;
   older seasons use ``/leagueHistory/{id}`` and come back as a single-element
   JSON list. ``_season_base_url`` and ``fetch`` handle both.

Private leagues need two cookies from a logged-in browser session — ``espn_s2``
and ``SWID`` (keep the surrounding braces on SWID). See ``extraction/README.md``.
"""
from __future__ import annotations

import logging
import os
import time
from datetime import date

import requests

log = logging.getLogger("fantasy_football")

READ_HOST = "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl"

# Seasons before this use the /leagueHistory/ URL shape instead of /seasons/.
HISTORY_CUTOVER_SEASON = 2018


class ESPNConfig:
    """League identity + cookies, read from the environment (see .env.example)."""

    def __init__(self) -> None:
        self.league_id = int(os.environ["ESPN_LEAGUE_ID"])
        self.espn_s2 = os.environ.get("ESPN_S2")
        self.swid = os.environ.get("ESPN_SWID")  # keep the surrounding {braces}
        self.first_season = int(os.environ.get("ESPN_FIRST_SEASON", "2015"))

    @property
    def cookies(self) -> dict[str, str]:
        if self.espn_s2 and self.swid:
            return {"espn_s2": self.espn_s2, "SWID": self.swid}
        return {}


def _season_base_url(season: int, config: ESPNConfig) -> str:
    if season >= HISTORY_CUTOVER_SEASON:
        return f"{READ_HOST}/seasons/{season}/segments/0/leagues/{config.league_id}"
    return f"{READ_HOST}/leagueHistory/{config.league_id}"


def fetch(
    season: int,
    views: list[str],
    *,
    extra_params: dict | None = None,
    headers: dict | None = None,
    config: ESPNConfig | None = None,
    retries: int = 3,
    backoff: float = 2.0,
) -> dict:
    """GET one or more ``view`` values for a season, returned as a single dict.

    Pre-2018 ``leagueHistory`` responses are JSON lists (one element per season
    the query matched); this normalizes them to element ``[0]``.
    """
    config = config or ESPNConfig()
    url = _season_base_url(season, config)
    params: dict = {"view": views}
    if season < HISTORY_CUTOVER_SEASON:
        params["seasonId"] = season
    if extra_params:
        params.update(extra_params)

    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            resp = requests.get(
                url, params=params, cookies=config.cookies, headers=headers, timeout=30
            )
            if resp.status_code == 401:
                raise RuntimeError(
                    "401 Unauthorized — for a private league this means ESPN_S2 / "
                    "ESPN_SWID are missing, wrong, or expired (see README)."
                )
            resp.raise_for_status()
            data = resp.json()
            if isinstance(data, list):
                data = data[0] if data else {}
            return data
        except Exception as e:  # noqa: BLE001 — retry any transport/HTTP error
            last_err = e
            if attempt == retries:
                break
            wait = backoff**attempt
            log.warning(
                "season=%s views=%s attempt=%d failed (%s); retrying in %.1fs",
                season, views, attempt, e, wait,
            )
            time.sleep(wait)
    raise RuntimeError(
        f"ESPN request failed for season={season} views={views} after {retries} attempts"
    ) from last_err


def season_range(config: ESPNConfig | None = None) -> range:
    """First season through the current calendar year (inclusive)."""
    config = config or ESPNConfig()
    return range(config.first_season, date.today().year + 1)
