"""Loads linked Plaid Items (bank/brokerage institutions) from the
PLAID_ACCESS_TOKENS env var — a JSON array of {item_id, access_token,
nickname}, grown over time by running `link_item.py` once per institution.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class PlaidItem:
    item_id: str
    access_token: str
    nickname: str


def load_items() -> list[PlaidItem]:
    raw = os.environ.get("PLAID_ACCESS_TOKENS", "").strip()
    if not raw:
        raise RuntimeError(
            "PLAID_ACCESS_TOKENS is unset or empty — link at least one institution "
            "with `python -m plaid_extract.link_item` first (see extraction/README.md)."
        )
    try:
        entries = json.loads(raw)
    except json.JSONDecodeError as e:
        raise RuntimeError("PLAID_ACCESS_TOKENS is not valid JSON") from e
    if not isinstance(entries, list) or not entries:
        raise RuntimeError("PLAID_ACCESS_TOKENS must be a non-empty JSON array")
    return [
        PlaidItem(
            item_id=entry["item_id"],
            access_token=entry["access_token"],
            nickname=entry.get("nickname", entry["item_id"]),
        )
        for entry in entries
    ]
