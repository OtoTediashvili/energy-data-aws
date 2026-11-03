{#
    A timestamp cast to the precision the table being written can hold.
    Athena stores Iceberg timestamps in microseconds, timestamp(6), and Hive
    tables in milliseconds, timestamp(3), and a CTAS with the other precision
    fails. The marts are Iceberg, but a dbt unit test first builds an empty
    scratch table from the model's query to learn its column types, and that
    table is Hive. So the cast follows the table type instead of being fixed.
#}

{% macro table_timestamp(expression) -%}
    {%- if config.get('table_type', default='hive') | lower == 'iceberg' -%}
        cast({{ expression }} as timestamp(6))
    {%- else -%}
        cast({{ expression }} as timestamp(3))
    {%- endif -%}
{%- endmacro %}
