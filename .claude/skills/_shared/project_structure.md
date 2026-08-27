# Project Structure (shared reference)

How to organize a dbt project: the layers, folder conventions, YAML/doc organization,
config cascading, and the non-model folders. Sources: dbt Labs "How we structure our
dbt projects" (staging, intermediate, marts, the rest of the project).

## The mental model

The project moves from source-conformed → business-conformed data through layers,
"narrowing the DAG and widening the tables":

- **staging** — atoms: clean, source-conformed building blocks (1 per source table)
- **intermediate** — molecules: purpose-built transformation steps
- **marts** — cells: business-defined entities at a specific grain

Until the marts layer the DAG should look like an arrowhead pointing right — many
narrow source-conformed concepts converging into fewer, wider, business-conformed ones.
**Allow multiple inputs to a model, but not multiple outputs** (several arrows in is
fine; several arrows out is a red flag).

## Model reference rules — who can ref whom

These layer-dependency rules are strict in this repo. When reviewing or building, verify
every `ref()`/`source()` against them:

- **Staging** is **one-to-one with a source**, references **only a `source()`**, and does
  **no joins**. Staging is the only place `source()` is used.
  - **Need to join another table?** That's modeling — put it in an **intermediate model**,
    not staging. Every real join in this repo lives in `int_`. (`base_` models exist only
    to land a raw source as a table for a passthrough `stg_` to read — they never join.)
- **Intermediate** may read from **staging models or other intermediate models only**.
- **Facts & dimensions** (`fct_*` / `dim_*`) may read from **intermediate or staging
  models only**. **A fact/dimension must NOT read from another fact or dimension.**
- **Metrics** (`metrics_*`, and the legacy `mart_*`) are **specific aggregations or
  reporting-specific modeling used downstream in reporting/visualization.** They live
  *outside* the fact/dimension marts because they're one-off structures that don't fit a
  relational data store. They may read from facts, dimensions, intermediate, or staging
  as needed for the rollup — but nothing reads *from* them except reporting/BI. Sole
  exception: a pure reshape sibling (a `_tidy` unpivot) may read the wide `metrics_`
  table it reshapes.
- **Semantic views** (`models/semantic_views/`, `materialized='semantic_view'`) are
  Snowflake `SEMANTIC VIEW` objects that expose facts and dimensions to LLM / BI tools as
  governed, named metrics. They reference **facts and dimensions
  only**, and like metrics are **terminal** — reporting/LLM tools read from them, nothing
  else does.

```
source  ──►  staging  ──►  intermediate  ──►  dim_/fct_ (marts) ─┬─►  metrics_ (reporting rollups, terminal)
          (1:1, no joins)   (joins live here)                    └─►  semantic_views (LLM/BI access, terminal)
```

### Reporting surface: metrics model vs. semantic view

Both are terminal reporting surfaces on top of the marts; pick by **how much modeling the
metric needs**. Ask: *"Can I express this as a single aggregate over fact rows joined to
their dimensions?"*

- **Semantic view** — yes: the metric is a straightforward `COUNT` / `SUM` /
  `COUNT DISTINCT` / `AVG` / simple ratio or percentile over the joined fact+dim rows. No
  row-level pre-computation. This is the LLM/BI-native surface — **prefer it when the
  metric fits.**
- **Metrics model (`metrics_*`)** — no: the metric needs manipulation the semantic-view
  grammar can't express (a **date spine, window functions, cohort baselines, waterfalls,
  unpivots, multi-pass aggregation, metric trees, point-in-time** logic). Build the table;
  BI reads it directly, or a thin semantic view layers on top.
- **Boundary case** — if the only hard part is a row-level explosion or bridge, do it in
  an **intermediate model** and let the semantic view aggregate on top; don't build a
  `metrics_` table for it. *Example:* counting subscriptions **active on each day** needs
  each subscription fanned out across the dates its billing period overlaps — a row-level
  explosion the semantic-view grammar can't do. Build that date-overlap bridge as an
  intermediate model (grain `subscription_id × date_day`), then the semantic view does a
  plain `COUNT(DISTINCT subscription_id)` by date — `int_` + semantic view, no `metrics_`
  table.

Layer-specific requirements live in the `dbt_metrics_model` and `dbt_semantic_view` skills.

## Full recommended directory structure

```
personal_snowflake
├── analyses
├── seeds
│   └── category_mappings.csv
├── macros
│   ├── _macros.yml
│   └── cents_to_dollars.sql
├── snapshots
├── tests
│   └── assert_positive_value_for_amount.sql
└── models
    ├── staging
    │   ├── garmin
    │   │   ├── _garmin__docs.md
    │   │   ├── _garmin__models.yml
    │   │   ├── _garmin__sources.yml
    │   │   ├── stg_garmin__activities.sql
    │   │   └── stg_garmin__sleep.sql
    │   └── finance
    │       ├── _finance__models.yml
    │       ├── _finance__sources.yml
    │       └── stg_finance__transactions.sql
    ├── intermediate
    │   └── finance
    │       ├── _int_finance__models.yml
    │       └── int_transactions_categorized.sql
    ├── marts
    │   ├── health
    │   │   ├── _health__models.yml
    │   │   ├── activities.sql
    │   │   └── daily_metrics.sql
    │   └── finance
    │       ├── _finance__models.yml
    │       └── accounts.sql
    └── utilities
        └── all_dates.sql
```

## Staging folder — organize by SOURCE SYSTEM

- One subfolder **per source system** (`garmin`, `finance`). Source systems share
  loading methods/properties, so it's easy to operate on similar sets.
- ❌ Don't subdivide by **loader** (Fivetran, Stitch…) — too broad.
- ❌ Don't subdivide by **business grouping** in staging — that creates overlapping,
  conflicting definitions and breaks the single source of truth. Everyone builds from
  the same atomic staging components.
- File naming: **`stg_[source]__[entity]s.sql`** (double underscore separates source
  from entity). The rare passthrough-landing base model uses
  **`base_[source]__[entity]s.sql`** in a `base/` subfolder — for landing a raw source as
  a table only, never for joins.

## Intermediate folder — organize by DATA DOMAIN

- Subfolders by area of concern (e.g. `finance`, `health`), each model inside an
  `intermediate` subfolder.
- File naming: **`int_[entity]s_[verb]s.sql`** — verbs describe the transformation
  (`pivoted`, `aggregated_to_day`, `joined`, `fanned_out_by_quantity`, `summed`,
  `funnel_created`). **Drop the double underscores used in staging** — that convention
  is staging-only, even for a model that still operates at a single source system
  (e.g. `int_garmin_activities_summed`, not `int_garmin__activities_summed`).

## Marts folder — organize by DATA DOMAIN

- Subfolders by domain (`health`, `finance`). With fewer than
  ~10 marts you may not need subfolders.
- **Name by entity in plain English** (`activities`, `transactions`, `accounts`) — the
  concept that forms the grain.
- ❌ Don't build the same concept differently across domains (a health-side
  `daily_summary` and a finance-side `daily_summary` that disagree about what counts as
  "the day" is an anti-pattern). If two domains genuinely need different concepts,
  name them as distinct concepts (`net_spend` vs `gross_spend`), not domain-specific
  views.

## Don't over-optimize folder structure early

- If you have fewer than ~10 marts and aren't hitting problems, you can forego marts
  subdirectories — **except in staging, where source-system subfolders are always
  needed** as you add sources.
- Goal: a single source of truth — don't let health and finance each build their own
  version of the same rollup.

## YAML, docs, and config organization

### Config per directory (recommended)

- Create a **`_[directory]__models.yml`** per models directory configuring all models in
  it. For staging folders, also a **`_[directory]__sources.yml`**.
- If you use doc blocks, add a **`_[directory]__docs.md`** per directory.
- **Leading underscore** sorts these to the top of the folder and separates them from
  model SQL. **Include the directory name** so files are quick to fuzzy-find (YAML file
  names don't need to be unique like model files do). Label files by the YAML dict they
  contain.
- ❌ **Config per project** (one giant YAML) — technically works but hard to find
  specific config.
- ⚠️ **Config per model** (one YAML per model) — fast to locate but the file-management
  overhead outweighs the benefit; not recommended for most projects.

### Cascade config in `dbt_project.yml`

Define defaults (schema, materialization) at the directory level and let dbt's cascading
scope priority handle variations — you only configure exceptions. See
[materialization_guidance.md](materialization_guidance.md) for the example.

- **Lean on folders as the primary selector/grouping mechanism**
  (`dbt build --select marts.finance`). Use **tags only for exceptions** to your
  folder rules — relying on tags for everything creates unnecessary complexity.

## Non-model folders

- **seeds/** — load lookup tables that don't exist in any source system (merchant
  name→spend category, Garmin activity-type code→display name). ❌ Don't use seeds to
  load source-system data; use a proper EL tool to land that in the warehouse.
- **analyses/** — version-controlled queries you want Jinja on but won't build as
  models (e.g. auditing queries using the audit_helper package for migrations).
- **tests/** — singular tests, best for flexibly testing how several specific models
  interact/relate (like integration tests vs. the unit-test feel of generic tests).
  Much singular-test logic eventually migrates into custom generic tests or pre-built
  package tests.
- **snapshots/** — Type 2 slowly-changing-dimension records from Type 1 (destructively
  updated) source data.
- **macros/** — DRY up repeated transformations. **Document macros** in a `_macros.yml`
  (purpose + arguments) once ready for use.
- **models/utilities/** — general-purpose models from macros or seeds (e.g. a date
  spine via dbt_utils `date_spine`); not part of staging.

## Groups

A group is a collection of nodes in the DAG enabling intentional collaboration and
restricting access to private models. Define groups in `.yml` under a `groups:` key;
v1.10+ supports `description` and `meta` on a group.

## Development flow (not DAG order)

Structure docs follow DAG order, but you build in this order: (1) mock the output with
stakeholders, (2) write the SQL to produce it and identify required tables, (3) ensure
the atomic pieces are staged, (4) combine components in a mart, (5) refactor — split
logic into intermediate models. This yields clean, readable models with a clear DAG and
maximum testing surface area.

## Actual layout in this repo (overrides where noted)

> **Layers in this repo:** `staging/` → `intermediate/` → `marts/` → `metrics/` →
> `semantic_views/`.
>
> **Sources / staging folders:** `garmin` (Garmin Connect wellness and activity data —
> already extracted, see `extraction/garmin/`), `finance` (personal finance
> transactions/accounts — source not yet decided), `manual` (hand-entered or backfilled
> data). Staging files: `stg_<source>__<table>.sql`.
>
> **Intermediate domains:** e.g. `health/`, `finance/`. Some general-purpose int models
> (`int_dates_spine`) live at the top of `intermediate/`; new ones go in a domain folder
> unless clearly cross-domain. Files: `int_<what_this_produces>.sql`.
>
> **Marts domains:** `_core/` (cross-cutting dims/facts used everywhere — e.g.
> `dim_dates`), `health/`, `finance/`, `meta/` (pipeline/extraction metadata). New marts
> go in the owning domain; `_core/` is reserved for things many domains use. Marts hold
> **`dim_`** (entity) and **`fct_`** (event) models.
>
> **Metrics layer (`metrics/`, `metrics_*`):** reporting / visualization-specific
> rollups built on top of facts, dimensions, and other models. **`mart_*` is a legacy
> prefix being migrated to `metrics_*`** — do not create new `mart_` models; put new
> reporting rollups in `metrics/` as `metrics_*`.
>
> **YAML/doc layout.** This repo uses the dbt Labs default described above: one
> **`_[directory]__models.yml`** per models directory (and `_[directory]__sources.yml`
> for staging), e.g. `models/intermediate/_intermediate__models.yml` and
> `models/marts/_marts__models.yml` — **not** a per-model `docs/` subfolder.
>
> **`import_models` macro** (`macros/import_models.sql`) is the standard for `ref()`
> imports in intermediate/mart/metrics layers — see
> [sql_style.md](sql_style.md).

## Overarching principles

1. **Consistency matters more than any specific convention** — document how/why you
   deviate.
2. **Folder-based selection over tagging.**
3. **DRY configuration** via cascading `dbt_project.yml` defaults.
4. **Clear documentation** of conventions for the team.
5. **Living document** — revisit structure as dbt and the project evolve.
