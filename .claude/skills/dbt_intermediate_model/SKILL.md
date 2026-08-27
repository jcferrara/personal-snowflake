---
name: dbt_intermediate_model
description: Use when creating, modifying, or reviewing dbt intermediate models (int_<purpose>).
---

# dbt Intermediate Models

Intermediate models are **purpose-built transformation steps** — molecules — that bring
staging models together into more connected shapes on the way to marts. They break
complexity out of marts and are generally **not exposed to end users**.

## Shared references (read these)

- [../_shared/project_structure.md](../_shared/project_structure.md) — organize
  intermediate by data domain
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming, keys, field
  ordering
- [../_shared/sql_style.md](../_shared/sql_style.md) — CTE structure, verbose CTE names
- [../_shared/jinja_style.md](../_shared/jinja_style.md) — DRY-ing logic with Jinja
- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md) —
  ephemeral vs. view-in-custom-schema

## Rules

0. **Reference rule:** intermediate models may read from **staging models or
   other intermediate models only** — never from `dim_`/`fct_`/`metrics_`. See
   [../_shared/project_structure.md](../_shared/project_structure.md). Cross-entity
   combinations that two marts need belong here, in an intermediate model.
1. **Have a clear transformation purpose.** Every intermediate model should do one
   understandable thing. Name it with a **verb** describing what it does.
2. **Naming:** `int_[entity]s_[verb]s.sql` — verbs like `pivoted`,
   `aggregated_to_day`, `joined`, `fanned_out_by_quantity`, `summed`,
   `funnel_created`. Reference the unified entity. **Drop the double underscores**
   used in staging — that convention is staging-only, even for a model that still
   operates at a single source system (e.g. `int_garmin_activities_summed`, not
   `int_garmin__activities_summed`).
   - **In practice**, this repo names intermediates descriptively as
     `int_<what_it_produces>` (e.g. `int_daily_wellness_joined`,
     `int_transactions_categorized`, `int_account_balances_rolled_up`) rather than
     strictly enforcing the `[entity]s_[verb]s` shape. Keep names descriptive; don't
     rename existing models to fit the verb pattern.
3. **Organize by data domain**, not source system. Put models in
   `models/intermediate/<domain>/` — domains in this repo include `health/`,
   `finance/`. General-purpose models (`int_dates_spine`) may live at the top of
   `intermediate/`; new ones go in a domain folder unless clearly cross-domain.
4. **Decompose complexity** — use intermediate models for:
   - **Structural simplification** — join a reasonable number (~4–6) of concepts here so
     the mart joins two intermediate models instead of having 10 joins.
   - **Re-graining** — fan out or collapse to the right composite grain (e.g. fan
     `activities` out to `activity_laps` by lap count) so you can verify the grain in
     isolation before mixing with other components.
   - **Isolating complex/hard-to-follow logic** into its own model so it's easy to
     refine, test, and reference cleanly downstream.
5. **Document the grain.** State the grain explicitly (e.g. "one row per transaction")
   in the model's YAML so re-graining is verifiable.
6. **DRY, inside and across models.** Use descriptive CTE names that tell the
   transformation story; use Jinja where it reduces repetition (see example) without
   hurting readability.
7. **Narrow the DAG:** multiple inputs are expected and good; **multiple outputs are a
   red flag.** Move toward fewer, wider, domain-conformed concepts.
8. **Don't over-optimize early:** aim for a single source of truth. With fewer than ~10
   marts and no problems, subfolders may be unnecessary (staging always needs them).

## Example (descriptive CTEs + Jinja for DRY)

```sql
-- int_intensity_minutes_pivoted_to_day.sql
{%- set intensity_types = ['moderate', 'vigorous'] -%}
with
intensity_minutes as (
    select * from {{ ref('stg_garmin__intensity_minutes') }}
),
pivot_and_aggregate_intensity_minutes_to_day_grain as (
    select
        activity_date,
        {% for intensity_type in intensity_types -%}
            sum(
                case
                    when intensity_type = '{{ intensity_type }}'
                    then minutes
                    else 0
                end
            ) as {{ intensity_type }}_minutes,
        {%- endfor %}
        sum(minutes) as total_intensity_minutes
    from intensity_minutes
    group by 1
)
select * from pivot_and_aggregate_intensity_minutes_to_day_grain
```

The CTE name (`pivot_and_aggregate_intensity_minutes_to_day_grain`) communicates the
transformation at a glance. Long, clear file/CTE names are worth it.

## Materialization

- **Materialize as `view`** (this repo overrides the dbt Labs ephemeral default).
  Views let you query mid-pipeline state directly in Snowsight while iterating, instead
  of only seeing it interpolated into a downstream model. Set it explicitly at the top
  of the file:
  ```sql
  {{ config(materialized = 'view') }}
  ```
- Still **not exposed to end users** as a reporting surface — these are building blocks.
- (Upstream dbt Labs would default to ephemeral; this repo prefers `view` instead — see
  [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md).)

## Imports & surrogate keys

- Use the **`import_models(refs=[...], ctes=[...])` macro** for all `ref()` imports
  (CTE names use business meaning, e.g. `garmin_activities`, not the staging model name).
  See [../_shared/sql_style.md](../_shared/sql_style.md).
- When a stable identifier doesn't exist in source, build it with
  `dbt_utils.generate_surrogate_key([...]) as sk`; the `sk` grain must equal the model's
  grain (fix duplicates upstream, never by widening the `sk`). See
  [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md).
- **Tests:** `unique` + `not_null` on the grain key (the `sk` or natural id) only — keep
  it minimal (no per-column tests unless asked).
- **Docs:** document the model (purpose + grain) and **every column** in
  `models/intermediate/<domain>/_int_<domain>__models.yml` (or
  `models/intermediate/_intermediate__models.yml` for general-purpose top-level models),
  capturing business logic, kept in sync with the SQL. See the `dbt_model_documentation`
  skill.

## Validation steps

1. **`dbt compile --select int_<name>`** for structural changes.
2. **`dbt build --select +int_<name>`** to build upstream + run tests when logic
   changes (the model materializes as a `view`, so you can query it directly in your
   dev schema to inspect mid-pipeline state).
3. **Verify the grain** (row count and key uniqueness match the documented grain).
4. Run SQL linting if configured.
