"""Snowflake connection + generic staged-MERGE upsert for the RAW.GARMIN layer.

Every landed table has the same shape: (NATURAL_KEY, RAW_DATA VARIANT,
EXTRACTED_AT, SOURCE_METHOD). Flattening the JSON payload happens later in
dbt staging models, not here.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

import pandas as pd
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from snowflake.connector.pandas_tools import write_pandas


def _load_private_key_bytes(path: str) -> bytes:
    passphrase = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
    with open(path, "rb") as f:
        p_key = serialization.load_pem_private_key(
            f.read(),
            password=passphrase.encode() if passphrase else None,
        )
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def connect() -> snowflake.connector.SnowflakeConnection:
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key=_load_private_key_bytes(os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]),
        role=os.environ.get("SNOWFLAKE_ROLE", "EXTRACTOR"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "EXTRACT_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "RAW"),
        schema=os.environ.get("SNOWFLAKE_SCHEMA", "GARMIN"),
    )


def existing_keys(conn: snowflake.connector.SnowflakeConnection, table: str) -> set[str]:
    """Natural keys already landed for `table`, or empty set if it doesn't exist yet."""
    cur = conn.cursor()
    try:
        cur.execute(f"SELECT NATURAL_KEY FROM {table.upper()}")
    except snowflake.connector.errors.ProgrammingError:
        return set()
    return {str(row[0]) for row in cur.fetchall()}


def upsert(conn: snowflake.connector.SnowflakeConnection, table: str, rows: list[dict[str, Any]]) -> int:
    """Stage `rows` and MERGE them into RAW.GARMIN.<table>, keyed by NATURAL_KEY.

    Each row must have keys: natural_key, raw_data (JSON-serializable), source_method.
    """
    if not rows:
        return 0

    table_u = table.upper()
    stg_table = f"STG_{table_u}"
    now = datetime.now(timezone.utc).isoformat()

    # EXTRACTED_AT travels through staging as a plain ISO string, then gets cast
    # with TO_TIMESTAMP_NTZ in the MERGE below — write_pandas + a tz-aware
    # pandas Timestamp column round-trips through parquet in a way Snowflake's
    # TIMESTAMP_NTZ merge target rejects ("Timestamp ... is not recognized").
    df = pd.DataFrame(
        [
            {
                "NATURAL_KEY": str(row["natural_key"]),
                "RAW_DATA": json.dumps(row["raw_data"], default=str),
                "EXTRACTED_AT": now,
                "SOURCE_METHOD": row["source_method"],
            }
            for row in rows
        ]
    )

    cur = conn.cursor()
    cur.execute(
        f"""
        CREATE TABLE IF NOT EXISTS {table_u} (
            NATURAL_KEY VARCHAR,
            RAW_DATA VARIANT,
            EXTRACTED_AT TIMESTAMP_NTZ,
            SOURCE_METHOD VARCHAR
        )
        """
    )
    cur.execute(
        f"""
        CREATE OR REPLACE TEMPORARY TABLE {stg_table} (
            NATURAL_KEY VARCHAR,
            RAW_DATA STRING,
            EXTRACTED_AT STRING,
            SOURCE_METHOD VARCHAR
        )
        """
    )

    write_pandas(conn, df, stg_table)

    cur.execute(
        f"""
        MERGE INTO {table_u} t
        USING {stg_table} s
        ON t.NATURAL_KEY = s.NATURAL_KEY
        WHEN MATCHED THEN UPDATE SET
            RAW_DATA = PARSE_JSON(s.RAW_DATA),
            EXTRACTED_AT = TO_TIMESTAMP_NTZ(s.EXTRACTED_AT),
            SOURCE_METHOD = s.SOURCE_METHOD
        WHEN NOT MATCHED THEN INSERT (NATURAL_KEY, RAW_DATA, EXTRACTED_AT, SOURCE_METHOD)
        VALUES (s.NATURAL_KEY, PARSE_JSON(s.RAW_DATA), TO_TIMESTAMP_NTZ(s.EXTRACTED_AT), s.SOURCE_METHOD)
        """
    )
    return len(rows)
