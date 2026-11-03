{#
    By default dbt names schemas "<target schema>_<custom schema>": here that
    would be energy_staging_energy_marts. Each layer is a Glue database that
    Terraform creates and grants access to, so the custom schema is used
    verbatim: energy_staging, energy_marts, energy_raw.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
