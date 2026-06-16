#!/usr/bin/env bash
# Shared repository build helpers used by Flatpak, RPM, and DEB paths.

repo_nonempty_lines() {
  sed '/^[[:space:]]*$/d'
}

load_apps_and_sources() {
  local apps_text="${1:-${APP:-}}"
  local sources_text="${2:-${SOURCE_GIT:-}}"
  mapfile -t APPS < <(printf '%s\n' "$apps_text" | repo_nonempty_lines)
  mapfile -t SOURCES < <(printf '%s\n' "$sources_text" | repo_nonempty_lines)
  [[ ${#APPS[@]} -gt 0 ]] || { echo "::error::At least one app-id is required"; exit 1; }
  primary_app="${APPS[0]}"
}

source_for_app_index() {
  local index="$1"
  printf '%s\n' "${SOURCES[$index]:-${SOURCES[0]:-}}"
}

prepare_app_workdir() {
  local app="$1" source_git="${2:-}" root="${3:-$PWD/work}"
  local app_work="$root/$app"
  mkdir -p "$app_work"

  if [[ -n "$source_git" ]]; then
    if [[ -e "$app_work/source" ]]; then
      echo "::error::Source checkout path already exists: $app_work/source"
      exit 1
    fi
    git clone --recursive "$source_git" "$app_work/source"
    cp -a "$app_work/source/." "$app_work/"
  fi

  printf '%s\n' "$app_work"
}

run_user_build_script() {
  local app_work="$1" build_script="${2:-}"
  [[ -n "$build_script" ]] || return 0

  (
    cd "$app_work"
    if [[ "$build_script" != *$'\n'* ]]; then
      local build_cmd first_word
      build_cmd="$build_script"
      first_word="${build_cmd%%[[:space:]]*}"
      if [[ -f "$first_word" ]]; then
        chmod +x "$first_word"
        if [[ "$first_word" != */* ]]; then
          build_cmd="./$build_cmd"
        fi
        bash -lc "$build_cmd"
        exit 0
      fi
    fi

    printf '%s\n' "$build_script" > build-extra.sh
    bash build-extra.sh
  )
}

prepare_app_workdirs_and_run_build_scripts() {
  local work_root="$1" build_script="${2:-}"
  local app source_git app_work i
  load_apps_and_sources "${APP:-}" "${SOURCE_GIT:-}"
  for i in "${!APPS[@]}"; do
    app="${APPS[$i]}"
    source_git="$(source_for_app_index "$i")"
    app_work="$(prepare_app_workdir "$app" "$source_git" "$work_root")"
    SOURCE_ID="$app" PATCH_ROOT="$app_work/patches" run_user_build_script "$app_work" "$build_script"
  done
}

target_arch() {
  local target="$1"
  printf '%s\n' "${target##*-}"
}

target_family() {
  local target="$1" arch
  arch="$(target_arch "$target")"
  if [[ "$target" == *"-$arch" ]]; then
    printf '%s\n' "${target%-${arch}}"
  else
    printf '%s\n' "$target"
  fi
}

target_label() {
  local family="$1"
  printf '%s\n' "$family" | sed -E 's/-/ /g; s/(^| )([a-z])/'"'\1'"'\U\2/g'
}

deb_target_suite() {
  local family="$1"
  case "$family" in
    ubuntu-*) printf '%s\n' "${family#ubuntu-}" ;;
    debian-*) printf '%s\n' "${family#debian-}" ;;
    *) printf '%s\n' "$family" ;;
  esac
}

deb_target_mirror() {
  local family="$1"
  case "$family" in
    ubuntu-*) printf 'http://archive.ubuntu.com/ubuntu\n' ;;
    *) printf 'http://deb.debian.org/debian\n' ;;
  esac
}

repo_info_for_target() {
  local package_type="$1" app="$2" target="$3" target_layout="${4:-true}"
  local arch family
  arch="$(target_arch "$target")"
  family="$(target_family "$target")"
  if [[ "$target_layout" == true ]]; then
    case "$package_type" in
      rpm) printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${app}-${family}" "rpm/${app}/${family}/${arch}" "${app}-${family}.repo" "$family" "$arch" "$(target_label "$family")" ;;
      deb) printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${app}-${family}" "deb/${app}/${family}/${arch}" "${app}-${family}.sources" "$family" "$arch" "$(target_label "$family")" ;;
      *) echo "::error::Unsupported package type for repo info: $package_type"; exit 1 ;;
    esac
  else
    case "$package_type" in
      rpm) printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "rpm/${app}" "${app}.repo" "$target" "$arch" "$target" ;;
      deb) printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "deb/${app}" "${app}.sources" "$target" "$arch" "$target" ;;
      *) echo "::error::Unsupported package type for repo info: $package_type"; exit 1 ;;
    esac
  fi
}

init_package_metadata() {
  local package_type="$1" metadata_dir="${2:-/work/public/publisher-metadata}"
  mkdir -p "$metadata_dir"
  touch "$metadata_dir/packages.txt"
  : > "$metadata_dir/repos.tsv"
  : > "$metadata_dir/targets.txt"
}

metadata_sort_unique() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    sort -u "$file" -o "$file"
  done
}

metadata_append_package() {
  local package_name="$1" metadata_dir="${2:-/work/public/publisher-metadata}"
  [[ -n "$package_name" ]] || return 0
  mkdir -p "$metadata_dir"
  printf '%s\n' "$package_name" >> "$metadata_dir/packages.txt"
}


layered_file_candidates() {
  local root="$1" family="$2" target="$3" relative_path="$4"
  printf '%s\n' \
    "$root/$relative_path" \
    "$root/$family/$relative_path" \
    "$root/$target/$relative_path"
}

layered_glob_files() {
  local root="$1" family="$2" target="$3" relative_glob="$4"
  local candidate
  while IFS= read -r candidate; do
    # Expand the glob here so callers can share the same app/family/target layering rules
    # without duplicating package-format-specific discovery logic.
    compgen -G "$candidate" || true
  done < <(layered_file_candidates "$root" "$family" "$target" "$relative_glob") | sort -u
}

layered_patch_candidates() {
  local patch_root="$1" family="$2" target="$3" filename="$4"
  printf '%s\n' \
    "$patch_root/$filename" \
    "$patch_root/$family/$filename" \
    "$patch_root/$target/$filename"
}

apply_git_layered_patches() {
  local src_dir="$1" patch_root="$2" family="$3" target="$4"
  shift 4
  local filename patch_file
  for filename in "$@"; do
    while IFS= read -r patch_file; do
      if [[ -f "$patch_file" ]]; then
        echo "Applying patch: $patch_file"
        git -C "$src_dir" apply --unidiff-zero --verbose "$patch_file" || git -C "$src_dir" apply --verbose "$patch_file" || patch -d "$src_dir" -p1 < "$patch_file"
      fi
    done < <(layered_patch_candidates "$patch_root" "$family" "$target" "$filename")
  done
}

copy_layered_files() {
  local dest_dir="$1" patch_root="$2" family="$3" target="$4"
  shift 4
  local filename source_file
  for filename in "$@"; do
    while IFS= read -r source_file; do
      if [[ -f "$source_file" ]]; then
        echo "Copying layered file: $source_file"
        cp -f "$source_file" "$dest_dir/"
      fi
    done < <(layered_patch_candidates "$patch_root" "$family" "$target" "$filename")
  done
}

hash_layered_files() {
  local patch_root="$1" family="$2" target="$3"
  shift 3
  local filename file
  for filename in "$@"; do
    while IFS= read -r file; do
      [[ ! -f "$file" ]] || sha256sum "$file"
    done < <(layered_patch_candidates "$patch_root" "$family" "$target" "$filename")
  done
}

queue_safe_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

queue_write_env() {
  local queue_dir="$1" safe_id="$2"
  shift 2
  mkdir -p "$queue_dir"

  local queue_file tmp
  queue_file="$queue_dir/$(date +%s%N)-$$-${safe_id}.env"
  tmp="${queue_file}.tmp"
  : > "$tmp"

  while [[ $# -gt 0 ]]; do
    local key="$1" value="$2"
    shift 2
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
  done

  mv "$tmp" "$queue_file"
}

queue_list_files() {
  local queue_dir="$1"
  find "$queue_dir" -type f -name '*.env' | sort
}
