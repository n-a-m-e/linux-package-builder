#!/usr/bin/env bash
set -euo pipefail

source publisher/common/repository-common.sh

rm -rf work flatpak-files.txt
mkdir -p work

load_apps_and_sources "$APP" "$SOURCE_GIT"

for i in "${!APPS[@]}"; do
  app="${APPS[$i]}"
  source_git="$(source_for_app_index "$i")"
  app_work="$(prepare_app_workdir "$app" "$source_git" "$PWD/work")"

  run_user_build_script "$app_work" "${BUILD_SCRIPT:-}"

  found=""
  for ext in yaml yml json; do
    if [[ -f "$app_work/$app.$ext" ]]; then
      found="$app_work/$app.$ext"
      break
    fi
  done

  [[ -n "$found" ]] || { echo "::error::Missing Flatpak manifest for $app. Expected $app.yaml, $app.yml, or $app.json"; exit 1; }
  printf '%s\n' "$found" >> flatpak-files.txt
done

{
  echo 'files<<EOF'
  cat flatpak-files.txt
  echo 'EOF'
} >> "$GITHUB_OUTPUT"
