{#
    Every row satisfies the expression. Returns the rows that don't; a NULL
    result counts as a failure. Zero rows passes.
#}

{% test expression_is_true(model, expression) %}

select *
from {{ model }}
where not coalesce({{ expression }}, false)

{% endtest %}
