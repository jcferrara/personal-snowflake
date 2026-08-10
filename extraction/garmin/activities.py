"""Activities collector — paginated, keyed by activityId, newest first.

Unlike the date-windowed collectors in collectors.py, activities aren't
watermarked by date: we page through Garmin's activity list (newest first)
until we hit an activityId already landed in Snowflake.
"""
from __future__ import annotations

from garminconnect import Garmin

TABLE = "ACTIVITIES"
PAGE_SIZE = 100


def fetch_new_activities(client: Garmin, known_ids: set[str]) -> list[dict]:
    rows: list[dict] = []
    start = 0
    while True:
        page = client.get_activities(start, PAGE_SIZE)
        if not page:
            break
        hit_known = False
        for activity in page:
            activity_id = str(activity["activityId"])
            if activity_id in known_ids:
                hit_known = True
                break
            rows.append(
                {
                    "natural_key": activity_id,
                    "raw_data": activity,
                    "source_method": "get_activities",
                }
            )
        if hit_known or len(page) < PAGE_SIZE:
            break
        start += PAGE_SIZE
    return rows
