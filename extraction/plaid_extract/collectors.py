"""Plaid endpoints -> RAW.PLAID row builders.

One collector per table. Each returns a list of (table, rows) pairs, where
every row is the {natural_key, raw_data, source_method} dict
snowflake_writer.upsert expects. Payloads land close to Plaid's raw response —
flattening happens later in dbt staging models, not here.
"""
from __future__ import annotations

import logging
from datetime import date
from typing import Any

from plaid.api.plaid_api import PlaidApi
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.investments_holdings_get_request import InvestmentsHoldingsGetRequest
from plaid.model.investments_transactions_get_request import InvestmentsTransactionsGetRequest
from plaid.model.investments_transactions_get_request_options import (
    InvestmentsTransactionsGetRequestOptions,
)
from plaid.model.transactions_sync_request import TransactionsSyncRequest

from .items import PlaidItem
from .plaid_client import call_with_retry

log = logging.getLogger("plaid_extract")

TableRows = tuple[str, list[dict[str, Any]]]

TRANSACTIONS_SYNC_PAGE_SIZE = 500
INVESTMENT_TRANSACTIONS_PAGE_SIZE = 500


def _row(natural_key: str, payload: Any, source_method: str) -> dict[str, Any]:
    return {"natural_key": natural_key, "raw_data": payload, "source_method": source_method}


def _dedupe_securities(securities: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Both investment endpoints return a SECURITIES bucket; the same
    security can repeat across pages/calls, so dedupe by security_id before
    upserting (last-write-wins, but the payload is reference data that
    rarely changes)."""
    by_id = {sec["security_id"]: sec for sec in securities}
    return list(by_id.values())


def accounts(client: PlaidApi, item: PlaidItem) -> list[TableRows]:
    """ACCOUNTS — full snapshot every run; balances change, MERGE updates in place."""
    resp = call_with_retry(
        lambda: client.accounts_get(AccountsGetRequest(access_token=item.access_token)),
        item_id=item.item_id,
        nickname=item.nickname,
    ).to_dict()
    rows = [
        _row(acct["account_id"], {**acct, "item_id": item.item_id}, "accounts_get")
        for acct in resp.get("accounts", [])
    ]
    return [("ACCOUNTS", rows)]


def transactions_sync(
    client: PlaidApi, item: PlaidItem, cursor: str | None
) -> tuple[list[TableRows], str]:
    """TRANSACTIONS — loops /transactions/sync while has_more, accumulating
    added/modified and removed. `removed` rows land with
    raw_data={"transaction_id": ..., "removed": true} and a distinct
    source_method so dbt staging decides how to interpret them — this
    extractor never deletes rows itself.

    Returns (table_rows, final_cursor). The caller persists final_cursor only
    after a successful upsert of these rows, so a crash mid-loop safely
    re-syncs from the last *persisted* cursor on the next run
    (transactions_sync is designed to be idempotent on retry).
    """
    rows: list[dict[str, Any]] = []
    while True:
        # TransactionsSyncRequest's `cursor` field is typed str — it must be
        # omitted entirely (not passed as None) for the very first sync.
        kwargs = {"access_token": item.access_token, "count": TRANSACTIONS_SYNC_PAGE_SIZE}
        if cursor is not None:
            kwargs["cursor"] = cursor
        resp = call_with_retry(
            lambda kwargs=kwargs: client.transactions_sync(TransactionsSyncRequest(**kwargs)),
            item_id=item.item_id,
            nickname=item.nickname,
        ).to_dict()

        for txn in resp.get("added", []) + resp.get("modified", []):
            rows.append(_row(txn["transaction_id"], {**txn, "item_id": item.item_id}, "transactions_sync"))
        for removed in resp.get("removed", []):
            rows.append(
                _row(
                    removed["transaction_id"],
                    {"transaction_id": removed["transaction_id"], "item_id": item.item_id, "removed": True},
                    "transactions_sync_removed",
                )
            )

        cursor = resp["next_cursor"]
        if not resp.get("has_more"):
            break

    return [("TRANSACTIONS", rows)], cursor


def investment_transactions(
    client: PlaidApi, item: PlaidItem, start_date: date, end_date: date
) -> list[TableRows]:
    """INVESTMENT_TRANSACTIONS + SECURITIES — offset-paginated
    /investments/transactions/get over [start_date, end_date]."""
    txn_rows: list[dict[str, Any]] = []
    securities: list[dict[str, Any]] = []
    offset = 0
    total: int | None = None

    while total is None or offset < total:
        current_offset = offset
        resp = call_with_retry(
            lambda: client.investments_transactions_get(
                InvestmentsTransactionsGetRequest(
                    access_token=item.access_token,
                    start_date=start_date,
                    end_date=end_date,
                    options=InvestmentsTransactionsGetRequestOptions(
                        count=INVESTMENT_TRANSACTIONS_PAGE_SIZE, offset=current_offset
                    ),
                )
            ),
            item_id=item.item_id,
            nickname=item.nickname,
        ).to_dict()

        page = resp.get("investment_transactions", [])
        for txn in page:
            txn_rows.append(
                _row(
                    txn["investment_transaction_id"],
                    {**txn, "item_id": item.item_id},
                    "investments_transactions_get",
                )
            )
        securities.extend(resp.get("securities", []))

        total = resp["total_investment_transactions"]
        offset += len(page)
        if not page:
            break  # defensive: avoid looping forever if a page ever comes back empty before offset==total

    security_rows = [
        _row(sec["security_id"], sec, "investments_transactions_get") for sec in _dedupe_securities(securities)
    ]
    return [("INVESTMENT_TRANSACTIONS", txn_rows), ("SECURITIES", security_rows)]


def holdings(client: PlaidApi, item: PlaidItem) -> list[TableRows]:
    """HOLDINGS + SECURITIES — full snapshot every run via
    /investments/holdings/get. No stable Plaid ID for a holding, so
    NATURAL_KEY is the {account_id}-{security_id} composite; MERGE updates
    quantity/value in place."""
    resp = call_with_retry(
        lambda: client.investments_holdings_get(InvestmentsHoldingsGetRequest(access_token=item.access_token)),
        item_id=item.item_id,
        nickname=item.nickname,
    ).to_dict()

    holding_rows = [
        _row(
            f"{h['account_id']}-{h['security_id']}",
            {**h, "item_id": item.item_id},
            "investments_holdings_get",
        )
        for h in resp.get("holdings", [])
    ]
    security_rows = [
        _row(sec["security_id"], sec, "investments_holdings_get")
        for sec in _dedupe_securities(resp.get("securities", []))
    ]
    return [("HOLDINGS", holding_rows), ("SECURITIES", security_rows)]
