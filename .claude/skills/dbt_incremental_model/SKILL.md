---
name: dbt_incremental_model
description: Use when creating, modifying, debugging, or reviewing incremental models and materialization configs.
---

# dbt Incremental Models & Materialization Configs

Incremental models generate a **table built piece by piece** — applying transformations
only to new or updated rows — for large/compute-intensive datasets where a full rebuild
is too slow or costly.

## Shared references (read these)

- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md) —
  full incremental mechanics, drift, lookback, examining builds (primary reference)
- [../_shared/sql_style.md](../_shared/sql_style.md) — CTE/config formatting
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — keys and naming
- [../_shared/yaml_style.md](../_shared/yaml_style.md) — source freshness config, tests

## When to use incremental (and when not)

- **Use it** only when the source data is very large and/or transformations are
  compute-intensive, so a full **table** rebuild takes too long. Follow the golden rule:
  **view → table → incremental**, escalating only when the previous step is too slow.
- **Prefer a plain table** if you can afford to rebuild from scratch — it's the simplest
  and most accurate option. Don't make models incremental by default; it adds real
  complexity and a maintenance burden (drift).
- Use the dbt Cloud **Model Timing** tab or dbt Core CLI build times to identify the
  slow models worth converting (see materialization_guidance.md → Examining builds).

## The three things you need

1. A **filter** selecting only new/updated rows.
2. A **conditional block** (`{% if is_incremental() %}`) wrapping the filter.
3. **Config** declaring `materialized='incremental'` (and usually a `unique_key`).

## Standard pattern

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

- **`{{ this }}`** = this model's table as built last run, so `max(updated_at) from
  {{ this }}` is the cutoff (most recent record processed last run).
- **First run** (no table): `is_incremental()` is false → whole table built. **Later
  runs**: true → only rows newer than the cutoff are processed.
- **`is_incremental()` is true only when** the config is incremental **and** a table
  already exists **and** `--full-refresh` was **not** passed.

> **Project override — no scalar subqueries.** The
> `where updated_at > (select max(updated_at) from {{ this }})` pattern above is the dbt
> Labs standard, but this repo **bans subqueries**. Use a dedicated `cutoff` CTE instead,
> keep other imports in `import_models`, and hand-write the incremental source CTE just
> after it (with a `dev_environment_filter` for the non-incremental dev path):
>
> ```sql
> {{ config(materialized = 'incremental', unique_key = 'sk') }}
>
> with
>
> {{ import_models(refs = [ref('stg_garmin__activities')], ctes = ['activities']) }},
>
> {% if is_incremental() %}
> cutoff as (
>     select dateadd('day', -30, max(updated_at)) as cutoff_at
>     from {{ this }}
> ),
> {% endif %}
>
> sleep_summary as (
>     select sleep_summary.*
>     from {{ ref('stg_garmin__sleep') }} as sleep_summary
>     {% if is_incremental() %}
>     inner join cutoff on sleep_summary.updated_at >= cutoff.cutoff_at
>     {% else %}
>     {{ dev_environment_filter('updated_at') }}
>     {% endif %}
> )
> -- functional CTEs follow
> ```
>
> The `dateadd('day', -30, ...)` in the `cutoff` CTE is the lookback window (see below).
> See [../_shared/sql_style.md](../_shared/sql_style.md).

## Unique key (merge / upsert)

- `unique_key` tells dbt to **update** an existing record with the same key instead of
  inserting a duplicate. This extends incremental from immutable append-only data to
  **mutable** records that change over time (as long as you have an `updated_at`-style
  column).
- A defined `unique_key` is also what makes a lookback window safe — re-processed rows
  update in place rather than duplicating.

## Late-arriving facts, lookback windows, drift

- **Late-arriving facts** can be filtered out permanently: they arrive with an old
  timestamp but the warehouse already holds a newer `max(updated_at)`.
- **Add a lookback window** — subtract a few days from the cutoff
  (`max(updated_at) - interval 'N days'`) to re-capture late data. Longer window = less
  efficient but slower drift; it never fully eliminates drift (a 3-day window still
  misses a record 4 days late).
- **Drift is inevitable** over time. **Common pattern: full refresh weekly or monthly**
  at a low-activity point (e.g. weekend) to reset it, for incremental models of
  manageable size.

## Full refresh behavior

- Run `dbt build --full-refresh -s <model>` to rebuild the whole table from scratch
  (makes `is_incremental()` false, skipping the filter). Do this regularly if data size
  allows.

## State-aware orchestration

- Configure a **`loaded_at_field`** or **`loaded_at_query`** on the source so freshness
  detection checks the right column instead of all warehouse metadata.
- **Align the `loaded_at_query` lookback with your incremental filter's lookback**, or
  state-aware orchestration may skip a rebuild your lookback window would otherwise
  catch (late records can carry an earlier event timestamp).

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

## Materialization config placement

- Folder defaults belong in `dbt_project.yml`; per-model overrides go in the in-file
  `config()` block. Configs **cascade — the more specific scope wins.** See
  materialization_guidance.md for the cascade example.

## Testing & validation

1. **`dbt compile --select <model>`** — confirm the Jinja/SQL compiles in both branches.
2. **First build:** `dbt build --select <model>` on an empty target → verify the full
   table builds correctly (`is_incremental()` false path).
3. **Incremental build:** run again → verify only new/updated rows are processed and the
   `unique_key` upserts correctly (no duplicates; pk `unique` test passes).
4. **Full refresh:** `dbt build --full-refresh --select <model>` → verify it rebuilds
   identically (catches drift / filter bugs).
5. **Examine build timing** (Model Timing / CLI) to confirm the incremental run is
   actually faster than the table it replaced.
6. Run SQL linting if configured.

## Local development & shipping loop

This is the end-to-end loop for developing **any** dbt model or fixing a failing test in
this repo — not only incremental models.

**Setup** (see the root [README.md](../../../README.md) for full detail): dependencies
are managed in the shared **venv** (not uv/pipenv). Each session, activate it and (if
`packages.yml` changed) reinstall deps:

```bash
source .venv/bin/activate
cd dbt
dbt deps
```

The `dev` target (the default in `~/.dbt/profiles.yml`) writes to `ANALYTICS_DEV.*`.
**`prod` writes to `ANALYTICS.PROD`** — only target it deliberately
(`dbt run --target prod`), never by default.

1. **Investigate before editing.** For a failing test, read the log (test name, model,
   `Got N results`), read the model SQL (columns, joins, grain), then **profile the
   source in Snowflake** — the most important and most-skipped step. Typical diagnostics:
   ```sql
   -- "unique" failure: which key dupes, and is each LEFT JOIN input unique on its key?
   select <key>, count(*) as n from <model> group by 1 having n > 1 order by n desc;
   select count(*) as total, count(distinct <join_key>) as distinct_key from <staging>;
   -- "not_null" failure: are the nulls already null in the source?
   select count(*) total, count_if(<col> is null) null_count from {{ source('...','...') }};
   ```
   The bug is almost always upstream: duplicate source rows (fanout), a null FK (orphan
   join), a genuine source data hole, or a mis-specified test. **State the root cause
   before writing the fix** — if you can't explain why the fix is correct, it isn't.
2. **Edit** the smallest change that fixes the root cause. If the cause is upstream
   (duplicate source rows), fix it in **staging** so all downstream models benefit — don't
   paper over it in the consumer or widen a surrogate key.
3. **Build in dev:** `dbt run --select <model>` (use `+<model>` / `+<model>+` to
   pull in parents / downstream children that aren't built in your dev schema).
4. **Verify in Snowflake** by querying the dev table directly — don't trust "dbt run
   succeeded"; a run can succeed while producing wrong data (did the nulls/dupes go
   away? spot-check values).
5. **Run affected tests:** `dbt test --select <model>` (and `<model>+` for
   downstream marts that were also failing).
6. **Open a PR** (branch off main, one logical change). The body should explain the
   **root cause**, not just the fix: what broke and where, the diagnostic that pinned it
   (table profile, join analysis, row counts — be specific), why the fix is correct, and
   the test plan (`dbt run`/`dbt test` output + the Snowflake spot-check).

**Anti-patterns:** editing prod tables directly in Snowflake; "fixing" a `unique` test by
adding columns to a surrogate key (the fanout is upstream); silencing a test with
`severity: warn` without understanding what it catches; merging without running tests
locally; pushing to `main` directly.
