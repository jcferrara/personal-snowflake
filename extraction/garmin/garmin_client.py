"""Garmin Connect login wrapper.

Tokens are cached at ~/.garminconnect (garth's default, mode 0600, outside the
repo) so runs after the first reuse the cached session instead of
re-authenticating. `Garmin.login(tokenstore)` only *loads* an existing cache
(and auto-refreshes an expired-but-present token) — it raises if the cache
doesn't exist yet, so the very first run has to fall back to a fresh
credential login and then write the cache itself, prompting for an MFA code
on stdin if the account has it enabled.
"""
from __future__ import annotations

import os
from pathlib import Path

from garminconnect import Garmin

TOKEN_STORE = str(Path.home() / ".garminconnect")


def get_client() -> Garmin:
    client = Garmin(
        email=os.environ["GARMIN_EMAIL"],
        password=os.environ["GARMIN_PASSWORD"],
        prompt_mfa=lambda: input("Garmin MFA code: "),
    )
    # Garmin's Cloudflare front blocks datacenter/cloud ASNs (e.g. GitHub-hosted
    # runners) on the OAuth token exchange with a 429, even for an
    # already-cached session. Routing through a residential/ISP proxy avoids it;
    # unset (the default for local runs) talks to Garmin directly.
    if proxy_url := os.environ.get("GARMIN_PROXY_URL"):
        client.garth.configure(proxies={"http": proxy_url, "https": proxy_url})
    try:
        client.login(TOKEN_STORE)
    except FileNotFoundError:
        client.login()
        client.garth.dump(TOKEN_STORE)
    return client
