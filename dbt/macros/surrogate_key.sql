{#
    A stable key from a natural key: the lowercase hex MD5 of its text. The
    same value dbt_utils.generate_surrogate_key gives for one column, without
    a package to download at build time.
#}

{% macro surrogate_key(column) -%}
    lower(to_hex(md5(to_utf8(cast({{ column }} as varchar)))))
{%- endmacro %}
