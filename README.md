# personal-snowflake

Personal data ecosystem — a monorepo covering both extraction (Python
scripts that land raw data into Snowflake) and transformation (dbt).

## Layout

```
personal-snowflake/
├── admin/         Snowflake account setup SQL (local only, gitignored)
├── dbt/           dbt project — transforms RAW.* into ANALYTICS.PROD
└── extraction/    Python scripts that extract from source APIs into RAW.*
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
