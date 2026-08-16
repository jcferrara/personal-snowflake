# Materialization Guidance (shared reference)

Available materializations, how to configure them, incremental behavior and best
practices, and how to examine builds. Sources: dbt Labs "Materializations best
practices" (available materializations, configuring, incremental models, best
practices, examining builds).

## The four materializations

dbt ships four basic materializations. Three (view, table, incremental) power ~99% of
modeling needs; the fourth (ephemeral) is for specific use cases.

### View (the default)

- Stores **only the SQL logic** in the warehouse, **not the data**. Builds almost
  instantly, costs almost nothing to build.
- Always reflects the **most up-to-date** input data (run fresh on every query).
- **Tradeoff:** processed on every query → slower to return than a table of the same
  data, and can cost more over time if the transformation is intensive and queried
  often.

### Table

- Stores **the data itself** (rows and columns on disk), packing all transformation
  compute into a single build run.
- **Faster, more responsive** queries; ideal for models queried regularly.
- **Improves compute costs** in most cases: compute is far more expensive than storage,
  so paying transformation compute once per build beats paying it on every query.
- **Tradeoff:** only as fresh as the most recent run. A table built hourly at 10:00
  holds data up to 10:00 until the next run.

### Incremental

- Builds a **table in pieces over time**, only adding/updating new or changed records.
  Builds more quickly than a full table of the same logic.
- **Tradeoffs:** initial run is slow (equivalent to a full table build on large data);
  adds complexity (layering and timing); can drift from source data over time, so extra
  effort is needed to capture historical changes. See incremental section below.

### Ephemeral

- Not built as an object in the warehouse; **interpolated as a CTE** into models that
  reference it. Keeps non-final building blocks out of the warehouse.
- **Tradeoff:** harder to troubleshoot since there's no queryable object. If you need
  to inspect results in development, materialize as a **view in a custom schema with
  restricted permissions** instead.

### Comparison

| Dimension | View | Table | Incremental |
| --- | --- | --- | --- |
| Build time | fastest (logic only) | slowest (linear to data) | medium (builds a portion) |
| Build cost | lowest (no data processed) | highest (all data) | medium (some data) |
| Query cost | higher (reprocess each query) | lower (data in warehouse) | lower (data in warehouse) |
| Freshness | best (up to the query) | moderate (up to last build) | moderate (up to last build) |
| Complexity | simple | simple | moderate (logical complexity) |

**Time is money:** "time" in the warehouse means compute time, the primary driver of
cost — which is why the time and cost rows track together.

## Configuring materializations

### In a model (Jinja config block)

```sql
{{ config(materialized='view') }}
select ...
```

```sql
{{ config(materialized='table') }}
select ...
```

Python:

```python
def model(dbt, session):
    dbt.config(materialized="table")
    return model_df
```

- `materialized` declares the **outcome** you want; the executed SQL depends on the
  adapter but results are equivalent across adapters (declarative approach).
- **Python models cannot be materialized as views**, and not all adapters support
  Python.

### At the folder level in `dbt_project.yml` (preferred for defaults)

```yaml
# dbt_project.yml
models:
  personal_snowflake:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
      finance:
        +schema: finance
      health:
        +schema: health
```

- **Configs cascade — the more specific scope takes precedence.** This keeps config DRY
  so you only specify exceptions, not the same materialization in every model.
- Override the folder default in an individual model's config block when needed.

## Choosing a materialization — the golden rule

> **Start with views. When they take too long to query, make them tables. When the
> tables take too long to build, make them incremental.**

Start simple and only add complexity as necessary.

- **Views** — freshest, real-time state; great building blocks and for small datasets
  with light logic needing near-real-time access. The dbt default.
- **Tables** — most performant; great for things end users touch (e.g. a mart serving a
  popular dashboard) and for frequently used, compute-intensive transformations.
- **Incremental** — same purposes as tables, but for larger datasets so they can be
  built and accessed performantly. Decide table vs. incremental by whether you can
  process the whole table at once or need to do it in chunks. Don't rush to make all
  marts incremental by default — it introduces superfluous difficulty.

### By layer

- **Staging:** views. Rarely queried directly, need to stay in sync with source as
  building blocks. Views are the default, but specifying `+materialized: view` is good
  for clarity.
- **Intermediate:** ephemeral (keeps building blocks out of the warehouse), or views in
  a custom restricted schema when you need visibility for troubleshooting.
- **Marts:** tables or incremental. End users touch them and need performance; many
  domains are fine with hourly/daily refreshed data.

> **This repo's overrides — materialization by layer** (set in `dbt_project.yml`):
> - **Intermediate models are materialized as `view`** (not ephemeral). Views let you
>   query mid-pipeline state directly in Snowsight while iterating, instead of only
>   being able to see the interpolated result inside a downstream model. Set it
>   explicitly with `{{ config(materialized = 'view') }}` at the top of the file if you
>   ever override the folder default.
> - **Marts are `table`** (or `incremental` for very large/append-heavy facts). Always
>   specify `materialized = 'table'` explicitly in a `config()` block even though it's
>   the project default — it makes intent obvious to readers.
> - **Staging stays `view`** (the project default; `staging: +materialized: view`).

## Incremental models in depth

### When they make sense

Use incremental when the source data is very large and/or transformations are
compute-intensive, making a full rebuild too slow/costly. If you can afford a full
**table** rebuild (time, compute, money), that's the simplest and most accurate option.
Only go incremental when you can't realistically rebuild the whole table.

### Three things you need

1. A **filter** to select just new/updated records.
2. A **conditional block** that wraps the filter and applies it only when wanted.
3. **Configuration** telling dbt to build incrementally.

### The `{{ this }}` keyword

`{{ this }}` references this model's table **as built in the last run**. So
`max(updated_at) from {{ this }}` is the most recent record processed last run — your
cutoff.

### Standard pattern

```sql
{{
   config(
       materialized='incremental',
       unique_key='transaction_id'
   )
}}
select * from transactions
{% if is_incremental() %}
where updated_at > (select max(updated_at) from {{ this }})
{% endif %}
```

- On the **first run** (no table yet) `is_incremental()` is false → the whole table is
  captured.
- On **subsequent runs** it's true → only rows newer than the cutoff are processed.

### `unique_key` (merge / upsert)

- Tells dbt that if a record with the same key already exists in the warehouse, **update
  it instead of inserting a duplicate**.
- This broadens incremental from immutable (append-only) tables to **mutable** records
  (rows that change over time), as long as you have an "updated" column (e.g.
  `updated_at`). You are now both adding and updating rows.

### `is_incremental()` macro

Returns true only when **all** of these hold:

1. materialization config is `incremental`,
2. an existing table for this model is in the warehouse,
3. the `--full-refresh` flag was **not** passed.

### Full refresh

Run with `--full-refresh` (e.g. `dbt build --full-refresh -s transactions`) to make
`is_incremental()` false, skip the `where` filter, and **rebuild the whole table from
scratch**. Do this regularly if the data size allows.

### Late-arriving facts and lookback windows

- Late data (records that load after the cutoff) can be filtered out forever — they
  arrive with an old timestamp but the warehouse already has a newer `max(updated_at)`.
- **Mitigate with a lookback window:** subtract a few days from `max(updated_at)` to
  re-capture late data within that window. With a `unique_key` defined, re-processed
  rows just update existing ones (no duplication). You process more data, but in a fixed
  way that hews closer to source.

```yaml
sources:
  - name: raw_finance
    tables:
      - name: transactions
        config:
          loaded_at_query: |
            select max(ingested_at)
            from {{ this }}
            where ingested_at >= current_timestamp - interval '3 days'
```

### Drift and the full-refresh cadence

- Incremental models **inevitably drift** from source over time (imperfect loaders,
  late facts). A lookback window slows drift — **longer window = less efficient but
  slower drift** — but never fully eliminates it (a 3-day window still misses a record
  4 days late).
- **Common pattern:** run a **full refresh weekly or monthly** at a low-activity point
  (e.g. weekends) to reset accumulated drift, for incremental models of manageable size.

### State-aware orchestration

- By default, state-aware orchestration detects freshness from warehouse metadata,
  which can run models more often than needed. Configure a `loaded_at_field` (a
  timestamp column) or a `loaded_at_query` (custom SQL) so dbt checks the right field.
- Late-arriving records may have an earlier event timestamp, so state-aware
  orchestration could skip a rebuild your lookback window would otherwise catch. **Align
  your `loaded_at_query` with the same lookback window used in your incremental
  filter.**

## Examining builds

Use build telemetry to decide when to escalate a materialization (view → table →
incremental).

### dbt Cloud Model Timing

- The **Model Timing tab** (for a configured Job) maps models across threads (up to 64;
  e.g. 4 threads = 4 lanes) over time so you can pinpoint the longest-running models —
  good candidates to make incremental.
- With a single dbt invocation (e.g. `dbt build`), the chart reflects all models. With
  multiple commands (e.g. `dbt build` then `dbt compile`), it reflects only the final
  command's models; models run in both show the last invocation's timing, and models not
  re-invoked retain their earlier timing.

### dbt Core CLI output

Two log lines per model — START and completion:

```
20:24:51  5 of 10 START sql view model main.stg_products ......... [RUN]
20:24:51  5 of 10 OK created sql view model main.stg_products .... [OK in 0.13s]
```

- Shows position (5 of 10), start timestamp, language (sql vs python), materialization
  type, completion status (`OK`/error/warn), and build time. Thanks to threads, the OK
  line may not immediately follow START.
- **Views should typically take a second or two** — watch tables and incremental models
  more closely.

### dbt Artifacts package

- dbt stores run metadata (build duration, start/finish, status, materialization type,
  and more) in **artifacts** (JSON). dbt Cloud packages the useful bits into a
  visualization.
- For dbt Core, the **dbt Artifacts package** provides models you can visualize in your
  BI tool to build your own model-timing and materialization-strategy reports.
