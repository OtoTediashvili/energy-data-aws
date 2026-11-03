{#
    The market day an instant belongs to. The day-ahead auction defines days
    in Brussels wall-clock time; the lake stores UTC. A zone-aware conversion,
    never a fixed offset: +2 is right in summer and silently wrong for every
    winter hour.

    Raw timestamps carry no time zone (they are UTC by convention), so the
    zone is attached first, then converted.
#}

{% macro market_date(utc_timestamp) -%}
    cast(with_timezone({{ utc_timestamp }}, 'UTC') at time zone '{{ var("market_timezone") }}' as date)
{%- endmacro %}
