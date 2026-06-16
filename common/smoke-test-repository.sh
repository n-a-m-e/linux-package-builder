#!/usr/bin/env bash
set -euo pipefail

metadata_dir="public/publisher-metadata"

require_file() {
  [[ -f "$1" ]] || { echo "::error::Missing required file: $1"; exit 1; }
}

require_name() {
  local name="$1" message="$2"
  if ! find public -type f -name "$name" -print -quit | grep -q .; then
    echo "::error::$message"
    exit 1
  fi
}

require_repo_metadata() {
  local message="$1"
  if ! find public -type f -path '*/repodata/repomd.xml' -print -quit | grep -q .; then
    echo "::error::$message"
    exit 1
  fi
}

case "${PACKAGE_TYPE:-}" in
  rpm)
    require_file public/GPG-KEY-repo
    require_file "$metadata_dir/packages.txt"
    require_file "$metadata_dir/repos.tsv"
    require_file "$metadata_dir/targets.txt"
    require_name '*.repo' 'No RPM .repo file was generated.'
    require_repo_metadata 'No RPM repodata/repomd.xml was generated.'
    ;;
  deb)
    require_file public/GPG-KEY-repo
    require_file "$metadata_dir/packages.txt"
    require_file "$metadata_dir/repos.tsv"
    require_file "$metadata_dir/targets.txt"
    require_name '*.sources' 'No DEB .sources file was generated.'
    require_name Release 'No DEB Release file was generated.'
    require_name InRelease 'No DEB InRelease file was generated.'
    ;;
  *)
    echo "::error::Unsupported package-type for repository smoke test: ${PACKAGE_TYPE:-}"
    exit 1
    ;;
esac

echo "Repository smoke test passed for ${PACKAGE_TYPE}."
