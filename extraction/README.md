# extraction

Python scripts that pull data from source APIs and land it, incrementally,
into Snowflake's `RAW` database. One self-contained package per source:

- **`garmin/`** → `RAW.GARMIN` — Garmin Connect wellness/activity data.
- **`fantasy_football/`** → `RAW.FANTASY_FOOTBALL` — an ESPN fantasy football
  league, pulled straight from ESPN's undocumented v3 API (no wrapper package).

Every landed table across both sources has the same four columns —
`NATURAL_KEY`, `RAW_DATA` (VARIANT JSON), `EXTRACTED_AT`, `SOURCE_METHOD` —
and writes are idempotent MERGEs keyed by `NATURAL_KEY`. Flattening the JSON
is a dbt staging concern, not done here. Snowflake auth is key-pair (the same
account/key dbt uses); the shared `.env` (see `.env.example`) holds every
source's config, with `SNOWFLAKE_SCHEMA` set per run.

# Garmin Connect

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

# ESPN Fantasy Football

Pulls one ESPN fantasy football league directly from ESPN's (unofficial,
undocumented) fantasy v3 API — no third-party wrapper — and lands it in
`RAW.FANTASY_FOOTBALL` as raw JSON.

### What it lands

| Table | Grain (`NATURAL_KEY`) | Source view(s) |
| --- | --- | --- |
| `LEAGUE_SETTINGS` | `{season}` | `mSettings,mTeam` |
| `TEAMS` | `{season}-{team_id}` | `mSettings,mTeam` |
| `MEMBERS` | `{season}-{member_id}` | `mSettings,mTeam` |
| `DRAFT_PICKS` | `{season}-{overall_pick}` | `mDraftDetail` |
| `TRANSACTIONS` | `{season}-{transaction_id}` | `mTransactions2` |
| `MATCHUPS` | `{season}-{week}-{matchup_id}` | `mMatchupScore,mBoxscore` |
| `FREE_AGENTS` | `{season}-{week}-{player_id}` | `kona_player_info` |

`MATCHUPS` payloads carry the full nested per-player boxscore roster for both
sides — flatten it in dbt, not here. `FREE_AGENTS`, despite the name, is a
weekly snapshot of the **whole** player pool — rostered players included, with
`onTeamId` on each row so dbt can split them — so ownership %, projections and
ratings land for every player, not just the waiver wire. Because every table shares the raw
four-column shape, the `RAW_DATA:` / `RAW_DATA::` VARIANT path syntax is how
dbt staging reads it (same as `RAW.GARMIN`).

## Setup

1. Install into the shared venv (`pip install -r extraction/requirements.txt`).
2. Run section 10 (`RAW.FANTASY_FOOTBALL`) of `admin/exact_grants.sql` in
   Snowsight once, if you haven't. The extractor auto-creates the tables; that
   block just creates the schema and grants `EXTRACTOR`.
3. Get your **league ID** from the league URL
   (`.../league?leagueId=123456` → `123456`).
4. For a private league, get two cookies from a logged-in
   [fantasy.espn.com](https://fantasy.espn.com) session: DevTools →
   Application/Storage → Cookies → copy `espn_s2` and `SWID` (keep SWID's
   surrounding `{braces}`). These last months; a sudden `401` means they
   expired — grab fresh ones.
5. Fill `ESPN_LEAGUE_ID`, `ESPN_S2`, `ESPN_SWID`, `ESPN_FIRST_SEASON` in `.env`.

## Running

```
cd extraction
python -m fantasy_football.explore            # dump sample_*.json — inspect the real shape first
python -m fantasy_football.main               # current season, weeks 1..current + a free-agent snapshot
python -m fantasy_football.main --backfill    # every season since ESPN_FIRST_SEASON
python -m fantasy_football.main --seasons 2022 2023
python -m fantasy_football.main --only draft,transactions
python -m fantasy_football.main --weeks 1-6   # override the matchup week range
```

Writes MERGE on `NATURAL_KEY`, so re-running (or re-running a failed job) is
safe and never duplicates. There's no watermark table: the current season is
cheap to re-pull in full, and past seasons are immutable. If one collector
errors mid-run, the rest of that season still runs.

**By design:** `FREE_AGENTS` is a snapshot of the pool *right now* — ESPN
exposes no historical pool, so it's forward-only and skipped for any season
before the current one (including during `--backfill`). Runs 3x/week overwrite
that week's rows, so one snapshot per week is retained (the last run). Pre-2018 seasons use a
different ESPN URL shape (`leagueHistory` vs `seasons/{year}`) and are the most
likely to have drifted field names — run `explore.py <season>` against an old
season before backfilling it.

## Cron

```cron
0 6 * 9,10,11,12,1 2 cd /path/to/personal-snowflake/extraction && /path/to/personal-snowflake/.venv/bin/python -m fantasy_football.main >> /tmp/ff_extract.log 2>&1
```

## GitHub Actions

`.github/workflows/fantasy_football_extract.yml` runs the extraction ~6am
Pacific on Tuesdays during the season (Sep–Jan) and can be triggered manually
(`workflow_dispatch`) — its `seasons` input maps to `--seasons` for a one-off
historical backfill on the runner.

It reuses the Garmin workflow's `SNOWFLAKE_*` secrets and key handling, so the
only new secrets to add are the ESPN ones:

```
gh secret set ESPN_LEAGUE_ID
gh secret set ESPN_S2
gh secret set ESPN_SWID
gh secret set ESPN_FIRST_SEASON
```

The extraction writes to `RAW.FANTASY_FOOTBALL` unconditionally
(`snowflake_writer.SCHEMA`), so the Garmin-oriented `SNOWFLAKE_SCHEMA` in the
shared `.env` / secrets is ignored here — nothing to change.

## Adding a collector

Add a function to `fantasy_football/collectors.py` that returns
`[(TABLE_NAME, rows)]` (each row `{natural_key, raw_data, source_method}`),
then register it in `main.py` under `SEASON_COLLECTORS`, `WEEK_COLLECTORS`, or
`SNAPSHOT_COLLECTORS` depending on its grain. No SQL or write-path changes —
`snowflake_writer.upsert` creates the table on first run.
