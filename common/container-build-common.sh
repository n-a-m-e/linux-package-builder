#!/usr/bin/env bash
set -euxo pipefail

[[ -n "${PACKAGE_TYPE:-}" ]] || { echo "::error::PACKAGE_TYPE is required"; exit 1; }

source /work/publisher/common/repository-common.sh
source "/work/publisher/${PACKAGE_TYPE}/container-hooks.sh"

common_setup_gpg() {
  export GNUPGHOME=/root/.gnupg
  chmod 700 "$GNUPGHOME"
  gpg --batch --list-secret-keys "$FPR" >/dev/null
  export FPR
}

common_write_index() {
  local title
  title="$(package_index_title)"
  printf '<!doctype html>\n<html><head><meta charset="utf-8"><title>%s</title></head>\n<body><h1>%s</h1></body></html>\n' "$title" "$title" > /work/public/index.html
}

validate_package_queue() {
  local queue_dir="${PACKAGE_BUILD_QUEUE_DIR:-/work/package-build-queue}"
  if ! compgen -G "$queue_dir/*.env" >/dev/null; then
    echo "::error::$(package_queue_contract_message)"
    exit 1
  fi
}

package_install_tools
common_setup_gpg
package_configure_signing
package_init_dirs
init_package_metadata "$PACKAGE_TYPE" /work/public/publisher-metadata
package_export_public_key
package_install_queue_shim
prepare_app_workdirs_and_run_build_scripts /work/work "${BUILD_SCRIPT:-}"
validate_package_queue
package_build_all_targets
package_finalize_metadata
common_write_index
