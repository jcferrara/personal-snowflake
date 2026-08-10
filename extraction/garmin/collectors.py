"""Declarative registry of Garmin daily/wellness metrics to extract.

Each entry maps a RAW.GARMIN table to the garminconnect client method that
produces it. Range collectors call a method that natively takes a
(start, end) window and return it in one call; daily collectors have no
range variant and are called once per date in the window.

Response shapes vary by endpoint and aren't all identical to what's been
spot-checked here — if a new collector's rows land with a numeric-suffix
fallback key instead of a real date (see `_row_key` below), check that
endpoint's actual payload and add its date field name.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any

from garminconnect import Garmin

DATE_KEY_FIELDS = ("calendarDate", "date", "summaryDate")


@dataclass(frozen=True)
class Collector:
    table: str
    method: str
    kind: str  # "range" or "daily"


RANGE_COLLECTORS = [
    Collector("STEPS", "get_daily_steps", "range"),
    Collector("BODY_BATTERY", "get_body_battery", "range"),
    Collector("BODY_COMPOSITION", "get_body_composition", "range"),
    Collector("WEIGH_INS", "get_weigh_ins", "range"),
    Collector("ENDURANCE_SCORE", "get_endurance_score", "range"),
    Collector("HILL_SCORE", "get_hill_score", "range"),
]

# The installed garminconnect version (pinned <0.3) only exposes single-day
# variants for these — no get_rhr_daily/get_sleep_daily/get_hrv_data_range
# range methods exist here, unlike some other versions of this library.
DAILY_COLLECTORS = [
    Collector("STATS", "get_stats", "daily"),
    Collector("RESTING_HEART_RATE", "get_rhr_day", "daily"),
    Collector("SLEEP", "get_sleep_data", "daily"),
    Collector("HRV", "get_hrv_data", "daily"),
    Collector("BODY_BATTERY_EVENTS", "get_body_battery_events", "daily"),
    Collector("ALL_DAY_STRESS", "get_all_day_stress", "daily"),
    Collector("TRAINING_READINESS", "get_training_readiness", "daily"),
    Collector("TRAINING_STATUS", "get_training_status", "daily"),
    Collector("FLOORS", "get_floors", "daily"),
    Collector("RESPIRATION", "get_respiration_data", "daily"),
    Collector("SPO2", "get_spo2_data", "daily"),
    Collector("INTENSITY_MINUTES", "get_intensity_minutes_data", "daily"),
    Collector("MAX_METRICS", "get_max_metrics", "daily"),
    Collector("HYDRATION", "get_hydration_data", "daily"),
]

ALL_COLLECTORS = RANGE_COLLECTORS + DAILY_COLLECTORS


def _row_key(item: Any, fallback: str) -> str:
    if isinstance(item, dict):
        for field in DATE_KEY_FIELDS:
            if item.get(field):
                return str(item[field])
    return fallback


MAX_RANGE_DAYS = 27  # several usersummary-service endpoints 400 on windows wider than ~28 days


def _chunk_ranges(start: date, end: date, max_days: int) -> list[tuple[date, date]]:
    chunks = []
    chunk_start = start
    while chunk_start <= end:
        chunk_end = min(chunk_start + timedelta(days=max_days - 1), end)
        chunks.append((chunk_start, chunk_end))
        chunk_start = chunk_end + timedelta(days=1)
    return chunks


def fetch_range(client: Garmin, collector: Collector, start: date, end: date) -> list[dict]:
    method = getattr(client, collector.method)
    rows: list[dict] = []
    for chunk_start, chunk_end in _chunk_ranges(start, end, MAX_RANGE_DAYS):
        result = method(chunk_start.isoformat(), chunk_end.isoformat())
        if not result:
            continue
        items = [result] if isinstance(result, dict) else result
        rows.extend(
            {
                "natural_key": _row_key(item, f"{chunk_start.isoformat()}_{i}"),
                "raw_data": item,
                "source_method": collector.method,
            }
            for i, item in enumerate(items)
        )
    return rows


def fetch_daily(client: Garmin, collector: Collector, cdate: date) -> list[dict]:
    method = getattr(client, collector.method)
    result = method(cdate.isoformat())
    if not result:
        return []
    return [
        {
            "natural_key": cdate.isoformat(),
            "raw_data": result,
            "source_method": collector.method,
        }
    ]
