{% macro import_models(refs=[], ctes=[]) -%}
{#- Each argument passed to the macro should be a valid 'ref()' function. -#}
{%- if refs==[] -%}
    {{-
        exceptions.raise_compiler_error(
            "Invalid arguments. Cannot be an empty list. Must pass a list of valid ref() function calls. The referenced refs must exist."
        )
    -}}
{%- endif -%}
{#- Use aliases as CTE names -#}
{%- if ctes!=[] and ctes is defined -%}
{%- if refs|length != ctes|length -%}
    {{-
        exceptions.raise_compiler_error(
            "Invalid arguments. refs and ctes must be the same length."
        )
    -}}
{%- endif -%}
{%- for i in refs -%}
{%- set ref = refs[loop.index-1] -%}  {#- Jinja indexes start at 1 -#}
{%- set alias = ctes[loop.index-1] -%}
{{ alias }} as (
    select * from {{ ref }}
){%- if not loop.last -%},{%- endif -%}
{%- endfor -%}
{#- Use the ref names as the CTE names -#}
{%- else -%}
{%- for ref in refs %}
{{ ref.name }} as (
    select * from {{ ref }}
){%- if not loop.last -%},{%- endif -%}
{%- endfor -%}
{%- endif -%}
{%- endmacro -%}