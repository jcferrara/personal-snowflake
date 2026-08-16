# AGENTS.md

This is a **personal data monorepo**: `extraction/` (Python scripts that land raw
source data into Snowflake's `RAW` database) and `dbt/` (a **dbt analytics engineering
project** that transforms `RAW.*` into `ANALYTICS.*`). Target warehouse is Snowflake;
dbt is run via the dbt Core CLI (no dbt Cloud). This file's standards below are for
**dbt work**; `extraction/` is plain Python governed by `extraction/README.md`, not by
the `.claude/skills/` dbt standards.

## Where the standards live

- **AI dbt standards live in `.claude/skills/`.** Do not restate them here.
- **Task-specific instructions live in each skill's `SKILL.md`.**
- **Reusable, cross-cutting standards live in `.claude/skills/_shared/`** (dbt model
  style, SQL style, Python style, Jinja style, YAML style, materialization guidance,
  project structure).

## Before you edit

1. **Identify the model layer first** (`staging/`, `intermediate/`, `marts/`,
   `metrics/`, `semantic_views/`).
2. **Read and follow the relevant skill before making any dbt change.** The skill
   points you to the `_shared/` references it relies on — read those too.

## Skill routing

| You are working on… | Use this skill |
| --- | --- |
| Staging models (`stg_*`) | `dbt_staging_model` |
| Intermediate models (`int_*`) | `dbt_intermediate_model` |
| Marts — facts, dimensions, business entities (`dim_*`, `fct_*`) | `dbt_mart_model` |
| Metrics models (`metrics_*` in `models/metrics/`) | `dbt_metrics_model` |
| Snowflake semantic views (`models/semantic_views/`) | `dbt_semantic_view` |
| Incremental models and any materialization change | `dbt_incremental_model` |
| Writing/updating a model's YAML documentation | `dbt_model_documentation` |
| PR review and model critique | `dbt_model_review` |

Reporting/visualization rollups are **`metrics_*` in the `metrics/` layer** (`mart_*`
is legacy — do not create new `mart_` models); use `dbt_metrics_model`. Semantic views
(`models/semantic_views/`) use `dbt_semantic_view`. The rule for which of the two a
given metric belongs in lives in `_shared/project_structure.md` ("Reporting surface:
metrics model vs. semantic view"). See `dbt_mart_model` for the marts-vs-metrics
distinction.

## Hard rules

- Do **not** add joins to staging models unless the skill explicitly allows the
  exception.
- Do **not** add business metrics to staging models.
- Do **not** change a model's grain without calling it out.
- Do **not** change materialization strategy without explaining the freshness, cost,
  and rebuild tradeoffs.
- Do **not** duplicate shared style guidance inside individual skills — it belongs in
  `.claude/skills/_shared/`.
- Do **not** ignore tests when changing keys, joins, relationships, grain, business
  logic, or materialization behavior.
- Do **not** create new standards outside `.claude/skills/_shared/` unless explicitly
  asked.
- Prefer **business terminology over source-system terminology** when naming marts.

## Validation expectations

- Run the **narrowest applicable** dbt validation command.
- Prefer `dbt compile` for structural changes.
- Prefer `dbt build` for logic, test, and downstream-impact changes.
- No SQL linter is configured in this repo yet (no `.sqlfluff`) — skip linting unless
  one is added.

## Response expectations

Keep responses concise and implementation-focused. When reporting a dbt change, state:

- **What changed** (and why it belongs in that model layer).
- **The model layer.**
- **The model grain.**
- **Tests added or changed.**
- **Validation performed or recommended.**
- **Risks, assumptions, or follow-up items.**

**Call out ambiguity** instead of silently choosing a questionable model layer, grain,
or materialization — surface it and ask before proceeding.

## Repo operational reference

These are tool-agnostic repo conventions. Style/modeling detail stays in
`.claude/skills/`.

### Layer structure

```
models/
  staging/        one model per source table — light renaming, type casts
  intermediate/   business logic, denormalization, joins across sources
  marts/          dim_*, fct_* — analyst-facing entity & event tables
                  (_core/ cross-cutting, health/, finance/, meta/ domains)
  metrics/        metrics_* — reporting/viz rollups (mart_* is legacy, migrating here)
  semantic_views/ Snowflake semantic views (materialized='semantic_view') — planned,
                  not yet built
```

### Local development

Dependency management is via a shared root **venv** + **pip** (no `uv`, no dbt Cloud).
Snowflake auth is via private key; credentials live in `~/.dbt/profiles.yml`.

```bash
source .venv/bin/activate
pip install -r dbt/requirements.txt         # dbt-core, dbt-snowflake
cd dbt
dbt deps                                     # required after any packages.yml change
dbt run  --select <model_name>               # builds into your dev schema
dbt test --select <model_name>
```

Profile is `personal_snowflake`, role `TRANSFORMER` / warehouse `TRANSFORM_WH`. Target
`dev` (the default) writes to `ANALYTICS_DEV.*`; `prod` writes to `ANALYTICS.PROD` and
must be targeted deliberately (`--target prod`), never by default. Graph operators:
`+model` (upstream), `model+` (downstream), `+model+` (both).

### Pull request conventions

Branch off `main`, one logical change per branch, descriptive branch names (e.g.
`add-dim-dates-model`). No `pull_request_template.md` exists in this repo — write a
concise description covering what changed and why. For bug-fix PRs, explain the
**root cause** (what broke and where, the diagnostic that pinned it, why the fix is
correct, and the test plan), not just the fix. Keep titles under ~70 chars.

### Common pitfalls

- Run `dbt deps` after pulling `main`, or refs to `dbt_utils`/`dbt_date` fail with
  "macro not found".
- `dbt run --select <model>` fails if parents aren't built — use `+<model>` to pull
  them in.
- The `column_name:` override on the built-in `unique` test is silently ignored — use
  `dbt_utils.unique_combination_of_columns`.
- **Source data is the truth.** Before "fixing" a not_null/unique failure, profile the
  source — the bug is usually upstream.
- **Garmin RAW landing shape:** every `RAW.GARMIN.<table>` has exactly four columns —
  `NATURAL_KEY`, `RAW_DATA` (VARIANT JSON), `EXTRACTED_AT`, `SOURCE_METHOD`. Staging
  models over Garmin sources must flatten `raw_data` with `:`/`::` path syntax, not
  simple column renames.

### Where to find things

- SQL style reference: `.claude/skills/_shared/sql_style.md` (no separate root-level
  style guide file in this repo).
- PR template: none.
- Custom macros: `dbt/macros/` (`import_models.sql` is the ref convention for
  intermediate/mart/metrics layers).
- Seeds: `dbt/seeds/`.
- Tests/yml: one `_[directory]__models.yml` per models directory (and
  `_[directory]__sources.yml` for staging) — not a per-model `docs/` subfolder.
