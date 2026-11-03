#!/usr/bin/env bash
# The functions' container image, tagged by its content.
#
#   scripts/image.sh tag    print the tag: a hash of everything in the image
#   scripts/image.sh push   build and push it to ECR, unless ECR already has it
#
# The same code always gets the same tag, and the repository refuses to
# overwrite a tag. So a tag in the Terraform plan always means one exact
# image, and an unchanged image is never rebuilt or pushed again.
set -euo pipefail
cd "$(dirname "$0")/.."

repository=energy-functions

tag() {
  {
    cat Dockerfile pyproject.toml uv.lock
    find src -type f -name '*.py' -not -path '*/__pycache__/*' -print0 | LC_ALL=C sort -z | xargs -0 cat
  } | sha256sum | cut -c1-12
}

push() {
  local tag account region registry image
  tag=$(tag)
  account=$(aws sts get-caller-identity --query Account --output text)
  region=${AWS_REGION:?AWS_REGION is not set}
  registry="$account.dkr.ecr.$region.amazonaws.com"
  image="$registry/$repository:$tag"

  if aws ecr describe-images --repository-name "$repository" \
    --image-ids imageTag="$tag" > /dev/null 2>&1; then
    echo "$image is already in ECR: nothing to build."
    return
  fi

  # --provenance=false: Lambda takes a plain image, not the image index that
  # Docker builds when it attaches build attestations.
  docker build --platform linux/amd64 --provenance=false --tag "$image" .

  # The login goes into a throwaway Docker config, deleted when the script
  # ends. In WSL, Docker Desktop keeps logins in the Windows credential store,
  # and that store refuses ECR's long login token: "error saving credentials
  # ... The stub received bad data". The token expires after 12 hours anyway,
  # so there is nothing worth keeping.
  login_config=$(mktemp -d)
  trap 'rm -rf "$login_config"' EXIT
  aws ecr get-login-password \
    | docker --config "$login_config" login --username AWS --password-stdin "$registry"
  docker --config "$login_config" push "$image"
  echo "Pushed $image"
}

case ${1:-} in
  tag) tag ;;
  push) push ;;
  *)
    echo "usage: scripts/image.sh tag|push" >&2
    exit 2
    ;;
esac
