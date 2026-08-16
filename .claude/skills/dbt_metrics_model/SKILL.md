---
name: dbt_metrics_model
description: Use when creating, modifying, or reviewing metrics models (`metrics_*` in `models/metrics/`) — reporting/visualization rollups that need real modeling (date spines, windows, cohort baselines, waterfalls).
---

# dbt Metrics Models (`metrics_*`)

Metrics models are SQL **tables for reporting/visualization rollups that need real
modeling** — a date spine, a window, a cohort baseline, a waterfall, an unpivot. They are
the place for logic the relational marts deliberately don't carry. They sit at the end of
the chain and are **terminal**: reporting/BI reads from them; **no other dbt model may
`ref` a `metrics_` model** — with one exception: a pure reshape sibling (a `_tidy`
unpivot) may `ref` the wide `metrics_` table it reshapes, and nothing may `ref` the
reshape.

**Is this even a metrics model?** If the metric is a straightforward aggregate
(`COUNT`/`SUM`/`COUNT DISTINCT`/`AVG`/simple ratio) over joined fact+dim rows, it belongs
in a **semantic view**, not here — see the routing rule in
[../_shared/project_structure.md](../_shared/project_structure.md) and the
[dbt_semantic_view](../dbt_semantic_view/SKILL.md) skill. Build a `metrics_` table only
when the logic won't fit one aggregate expression.

## Shared references (read these)

- [../_shared/project_structure.md](../_shared/project_structure.md) — layers, who-can-`ref`-whom, and the metrics-vs-semantic-view routing rule
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming by data type, primary keys, column ordering
- [../_shared/sql_style.md](../_shared/sql_style.md) — CTE structure, `import_models`, joins, aggregation
- [../_shared/yaml_style.md](../_shared/yaml_style.md) — model docs and tests
- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md) — table vs. incremental
- [dbt_mart_model](../dbt_mart_model/SKILL.md) — the marts (`dim_`/`fct_`) these build on, and the marts-vs-metrics boundary

## Rules

1. **Live in `models/metrics/<domain>/` with the `metrics_` prefix.** `mart_*` is the
   **legacy** prefix being migrated here — **do not create new `mart_` models.**
   Name new models **`metrics_<entity>_<subject>_<time_grain>[_<shape>]`** — entity is
   the grain's subject (`account` for tracked financial accounts, matching
   `account_id`), subject is what's measured, time grain last as the variant
   qualifier, `_tidy` for long-form unpivots
   (e.g. `metrics_account_cash_flow_monthly_tidy`). **The subject may be
   omitted only for the canonical wide rollup of an entity/grain** — one such model
   per entity/grain, absorbing that entity's metric families instead of spawning
   subject-scoped siblings on divergent spines (e.g. `metrics_account_monthly`).
   Basis (`local`/`pst`) stays out of the model name — it lives on the date column
   (`accrual_month_local`) — unless two basis variants of the same model must
   coexist; for measures a wide table stores on both bases, see the basis-suffix
   exception in [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md).
   Older `metrics_` names that predate this grammar get aligned as they're next
   touched.
2. **Read from facts and dimensions.** In the ideal case a metrics model reads **only
   `fct_*` and `dim_*`.** Reach into `intermediate`/`staging` only when a fact/dim does
   not yet expose what you need — and prefer fixing that by adding the column/measure to
   the fact or dimension. Use the **`import_models(refs=[...], ctes=[...])`** macro for
   all imports.
3. **State the grain explicitly** ("one row per account per accrual month") and test it
   with `dbt_utils.unique_combination_of_columns`.
4. **Don't re-derive canonical measures.** Financial/volume measures come straight from
   the fact's canonical measure columns — never recompute them inline. A new financial
   metric must reconcile to the canonical fact (prove `diff = 0`).
5. **Dates are dimensions, not the consolidation axis.** Keep PST/local/report-date as
   columns or split bases by basis; don't collapse them away.
6. **Materialize as `table`** (or `incremental` if the table is too slow to build — use
   the `dbt_incremental_model` skill). Configure folder defaults in `dbt_project.yml`.
7. **Document the model + every column** in
   `models/metrics/<domain>/_metrics_<domain>__models.yml`
   (see `dbt_model_documentation`), and follow the LLM-consumable naming guidance in
   [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) (business names like
   `account_id`, one name per concept).

## Validation

- `dbt build --select +<metrics_model>` — builds upstream and runs the grain test.
- Verify the grain is unique (no unexpected fanout), and that any financial measure
  reconciles to the canonical fact (`diff = 0`).
- Run SQL linting if the repo has SQLFluff configured.

## Example

A metric that needs a window over a spine belongs here — a plain `SUM`/`COUNT` by month
would be a semantic view, but a month-over-month change needs `LAG`, which the
semantic-view grammar can't express (column/measure names below are illustrative):

```sql
-- metrics_spend_by_account_month.sql  (one row per account per month)
{{ config(materialized='table') }}

with

{{ import_models(refs=[ref('fct_transactions')], ctes=['transactions']) }},

monthly as (

    select
        transactions.account_id,
        date_trunc('month', transactions.report_date) as month,
        -- canonical measure taken straight from the fact, not re-derived
        sum(transactions.amount_usd) as spend_usd

    from transactions

    group by 1, 2

),

/* Month-over-month change needs LAG across the month spine — a window the
   semantic-view grammar can't express, so this belongs in a metrics_ table. */
with_mom as (

    select
        *,
        spend_usd - lag(spend_usd) over (
            partition by account_id order by month
        ) as spend_mom_change_usd

    from monthly

)

select * from with_mom
```
