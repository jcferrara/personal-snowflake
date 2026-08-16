# Jinja Style (shared reference)

Style for Jinja in dbt models and macros. Source: dbt Labs "How we style our Jinja."

## Rules

- **Spaces inside delimiters.** Write `{{ this }}` not `{{this}}`, and `{% ... %}` with
  inner spaces. Applies to both variable `{{ }}` and block `{% %}` delimiters.
- **Use newlines to visually separate logical blocks of Jinja.**
- **Indent 4 spaces into a Jinja block** to show visually that the enclosed code is
  wrapped by that block.
- **Don't worry (too much) about Jinja whitespace control.** Prioritize readable
  project code over perfect compiled output. The time saved by not fighting whitespace
  trimming outweighs the cost of imperfect compiled SQL.
- **List arguments in macro calls go one item per line.** When a macro takes list
  arguments — e.g. `import_models(refs=[...], ctes=[...])` — put each element on its
  own line for *every* list (even short ones), so the `refs` and `ctes` line up
  position-for-position and each `ref()` maps to its CTE alias at a glance. Never cram
  a list onto one line while its paired list is multi-line. sqlfluff can't enforce this
  (it lints the compiled SQL, not the macro call), so it's a review-checked convention.

```jinja
{{
    import_models(
        refs=[
            ref('fct_transactions'),
            ref('dim_accounts')
        ],
        ctes=[
            'transactions',
            'accounts'
        ]
    )
}}
```

## Core principle

**Readability over perfect whitespace control.** This governs the whole approach to
Jinja. Favor clear, well-spaced project code; only reach for whitespace control
(`{%-`, `-%}`) when it genuinely aids readability.

## Example

```jinja
{% macro make_cool(uncool_id) %}
    do_cool_thing({{ uncool_id }})
{% endmacro %}

select
    entity_id,
    entity_type,
    {% if this %}
        {{ that }},
    {% else %}
        {{ the_other_thing }},
    {% endif %}
    {{ make_cool('uncool_id') }} as cool_id
```

## Related practice (from SQL/structure guides)

- Use Jinja to keep models DRY (e.g. looping over a list of values to pivot) — but do
  not over-use it; if Jinja makes a model hard to follow, prefer plain SQL or push the
  logic into an intermediate model.
- Document macros in a `_macros.yml` (purpose and arguments) once they're ready for use.
- **This repo:** do not use Jinja comments (`{# #}`) in model SQL — use `/* */` CTE
  headers and `--` inline comments instead (see [sql_style.md](sql_style.md)). Jinja
  comments are still fine inside macro files.
