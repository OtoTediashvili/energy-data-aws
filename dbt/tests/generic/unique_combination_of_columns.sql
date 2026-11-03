{#
    No two rows share these columns. Returns each duplicated combination;
    zero rows passes. (dbt_utils has the same test; this project downloads no
    packages, so nothing is fetched when the transform image is built.)
#}

{% test unique_combination_of_columns(model, combination_of_columns) %}

select
    {{ combination_of_columns | join(', ') }},
    count(*) as copies
from {{ model }}
group by {{ combination_of_columns | join(', ') }}
having count(*) > 1

{% endtest %}
