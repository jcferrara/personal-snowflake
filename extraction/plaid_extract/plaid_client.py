"""Thin wrapper around the plaid-python SDK: client construction, plus
retry/backoff for transient errors and a distinguishable exception for
ITEM_LOGIN_REQUIRED.

Module (and package) name is `plaid_extract`, not `plaid` — the installed
plaid-python SDK itself imports as top-level `plaid`, and a package literally
named `plaid` living on `sys.path` (as this one would be, when run via
`python -m` from the `extraction/` working directory) would shadow it.
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Callable, TypeVar

import plaid
from plaid.api import plaid_api

log = logging.getLogger("plaid_extract")

T = TypeVar("T")

# Transient, worth retrying. ITEM_LOGIN_REQUIRED is handled separately below —
# it's not transient, it needs an interactive re-link.
RETRYABLE_ERROR_CODES = {"RATE_LIMIT_EXCEEDED", "INTERNAL_SERVER_ERROR", "PLANNED_MAINTENANCE"}
RETRYABLE_HTTP_STATUSES = {429, 500, 502, 503, 504}


class ItemLoginRequiredError(Exception):
    """The Item's access_token is still valid, but Plaid needs the user to
    re-authenticate interactively via Link's "update mode" — which can't
    happen in CI. Caller should skip this item for the run, not retry."""

    def __init__(self, item_id: str, nickname: str) -> None:
        self.item_id = item_id
        self.nickname = nickname
        super().__init__(f"item_id={item_id} ({nickname}): ITEM_LOGIN_REQUIRED")


def get_client() -> plaid_api.PlaidApi:
    env = os.environ.get("PLAID_ENV", "production").lower()
    host = {"sandbox": plaid.Environment.Sandbox, "production": plaid.Environment.Production}[env]
    configuration = plaid.Configuration(
        host=host,
        api_key={
            "clientId": os.environ["PLAID_CLIENT_ID"],
            "secret": os.environ["PLAID_SECRET"],
        },
    )
    return plaid_api.PlaidApi(plaid.ApiClient(configuration))


def call_with_retry(
    fn: Callable[[], T],
    *,
    item_id: str,
    nickname: str,
    retries: int = 3,
    backoff: float = 2.0,
) -> T:
    """Call a single plaid-python SDK request (passed as a zero-arg closure),
    retrying transient errors with exponential backoff — mirrors
    espn_client.fetch's retry loop.

    Raises ItemLoginRequiredError immediately (never retried) when Plaid
    reports error_code == ITEM_LOGIN_REQUIRED. Any other non-retryable error
    is re-raised immediately rather than masked by retries.
    """
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            return fn()
        except plaid.ApiException as e:
            body = json.loads(e.body) if e.body else {}
            error_code = body.get("error_code")
            if error_code == "ITEM_LOGIN_REQUIRED":
                raise ItemLoginRequiredError(item_id, nickname) from e
            if error_code not in RETRYABLE_ERROR_CODES and e.status not in RETRYABLE_HTTP_STATUSES:
                raise
            last_err = e
            if attempt == retries:
                break
            wait = backoff**attempt
            log.warning(
                "item=%s (%s) attempt=%d failed (%s); retrying in %.1fs",
                item_id, nickname, attempt, error_code or e.status, wait,
            )
            time.sleep(wait)
    raise RuntimeError(
        f"item={item_id} ({nickname}): Plaid request failed after {retries} attempts"
    ) from last_err
