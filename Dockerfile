# syntax=docker/dockerfile:1
#
# Two images from one file, both on AWS's Lambda base image, both tagged by
# scripts/image.sh with one hash of everything they contain:
#
#   ingest     the extract and parse functions: the locked runtime
#              dependencies and the code. No dbt.
#   transform  the transform function: the same, plus dbt and the dbt
#              project, which it runs with `dbt build`.
#
# Built for x86_64 by scripts/image.sh: docker build --target ingest|transform.

FROM ghcr.io/astral-sh/uv:0.12.24 AS uv

FROM public.ecr.aws/lambda/python:3.12 AS ingest

# Dependencies first, from the lockfile, so a code change doesn't reinstall them.
COPY pyproject.toml uv.lock /tmp/build/
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv export --directory /tmp/build --frozen --no-default-groups --no-emit-project -o /tmp/build/requirements.txt \
    && uv pip install --no-cache --python /var/lang/bin/python3 \
        --target "${LAMBDA_TASK_ROOT}" -r /tmp/build/requirements.txt \
    && rm -rf /tmp/build

COPY src/energy "${LAMBDA_TASK_ROOT}/energy"

CMD ["energy.handlers.extract"]

FROM public.ecr.aws/lambda/python:3.12 AS transform

# The runtime dependencies and the lockfile's dbt group.
COPY pyproject.toml uv.lock /tmp/build/
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv export --directory /tmp/build --frozen --no-default-groups --group dbt --no-emit-project -o /tmp/build/requirements.txt \
    && uv pip install --no-cache --python /var/lang/bin/python3 \
        --target "${LAMBDA_TASK_ROOT}" -r /tmp/build/requirements.txt \
    && rm -rf /tmp/build

# No usage statistics from a scheduled job: dbt would also try to write an
# id file next to the profile, in a read-only image.
ENV DBT_SEND_ANONYMOUS_USAGE_STATS=false

# Not /var/task/dbt: that is where the dbt package itself is installed.
COPY dbt "${LAMBDA_TASK_ROOT}/dbt_project"
COPY src/energy "${LAMBDA_TASK_ROOT}/energy"

CMD ["energy.transform.handler"]
