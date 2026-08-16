# dbt Model Style (shared reference)

Naming and structural conventions for dbt models, fields, and keys. Source: dbt Labs
"How we style our dbt models." These apply across all layers; layer-specific
overrides live in each `SKILL.md`.

## Model names

- **Pluralize model names** for entities with multiple rows: `activities`,
  `transactions`, `accounts`. Use singular only when a single row is expected.
- **Use `snake_case`** for schema, table, and column names.
- **Use underscores, never dots**, in model names. ✅ `models_without_dots`
  ❌ `models.with.dots`. Most platforms use dots to separate
  `database.schema.object`, so underscores reduce quoting needs and avoid issues in
  parts of dbt.
- **Names must be unambiguous and readable.** Do not abbreviate or alias — emphasize
  readability over brevity. ❌ `acct` for `account`, ❌ `txn` for `transaction`.
- **Use domain terminology, not source terminology** — the name you and an LLM reason
  with. If the source API calls it `activityId` but you think of it as a workout,
  name it `activity_id`.

  **This repo's canonical keys: `account_id` (finance account) and `activity_id`
  (Garmin workout).** The source/raw layer names these `acct_id` / `accountid` and
  `activityid` — the finance source abbreviates the field, and Garmin's raw JSON uses
  camelCase with no separator. Two rules:
  - **Reporting layer (`metrics_` models and semantic views): canonical names only.**
    Never select, output, or join on `acct_id`, `accountid`, or `activityid` here —
    even when an upstream fact/dim exposes them. The canonical alias already exists on
    the fact/dim, so reference it (`transactions.account_id`, not
    `transactions.acct_id`; `dim_budgets.account_id`, not `accountid`). And
    don't re-alias the canonical to a decorated output name — emit `account_id`, not
    `account_id as acctid`. (The one exception is joining to raw staging that
    only carries the source column — unavoidable, but keep it out of the output.)
  - **Facts / dims: additive alias.** Keep the source column for existing consumers and
    add the canonical alongside it — `acct_id as account_id`, `activityid as activity_id`
    (also `accountid → account_id` when a source exposes it that way). The source
    column stays for back-compat until retired.

  This is the standing convention — don't restate it as a per-model comment.
- **Version models with a `_v1`, `_v2` suffix** for consistency (`activities_v1`,
  `activities_v2`).

## Primary keys

- **Every model should have a primary key.**
- **Name the primary key `<object>_id`** — e.g. `account_id`, `activity_id`. This makes
  it obvious which `id` is referenced in downstream joins.
- **Keys should be string data types.**

## Surrogate keys

> When a model needs a stable identifier that doesn't exist in the source, build it with
> `dbt_utils.generate_surrogate_key([...])` and name it **`sk`** (or `<entity>_sk` if
> multiple coexist). The surrogate-key grain must equal the model's grain. If the `sk`
> source column has duplicates upstream, the `unique` test fails — **fix the duplicate
> at its source (dedup in staging), do not add more columns to the `sk`** (that hides
> the join fanout instead of fixing it). Surrogate keys are an **intermediate/mart**
> concern — staging models do not add them.

## Consistent field naming

- **Use the same field name across models** for the same concept. A key to the
  `accounts` table should be `account_id` everywhere — not `acct_id` or `id` in some
  places. Consistency is the priority.
- **Avoid reserved words** as column names.

## Cross-layer name consistency

**A concept keeps one name from fact → semantic view → metrics table.** Never re-alias
a column or metric coming out of a semantic view to a different name in a metrics model
when it means the same thing — re-aliasing breaks lineage, breaks grep, and makes two
dashboards disagree about what a number is called.

- Semantic views expose fact/dim columns under their fact/dim names; metric names match
  the canonical measure they aggregate.
- Metrics models select semantic-view metrics and dimensions **as-is**. A new name is
  allowed only for a genuinely new concept — an adjustment or a calculation performed
  in that model (e.g. `calorie_deficit` computed from SV inputs).
- If the name coming through is wrong, fix it at its source (fact/dim, then SV) and
  pull it through — don't patch it with an alias downstream.

## Field naming by type

| Type | Convention | Example |
| --- | --- | --- |
| Boolean | Prefix with `is_` or `has_` | `is_active`, `has_discount` |
| Timestamp | Suffix `_at`, store in **UTC**; if another timezone, suffix it | `created_at`, `created_at_pt` |
| Date | Suffix `_date` | `created_date` |
| Event date/time tense | Past tense | `created`, `updated`, `deleted` |
| Price / amount | Decimal currency (`19.99`); if integer/non-decimal, suffix it | `amount`, `price_in_cents`, `amount_cents` |
| Count | Prefix `num_<entity>` for a count of rows/things | `num_activities`, `num_transactions`, `num_days_tracked` |

Counts use `num_` going forward. The repo also has many legacy `<entity>_count` columns
(e.g. `session_count`, `event_count`) — leave those as-is, but name new count columns `num_`.

## Measures and denomination

**A measure names what is measured plus its denomination. A dimension names how it's
grouped** — grain, timezone, localization. That split answers most naming questions:

- **Money measures follow `{measure}_{denomination}`.** Always carry the currency
  suffix (`_usd`), even while the business is USD-only — a cheap hedge against
  multi-currency later.
- **No `total_` prefix.** It adds no meaning and is often wrong — at a finer grain the
  value is a subtotal. ✅ `spend_usd` ❌ `total_spend`.
- **Localization and grain belong to the dimension, never the measure.**
  `posted_month_local` is correct — it is the localized month. `spend_usd_local` is
  not — the query groups spend by a localized month; the spend itself isn't "local".
  **One exception:** a wide output table that stores the *same measure on more than
  one basis* as separate columns puts the basis in both column names
  (`spend_usd_local` / `spend_usd_report` on `metrics_account_monthly` — local is the
  merchant's timezone at purchase time, report is your home reporting timezone) —
  there is no basis dimension left to group by. Single-basis columns in the same
  table stay plain. This never applies to semantic-view metrics.
- **A semantic-view metric that aggregates a canonical fact measure keeps the fact
  column's name.** `SUM(spend_usd)` is the metric `spend_usd`, not
  `total_spend` (see "Cross-layer name consistency" above — the same rule applies
  to every column, not just money).
- **Snowflake namespace constraint:** facts, dimensions, and metrics share one
  namespace per logical table, and a metric named after a base column makes the raw
  column unreachable to every other expression in that table. So declare each
  canonical measure once — as the metric — and don't also declare it as a row-level
  fact. Ratio metrics compose other metrics
  (`savings_rate AS (income_usd - spend_usd) / NULLIF(income_usd, 0)`); a metric that
  needs a row-level CASE over a measure gets the bucket precomputed as a column on the
  fact (e.g. `discretionary_spend_usd` splitting essential vs. discretionary spend)
  instead of reaching for the shadowed raw column.
- **Party/qualifier prefixes only where they disambiguate coexisting measures.**
  `amount_usd`, `my_share_usd`, and `reimbursed_usd` are three distinct canonical
  measures on `fct_transactions` — the qualifiers are load-bearing (a shared dinner
  might post `amount_usd = 120`, `my_share_usd = 60`, `reimbursed_usd = 60` once a
  friend pays you back). Where no counterpart measure exists, drop the qualifier.
- **Renames on in-use surfaces are additive.** Facts, dims, and shared macros with
  existing consumers get the compliant name **beside** the old column (the same
  additive-alias pattern as `account_id` beside `acct_id`); the old column
  stays until retired. New models and semantic views adopt the new names outright.
  When a semantic-view metric is renamed in place, keep the old name in its
  `WITH SYNONYMS` list.

## Column ordering by data type

Use a consistent order of data types, and group + label columns by type with comment
markers. This minimizes join errors, makes the model easier to read, and helps
downstream consumers scan for columns. Preferred order:

**ids → strings → numerics → booleans → dates → timestamps**

## Annotated model example

```sql
with source as (
    select * from {{ source('garmin', 'raw_activities') }}
),
renamed as (
    select
        ----------  ids
        activityid as activity_id,
        deviceid as device_id,
        activitytypeid as activity_type_id,
        ---------- strings
        activityname as activity_name,
        ---------- numerics
        (distance / 1000.0)::float as distance_km,
        (duration)::float as duration_seconds,
        ---------- booleans
        favorite as is_favorite,
        ---------- dates
        date(startTimeLocal) as activity_date,
        ---------- timestamps
        startTimeLocal::timestamp_ltz as started_at
    from source
)
select * from renamed
```

## Overriding principle

**Consistency matters more than any single convention.** If your project deviates,
document how and why (README/wiki) so the whole team applies it the same way.
