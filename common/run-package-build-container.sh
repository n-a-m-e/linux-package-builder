#!/usr/bin/env bash
set -euo pipefail

case "${PACKAGE_TYPE:-}" in
  rpm|deb) ;;
  *)
    echo "::error::Unsupported package-type for repository build: ${PACKAGE_TYPE:-}"
    exit 1
    ;;
esac

# Package-specific hooks own the container image choice.
# shellcheck source=/dev/null
source "publisher/${PACKAGE_TYPE}/container-hooks.sh"
container_image="$(package_container_image)"
[[ -n "$container_image" ]] || { echo "::error::${PACKAGE_TYPE} hook did not provide a container image"; exit 1; }

mkdir -p package-cache public work package-build-queue

docker run -i --privileged --rm \
  -e PACKAGE_TYPE="$PACKAGE_TYPE" \
  -e APP="$APP" \
  -e SOURCE_GIT="$SOURCE_GIT" \
  -e BUILD_SCRIPT="$BUILD_SCRIPT" \
  -e REPO_OWNER="$REPO_OWNER" \
  -e REPO_NAME="$REPO_NAME" \
  -e FPR="$FPR" \
  -e TARGETS="$TARGETS" \
  -e PUBLIC_ROOT="/work/public" \
  -e PACKAGE_BUILD_QUEUE_DIR="/work/package-build-queue" \
  -v "$PWD:/work" \
  -v "$PWD/package-cache:/package-cache" \
  -v "$HOME/.gnupg:/root/.gnupg" \
  -w /work \
  "$container_image" \
  bash /work/publisher/common/container-build-common.sh
