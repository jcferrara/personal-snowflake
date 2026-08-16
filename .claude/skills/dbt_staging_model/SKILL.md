---
name: dbt_staging_model
description: Use when creating, modifying, or reviewing dbt staging models (stg_[source]__[entity]s).
---

# dbt Staging Models

Staging models are the **atomic building blocks** of the project: they condense raw
source data into clean, source-conformed concepts. One staging model per source table.

## Shared references (read these)

- [../_shared/project_structure.md](../_shared/project_structure.md) — folder layout,
  organize staging by source system
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming, keys, field
  ordering by type
- [../_shared/sql_style.md](../_shared/sql_style.md) — CTE structure, formatting
- [../_shared/yaml_style.md](../_shared/yaml_style.md) — sources/models YAML and tests
- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md) —
  why staging is a view

## Rules

1. **1-to-1 with the source, references only a `source()`.** Exactly one staging model
   per source table. Staging is the **only place** the `source()` macro is used. A
   staging model takes exactly one `source()` and **no joins** — if you need to join
   another table (a crosswalk, a deletes table, a second source), that's modeling, so it
   goes in an **intermediate model**, not here (see rule 3).
2. **Preserve grain.** Do not aggregate or group — that changes grain and loses access
   to source data needed downstream. Keep one row per source row.
3. **No joins, no business logic** (with the exceptions below). Joining here duplicates
   computation and creates confusing relationships that ripple downstream.
4. **Light cleanup only.** Allowed: renaming, type casting, basic computations (e.g.
   cents→dollars `amount / 100.0`), and categorizing with `case` statements (buckets,
   booleans).
5. **Apply DRY upstream.** If a transformation will be needed in *every* downstream
   model (always cast a date, always convert cents), do it here once.
6. **Naming:** `stg_[source]__[entity]s.sql` — double underscore between source and
   entity, plural entity. Organize files in `models/staging/[source_system]/`.
7. **Field naming and ordering** per dbt_model_style.md: rename to business terms,
   booleans `is_`/`has_`, timestamps `_at` (UTC), dates `_date`, primary key
   `<object>_id` (string). Order columns **ids → strings → numerics → booleans → dates
   → timestamps**, with comment markers per group.
8. **Materialize as views** (the default). Set it for the staging folder in
   `dbt_project.yml` for clarity: `staging: +materialized: view`.

## Standard pattern (two CTEs)

```sql
-- stg_finance__transactions.sql
with source as (
    select * from {{ source('finance', 'transaction') }}
),
renamed as (
    select
        -- ids
        id as transaction_id,
        acctid as account_id,
        -- strings
        merchantname as merchant_name,
        case
            when category in ('groceries', 'dining', 'transit')
                then 'essential'
            else 'discretionary'
        end as spend_type,
        status,
        -- numerics
        amount as amount_cents,
        amount / 100.0 as amount_usd,
        -- booleans
        case when status = 'posted' then true else false end as is_posted,
        -- dates
        date_trunc('day', posted) as posted_date,
        -- timestamps
        posted::timestamp_ltz as posted_at
    from source
)
select * from renamed
```

- `source` CTE = import (pulls the source table). `renamed` CTE = logic. Final line is
  `select * from renamed`.

## Joins belong in intermediate, not staging

Staging never joins. If a transformation needs another table — re-keying via a crosswalk,
deriving `is_deleted` from a separate deletes table, relating two source entities — that's
modeling, and it goes in an **intermediate model** that `ref()`s the relevant staging
models. This is the established pattern in this repo: every real join lives in `int_`.
Keep each `stg_` as one clean, source-conformed concept so it stays reusable by any
downstream model that wants to join it differently.

A model that grows an inline join is tech debt the moment it lands — refactor the join
into `int_` before it ships, not after.

**`base_` models are not a join escape hatch.** A `base/` subfolder is only for landing a
raw source into the warehouse before a passthrough `stg_` reads it (e.g. a Snowflake
Marketplace share materialized as a table, or an incremental append landing). Base models
do **not** join — if you reach for a base model to perform a join, the join belongs in
intermediate instead.

The one genuinely grain-preserving case that stays in staging is **unioning disparate but
symmetrical sources** (e.g. symmetrical CSV exports from two different brokerage
accounts sharing the same schema, unioned into one entity) — a union produces a single
logical concept, not a join, so it's still source-conforming.

## Cleanup logic — when to add it

Staging is usually a passthrough, but defensive logic belongs here when the source has
known data-quality issues that would break downstream joins:

- **Dedup** when the source allows duplicates on a key downstream models join on:
  ```sql
  qualify row_number() over (
      partition by natural_key
      order by extracted_at desc nulls last, id desc
  ) = 1
  ```
  Be conservative with the partition key — partitioning by a column that's null for most
  rows collapses all null-keyed rows to one. Use a
  `case when key is null then 1 else row_number() ... end = 1` pattern when null keys
  should pass through.
- **Coalesce a defensive default** when an FK can be missing but downstream needs
  something (e.g. missing `timezone` would null out every `convert_timezone(...)`):
  `coalesce(timezone, 'America/Los_Angeles')` — and comment why.
- **Filter** only when source rows are genuinely garbage (test records, soft-deletes).
  Don't silently drop work-in-progress data — prefer `severity: warn` on the test.

## Garmin RAW landing shape

Garmin data lands as **semi-structured JSON**, not a relational source. Every
`RAW.GARMIN.<table>` has exactly four columns — `NATURAL_KEY`, `RAW_DATA` (a `VARIANT`
JSON blob), `EXTRACTED_AT`, and `SOURCE_METHOD` (the garminconnect client method that
produced the row; see `extraction/garmin/snowflake_writer.py` and
`extraction/garmin/collectors.py`). A Garmin staging model's `renamed` CTE flattens the
fields you need out of `raw_data` with `:` / `::` path syntax instead of simple column
renames:

```sql
-- stg_garmin__sleep.sql
with source as (
    select * from {{ source('garmin', 'sleep') }}
),
renamed as (
    select
        -- ids
        natural_key as sleep_id,
        -- numerics
        raw_data:dailySleepDTO.sleepTimeSeconds::int as sleep_time_seconds,
        -- dates
        raw_data:calendarDate::date as sleep_date,
        -- timestamps
        extracted_at::timestamp_ntz as extracted_at
    from source
)
select * from renamed
```

Always carry `extracted_at` and `source_method` through to the end of the `renamed`
select, under their own comment block (consistent order across all Garmin staging
models) — they're the only lineage/freshness signal this source gives you, since
Garmin's daily/range endpoints have no `updated_at` concept of their own.

## YAML, tests, documentation

- This repo uses the dbt Labs default: `models/staging/<source>/_<source>__sources.yml`
  for source definitions and `models/staging/<source>/_<source>__models.yml` for every
  staging model's tests/docs in that source folder. See
  [../_shared/project_structure.md](../_shared/project_structure.md).
- **Test only the primary key: `unique` + `not_null`.** Do not add tests on other
  columns unless explicitly asked — the source may allow nulls and extra tests become
  noisy warnings. See the testing convention in
  [../_shared/sql_style.md](../_shared/sql_style.md).
- **Document every column** in `_<source>__models.yml` with a helpful
  description (including any cleanup/business logic applied), and keep it in sync with the
  SQL. See the `dbt_model_documentation` skill.

## Validation steps

1. **`dbt compile --select stg_<source>__<entity>`** — confirm it compiles (structural).
2. **`dbt build --select stg_<source>__<entity>`** — run + test the model when logic
   changed.
3. Confirm grain is unchanged (row count vs. source; primary-key uniqueness test
   passes).
4. Run SQL linting if configured (SQLFluff).

## Tooling note

`dbt-codegen` can generate staging models and source YAML once you're comfortable
writing them by hand — staging follows rote, 1-per-source-table patterns.
