# Personal Snowflake Reporting

Dashboards built with [Observable Framework](https://observablehq.com/framework)
on top of the `ANALYTICS` database in Snowflake — the marts and metrics produced
by the `dbt/` project in this monorepo.

## Dashboards

- [**Body metrics**](./body-metrics) — weight, body-fat %, and BMI trends with
  7- and 14-day moving averages, from `metrics_daily_body_metrics`.

## How it works

Each dashboard's data is pulled at **build time** by a TypeScript data loader in
`src/data/`. Loaders query Snowflake with key-pair auth via `snowflake-sdk`
(shared client in `src/lib/snowflake.ts`) and emit JSON that Framework caches and
serves as a static file. Nothing hits Snowflake from the browser.

See [`README.md`](https://github.com/jcferrara/personal-snowflake/tree/main/reporting)
for setup and for adding a new dashboard.
