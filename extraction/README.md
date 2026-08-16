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

## GitHub Actions

`.github/workflows/garmin_extract.yml` runs the extraction once a day at
2am Pacific (two `cron` entries handle the PST/PDT switch, since Actions
schedules are UTC-only — see the workflow file for the ~1 week of fuzz
around each DST transition). It can also be triggered manually from the
Actions tab (`workflow_dispatch`).

The runner starts from nothing each time, so it needs your Garmin session
cache and Snowflake key handed to it as repo secrets rather than reading
them off disk like a local run does:

1. **Garmin session** — the workflow restores `~/.garminconnect` from a
   `GARMIN_TOKEN_STORE` secret so it never has to log in (and hit an MFA
   prompt) on the runner. Seed it from a cache you've already logged in
   with locally:
   ```
   tar -C ~/.garminconnect -czf - oauth1_token.json oauth2_token.json | base64 | gh secret set GARMIN_TOKEN_STORE
   ```
   The long-lived `oauth1_token.json` is what actually needs to stay valid;
   Garmin expires it roughly once a year, at which point the workflow will
   start failing on login and this needs to be re-run after a fresh local
   login.

2. **Garmin proxy** — GitHub-hosted runners live on Azure/cloud IP ranges,
   which Garmin's Cloudflare front blocks with a 429 on the OAuth token
   exchange even when the cached session above is valid. Routing that one
   call through a residential/ISP proxy fixes it. We use a
   [Webshare](https://www.webshare.io/) static residential (ISP) proxy IP —
   grab its connection details from the Webshare dashboard's Proxy List page
   (`http://username:password@host:port`) and set it as a secret:
   ```
   gh secret set GARMIN_PROXY_URL
   ```
   `garmin_client.py` only routes the Garmin login/API calls through it —
   Snowflake isn't IP-blocked, so that connection stays direct. Leaving
   `GARMIN_PROXY_URL` unset (the default for local runs) talks to Garmin
   directly, same as before.

3. **Snowflake private key**:
   ```
   base64 < /path/to/your/rsa_key.p8 | gh secret set SNOWFLAKE_PRIVATE_KEY_B64
   ```
   Add `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` too if your key is encrypted.

4. **Everything else**, one secret per env var from `.env.example`:
   ```
   gh secret set GARMIN_EMAIL
   gh secret set GARMIN_PASSWORD
   gh secret set SNOWFLAKE_ACCOUNT
   gh secret set SNOWFLAKE_USER
   gh secret set SNOWFLAKE_ROLE
   gh secret set SNOWFLAKE_WAREHOUSE
   gh secret set SNOWFLAKE_DATABASE
   gh secret set SNOWFLAKE_SCHEMA
   ```
   (`gh secret set NAME` with no `--body` prompts for the value, or reads
   stdin if piped, so nothing sensitive ends up in shell history.)

## Adding a new metric

Most Garmin endpoints just need a new row in `garmin/collectors.py`'s
`RANGE_COLLECTORS` or `DAILY_COLLECTORS` list (table name + client method
name) — no new SQL or write logic needed. Response shapes vary by endpoint;
if a collector's rows land with a fallback key instead of a real date, check
the endpoint's actual payload shape and extend `DATE_KEY_FIELDS` in
`collectors.py`.
