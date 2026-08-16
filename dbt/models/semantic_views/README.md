# Semantic Views

Snowflake `SEMANTIC VIEW` objects that expose facts and dimensions to LLM / BI tools as
governed, named, synonym-rich metrics. Built via the `Snowflake-Labs/dbt_semantic_view`
package (`materialized='semantic_view'` — see `packages.yml`), which provides the
custom materialization; the model body is Snowflake's `CREATE SEMANTIC VIEW` grammar
(`TABLES`, `RELATIONSHIPS`, `FACTS`, `DIMENSIONS`, `METRICS`, top-level `COMMENT`).

Standards for these views live in the `dbt_semantic_view` skill (`.claude/skills/`):
facts and dimensions only (never `stg_`/raw tables), `PRIMARY KEY` on every declared
table, named `fact → dimension` relationships (no fact-to-fact joins), and `COMMENT` +
`SYNONYMS` on everything.

**No semantic views exist yet.** This repo currently has one mart (`dim_dates`) and no
fact tables — build a `fct_*` mart first (see `dbt_mart_model`), then the first
semantic view on top of it.

## Structure (once views exist)

- One subfolder per domain, matching the marts domains (`_core/`, `health/`,
  `finance/`, `meta/`).
- Per-view YAML description in `docs/<view>.yml` (same `_[directory]__models.yml`-style
  layout used elsewhere, scoped per model since each view's description is long).
- A domain-level `README.md` listing its views (name / grain / purpose) plus one
  Mermaid `erDiagram` per view, generated from that view's declared `TABLES` /
  `RELATIONSHIPS` (fact at the center, its dimensions, named relationships as edge
  labels).

```
models/semantic_views/
  <domain>/
    README.md
    <view>.sql
    docs/
      <view>.yml
```

## Before building the first one

- Snowflake role `TRANSFORMER` needs `CREATE SEMANTIC VIEW` on the target schema
  (`ANALYTICS_DEV.*` / `ANALYTICS.PROD`) — not yet granted in `admin/exact_grants.sql`
  as of this writing. Add it there (mirroring the existing `CREATE TABLE`/`CREATE VIEW`
  grants to `TRANSFORMER`) before the first `dbt run` on a semantic view.
- Validate with `dbt run --select <semantic_view>`, then sanity-query the view in
  Snowsight to confirm metrics resolve.
