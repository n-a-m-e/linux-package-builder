#!/usr/bin/env bash
set -euo pipefail

source /work/publisher/common/repository-common.sh

program="$(basename "$0")"
[[ "$program" == "package-build-queue" ]] || { echo "Unsupported command name: $program. Use package-build-queue." >&2; exit 1; }
[[ "${1:-}" == add ]] || { echo "Unsupported command: ${1:-}. Expected: package-build-queue add" >&2; exit 1; }
shift

queue_type="${PACKAGE_TYPE:-}"
[[ "$queue_type" == rpm || "$queue_type" == deb ]] || { echo "PACKAGE_TYPE must be rpm or deb" >&2; exit 1; }

clone_url=""
ref=""
subdir=""
spec=""
package=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clone-url) clone_url="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --subdir) subdir="$2"; shift 2 ;;
    --spec) spec="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    *) echo "Unsupported package-build-queue argument: $1" >&2; exit 1 ;;
  esac
done

queue_dir="${PACKAGE_BUILD_QUEUE_DIR:-/work/package-build-queue}"

case "$queue_type" in
  rpm)
    [[ -n "$clone_url" ]] || { echo "RPM declarations require --clone-url" >&2; exit 1; }
    [[ -n "$subdir" ]] || { echo "RPM declarations require --subdir" >&2; exit 1; }
    [[ -n "$spec" ]] || { echo "RPM declarations require --spec" >&2; exit 1; }
    safe_id="$(queue_safe_id "${package:-${spec%.spec}}-$subdir")"
    queue_write_env "$queue_dir" "$safe_id" \
      QUEUE_TYPE rpm \
      CLONE_URL "$clone_url" \
      REF "${ref:-master}" \
      SUBDIR "$subdir" \
      SPEC "$spec" \
      PACKAGE "${package:-${spec%.spec}}" \
      SOURCE_ID "${SOURCE_ID:-}"
    metadata_append_package "${package:-${spec%.spec}}" "${PUBLIC_ROOT:-/work/public}/publisher-metadata"
    echo "Declared RPM package: ${package:-${spec%.spec}}"
    ;;
  deb)
    [[ -n "$package" ]] || { echo "DEB declarations require --package" >&2; exit 1; }
    subdir="${subdir:-.}"
    safe_id="$(queue_safe_id "$package-$subdir")"
    queue_write_env "$queue_dir" "$safe_id" \
      QUEUE_TYPE deb \
      CLONE_URL "$clone_url" \
      REF "${ref:-main}" \
      SUBDIR "$subdir" \
      PACKAGE "$package" \
      SOURCE_ID "${SOURCE_ID:-}"
    metadata_append_package "$package" "${PUBLIC_ROOT:-/work/public}/publisher-metadata"
    echo "Declared DEB package: $package"
    ;;
esac
