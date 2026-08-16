---
name: dbt_mart_model
description: Use when creating, modifying, or reviewing marts, facts, dimensions, and business entity models.
---

# dbt Mart Models

Marts are where everything comes together — **domain-defined entities** (the entity /
concept layer). Each mart represents a specific entity or concept at its **unique
grain**: an activity, an account, a transaction, a daily wellness metric. Every row is
one discrete instance of that concept.

## Shared references (read these)

- [../_shared/project_structure.md](../_shared/project_structure.md) — organize marts by
  domain, name by entity
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming, primary keys,
  field ordering
- [../_shared/sql_style.md](../_shared/sql_style.md) — CTE structure, joins, aggregation
- [../_shared/yaml_style.md](../_shared/yaml_style.md) — model docs and tests
- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md) —
  table vs. incremental

## Rules

1. **Represent an entity at a single, clear grain.** State the grain explicitly
   ("one row per transaction"). The mart's core grain stays fixed even though you bring
   in lots of other concepts (e.g. tons of `account` data into a `transactions` mart). If
   you start rolling up across a date spine (`account_transactions_per_day`), you've
   moved past marts into **metrics**.
2. **Name by entity in plain English** based on the grain: `activities`, `transactions`,
   `accounts`. Pure marts (no time-based rollup) should not carry a time dimension
   (`transactions_per_day`) — capture those via metrics. Organize by domain under
   `models/marts/[domain]/` (`health`, `finance`); subfolders optional below ~10
   marts.
3. **Every mart has a primary key** named `<object>_id`, string type, tested `unique` +
   `not_null`. Apply field naming/ordering from dbt_model_style.md.
4. **Build from intermediate or staging models only** (`{{ ref(...) }}` via
   `import_models` at the top). Marts sit at the end of the chain: staging →
   intermediate → marts.
5. **A `dim_`/`fct_` must NOT read from another `dim_` or `fct_`** (this repo's layer
   rule). If you need to combine entities/events — e.g. transaction data aggregated to
   an account grain — do that combination in an **intermediate model** (and feed both
   marts from it), or, if it's a reporting-specific rollup, build it as a **`metrics_`
   model** in the `metrics/` layer. See
   [../_shared/project_structure.md](../_shared/project_structure.md).
6. **Wide and denormalized is good.** Storage is cheap, compute is expensive — pack
   everything someone needs about the concept into one wide table rather than
   re-joining repeatedly. (See the Semantic Layer caveat below for the exception.)
7. **Limit join complexity.** Weigh number of joined concepts against logic complexity.
   8 simple joins may be fine; 4 concepts woven with heavy window functions may be too
   much. **If bringing together more than ~4–5 concepts, add intermediate models** —
   two intermediates of three concepts each, joined in the mart, reads far better than
   one mart with six joins.
8. **Don't build the same concept differently across domains** (a health-side
   `daily_summary` and a finance-side `daily_summary` is an anti-pattern). Genuinely
   different needs become distinct concepts (`net_spend` vs `gross_spend`), not
   domain-specific views.

## Naming: marts vs. metrics

This repo uses Kimball-style prefixes (overriding the dbt Labs plain-entity naming). Pick
the prefix by asking **"what's the grain?"**:

| Prefix | Represents | Grain | Examples |
| --- | --- | --- | --- |
| `dim_` | An entity | One row per entity instance | `dim_accounts`, `dim_devices`, `dim_dates` |
| `fct_` | An event/transaction | One row per event | `fct_activities`, `fct_transactions`, `fct_daily_metrics` |

**`mart_` is a legacy prefix — do not create new `mart_` models.** Reporting / visualization-
specific rollups that take underlying facts, dimensions, or other models and compute
reporting metrics now belong in the **`metrics/` layer with a `metrics_` prefix**
(`metrics_daily_training_load`, `metrics_monthly_net_worth`). Existing `mart_*` models
are being migrated to `metrics_*`; if you touch one, prefer moving it to the metrics
layer. So **this skill (the marts layer) is for `dim_` and `fct_` entity/event models**;
pure reporting rollups go to metrics. See
[../_shared/project_structure.md](../_shared/project_structure.md).

**Domains** (subfolders under `models/marts/`): `_core/` (cross-cutting dims/facts used
everywhere), `health/`, `finance/`, `meta/`. New marts go in the owning
domain; `_core/` is reserved for things many domains use. Docs go in
`models/marts/_marts__models.yml`.

## Imports & surrogate keys

- Use the **`import_models(refs=[...], ctes=[...])` macro** for all `ref()` imports (CTE
  names use business meaning, e.g. `accounts`, `garmin_activities`). See
  [../_shared/sql_style.md](../_shared/sql_style.md).
- **Never** reference `{{ source(...) }}` in a mart — always go through staging. Don't
  join staging directly when an intermediate already exposes the same data.
- Dimension grain is usually the natural business key (`account_id`). Fact grain is
  usually a surrogate built from the event's natural keys
  (`dbt_utils.generate_surrogate_key([...]) as sk`). If the grain `unique` test fails,
  the duplicate is in an upstream join — fix it in staging, not by widening the key.

## Examples

A fact built from staging + an intermediate (note `import_models`, `/* */` CTE headers):

```sql
-- fct_transactions.sql
{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('stg_finance__transactions'), ref('int_transactions_categorized')],
        ctes = ['transactions', 'categorized_transactions']
    )
}},

/* Join each transaction to its resolved spend category, defaulting
   uncategorized transactions so the transaction grain is preserved. */
transactions_and_categorized_transactions_joined as (

    select
        transactions.transaction_id,
        transactions.account_id,
        transactions.transaction_date,
        coalesce(categorized_transactions.category, 'uncategorized') as category,
        coalesce(categorized_transactions.is_recurring, false) as is_recurring

    from transactions

    left join categorized_transactions
        on transactions.transaction_id = categorized_transactions.transaction_id

)

select * from transactions_and_categorized_transactions_joined
```

A dimension that needs transaction rollups **does not read `fct_transactions`** — the
account-grain aggregation lives in an intermediate model
(`int_transactions_aggregated_to_account`), which both this dim and the fact can build
on:

```sql
-- dim_accounts.sql
{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [
            ref('stg_finance__accounts'),
            ref('int_transactions_aggregated_to_account')
        ],
        ctes = ['accounts', 'account_transactions']
    )
}},

/* Widen each account with its transaction rollups (first/last transaction,
   transaction count, current balance), defaulting accounts with no transactions. */
accounts_and_account_transactions_joined as (

    select
        accounts.account_id,
        accounts.account_name,
        accounts.account_type,
        account_transactions.first_transaction_date,
        account_transactions.most_recent_transaction_date,
        coalesce(account_transactions.num_transactions, 0) as num_transactions,
        account_transactions.current_balance_usd

    from accounts

    left join account_transactions
        on accounts.account_id = account_transactions.account_id

)

select * from accounts_and_account_transactions_joined
```

## Materialization

- **Table or incremental.** At the marts layer you build the data itself for fast end-
  user performance and to avoid recomputing whole chains on every dashboard refresh.
- **Golden rule:** start with a view → make it a table when the view is too slow to
  query → make it incremental when the table is too slow to build. Don't make marts
  incremental by default — it adds superfluous difficulty. For incremental marts, use
  the `dbt_incremental_model` skill.
- Configure folder defaults in `dbt_project.yml` (`marts: +materialized: table`, plus
  per-domain `+schema`).

## Semantic Layer caveat

- **Without the dbt Semantic Layer:** denormalize as above.
- **With the Semantic Layer:** keep marts **more normalized** to give MetricFlow
  flexibility. Follow the "How we build our metrics" guidance if this project uses the
  Semantic Layer.

## Tests, documentation, validation

- **Test the grain key with `unique` + `not_null` — and usually nothing else.** Add
  `accepted_values`, `relationships`, side-column `not_null`, or range checks only when
  the task explicitly calls for it (use `severity: warn` where the source legitimately
  allows the condition). See the testing convention in
  [../_shared/sql_style.md](../_shared/sql_style.md).
- **Document the mart (what it represents + grain) and every column** — with helpful
  descriptions that capture any business logic — in `models/marts/_marts__models.yml`,
  kept in sync with the SQL. See the `dbt_model_documentation` skill.
- **Validation:**
  1. `dbt compile --select <mart>` for structural changes.
  2. `dbt build --select +<mart>` for logic/test changes (builds upstream too, runs
     downstream impact).
  3. Verify grain (primary-key uniqueness; no unexpected fanout — compare row counts
     before/after joins).
  4. Run SQL linting if configured.
- **Troubleshooting tip:** if a database error seems to surface in a mart but stems from
  an upstream view/ephemeral model, temporarily materialize that chain as **tables** so
  the warehouse throws the error where it actually occurs.
