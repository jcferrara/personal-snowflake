# personal-snowflake

Personal data ecosystem — a monorepo covering extraction (Python scripts
that land raw data into Snowflake), transformation (dbt), and reporting
(Observable Framework).

## Layout

```
personal-snowflake/
├── admin/         Snowflake account setup SQL (local only, gitignored)
├── dbt/           dbt project — transforms RAW.* into ANALYTICS.PROD
├── extraction/    Python scripts that extract from source APIs into RAW.*
└── reporting/     Observable Framework dashboards over ANALYTICS.*
```

## dbt

```
cd dbt
dbt deps
dbt run
```

Uses the `personal_snowflake` profile in `~/.dbt/profiles.yml`, role
`TRANSFORMER` / warehouse `TRANSFORM_WH`.

## extraction

See [extraction/README.md](extraction/README.md).

## reporting

Observable Framework app that reads `ANALYTICS.*` via `snowflake-sdk` data
loaders and renders static dashboards. Needs Node 18+.

```
cd reporting
npm install
cp .env.example .env
npm run dev
```

See [reporting/README.md](reporting/README.md).
