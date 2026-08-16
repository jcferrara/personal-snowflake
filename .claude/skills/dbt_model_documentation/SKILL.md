---
name: dbt_model_documentation
description: Use when writing or updating a dbt model's YAML documentation — documenting every column, capturing business logic, and keeping the YAML in sync whenever the model's SQL changes.
---

# dbt Model Documentation

Every dbt model has a sibling YAML doc. This skill is how you write and maintain it.
**Documentation is not optional or separate from a SQL change** — if you touch a model's
columns or logic, you update its YAML in the same change.

## Shared references (read these)

- [../_shared/yaml_style.md](../_shared/yaml_style.md) — documentation conventions + YAML
  formatting (primary reference)
- [../_shared/dbt_model_style.md](../_shared/dbt_model_style.md) — naming, keys, what
  columns mean
- [../_shared/sql_style.md](../_shared/sql_style.md) — the testing convention (PK only)
- [../_shared/project_structure.md](../_shared/project_structure.md) — where the YAML
  lives

## Where the YAML lives

This repo follows the dbt Labs per-directory default:

- `models/<layer>/<domain>/_<domain>__models.yml` — every model's tests + column docs
  for that directory
- `models/staging/<source>/_<source>__sources.yml` — source definitions

## Rules

1. **Document the model.** Give the model a `description` stating **what it represents
   and its grain** (e.g. "One row per financial account (grain: account_id)").
2. **Document every column.** Every column in the model's `select` must have a matching
   `name` + `description` in the YAML. There are **no undocumented columns** — if a
   column is in the SQL, it is in the YAML.
3. **Make descriptions helpful.** Explain what the column *is* and how to use it — don't
   just restate the name. ❌ `transaction_status: "the transaction status"`. ✅
   `transaction_status: "Lifecycle state of the transaction: 'pending', 'posted', or
   'declined'."`
4. **Document business logic.** If a column is derived (a `case`, a coalesce default, a
   unit conversion like cents→dollars, a filter that shapes it), state that logic in the
   description so a reader understands how the value was produced — mirror the `--`
   inline comment in the SQL.
5. **Keep YAML in sync with SQL — always, in the same edit.** When you:
   - **add** a column → add its YAML entry;
   - **rename** a column → rename it in the YAML;
   - **remove** a column → remove its YAML entry;
   - **change the logic** behind a column → update its description.
   SQL and docs must never drift. Treat a PR that changes columns without updating the
   YAML as incomplete.
6. **Tests stay minimal.** Documenting every column does **not** mean testing every
   column. The default and usually only test is **`unique` + `not_null` on the primary
   key** — the source id when one exists (e.g. `user_id` on `dim_users`), otherwise the
   dbt surrogate key (`sk`) for a new grain. Add no other tests unless explicitly asked
   (see [../_shared/sql_style.md](../_shared/sql_style.md)).

## Example

```yaml
version: 2

models:
  - name: dim_accounts
    description: >
      One row per financial account (grain: account_id). Joins the account
      record to its institution and current balance.
    columns:
      - name: account_id
        description: Primary key. Source id from the finance source's account list.
        data_tests:
          - unique
          - not_null
      - name: account_name
        description: Display name of the account (source `name`).
      - name: current_balance_usd
        description: >
          Current balance in decimal dollars. Converted from the source integer
          cents (`balance_cents / 100.0`).
      - name: is_active
        description: True when the account is open and not closed or archived.
```

## Validation

- Cross-check the model's `select` list against the YAML — every selected column is
  documented, every documented column still exists in the SQL.
- Confirm only the primary key carries `unique` + `not_null` (no stray tests).
- Descriptions read helpfully and capture any business logic applied.
