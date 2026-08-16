---
name: dbt_semantic_view
description: Use when creating, modifying, or reviewing Snowflake semantic views (`models/semantic_views/`, `materialized='semantic_view'`) — the layer that exposes facts and dimensions to LLM and BI tools as governed, named, synonym-rich metrics.
---

# dbt Semantic Views

Semantic views are Snowflake `SEMANTIC VIEW` objects that expose facts and dimensions to
**LLM and BI tools** as governed, named, synonym-rich metrics. They
carry **no heavy logic** — they declare tables, relationships, and straightforward
aggregations. They sit at the end of the chain and are **terminal**: LLM/BI tools read
from them; **no other dbt model may `ref` a semantic view.**

**Is this even a semantic view?** Semantic views hold only straightforward aggregates
(`COUNT`/`SUM`/`COUNT DISTINCT`/`AVG`/simple ratio or percentile) over joined fact+dim
rows. If a metric needs a date spine, window functions, cohort baselines, waterfalls, or
other modeling, build a **`metrics_` model** instead — see the routing rule in
[../_shared/project_structure.md](../_shared/project_structure.md) and the
[dbt_metrics_model](../dbt_metrics_model/SKILL.md) skill.

## Shared references (read these)

- [../_shared/project_structure.md](../_shared/project_structure.md) — layers, who-can-`ref`-whom, and the metrics-vs-semantic-view routing rule
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming by data type, primary keys, LLM-consumable names
- [dbt_mart_model](../dbt_mart_model/SKILL.md) — the facts and dimensions a semantic view is built from

## Structure

Materialized with `{{ config(materialized='semantic_view') }}`; the body is Snowflake's
`CREATE SEMANTIC VIEW` grammar — `TABLES`, `RELATIONSHIPS`, `FACTS`, `DIMENSIONS`,
`METRICS`, and a top-level `COMMENT`.

## Rules

1. **Every semantic view is backed by dbt `ref()`s — no orphans.** Each must be defined as
   a dbt model in `models/semantic_views/<domain>/`. A semantic view that exists in
   Snowflake without a dbt model is an orphan to be migrated into dbt, then dropped.
2. **`TABLES` reference only facts and dimensions** via `{{ ref(...) }}`, each with a
   declared `PRIMARY KEY` (and `UNIQUE` / `CONSTRAINT` where the grain needs it). **Never
   point a semantic view at a raw or `stg_` table.**
3. **`RELATIONSHIPS` name every join** — `fact (key) REFERENCES dim`. Use distinct named
   relationships for role-playing dimensions (e.g. a users dim joined as owner / creator /
   assignee). **Fact → dimension only — no fact-to-fact joins.** If a fact needs another
   fact's attribute, denormalize it onto the fact in the model (mart / intermediate layer),
   not by joining facts in the view. *(Exception: an intermediate bridge table for a
   row-level explosion — e.g. a date-overlap bridge that fans a subscription fact across
   the days it spans — which the routing rule in
   [../_shared/project_structure.md](../_shared/project_structure.md) sanctions.)*
4. **`FACTS` = additive row-level numeric columns; `DIMENSIONS` = grouping attributes;
   `METRICS` = the aggregations.** Keep `METRICS` to the straightforward forms
   (`SUM`/`COUNT`/`COUNT DISTINCT`/`AVG`/ratio/percentile). If a metric needs row-level
   pre-computation, model it as a `metrics_` table instead (or push a one-off explosion to
   an `int_` model and aggregate on top here).
5. **Built for LLMs — annotate everything.** Every table, fact, dimension, and metric gets
   a `COMMENT`, and metrics/dimensions get `WITH SYNONYMS` covering how you and an
   LLM phrase the concept (`spend`, `total spend`, `money spent`). The
   top-level `COMMENT` says what the view powers and how to slice it (which date column to
   filter, which view to prefer for a given question). Use business names, not source
   columns (`account_id`, not `acct_id`) — see
   [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md).
6. **One definition per concept.** Don't define the same metric two different ways across
   semantic views — single source of truth, same anti-pattern as duplicating marts.

## Validation

- `dbt run --select <semantic_view>` — confirm it compiles and creates in Snowflake.
- Sanity-query the view (or the matching `ask_*` analyst tool) to confirm metrics resolve.
- Run SQL linting if configured.

## Example

A straightforward metric — one expression, with synonyms and a comment — declared against
a fact joined to its dimensions (table/column names below are illustrative):

```sql
{{ config(materialized='semantic_view') }}

TABLES(
    fct_transactions AS {{ ref('fct_transactions') }}
        PRIMARY KEY (sk)
        COMMENT = 'Unified charges + refunds with category attribution.',
    dim_accounts AS {{ ref('dim_accounts') }}
        PRIMARY KEY (account_id)
        COMMENT = 'Account dimension for institution and account-type context.'
)

RELATIONSHIPS(
    transactions_to_accounts AS
        fct_transactions (account_id) REFERENCES dim_accounts (account_id)
)

METRICS(
    fct_transactions.total_spend AS
        SUM(fct_transactions.amount_usd)
        WITH SYNONYMS = ('total spend', 'spending total', 'total transaction amount')
        COMMENT = 'Total dollar amount spent across all transactions'
)

COMMENT = 'Transactions: spend and transaction-volume reporting. Joins to dim_accounts for institution and account-type context. Filter report_date for the window.'
```
