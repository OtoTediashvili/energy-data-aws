# syntax=docker/dockerfile:1
#
# One image for every function; Terraform sets each one's handler. AWS's
# Lambda base image provides the runtime; this adds the locked dependencies
# and the code. Built for x86_64 by scripts/image.sh.

FROM ghcr.io/astral-sh/uv:0.12.24 AS uv

FROM public.ecr.aws/lambda/python:3.12

# Dependencies first, from the lockfile, so a code change doesn't reinstall them.
COPY pyproject.toml uv.lock /tmp/build/
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv export --directory /tmp/build --frozen --no-dev --no-emit-project -o /tmp/build/requirements.txt \
    && uv pip install --no-cache --python /var/lang/bin/python3 \
        --target "${LAMBDA_TASK_ROOT}" -r /tmp/build/requirements.txt \
    && rm -rf /tmp/build

COPY src/energy "${LAMBDA_TASK_ROOT}/energy"

CMD ["energy.handlers.extract"]
