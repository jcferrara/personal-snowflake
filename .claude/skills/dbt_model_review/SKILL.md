---
name: dbt_model_review
description: Use when reviewing dbt model changes or pull requests — structure, naming, style, grain, joins, tests, docs, materialization, and layer correctness.
---

# dbt Model Review

A complete checklist for reviewing dbt model changes and PRs against dbt Labs best
practices. Work through every section; cite the specific shared reference when flagging
an issue.

## Shared references (all of them)

- [../_shared/project_structure.md](../_shared/project_structure.md)
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md)
- [../_shared/sql_style.md](../_shared/sql_style.md)
- [../_shared/python_style.md](../_shared/python_style.md)
- [../_shared/jinja_style.md](../_shared/jinja_style.md)
- [../_shared/yaml_style.md](../_shared/yaml_style.md)
- [../_shared/materialization_guidance.md](../_shared/materialization_guidance.md)

For deeper layer-specific rules, also consult `dbt_staging_model`,
`dbt_intermediate_model`, `dbt_mart_model`, `dbt_incremental_model`, and
`dbt_model_documentation`.

## 1. Model layer correctness & reference rules

- [ ] Is the model in the **right layer** for what it does (staging / intermediate /
      mart / metrics)?
- [ ] **Staging:** only renaming, casting, basic computations, categorizing — **no
      joins or aggregations**. 1:1 with a source; references **only `source()`** (only
      place `source()` is used). **Flag any join in a staging model** — joins are
      modeling and belong in an intermediate model. (`base_` models are passthrough
      landing tables only; they never join.)
- [ ] **Intermediate:** reads from **staging or other intermediate only**; a clear single
      transformation purpose; not exposed to end users.
- [ ] **`dim_`/`fct_`:** reads from **intermediate or staging only — never from another
      `dim_` or `fct_`.** Cross-entity rollups go in an intermediate model (or a
      `metrics_` model if reporting-specific).
- [ ] **`metrics_` (and legacy `mart_`):** reporting/visualization-specific aggregations
      that live outside the fact/dim marts; terminal (only BI/reporting reads from them).

## 2. Project structure & organization

- [ ] Correct folder: staging by **source system**, intermediate by **data
      domain**, marts by **data domain**.
- [ ] File naming: `stg_<source>__<table>`, `base_<source>__<table>`,
      `int_<purpose>`; marts are `dim_` (entity) or `fct_` (event). **No new `mart_`
      models** — reporting rollups go to the `metrics/` layer as `metrics_*` (`mart_*`
      is legacy, being migrated).
- [ ] YAML lives in the dbt Labs default **per-directory `_[directory]__models.yml`**
      (and `_[directory]__sources.yml` for staging) — **not** a per-model `docs/`
      subfolder.
- [ ] Folder-level config used in `dbt_project.yml`; **tags only for exceptions**, not
      as the primary grouping mechanism.

## 3. Naming & model style

- [ ] Models pluralized; `snake_case`; underscores not dots; no abbreviations.
- [ ] **Business terminology**, not source terminology.
- [ ] Primary key named `<object>_id`, string type; same field names reused across
      models for the same concept; no reserved words.
- [ ] Booleans `is_`/`has_`; timestamps `_at` in UTC (timezone suffix otherwise); dates
      `_date`; event tense past; currency in decimal (or explicit `_cents`).
- [ ] Columns grouped/ordered **ids → strings → numerics → booleans → dates →
      timestamps** with comment markers.

## 4. SQL style

- [ ] Lowercase keywords; 4-space indent; trailing commas; explicit `as`.
- [ ] **Optimized for human readability**, not fewer lines/characters — join conditions
      kept on one line (`on left.key = right.key`), `=` never broken across lines to
      satisfy a length limit (~80 chars is a guideline, readability wins).
- [ ] CTEs (not subqueries): **import CTEs at top** named after refs, selecting only
      needed columns / filtering early; **functional CTEs** do one logical unit with
      verbose names; **final line is `select * from <final_cte>`**.
- [ ] Fields stated before aggregates/window functions; aggregate early; `group by`
      number; reconsider design if grouping by many columns.
- [ ] `union all` over `union`; explicit `inner join`; columns prefixed with full table
      name; **no letter / non-descriptive table aliases** (`c.`, `o.`); joins read
      left → right.
- [ ] **No subqueries** (project override) — every `select` is a top-level CTE; scalar `max()`
      cutoffs use a `cutoff` CTE, not `(select max(...) from {{ this }})`.
- [ ] **`import_models` macro** used for all `ref()` imports in int/mart/metrics
      (hand-written import CTEs only for `source()` in staging and the incremental
      source).
- [ ] **Every functional CTE has a `/* */` header** of 1–3 plain-English sentences
      (import CTEs / `import_models` exempt); `--` inline comments explain business logic.
      **Never Jinja `{# #}`** in model SQL.

## 5. Grain

- [ ] The model's **grain is explicit and documented**, and the SQL actually produces
      that grain.
- [ ] Any **grain change** in the PR is intentional and called out (re-graining belongs
      in a dedicated intermediate model where it can be verified).
- [ ] Pure marts don't carry a time dimension (date rollups → metrics, not marts).

## 6. Joins & fanout

- [ ] No accidental **fanout** — row counts before/after joins make sense; primary-key
      uniqueness holds after joins.
- [ ] Join complexity is reasonable; **>4–5 concepts → push into intermediate models.**
- [ ] No multiple-output red flag (several models depending narrowly on one is fine;
      one model fanning into many divergent outputs is a smell).
- [ ] Reference rules respected (section 1) — no `dim_`/`fct_` reading another
      `dim_`/`fct_`, no circular dependencies; shared logic lives in an intermediate.

## 7. Jinja & Python (if present)

- [ ] Jinja: spaces inside `{{ }}`/`{% %}`, newlines/4-space indent for blocks,
      readability over whitespace control; Jinja not over-used where plain SQL is
      clearer; macros documented in `_macros.yml`.
- [ ] Python models: `black`/`ruff` clean; `def model(dbt, session)` returning a
      DataFrame; imports at top; not materialized as a view.

## 8. Tests

- [ ] **Primary key tested `unique` + `not_null` — and usually nothing else** (this
      repo's testing minimalism). PK is the **source id when one exists** (e.g. `user_id` on
      `dim_users`); for a **new grain not in the source**, a dbt
      `generate_surrogate_key` (`sk`) is built and tested. Composite grain uses a
      collapsed `sk` or `dbt_utils.unique_combination_of_columns`, not the built-in
      `unique` with a `column_name:` override.
- [ ] Extra tests (`relationships`, `accepted_values`, side-column `not_null`, range
      checks) appear **only** where the task explicitly calls for them; `severity: warn`
      used where the source legitimately allows the condition.
- [ ] **Tests are added or updated whenever** keys, joins, relationships, grain,
      business logic, or materialization behavior change.

## 9. Documentation (see `dbt_model_documentation`)

- [ ] Model has a `description` with what it represents **and its grain**.
- [ ] **Every column in the SQL is documented** in the YAML (no undocumented columns),
      and every documented column still exists in the SQL — the two are **in sync**. If
      this PR added/renamed/dropped/relogiced a column, the YAML reflects it.
- [ ] Descriptions are **helpful** (not name restatements) and **capture business logic**
      applied to the column.
- [ ] YAML lives in the directory's `_[directory]__models.yml` and follows
      yaml_style.md (2-space indent, ≤80 chars, explicit lists).

## 10. Materialization

- [ ] Materialization fits the layer **(this repo: staging→view, intermediate→`view`,
      mart→`table`/incremental)**, set explicitly in a `config()` block, following the
      golden rule (escalate to incremental only when a table build is too slow).
- [ ] Set at the right scope (folder default in `dbt_project.yml`, model override only
      for exceptions); cascade respected.
- [ ] Any **materialization change** explains the **freshness, cost, and rebuild
      tradeoffs**.

## 11. Incremental safety (if incremental)

- [ ] Incremental is justified (large/compute-heavy data; a table rebuild is too slow).
- [ ] Filter wrapped in `{% if is_incremental() %}`; uses `{{ this }}` cutoff correctly.
- [ ] `unique_key` set for mutable data (upsert, no duplicates).
- [ ] **Lookback window** present for late-arriving facts; drift acknowledged; a
      full-refresh cadence exists.
- [ ] `--full-refresh` rebuilds cleanly; `loaded_at_field`/`loaded_at_query` aligned
      with the lookback window for state-aware orchestration.
- [ ] Build timing confirms the incremental run beats the table it replaced.

## 12. Validation performed

- [ ] **`dbt compile`** for structural changes; **`dbt build`** (with
      `+`/`+model+` as needed) for logic, tests, and downstream impact — built in the
      `dev` target (`ANALYTICS_DEV.*`), **never** against `prod` by default.
- [ ] Change **verified in Snowflake** by querying the dev table directly (not just
      "dbt run succeeded"); root cause of any fix understood and stated.
- [ ] PR body explains **root cause** (diagnostic + why the fix is correct), not just
      the fix. See the dev/ship loop in `dbt_incremental_model`.
- [ ] SQL linting (SQLFluff) run if configured.
- [ ] For incremental: first build, incremental build, and full-refresh all verified.

## Review output

Summarize: what changed, the model layer, the grain, tests added/changed, validation
performed or recommended, and any risks, assumptions, or follow-up items. Flag anything
ambiguous (layer, grain, materialization) rather than letting a questionable choice pass.
