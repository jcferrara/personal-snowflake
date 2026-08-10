# extraction

Python scripts that pull data from source APIs and land it, incrementally,
into Snowflake's `RAW` database. Currently just Garmin Connect.

## Setup

1. From the repo root, install into the shared venv:
   ```
   source .venv/bin/activate
   pip install -r extraction/requirements.txt
   ```
2. Run the `RAW.GARMIN` schema/grants SQL in `admin/exact_grants.sql`
   (section 8) in Snowsight once, if you haven't already.
3. Copy `.env.example` to `.env` and fill in your Garmin credentials and
   Snowflake account/user/key path (see `~/.dbt/profiles.yml` for the values
   already in use by dbt, if you want to reuse the same account/key).

## Running

```
cd extraction
python -m garmin.main                       # every collector
python -m garmin.main --only stats,sleep     # a subset, useful for testing
```

The first run logs in to Garmin with your email/password (prompting for an
MFA code on stdin if your account has it enabled) and caches the session at
`~/.garminconnect`. Later runs reuse that cache and won't need MFA again
unless the refresh token expires.

Each collector tracks its own watermark in `RAW.GARMIN._EXTRACT_STATE`, so
re-running is incremental and safe to repeat (upserts are keyed, not
append-only).

For an initial historical load, pass `--since` to backfill the daily/range
collectors from a given date (activities are always backfilled in full,
since they're paged/deduped by ID rather than watermarked):

```
python -m garmin.main --since 2024-08-09
```

The daily collectors have no range API and are called once per day in the
window, so a multi-year `--since` means tens of thousands of sequential
Garmin API calls and a run of an hour or more, with a real risk of Garmin
rate-limiting partway through. After `--since` backfills each collector, its
watermark advances to today as normal, so subsequent runs go back to being
incremental.

## Cron

Example daily run at 6am, logging output:

```cron
0 6 * * * cd /path/to/personal-snowflake/extraction && /path/to/personal-snowflake/.venv/bin/python -m garmin.main >> /tmp/garmin_extract.log 2>&1
```

## Adding a new metric

Most Garmin endpoints just need a new row in `garmin/collectors.py`'s
`RANGE_COLLECTORS` or `DAILY_COLLECTORS` list (table name + client method
name) — no new SQL or write logic needed. Response shapes vary by endpoint;
if a collector's rows land with a fallback key instead of a real date, check
the endpoint's actual payload shape and extend `DATE_KEY_FIELDS` in
`collectors.py`.
