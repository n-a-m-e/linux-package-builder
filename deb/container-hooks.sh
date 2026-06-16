#!/usr/bin/env bash
# DEB-specific hooks for the shared container build driver.

package_container_image() {
  printf 'debian:stable\n'
}

package_install_tools() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-utils \
    ca-certificates \
    curl \
    debian-archive-keyring \
    devscripts \
    dpkg-dev \
    fakeroot \
    findutils \
    git \
    gnupg \
    gzip \
    patch \
    pbuilder \
    python3 \
    sed \
    tar \
    ubuntu-keyring \
    xz-utils
}

package_configure_signing() {
  :
}

package_init_dirs() {
  mkdir -p /work/public /work/deb-build /work/package-build-queue /package-cache/deb/pbuilder
}

package_export_public_key() {
  gpg --batch --armor --export "$FPR" > /work/public/GPG-KEY-repo
}

package_install_queue_shim() {
  install -m 0755 /work/publisher/common/package-build-queue.sh /usr/local/bin/package-build-queue
}

package_queue_contract_message() {
  printf '%s\n' 'DEB build contract requires build-script to declare all package inputs with package-build-queue add. Build order is resolved by the strict effective graph.'
}

package_index_title() {
  printf 'DEB repository\n'
}

ensure_pbuilder_base() {
  local target="$1" family="$2" suite="$3" arch="$4" mirror="$5"
  local base_tgz="/package-cache/deb/pbuilder/${target}/base.tgz"
  mkdir -p "$(dirname "$base_tgz")"
  if [[ ! -f "$base_tgz" ]]; then
    pbuilder --create \
      --basetgz "$base_tgz" \
      --distribution "$suite" \
      --architecture "$arch" \
      --mirror "$mirror" \
      --debootstrapopts --variant=buildd
  else
    pbuilder --update --basetgz "$base_tgz" || true
  fi
  printf '%s\n' "$base_tgz"
}

prepare_source_tree() {
  local src_root="$1" target="$2" family="$3" source_dir="$4" package_name="$5"
  rm -rf "$src_root"
  mkdir -p "$src_root"
  cp -a "$source_dir/." "$src_root/"
  rm -rf "$src_root/source"
  if [[ -d "$src_root/.git" ]]; then
    git -C "$src_root" reset --hard || true
  else
    git -C "$src_root" init
    git -C "$src_root" add .
    git -C "$src_root" -c user.name=builder -c user.email=builder@example.invalid commit -m init >/dev/null || true
  fi
  local patch_root="$source_dir/patches"
  apply_git_layered_patches "$src_root" "$patch_root" "$family" "$target" \
    "debian.patch" \
    "${package_name}.debian.patch"
  [[ -d "$src_root/debian" ]] || { echo "::error::Missing debian/ directory for $package_name"; exit 1; }
}

build_source_package_from_dir() {
  local target="$1" family="$2" package_name="$3" source_dir="$4" build_src="$5"
  prepare_source_tree "$build_src" "$target" "$family" "$source_dir" "$package_name"
  (cd "$build_src" && dpkg-buildpackage -S -us -uc)
}

publish_deb_repo() {
  local repo_dir="$1" repo_id="$2" arch="$3" deb
  mkdir -p "$repo_dir/pool"
  shopt -s nullglob
  local debs=("$repo_dir"/pool/*.deb)
  [[ ${#debs[@]} -gt 0 ]] || { echo "::error::No DEB files found in $repo_dir/pool"; exit 1; }
  for deb in "${debs[@]}"; do
    dpkg-deb -f "$deb" Package >> /work/public/publisher-metadata/packages.txt
  done
  (
    cd "$repo_dir"
    apt-ftparchive packages pool > Packages
    gzip -kf Packages
    apt-ftparchive release . > Release
    gpg --batch --yes --armor --detach-sign -u "$FPR" -o Release.gpg Release
    gpg --batch --yes --clearsign -u "$FPR" -o InRelease Release
  )
}

write_sources_file() {
  local repo_id="$1" repo_path="$2" repo_file="$3" target_label_name="$4"
  {
    printf 'Types: deb\n'
    printf 'URIs: https://%s.github.io/%s/%s\n' "$REPO_OWNER" "$REPO_NAME" "$repo_path"
    printf 'Suites: ./\n'
    printf 'Signed-By: /usr/share/keyrings/repository-signing.gpg\n'
  } > "/work/public/${repo_file}"
  printf '%s\t%s\t%s\t%s\n' "$repo_id" "$repo_file" "$repo_path" "$target_label_name" >> /work/public/publisher-metadata/repos.tsv
}

build_dsc_with_pbuilder() {
  local target="$1" family="$2" suite="$3" arch="$4" mirror="$5" repo_dir="$6" result_dir="$7" dsc="$8"
  local base_tgz
  base_tgz="$(ensure_pbuilder_base "$target" "$family" "$suite" "$arch" "$mirror")"
  pbuilder --build \
    --basetgz "$base_tgz" \
    --buildresult "$result_dir" \
    "$dsc"
  find "$result_dir" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$repo_dir/pool/" \;
}

build_queued_package_for_target() {
  local queue_file="$1" target="$2" repo_id="$3" repo_path="$4" family="$5" arch="$6"
  # shellcheck source=/dev/null
  source "$queue_file"
  local package_name="${PACKAGE:-${SOURCE_ID:-package}}"
  local source_id="${SOURCE_ID:-$primary_app}"
  local source_dir queue_work build_root result_dir repo_dir suite mirror dsc
  queue_work="/work/deb-source-src/${target}/${package_name}"
  build_root="/work/deb-build/${target}/${package_name}"
  result_dir="/work/deb-result/${target}/${package_name}"
  repo_dir="/work/public/${repo_path}"
  mkdir -p "$repo_dir/pool" "$build_root" "$result_dir"

  if [[ -n "${CLONE_URL:-}" ]]; then
    rm -rf "$queue_work"
    git clone --recursive "$CLONE_URL" "$queue_work"
    (cd "$queue_work" && git checkout "${REF:-main}")
    source_dir="$queue_work/${SUBDIR:-.}"
  else
    source_dir="/work/work/${source_id}/${SUBDIR:-.}"
  fi
  [[ -d "$source_dir" ]] || { echo "::error::Missing DEB queue source directory: $source_dir"; exit 1; }

  build_source_package_from_dir "$target" "$family" "$package_name" "$source_dir" "$build_root/src"
  dsc="$(find "$build_root" -maxdepth 1 -type f -name '*.dsc' -print -quit)"
  [[ -n "${dsc:-}" && -f "$dsc" ]] || { echo "::error::No DSC created for $package_name"; exit 1; }
  suite="$(deb_target_suite "$family")"
  mirror="$(deb_target_mirror "$family")"
  build_dsc_with_pbuilder "$target" "$family" "$suite" "$arch" "$mirror" "$repo_dir" "$result_dir" "$dsc"
}


deb_graph_node_id() {
  local queue_file="$1"
  (
    # shellcheck source=/dev/null
    source "$queue_file"
    queue_safe_id "${PACKAGE}-${SUBDIR:-.}"
  )
}

deb_graph_provider() {
  local providers_file="$1" dep_name="$2"
  awk -F '\t' -v p="$dep_name" '$1==p{print $2; exit}' "$providers_file"
}

deb_graph_validate_providers() {
  local providers_file="$1"
  awk -F '\t' '
    NF>=2 && seen[$1] && seen[$1] != $2 { print $1 "\t" seen[$1] "\t" $2; bad=1 }
    NF>=2 && !seen[$1] { seen[$1]=$2 }
    END { exit bad ? 1 : 0 }
  ' "$providers_file" > "${providers_file}.ambiguous" || {
    while IFS=$'\t' read -r name a b; do
      echo "::error::ambiguous internal DEB provider '$name': $a and $b"
    done < "${providers_file}.ambiguous"
    exit 1
  }
}

deb_graph_prepare_source() {
  local queue_file="$1" graph_root="$2" target="$3" family="$4" node_id="$5"
  # shellcheck source=/dev/null
  source "$queue_file"
  local package_name="${PACKAGE:-${SOURCE_ID:-package}}"
  local source_id="${SOURCE_ID:-$primary_app}"
  local source_dir queue_work prepared
  queue_work="$graph_root/queue-src/$node_id"
  prepared="$graph_root/prepared/$node_id"

  if [[ -n "${CLONE_URL:-}" ]]; then
    rm -rf "$queue_work"
    git clone --recursive "$CLONE_URL" "$queue_work" >/dev/null
    (cd "$queue_work" && git checkout "${REF:-main}" >/dev/null)
    source_dir="$queue_work/${SUBDIR:-.}"
  else
    source_dir="/work/work/${source_id}/${SUBDIR:-.}"
  fi
  [[ -d "$source_dir" ]] || { echo "::error::Missing DEB graph source directory: $source_dir"; exit 1; }
  prepare_source_tree "$prepared" "$target" "$family" "$source_dir" "$package_name" >/dev/stderr
  printf '%s\n' "$prepared"
}

deb_order_queue_files_for_target() {
  local target="$1" family="$2"
  local graph_root="/work/package-graph/deb/$target"
  local queue_file node_id prepared raw_node dep prov
  rm -rf "$graph_root"
  mkdir -p "$graph_root"
  : > "$graph_root/nodes.tsv"
  : > "$graph_root/node-queue.tsv"
  : > "$graph_root/providers.raw.tsv"
  : > "$graph_root/raw-builddeps.tsv"
  : > "$graph_root/raw-runtimedeps.tsv"
  : > "$graph_root/builddeps.tsv"
  : > "$graph_root/runtimedeps.tsv"

  mapfile -t queue_items < <(queue_list_files /work/package-build-queue)
  [[ ${#queue_items[@]} -gt 0 ]] || { echo "::error::No DEB package declarations were queued"; exit 1; }

  for queue_file in "${queue_items[@]}"; do
    node_id="$(deb_graph_node_id "$queue_file")"
    printf '%s\n' "$node_id" >> "$graph_root/nodes.tsv"
    printf '%s\t%s\n' "$node_id" "$queue_file" >> "$graph_root/node-queue.tsv"
    prepared="$(deb_graph_prepare_source "$queue_file" "$graph_root" "$target" "$family" "$node_id" | tail -n1)"
    [[ -f "$prepared/debian/control" ]] || { echo "::error::Missing debian/control for graph node $node_id"; exit 1; }
    python3 /work/publisher/common/deb-control-graph.py \
      --control "$prepared/debian/control" \
      --node "$node_id" \
      --providers-out "$graph_root/providers.raw.tsv" \
      --raw-builddeps-out "$graph_root/raw-builddeps.tsv" \
      --raw-runtimedeps-out "$graph_root/raw-runtimedeps.tsv"
  done

  sort -u "$graph_root/providers.raw.tsv" -o "$graph_root/providers.tsv"
  deb_graph_validate_providers "$graph_root/providers.tsv"

  while IFS=$'\t' read -r raw_node dep _kind; do
    [[ -n "${raw_node:-}" && -n "${dep:-}" ]] || continue
    prov="$(deb_graph_provider "$graph_root/providers.tsv" "$dep")"
    [[ -z "$prov" || "$prov" == "$raw_node" ]] || printf '%s\t%s\t%s\n' "$prov" "$raw_node" "$dep" >> "$graph_root/builddeps.tsv"
  done < "$graph_root/raw-builddeps.tsv"

  while IFS=$'\t' read -r raw_node dep _kind; do
    [[ -n "${raw_node:-}" && -n "${dep:-}" ]] || continue
    prov="$(deb_graph_provider "$graph_root/providers.tsv" "$dep")"
    [[ -z "$prov" || "$prov" == "$raw_node" ]] || printf '%s\t%s\t%s\n' "$prov" "$raw_node" "$dep" >> "$graph_root/runtimedeps.tsv"
  done < "$graph_root/raw-runtimedeps.tsv"

  sort -u "$graph_root/builddeps.tsv" -o "$graph_root/builddeps.tsv"
  sort -u "$graph_root/runtimedeps.tsv" -o "$graph_root/runtimedeps.tsv"

  python3 /work/publisher/common/effective-build-graph.py \
    --nodes "$graph_root/nodes.tsv" \
    --builddeps "$graph_root/builddeps.tsv" \
    --runtimedeps "$graph_root/runtimedeps.tsv" \
    --effective-edges-out "$graph_root/effective-builddeps.tsv" \
    > "$graph_root/order.txt"

  while read -r node_id; do
    awk -F '\t' -v n="$node_id" '$1==n{print $2; exit}' "$graph_root/node-queue.tsv"
  done < "$graph_root/order.txt"
}

build_target_repo() {
  local target="$1" repo_id repo_path repo_file family arch label repo_dir queue_file
  IFS=$'\t' read -r repo_id repo_path repo_file family arch label < <(repo_info_for_target deb "$primary_app" "$target" true)
  repo_dir="/work/public/${repo_path}"
  mkdir -p "$repo_dir/pool"

  mapfile -t ordered_queue_files < <(deb_order_queue_files_for_target "$target" "$family")
  for queue_file in "${ordered_queue_files[@]}"; do
    build_queued_package_for_target "$queue_file" "$target" "$repo_id" "$repo_path" "$family" "$arch"
  done

  publish_deb_repo "$repo_dir" "$repo_id" "$arch"
  write_sources_file "$repo_id" "$repo_path" "$repo_file" "$label"
  printf '%s\n' "$target" >> /work/public/publisher-metadata/targets.txt
}

package_build_all_targets() {
  mapfile -t DEB_TARGET_LIST < <(printf '%s\n' "${TARGETS:-}" | sed '/^[[:space:]]*$/d')
  [[ ${#DEB_TARGET_LIST[@]} -gt 0 ]] || { echo "::error::DEB requires targets."; exit 1; }

  local target
  for target in "${DEB_TARGET_LIST[@]}"; do
    echo "Building DEB target: $target"
    build_target_repo "$target"
  done
}

package_finalize_metadata() {
  metadata_sort_unique \
    /work/public/publisher-metadata/packages.txt \
    /work/public/publisher-metadata/repos.tsv \
    /work/public/publisher-metadata/targets.txt
}
