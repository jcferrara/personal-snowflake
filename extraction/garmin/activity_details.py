"""Activity details collector — per-activity time-series metrics (heart rate,
cadence, speed, GPS, body battery) sampled throughout an activity.

Unlike the date-windowed collectors in collectors.py, this isn't watermarked
by date: it's driven off the set of activity IDs already landed in
RAW.GARMIN.ACTIVITIES, one get_activity_details call per activity.
"""
from __future__ import annotations

from garminconnect import Garmin

TABLE = "ACTIVITY_DETAILS"


def fetch_activity_detail(client: Garmin, activity_id: str) -> dict | None:
    details = client.get_activity_details(activity_id)
    if not details:
        return None
    return {
        "natural_key": str(activity_id),
        "raw_data": details,
        "source_method": "get_activity_details",
    }
