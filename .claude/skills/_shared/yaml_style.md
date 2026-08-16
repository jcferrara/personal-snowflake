# YAML Style (shared reference)

Style for YAML in dbt projects (model docs, tests, sources). Source: dbt Labs "How we
style our YAML." File-organization conventions come from
[project_structure.md](project_structure.md).

## Formatting rules

- **Indent with two spaces.**
- **Indent list items.**
- **A single-entry list can be a string** (`'select': 'other_user'`), but best practice
  is an explicit list (`'select': ['other_user']`).
- **Use a new line to separate list items that are dictionaries** where appropriate.
- **Lines no longer than 80 characters.**
- **Validate/format with the dbt JSON schema** in a compatible IDE plus a YAML formatter
  (dbt recommends **Prettier**). dbt Cloud's IDE has built-in Prettier formatting for
  YAML, Markdown, and JSON (click **Format**); rules are customizable.

## Example

```yaml
models:
  - name: events
    columns:
      - name: event_id
        description: This is a unique identifier for the event
        data_tests:
          - unique
          - not_null
      - name: event_time
        description: "When the event occurred in UTC (eg. 2018-01-01 12:00:00)"
        data_tests:
          - not_null
      - name: user_id
        description: The ID of the user who recorded the event
        data_tests:
          - not_null
          - relationships:
              arguments: # available in v1.10.5+. Older versions set the
                         # <argument_name> as the top-level property.
                to: ref('users')
                field: id
```

## Documentation conventions

These rules govern what goes in a model's YAML doc. The detailed workflow is in the
`dbt_model_documentation` skill.

- **Document the model itself** — a `description` saying what the model represents and
  its **grain** (one row per …).
- **Document every column.** Every column that appears in the model's `select` must have
  a corresponding `name` + `description` entry in the YAML. No undocumented columns.
- **Descriptions must be helpful**, not a restatement of the column name. ❌
  `account_id: "The account id"`. ✅ `account_id: "FK to dim_accounts; the
  financial account this transaction was posted to."`
- **Document business logic.** If a column is derived or transformed (a `case`, a
  coalesce default, a unit conversion, a filter that shapes it), state that logic in the
  description so a reader knows how the value was produced.
- **Keep docs in sync with SQL.** Any time you add, rename, drop, or change the logic of
  a column in the SQL, make the **same change in the YAML in the same edit**. SQL and
  docs must never drift.
- **Tests stay minimal** — the default and usually only test is `unique` + `not_null` on
  the **primary key** (see the testing convention in [sql_style.md](sql_style.md)).
  Documenting every column does **not** mean testing every column.

```yaml
version: 2

models:
  - name: dim_devices
    description: >
      One row per Garmin device (grain: device_id). Combines the device record
      with its last-synced settings.
    columns:
      - name: device_id
        description: Primary key. Source id from Garmin's device list endpoint.
        data_tests:
          - unique
          - not_null
      - name: device_name
        description: Display name of the device (Garmin `displayName`).
      - name: timezone
        description: >
          IANA timezone configured on the device. Coalesced to 'America/Los_Angeles'
          when the source is null so downstream convert_timezone calls don't null out.
      - name: is_active
        description: True when the device is currently paired and syncing.
```

## File naming & organization (see project_structure.md for full detail)

This repo follows the dbt Labs default below — see the existing
`models/intermediate/_intermediate__models.yml` and `models/marts/_marts__models.yml`
for the pattern in place.

- **One config YAML per directory:** `_[directory]__models.yml`, and
  for staging also `_[directory]__sources.yml`. Doc blocks go in `_[directory]__docs.md`.
- **Leading underscore** sorts YAML files to the top of the folder and keeps them easy
  to distinguish from model SQL.
- **Include the directory name** in the file name so it's quick to fuzzy-find (since
  YAML file names don't have to be unique the way model files do).
