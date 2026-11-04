#!/usr/bin/env bash
# The functions' two container images, tagged by their content.
#
#   scripts/image.sh tag    print the tag: a hash of everything in the images
#   scripts/image.sh push   build and push both to ECR, skipping any ECR has
#
# One Dockerfile, two targets, one tag:
#   energy-functions:<tag>            ingest: the extract and parse functions
#   energy-functions:<tag>-transform  transform: the same plus dbt and its project
#
# The same files always give the same tag, and the repository refuses to
# overwrite a tag. So a tag in the Terraform plan always means exact images,
# and an unchanged image is never rebuilt or pushed again.
set -euo pipefail
cd "$(dirname "$0")/.."

repository=energy-functions

tag() {
  # File names as well as contents, so a renamed model changes the tag too.
  # Only what the images contain: no dbt target/ or logs/, no caches.
  {
    sha256sum Dockerfile .dockerignore pyproject.toml uv.lock
    find src dbt -type f \( -name '*.py' -o -name '*.sql' -o -name '*.yml' -o -name '*.csv' \) \
      -not -path '*/__pycache__/*' -not -path 'dbt/target/*' -not -path 'dbt/logs/*' \
      -not -path 'dbt/dbt_packages/*' -not -name '.user.yml' -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum
  } | sha256sum | cut -c1-12
}

push() {
  local tag account region registry target image
  tag=$(tag)
  account=$(aws sts get-caller-identity --query Account --output text)
  region=${AWS_REGION:?AWS_REGION is not set}
  registry="$account.dkr.ecr.$region.amazonaws.com"
  login_config="" # global, so the EXIT trap still sees it after push returns

  for target in ingest transform; do
    image="$registry/$repository:$tag"
    [[ $target == ingest ]] || image="$image-$target"

    if aws ecr describe-images --repository-name "$repository" \
      --image-ids imageTag="${image##*:}" > /dev/null 2>&1; then
      echo "$image is already in ECR: nothing to build."
      continue
    fi

    # --provenance=false: Lambda takes a plain image, not the image index that
    # Docker builds when it attaches build attestations.
    docker build --platform linux/amd64 --provenance=false --target "$target" --tag "$image" .

    # The login goes into a throwaway Docker config, deleted when the script
    # ends. In WSL, Docker Desktop keeps logins in the Windows credential
    # store, and that store refuses ECR's long login token: "error saving
    # credentials ... The stub received bad data". The token expires after 12
    # hours anyway, so there is nothing worth keeping.
    if [[ -z $login_config ]]; then
      login_config=$(mktemp -d)
      trap 'rm -rf "$login_config"' EXIT
      aws ecr get-login-password \
        | docker --config "$login_config" login --username AWS --password-stdin "$registry"
    fi
    docker --config "$login_config" push "$image"
    echo "Pushed $image"
  done
}

case ${1:-} in
  tag) tag ;;
  push) push ;;
  *)
    echo "usage: scripts/image.sh tag|push" >&2
    exit 2
    ;;
esac
